import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/local/database.dart';
import '../data/local/secure_storage.dart';
import '../data/models/message.dart';
import '../services/messaging_service.dart';
import '../services/notification_service.dart';
import '../services/signaling_service.dart';

class MessagesProvider extends ChangeNotifier {
  final MessagingService _messaging;
  final SignalingService _signaling;
  final _db = LocalDatabase.instance;

  final Map<String, List<Message>> _chats = {};
  final Map<String, int> _unreadCounts = {};
  final Set<String> _loadedPeerIds = {}; // peers explicitly opened this session
  StreamSubscription<SignalingMessage>? _sub;

  String? _typingPeerId;
  Timer? _typingTimer;
  String? _activeChatPeerId;

  MessagesProvider(this._messaging, this._signaling) {
    _listenToSignaling();
    NotificationService.onMessageReply = _handleNotificationReply;
    _processPendingReplies();
    _initUnreadCounts();
  }

  Future<void> _initUnreadCounts() async {
    final myId = await SecureStorage.getUserId() ?? '';
    if (myId.isEmpty) return;

    final lastMessages = await _db.getLastMessages(myId);
    final counts = await _db.getUnreadCounts(myId);

    // Seed _chats with the last known message so contact tiles show a preview
    // immediately on cold start (before WebSocket delivers new messages).
    for (final entry in lastMessages.entries) {
      if (!_chats.containsKey(entry.key)) {
        final msg = entry.value;
        _chats[entry.key] = [msg.copyWith(decryptedContent: msg.encryptedContent)];
      }
    }

    if (counts.isNotEmpty) _unreadCounts.addAll(counts);

    if (lastMessages.isNotEmpty || counts.isNotEmpty) notifyListeners();
  }

  List<Message> getChat(String peerId) => _chats[peerId] ?? [];
  bool isTyping(String peerId) => _typingPeerId == peerId;
  int getUnreadCount(String peerId) => _unreadCounts[peerId] ?? 0;

  void setActiveChat(String peerId) {
    _activeChatPeerId = peerId;
    _unreadCounts[peerId] = 0;
    notifyListeners();
  }

  void clearActiveChat() {
    _activeChatPeerId = null;
  }

  void _listenToSignaling() {
    _sub = _signaling.stream.listen((msg) async {
      switch (msg.event) {
        case SignalingEvent.newMessage:
          await _handleIncomingMessage(msg.data);

        case SignalingEvent.messageDelivered:
          final msgId = msg.data['message_id'] as String;
          final recipId = msg.data['recipient_id'] as String;
          await _db.updateMessageStatus(msgId, MessageStatus.delivered);
          _updateStatusInCache(recipId, msgId, MessageStatus.delivered);

        case SignalingEvent.messageAck:
          final msgId = msg.data['message_id'] as String;
          final recipId = msg.data['recipient_id'] as String;
          final status = (msg.data['status'] as String?) == 'delivered'
              ? MessageStatus.delivered
              : MessageStatus.sent;
          await _db.updateMessageStatus(msgId, status);
          _updateStatusInCache(recipId, msgId, status);

        case SignalingEvent.connected:
          await _messaging.flushPendingMessages();
          await _processPendingReplies();
          // Only refresh chats that were explicitly opened this session.
          // Seeded-only chats (_initFromLocalDb) are excluded to avoid
          // pulling stale 'read' statuses from the server onto messages
          // that are still in-flight.
          for (final peerId in _loadedPeerIds.toList()) {
            await loadChat(peerId);
          }

        case SignalingEvent.userTyping:
          _typingPeerId = msg.data['sender_id'] as String;
          _typingTimer?.cancel();
          _typingTimer = Timer(const Duration(seconds: 4), () {
            _typingPeerId = null;
            notifyListeners();
          });
          notifyListeners();

        case SignalingEvent.messagesRead:
          final msgIds = (msg.data['message_ids'] as List).cast<String>();
          final peerId = msg.data['reader_id'] as String;
          for (final id in msgIds) {
            await _db.updateMessageStatus(id, MessageStatus.read);
            _updateStatusInCache(peerId, id, MessageStatus.read);
          }

        case SignalingEvent.messageEdited:
          final msgId = msg.data['message_id'] as String;
          final newContent = msg.data['new_content'] as String;
          final editedAt =
              DateTime.tryParse(msg.data['edited_at'] as String? ?? '') ??
                  DateTime.now();
          await _db.updateMessageContent(msgId, newContent, editedAt);
          _updateEditedInCache(msgId, newContent, editedAt);

        case SignalingEvent.messageDeleted:
          final msgId = msg.data['message_id'] as String;
          await _db.markMessageDeleted(msgId);
          _updateDeletedInCache(msgId);

        case SignalingEvent.reactionAdded:
          final msgId = msg.data['message_id'] as String;
          final raw = msg.data['reactions'];
          final reactions = (raw as Map<String, dynamic>).map(
            (k, v) => MapEntry(k, List<String>.from(v as List)),
          );
          await _db.updateMessageReactions(msgId, reactions);
          _updateReactionsInCache(msgId, reactions);

        default:
          break;
      }
    });
  }

  Future<void> _handleIncomingMessage(Map<String, dynamic> data) async {
    final myId = await SecureStorage.getUserId() ?? '';
    final senderId = data['sender_id'] as String;
    final createdAt = data['created_at'] != null
        ? DateTime.tryParse(data['created_at'] as String) ?? DateTime.now()
        : DateTime.now();

    final msg = Message(
      id: data['message_id'] as String,
      senderId: senderId,
      recipientId: myId,
      encryptedContent: data['encrypted_content'] as String,
      nonce: data['nonce'] as String? ?? '',
      status: MessageStatus.delivered,
      createdAt: createdAt,
      isOutgoing: false,
      replyToId: data['reply_to_id'] as String?,
    );

    // No encryption — content is plaintext
    final decrypted = msg.copyWith(decryptedContent: msg.encryptedContent);
    await _db.upsertMessage(msg);

    final existing = _chats[senderId] ?? [];
    if (!existing.any((m) => m.id == msg.id)) {
      _chats[senderId] = [...existing, decrypted];

      final isActiveSender = _activeChatPeerId == senderId;
      final appState = SchedulerBinding.instance.lifecycleState;
      final isBackground = appState == AppLifecycleState.paused ||
          appState == AppLifecycleState.detached ||
          appState == AppLifecycleState.hidden;

      if (isBackground || !isActiveSender) {
        // Increment unread badge
        _unreadCounts[senderId] = (_unreadCounts[senderId] ?? 0) + 1;
      }

      // Immediately send read receipt if this chat is currently open
      if (isActiveSender && !isBackground) {
        await markMessagesRead(senderId);
      }

      if (isBackground) {
        // Only show system notification when app is backgrounded
        final senderName = data['sender_username'] as String? ?? 'New message';
        final senderVirtualId = data['sender_virtual_id'] as String? ?? '';
        final preview = msg.encryptedContent.length > 60
            ? '${msg.encryptedContent.substring(0, 60)}…'
            : msg.encryptedContent;
        await NotificationService.showMessageNotification(
          senderName: senderName,
          preview: preview,
          senderVirtualId: senderVirtualId,
        );
      }

      notifyListeners();
    }
  }

  Future<void> loadChat(String peerId) async {
    _loadedPeerIds.add(peerId);
    final msgs = await _messaging.fetchMessages(peerId);
    final existing = {for (final m in (_chats[peerId] ?? [])) m.id: m};
    _chats[peerId] = msgs.map((m) {
      final cached = existing[m.id];
      return m.copyWith(
        decryptedContent: cached?.decryptedContent ?? m.decryptedContent,
        reactions: (cached?.reactions.isNotEmpty == true)
            ? cached!.reactions
            : m.reactions,
        // Never downgrade status — keep the highest known state
        status: cached != null ? _maxStatus(m.status, cached.status) : m.status,
      );
    }).toList();

    // Recount unread so the badge is accurate after app restart
    if (_activeChatPeerId != peerId) {
      _unreadCounts[peerId] = _chats[peerId]!
          .where((m) => !m.isOutgoing && m.status != MessageStatus.read)
          .length;
    }

    notifyListeners();
  }

  static MessageStatus _maxStatus(MessageStatus a, MessageStatus b) {
    const order = MessageStatus.values; // pending, sent, delivered, read
    return order.indexOf(a) >= order.indexOf(b) ? a : b;
  }

  Future<void> sendMessage({
    required String recipientId,
    required String recipientVirtualId,
    required String recipientPublicKey,
    required String plaintext,
    String? replyToId,
  }) async {
    final msg = await _messaging.sendMessage(
      recipientId: recipientId,
      recipientVirtualId: recipientVirtualId,
      recipientPublicKey: recipientPublicKey,
      plaintext: plaintext,
      replyToId: replyToId,
    );

    final shown =
        msg.copyWith(decryptedContent: plaintext, status: MessageStatus.pending);
    _chats[recipientId] = [...(_chats[recipientId] ?? []), shown];
    notifyListeners();
  }

  Future<void> editMessage({
    required String peerId,
    required String messageId,
    required String newContent,
    required String recipientVirtualId,
  }) async {
    final editedAt = DateTime.now();
    await _messaging.editMessage(
      messageId: messageId,
      newContent: newContent,
      recipientId: peerId,
      recipientVirtualId: recipientVirtualId,
    );
    _updateEditedInCache(messageId, newContent, editedAt);
    notifyListeners();
  }

  Future<void> deleteMessage({
    required String peerId,
    required String messageId,
    required String recipientVirtualId,
  }) async {
    await _messaging.deleteMessage(
      messageId: messageId,
      recipientVirtualId: recipientVirtualId,
    );
    _updateDeletedInCache(messageId);
    notifyListeners();
  }

  /// Mark all incoming unread messages in a chat as read and notify the sender.
  Future<void> markMessagesRead(String peerId) async {
    final chat = _chats[peerId] ?? [];
    final unread = chat
        .where((m) => !m.isOutgoing && m.status != MessageStatus.read)
        .toList();
    if (unread.isEmpty) return;

    final ids = unread.map((m) => m.id).toList();
    _unreadCounts[peerId] = 0;
    _signaling.sendReadReceipt(messageIds: ids, senderId: peerId);

    for (final id in ids) {
      await _db.updateMessageStatus(id, MessageStatus.read);
    }
    _chats[peerId] = chat.map((m) {
      if (!m.isOutgoing && m.status != MessageStatus.read) {
        return m.copyWith(status: MessageStatus.read);
      }
      return m;
    }).toList();
    notifyListeners();
  }

  void _updateStatusInCache(String peerId, String msgId, MessageStatus status) {
    final chat = _chats[peerId];
    if (chat == null) return;
    final idx = chat.indexWhere((m) => m.id == msgId);
    if (idx != -1) {
      _chats[peerId]![idx] = chat[idx].copyWith(status: status);
      notifyListeners();
    }
  }

  void _updateEditedInCache(
      String msgId, String newContent, DateTime editedAt) {
    for (final peerId in _chats.keys) {
      final chat = _chats[peerId]!;
      final idx = chat.indexWhere((m) => m.id == msgId);
      if (idx != -1) {
        _chats[peerId]![idx] = chat[idx].copyWith(
          encryptedContent: newContent,
          decryptedContent: newContent,
          editedAt: editedAt,
        );
        notifyListeners();
        break;
      }
    }
  }

  void _updateDeletedInCache(String msgId) {
    for (final peerId in _chats.keys) {
      final chat = _chats[peerId]!;
      final idx = chat.indexWhere((m) => m.id == msgId);
      if (idx != -1) {
        _chats[peerId]![idx] = chat[idx].copyWith(isDeleted: true);
        notifyListeners();
        break;
      }
    }
  }

  Future<void> addReaction({
    required String peerId,
    required String messageId,
    required String emoji,
    required String recipientVirtualId,
  }) {
    _signaling.emitReaction(
      messageId: messageId,
      emoji: emoji,
      recipientVirtualId: recipientVirtualId,
    );
    return Future.value();
  }

  void _updateReactionsInCache(
      String msgId, Map<String, List<String>> reactions) {
    for (final peerId in _chats.keys) {
      final chat = _chats[peerId]!;
      final idx = chat.indexWhere((m) => m.id == msgId);
      if (idx != -1) {
        _chats[peerId]![idx] = chat[idx].copyWith(reactions: reactions);
        notifyListeners();
        break;
      }
    }
  }

  Future<void> _processPendingReplies() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getStringList('pending_notification_replies') ?? [];
      if (pending.isEmpty) return;
      await prefs.remove('pending_notification_replies');
      for (final entry in pending) {
        try {
          final map = jsonDecode(entry) as Map<String, dynamic>;
          final payload = jsonDecode(map['payload'] as String) as Map<String, dynamic>;
          final virtualId = payload['sender_virtual_id'] as String? ?? '';
          final reply = map['reply'] as String? ?? '';
          if (virtualId.isNotEmpty && reply.isNotEmpty) {
            await _handleNotificationReply(virtualId, reply);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _handleNotificationReply(
      String senderVirtualId, String replyText) async {
    try {
      await _messaging.sendMessageByVirtualId(
        recipientVirtualId: senderVirtualId,
        plaintext: replyText,
      );
    } catch (e) {
      dev.log('[MessagesProvider] notification reply error: $e');
    }
  }

  Future<void> clearChat(String peerId) async {
    await MessagingService.saveClearTimestamp(peerId);
    final myId = await SecureStorage.getUserId() ?? '';
    await _db.clearChat(myId, peerId);
    _chats.remove(peerId);
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _typingTimer?.cancel();
    super.dispose();
  }
}
