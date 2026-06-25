import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../data/local/database.dart';
import '../data/local/secure_storage.dart';
import '../data/models/group.dart';
import '../data/models/group_message.dart';
import '../services/groups_service.dart';
import '../services/signaling_service.dart';

class GroupJoinRequest {
  final String groupId;
  final String groupName;
  final String userId;
  final String username;
  final String? avatarUrl;
  const GroupJoinRequest({
    required this.groupId,
    required this.groupName,
    required this.userId,
    required this.username,
    this.avatarUrl,
  });
}

class GroupsProvider extends ChangeNotifier {
  final GroupsService _service;
  final SignalingService _signaling;
  final _db = LocalDatabase.instance;
  final _uuid = const Uuid();

  final Map<String, Group> _groups = {};
  final Map<String, List<GroupMessage>> _messages = {};
  final Map<String, int> _unreadCounts = {};
  final Map<String, String?> _typingUser = {}; // groupId → username
  final List<GroupJoinRequest> _pendingRequests = [];

  bool _isLoading = false;
  StreamSubscription<SignalingMessage>? _sub;

  List<Group> get groups {
    final list = _groups.values.toList();
    list.sort((a, b) {
      final at = a.lastMessageAt ?? a.createdAt;
      final bt = b.lastMessageAt ?? b.createdAt;
      return bt.compareTo(at);
    });
    return list;
  }

  bool get isLoading => _isLoading;
  List<GroupMessage> getMessages(String groupId) => _messages[groupId] ?? [];
  int getUnreadCount(String groupId) => _unreadCounts[groupId] ?? 0;
  String? getTypingUser(String groupId) => _typingUser[groupId];
  List<GroupJoinRequest> get pendingRequests => List.unmodifiable(_pendingRequests);
  int get totalPendingRequests => _pendingRequests.length;

  String? _activeGroupId;

  GroupsProvider(this._service, this._signaling) {
    _listenToSignaling();
  }

  void setActiveGroup(String groupId) {
    _activeGroupId = groupId;
    _unreadCounts[groupId] = 0;
    notifyListeners();
  }

  void clearActiveGroup() => _activeGroupId = null;

  void _listenToSignaling() {
    _sub = _signaling.stream.listen((msg) async {
      switch (msg.event) {
        case SignalingEvent.groupMessage:
          await _handleIncomingMessage(msg.data);

        case SignalingEvent.groupMessageEdited:
          final msgId = msg.data['message_id'] as String;
          final content = msg.data['new_content'] as String;
          final gid = msg.data['group_id'] as String;
          final editedAt = DateTime.tryParse(msg.data['edited_at'] as String? ?? '') ?? DateTime.now();
          await _db.updateGroupMessageContent(msgId, content, editedAt);
          _updateEdited(gid, msgId, content, editedAt);

        case SignalingEvent.groupMessageDeleted:
          final msgId = msg.data['message_id'] as String;
          final gid = msg.data['group_id'] as String;
          await _db.markGroupMessageDeleted(msgId);
          _updateDeleted(gid, msgId);

        case SignalingEvent.groupReactionAdded:
          final msgId = msg.data['message_id'] as String;
          final gid = msg.data['group_id'] as String;
          final raw = msg.data['reactions'];
          final reactions = (raw as Map<String, dynamic>).map(
            (k, v) => MapEntry(k, List<String>.from(v as List)),
          );
          await _db.updateGroupMessageReactions(msgId, reactions);
          _updateReactions(gid, msgId, reactions);

        case SignalingEvent.groupUserTyping:
          final gid = msg.data['group_id'] as String;
          final username = _groups[gid]
              ?.members
              .firstWhere((m) => m.userId == msg.data['user_id'],
                  orElse: () => GroupMember(
                    id: '', groupId: gid, userId: '', username: 'Someone',
                    virtualId: '', role: 'member', status: 'active',
                    joinedAt: DateTime.now(),
                  ))
              .username ?? 'Someone';
          _typingUser[gid] = username;
          notifyListeners();
          Future.delayed(const Duration(seconds: 4), () {
            if (_typingUser[gid] == username) {
              _typingUser.remove(gid);
              notifyListeners();
            }
          });

        case SignalingEvent.groupJoinRequest:
          final req = GroupJoinRequest(
            groupId: msg.data['group_id'] as String,
            groupName: msg.data['group_name'] as String,
            userId: msg.data['user_id'] as String,
            username: msg.data['username'] as String,
            avatarUrl: msg.data['avatar_url'] as String?,
          );
          _pendingRequests.removeWhere((r) => r.userId == req.userId && r.groupId == req.groupId);
          _pendingRequests.add(req);
          // Update group pending count
          if (_groups.containsKey(req.groupId)) {
            _groups[req.groupId] = _groups[req.groupId]!.copyWith(
              pendingCount: _groups[req.groupId]!.pendingCount + 1,
            );
          }
          notifyListeners();

        case SignalingEvent.groupMemberApproved:
          final gid = msg.data['group_id'] as String;
          // Reload group info
          _loadGroupDetail(gid);

        case SignalingEvent.groupMemberRejected:
          final gid = msg.data['group_id'] as String;
          _groups.remove(gid);
          notifyListeners();

        case SignalingEvent.groupMemberJoined:
          final gid = msg.data['group_id'] as String;
          // Remove from pending requests if we approved
          _pendingRequests.removeWhere((r) => r.userId == msg.data['user_id'] && r.groupId == gid);
          _loadGroupDetail(gid);

        case SignalingEvent.groupMemberLeft:
          final gid = msg.data['group_id'] as String;
          final userId = msg.data['user_id'] as String;
          final myId = await SecureStorage.getUserId();
          if (userId == myId) {
            _groups.remove(gid);
            _messages.remove(gid);
            _unreadCounts.remove(gid);
          } else {
            _loadGroupDetail(gid);
          }
          notifyListeners();

        case SignalingEvent.groupMemberPromoted:
          _loadGroupDetail(msg.data['group_id'] as String);

        case SignalingEvent.groupUpdated:
          final gid = msg.data['id'] as String;
          if (_groups.containsKey(gid)) {
            final updated = Group.fromJson(msg.data);
            _groups[gid] = _groups[gid]!.copyWith(
              name: updated.name,
              description: updated.description,
              avatarUrl: updated.avatarUrl,
            );
            notifyListeners();
          }

        case SignalingEvent.groupDeleted:
          final gid = msg.data['group_id'] as String;
          _groups.remove(gid);
          _messages.remove(gid);
          _unreadCounts.remove(gid);
          notifyListeners();

        default:
          break;
      }
    });
  }

  Future<void> _handleIncomingMessage(Map<String, dynamic> data) async {
    final myId = await SecureStorage.getUserId() ?? '';
    final msg = GroupMessage.fromJson(data, myId);
    await _db.upsertGroupMessage(msg);

    final existing = _messages[msg.groupId] ?? [];
    if (!existing.any((m) => m.id == msg.id)) {
      _messages[msg.groupId] = [...existing, msg];

      if (_activeGroupId != msg.groupId) {
        _unreadCounts[msg.groupId] = (_unreadCounts[msg.groupId] ?? 0) + 1;
      }

      // Update last message preview on group tile
      if (_groups.containsKey(msg.groupId)) {
        _groups[msg.groupId] = _groups[msg.groupId]!.copyWith(
          lastMessage: _messagePreview(msg.content, msg.attachmentType),
          lastMessageAt: msg.createdAt,
        );
      }

      notifyListeners();
    }
  }

  Future<void> loadGroups() async {
    _isLoading = true;
    notifyListeners();
    try {
      final list = await _service.fetchGroups();
      for (final g in list) {
        _groups[g.id] = g;
      }
      // Remove groups no longer active
      _groups.removeWhere((id, _) => !list.any((g) => g.id == id));
    } catch (e) {
      dev.log('[GroupsProvider] loadGroups error: $e');
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> _loadGroupDetail(String groupId) async {
    try {
      final g = await _service.fetchGroup(groupId);
      _groups[g.id] = _groups[g.id] != null
          ? _groups[g.id]!.copyWith(members: g.members, memberCount: g.memberCount)
          : g;
      // Refresh pending requests from members list
      _pendingRequests.removeWhere((r) => r.groupId == groupId);
      final pending = g.members.where((m) => m.isPending);
      for (final m in pending) {
        _pendingRequests.add(GroupJoinRequest(
          groupId: groupId,
          groupName: g.name,
          userId: m.userId,
          username: m.username,
          avatarUrl: m.avatarUrl,
        ));
      }
      notifyListeners();
    } catch (e) {
      dev.log('[GroupsProvider] _loadGroupDetail error: $e');
    }
  }

  Future<Group> createGroup({required String name, String? description, String? avatarUrl}) async {
    final g = await _service.createGroup(name: name, description: description, avatarUrl: avatarUrl);
    _groups[g.id] = g;
    notifyListeners();
    return g;
  }

  Future<Map<String, dynamic>> joinGroup(String code) async {
    return _service.joinGroup(code);
  }

  Future<void> loadMessages(String groupId) async {
    final myId = await SecureStorage.getUserId() ?? '';
    final msgs = await _service.fetchMessages(groupId, myId);
    final existing = {for (final m in (_messages[groupId] ?? [])) m.id: m};
    _messages[groupId] = msgs.map<GroupMessage>((m) {
      final cached = existing[m.id];
      return cached ?? m;
    }).toList();
    // Persist to local DB
    for (final m in _messages[groupId]!) {
      await _db.upsertGroupMessage(m);
    }
    if (_activeGroupId == groupId) _unreadCounts[groupId] = 0;
    notifyListeners();
  }

  Future<void> loadMessagesFromDb(String groupId) async {
    final msgs = await _db.getGroupMessages(groupId);
    if (msgs.isNotEmpty && (_messages[groupId]?.isEmpty ?? true)) {
      _messages[groupId] = msgs;
      notifyListeners();
    }
  }

  Future<void> sendMessage({
    required String groupId,
    required String content,
    String? replyToId,
    String? attachmentUrl,
    String? attachmentType,
    String? attachmentName,
    int? attachmentSize,
  }) async {
    final myId = await SecureStorage.getUserId() ?? '';
    final myUsername = await SecureStorage.getUsername() ?? '';
    final messageId = _uuid.v4();

    final optimistic = GroupMessage(
      id: messageId,
      groupId: groupId,
      senderId: myId,
      senderUsername: myUsername,
      content: content,
      replyToId: replyToId,
      attachmentUrl: attachmentUrl,
      attachmentType: attachmentType,
      attachmentName: attachmentName,
      attachmentSize: attachmentSize,
      createdAt: DateTime.now(),
      isOutgoing: true,
    );

    _messages[groupId] = [...(_messages[groupId] ?? []), optimistic];
    if (_groups.containsKey(groupId)) {
      _groups[groupId] = _groups[groupId]!.copyWith(
        lastMessage: _messagePreview(content, attachmentType),
        lastMessageAt: optimistic.createdAt,
      );
    }
    notifyListeners();

    _signaling.sendGroupMessage(
      groupId: groupId,
      messageId: messageId,
      content: content,
      replyToId: replyToId,
      attachmentUrl: attachmentUrl,
      attachmentType: attachmentType,
      attachmentName: attachmentName,
      attachmentSize: attachmentSize,
    );
  }

  Future<void> editMessage({
    required String groupId,
    required String messageId,
    required String newContent,
  }) async {
    final editedAt = DateTime.now();
    await _db.updateGroupMessageContent(messageId, newContent, editedAt);
    _updateEdited(groupId, messageId, newContent, editedAt);
    _signaling.emitGroupEditMessage(
      messageId: messageId,
      groupId: groupId,
      newContent: newContent,
    );
  }

  Future<void> deleteMessage({
    required String groupId,
    required String messageId,
  }) async {
    await _db.markGroupMessageDeleted(messageId);
    _updateDeleted(groupId, messageId);
    _signaling.emitGroupDeleteMessage(messageId: messageId, groupId: groupId);
  }

  void addReaction({
    required String groupId,
    required String messageId,
    required String emoji,
  }) {
    _signaling.emitGroupReaction(messageId: messageId, groupId: groupId, emoji: emoji);
  }

  Future<void> approveRequest(String groupId, String userId) async {
    await _service.approveRequest(groupId, userId);
    _pendingRequests.removeWhere((r) => r.userId == userId && r.groupId == groupId);
    if (_groups.containsKey(groupId)) {
      final pc = (_groups[groupId]!.pendingCount - 1).clamp(0, 999);
      _groups[groupId] = _groups[groupId]!.copyWith(pendingCount: pc);
    }
    await _loadGroupDetail(groupId);
    notifyListeners();
  }

  Future<void> rejectRequest(String groupId, String userId) async {
    await _service.rejectRequest(groupId, userId);
    _pendingRequests.removeWhere((r) => r.userId == userId && r.groupId == groupId);
    if (_groups.containsKey(groupId)) {
      final pc = (_groups[groupId]!.pendingCount - 1).clamp(0, 999);
      _groups[groupId] = _groups[groupId]!.copyWith(pendingCount: pc);
    }
    notifyListeners();
  }

  Future<void> removeMember(String groupId, String userId) async {
    await _service.removeMember(groupId, userId);
    await _loadGroupDetail(groupId);
  }

  Future<void> leaveGroup(String groupId) async {
    final myId = await SecureStorage.getUserId() ?? '';
    await _service.removeMember(groupId, myId);
    _groups.remove(groupId);
    _messages.remove(groupId);
    _unreadCounts.remove(groupId);
    notifyListeners();
  }

  Future<void> promoteToAdmin(String groupId, String userId) async {
    await _service.promoteToAdmin(groupId, userId);
    await _loadGroupDetail(groupId);
  }

  Future<Group> updateGroup(String groupId, {String? name, String? description, String? avatarUrl, String? themeId}) async {
    final updated = await _service.updateGroup(groupId, name: name, description: description, avatarUrl: avatarUrl, themeId: themeId);
    if (_groups.containsKey(groupId)) {
      _groups[groupId] = _groups[groupId]!.copyWith(
        name: updated.name,
        description: updated.description,
        avatarUrl: updated.avatarUrl,
        themeId: updated.themeId,
      );
    }
    notifyListeners();
    return updated;
  }

  Future<void> deleteGroup(String groupId) async {
    await _service.deleteGroup(groupId);
    _groups.remove(groupId);
    _messages.remove(groupId);
    _unreadCounts.remove(groupId);
    notifyListeners();
  }

  void sendTyping(String groupId) {
    _signaling.sendGroupTyping(groupId: groupId);
  }

  static String _messagePreview(String content, String? attachmentType) {
    if (content.isNotEmpty) return content;
    switch (attachmentType) {
      case 'image': return '📷 Photo';
      case 'gif': return '🎞 GIF';
      case 'video': return '🎥 Video';
      case 'audio': return '🎤 Voice note';
      case 'file': return '📎 File';
      default: return attachmentType != null ? '📎 $attachmentType' : '';
    }
  }

  Group? _groupOrNull(String groupId) => _groups[groupId];
  Group? groupById(String groupId) => _groups[groupId];

  Future<Group?> fetchGroupDetail(String groupId) async {
    try {
      final g = await _service.fetchGroup(groupId);
      _groups[g.id] = _groups[g.id] != null
          ? _groups[g.id]!.copyWith(members: g.members, memberCount: g.memberCount, pendingCount: g.pendingCount)
          : g;
      notifyListeners();
      return _groups[g.id];
    } catch (_) {
      return null;
    }
  }

  void _updateEdited(String groupId, String msgId, String content, DateTime editedAt) {
    final msgs = _messages[groupId];
    if (msgs == null) return;
    final idx = msgs.indexWhere((m) => m.id == msgId);
    if (idx != -1) {
      _messages[groupId]![idx] = msgs[idx].copyWith(content: content, editedAt: editedAt);
      notifyListeners();
    }
  }

  void _updateDeleted(String groupId, String msgId) {
    final msgs = _messages[groupId];
    if (msgs == null) return;
    final idx = msgs.indexWhere((m) => m.id == msgId);
    if (idx != -1) {
      _messages[groupId]![idx] = msgs[idx].copyWith(isDeleted: true);
      notifyListeners();
    }
  }

  void _updateReactions(String groupId, String msgId, Map<String, List<String>> reactions) {
    final msgs = _messages[groupId];
    if (msgs == null) return;
    final idx = msgs.indexWhere((m) => m.id == msgId);
    if (idx != -1) {
      _messages[groupId]![idx] = msgs[idx].copyWith(reactions: reactions);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
