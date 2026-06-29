import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/theme.dart';
import '../../../data/local/secure_storage.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/group.dart';
import '../../../data/models/group_message.dart';
import '../../../providers/contacts_provider.dart';
import '../../../providers/group_call_provider.dart';
import '../../../providers/groups_provider.dart';
import '../../../providers/messages_provider.dart';
import '../../../services/media_service.dart';
import '../../widgets/link_preview_card.dart';
import '../../widgets/user_avatar.dart';
import '../../widgets/voice_note_player.dart';
import '../media/photo_view_screen.dart';
import '../media/video_player_screen.dart';
import 'group_info_screen.dart';
import 'group_themes.dart';

class GroupChatScreen extends StatefulWidget {
  final Group group;
  const GroupChatScreen({super.key, required this.group});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _ctrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _recorder = AudioRecorder();
  bool _hasText = false;
  bool _isRecording = false;
  bool _uploading = false;
  bool _isMuted = false;
  GroupMessage? _replyTo;
  GroupMessage? _editingMsg;
  DateTime? _lastTypingSent;
  String _myId = '';
  Timer? _pollTimer;
  Timer? _highlightTimer;
  String? _highlightedMessageId;
  String? _mentionQuery;
  List<GroupMember> _mentionSuggestions = [];
  bool _searchMode = false;
  String _searchQuery = '';
  final _searchCtrl = TextEditingController();
  Set<String> _starredIds = {};
  int _prevMsgCount = 0;
  final Map<String, GlobalKey> _msgKeys = {};

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onTextChanged);
    _init();
  }

  Future<void> _init() async {
    _myId = await SecureStorage.getUserId() ?? '';
    final provider = context.read<GroupsProvider>();
    provider.setActiveGroup(widget.group.id);
    await provider.loadMessagesFromDb(widget.group.id);
    // Fetch full group detail: loads members (for @mention) + pinned message content
    provider.fetchGroupDetail(widget.group.id);
    await provider.loadMessages(widget.group.id);
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      final starred = prefs.getStringList('starred_${widget.group.id}') ?? [];
      setState(() {
        _isMuted = prefs.getBool('muted_group_${widget.group.id}') ?? false;
        _starredIds = Set<String>.from(starred);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    // Poll every 30s as fallback
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) provider.loadMessages(widget.group.id);
    });
  }

  @override
  void dispose() {
    context.read<GroupsProvider>().clearActiveGroup();
    _ctrl.dispose();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    _recorder.dispose();
    _pollTimer?.cancel();
    _highlightTimer?.cancel();
    super.dispose();
  }

  void _scrollToMessage(String messageId) {
    final key = _msgKeys[messageId];
    if (key?.currentContext == null) return;
    Scrollable.ensureVisible(
      key!.currentContext!,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      alignment: 0.5,
    );
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  static String _attachmentLabel(String? type) {
    switch (type) {
      case 'image': return '📷 Photo';
      case 'gif': return '🎞 GIF';
      case 'video': return '🎥 Video';
      case 'audio': return '🎤 Voice note';
      default: return '📎 Attachment';
    }
  }

  Future<void> _toggleMute() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _isMuted = !_isMuted);
    await prefs.setBool('muted_group_${widget.group.id}', _isMuted);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isMuted ? 'Notifications muted' : 'Notifications unmuted')),
      );
    }
  }

  Future<void> _toggleStar(GroupMessage m) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (_starredIds.contains(m.id)) {
        _starredIds.remove(m.id);
      } else {
        _starredIds.add(m.id);
      }
    });
    await prefs.setStringList('starred_${widget.group.id}', _starredIds.toList());
  }

  void _showStarredMessages(List<GroupMessage> allMsgs) {
    final starred = allMsgs.where((m) => _starredIds.contains(m.id)).toList();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, sc) => Column(
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: AppTheme.muted.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Text('Starred Messages',
                style: TextStyle(color: AppTheme.onSurface, fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Expanded(
              child: starred.isEmpty
                  ? const Center(child: Text('No starred messages', style: TextStyle(color: AppTheme.muted)))
                  : ListView.builder(
                      controller: sc,
                      itemCount: starred.length,
                      itemBuilder: (_, i) {
                        final m = starred[i];
                        return ListTile(
                          leading: const Icon(Icons.star_rounded, color: Colors.amber, size: 20),
                          title: Text(m.isOutgoing ? 'You' : m.senderUsername,
                              style: const TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            m.content.isNotEmpty ? m.content : _attachmentLabel(m.attachmentType),
                            style: const TextStyle(color: AppTheme.muted, fontSize: 13),
                            maxLines: 2, overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            DateFormat('MMM d').format(m.createdAt.toLocal()),
                            style: const TextStyle(color: AppTheme.muted, fontSize: 11),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            _jumpToMessage(m.id);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _jumpToMessage(String messageId) {
    setState(() { _searchMode = false; _searchQuery = ''; _searchCtrl.clear(); });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToMessage(messageId));
  }

  void _showPollCreator() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _PollCreatorSheet(
        onSubmit: (question, options) async {
          final pollData = jsonEncode({'question': question, 'options': options});
          await context.read<GroupsProvider>().sendMessage(
            groupId: widget.group.id,
            content: '',
            attachmentType: 'poll',
            attachmentName: pollData,
          );
        },
      ),
    );
  }

  void _showForwardPicker(GroupMessage m) {
    final content = m.isDeleted ? '' : m.content;
    final hasAttachment = m.attachmentUrl != null && !m.isDeleted;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ForwardPicker(
        content: content,
        attachmentUrl: hasAttachment ? m.attachmentUrl : null,
        attachmentType: hasAttachment ? m.attachmentType : null,
        attachmentName: hasAttachment ? m.attachmentName : null,
        attachmentSize: hasAttachment ? m.attachmentSize : null,
      ),
    );
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _onTextChanged() {
    final text = _ctrl.text;
    final hasText = text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
    // Typing indicator throttle
    final now = DateTime.now();
    if (hasText && (_lastTypingSent == null || now.difference(_lastTypingSent!).inSeconds >= 3)) {
      _lastTypingSent = now;
      context.read<GroupsProvider>().sendTyping(widget.group.id);
    }
    // @mention detection
    final sel = _ctrl.selection;
    if (sel.isValid && sel.isCollapsed) {
      final before = text.substring(0, sel.start);
      final atIdx = before.lastIndexOf('@');
      if (atIdx >= 0) {
        final query = before.substring(atIdx + 1);
        if (!query.contains(' ') && !query.contains('\n')) {
          final members = context.read<GroupsProvider>()
              .groupById(widget.group.id)
              ?.members
              .where((m) => m.isActive && m.username.toLowerCase().startsWith(query.toLowerCase()))
              .toList() ?? [];
          setState(() { _mentionQuery = query; _mentionSuggestions = members; });
          return;
        }
      }
    }
    if (_mentionQuery != null) setState(() { _mentionQuery = null; _mentionSuggestions = []; });
  }

  void _insertMention(GroupMember member) {
    final text = _ctrl.text;
    final pos = _ctrl.selection.start;
    final before = text.substring(0, pos);
    final atIdx = before.lastIndexOf('@');
    if (atIdx < 0) return;
    final after = text.substring(pos);
    final newText = '${text.substring(0, atIdx)}@${member.username} $after';
    _ctrl.text = newText;
    _ctrl.selection = TextSelection.fromPosition(
        TextPosition(offset: atIdx + member.username.length + 2));
    setState(() { _mentionQuery = null; _mentionSuggestions = []; });
  }

  Future<void> _sendText() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();
    final reply = _replyTo;
    setState(() { _replyTo = null; _editingMsg = null; });

    if (_editingMsg != null) {
      await context.read<GroupsProvider>().editMessage(
        groupId: widget.group.id,
        messageId: _editingMsg!.id,
        newContent: text,
      );
      return;
    }

    await context.read<GroupsProvider>().sendMessage(
      groupId: widget.group.id,
      content: text,
      replyToId: reply?.id,
    );
  }

  Future<void> _pickAndSend(Future<File?> Function() picker) async {
    final file = await picker();
    if (file == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final token = await SecureStorage.getToken() ?? '';
      final meta = await MediaService.upload(file, token);
      if (!mounted) return;
      final replyId = _replyTo?.id;
      await context.read<GroupsProvider>().sendMessage(
        groupId: widget.group.id,
        content: '',
        replyToId: replyId,
        attachmentUrl: meta.url,
        attachmentType: meta.type,
        attachmentName: meta.name,
        attachmentSize: meta.size,
      );
      setState(() { _replyTo = null; _uploading = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _uploading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to send: $e')));
      }
    }
  }

  Future<void> _startRecording() async {
    final perm = await Permission.microphone.request();
    if (!perm.isGranted || !mounted) return;
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/group_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() => _isRecording = true);
  }

  Future<void> _stopAndSendVoice() async {
    final path = await _recorder.stop();
    setState(() => _isRecording = false);
    if (path == null || !mounted) return;
    _showVoicePreview(path);
  }

  void _cancelRecording() async {
    await _recorder.stop();
    setState(() => _isRecording = false);
  }

  /// Called when the user inserts a GIF/image from the keyboard media panel.
  Future<void> _onKeyboardMediaInserted(KeyboardInsertedContent content) async {
    final bytes = content.data;
    if (bytes == null || bytes.isEmpty) return;
    final ext = content.mimeType.split('/').last;
    final tmpDir = await getTemporaryDirectory();
    final tmpFile = File(
        '${tmpDir.path}/group_kbd_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await tmpFile.writeAsBytes(bytes);
    await _pickAndSend(() async => tmpFile);
  }

  void _showVoicePreview(String path) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _VoicePreviewSheet(
        path: path,
        onSend: (effectId) async {
          setState(() => _uploading = true);
          try {
            final token = await SecureStorage.getToken() ?? '';
            final meta = await MediaService.upload(File(path), token);
            if (!mounted) return;
            final name = effectId != null ? 'voice_note.m4a#$effectId' : 'voice_note.m4a';
            await context.read<GroupsProvider>().sendMessage(
              groupId: widget.group.id,
              content: '',
              replyToId: _replyTo?.id,
              attachmentUrl: meta.url,
              attachmentType: 'audio',
              attachmentName: name,
              attachmentSize: meta.size,
            );
            setState(() { _replyTo = null; _uploading = false; });
          } catch (e) {
            if (mounted) {
              setState(() => _uploading = false);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to send: $e')));
            }
          }
        },
      ),
    );
  }

  void _showAttachSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.symmetric(horizontal: 160, vertical: 12),
              decoration: BoxDecoration(color: AppTheme.muted.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)),
            ),
            _AttachOption(icon: Icons.photo_camera_rounded, label: 'Camera', color: AppTheme.primary,
                onTap: () { Navigator.pop(context); _pickAndSend(MediaService.pickFromCamera); }),
            _AttachOption(icon: Icons.photo_library_rounded, label: 'Gallery', color: AppTheme.accent,
                onTap: () { Navigator.pop(context); _pickAndSend(MediaService.pickFromGallery); }),
            _AttachOption(icon: Icons.videocam_rounded, label: 'Video', color: Colors.orange,
                onTap: () { Navigator.pop(context); _pickAndSend(MediaService.pickVideoFromGallery); }),
            _AttachOption(icon: Icons.gif_box_rounded, label: 'GIF', color: Colors.purple,
                onTap: () { Navigator.pop(context); _pickAndSend(MediaService.pickFromGallery); }),
            _AttachOption(icon: Icons.insert_drive_file_rounded, label: 'File', color: Colors.blueGrey,
                onTap: () { Navigator.pop(context); _pickAndSend(MediaService.pickFile); }),
            _AttachOption(icon: Icons.poll_rounded, label: 'Poll', color: Colors.teal,
                onTap: () { Navigator.pop(context); _showPollCreator(); }),
          ],
        ),
      ),
    );
  }

  static const _quickEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥'];

  void _showMessageOptions(GroupMessage m) {
    final isMe = m.senderId == _myId;
    final group = context.read<GroupsProvider>().groupById(widget.group.id);
    final isAdmin = group?.isAdmin ?? false;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              decoration: BoxDecoration(color: AppTheme.muted.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)),
            ),
            // ── Quick emoji reactions ──────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: _quickEmojis.map((e) {
                  final reacted = m.reactions[e]?.contains(_myId) == true;
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      context.read<GroupsProvider>().addReaction(
                        groupId: widget.group.id,
                        messageId: m.id,
                        emoji: e,
                      );
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: reacted
                            ? AppTheme.primary.withValues(alpha: 0.2)
                            : AppTheme.inputBg,
                        shape: BoxShape.circle,
                      ),
                      child: Center(child: Text(e, style: const TextStyle(fontSize: 24))),
                    ),
                  );
                }).toList(),
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2A3A4A)),
            ListTile(
              leading: const Icon(Icons.reply_rounded, color: AppTheme.primary),
              title: const Text('Reply'),
              onTap: () { Navigator.pop(ctx); setState(() => _replyTo = m); },
            ),
            if (!m.isDeleted)
              ListTile(
                leading: const Icon(Icons.forward_rounded, color: AppTheme.muted),
                title: const Text('Forward'),
                onTap: () { Navigator.pop(ctx); _showForwardPicker(m); },
              ),
            if (isAdmin && !m.isDeleted)
              ListTile(
                leading: const Icon(Icons.push_pin_rounded, color: AppTheme.muted),
                title: const Text('Pin message'),
                onTap: () {
                  Navigator.pop(ctx);
                  context.read<GroupsProvider>().pinMessage(widget.group.id, m.id);
                },
              ),
            ListTile(
              leading: Icon(
                _starredIds.contains(m.id) ? Icons.star_rounded : Icons.star_border_rounded,
                color: _starredIds.contains(m.id) ? Colors.amber : AppTheme.muted,
              ),
              title: Text(_starredIds.contains(m.id) ? 'Unstar' : 'Star'),
              onTap: () { Navigator.pop(ctx); _toggleStar(m); },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded, color: AppTheme.muted),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: m.content));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
              },
            ),
            if (isMe && !m.isDeleted && m.attachmentUrl == null)
              ListTile(
                leading: const Icon(Icons.edit_rounded, color: AppTheme.accent),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() { _editingMsg = m; _replyTo = null; });
                  _ctrl.text = m.content;
                  _ctrl.selection = TextSelection.fromPosition(TextPosition(offset: m.content.length));
                },
              ),
            if (isMe || isAdmin)
              ListTile(
                leading: const Icon(Icons.delete_rounded, color: AppTheme.danger),
                title: const Text('Delete', style: TextStyle(color: AppTheme.danger)),
                onTap: () {
                  Navigator.pop(ctx);
                  context.read<GroupsProvider>().deleteMessage(
                    groupId: widget.group.id,
                    messageId: m.id,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<GroupsProvider>();
    final msgs = provider.getMessages(widget.group.id);
    final typingUser = provider.getTypingUser(widget.group.id);
    final group = provider.groupById(widget.group.id) ?? widget.group;

    // Auto-scroll to bottom when new messages arrive and user is near the bottom
    if (msgs.length != _prevMsgCount) {
      _prevMsgCount = msgs.length;
      final atBottom = !_scrollCtrl.hasClients ||
          _scrollCtrl.position.pixels >= _scrollCtrl.position.maxScrollExtent - 120;
      if (atBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    }

    final displayMsgs = (_searchMode && _searchQuery.isNotEmpty)
        ? msgs.where((m) => m.content.toLowerCase().contains(_searchQuery)).toList()
        : msgs;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.inputBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.onSurface),
          onPressed: _searchMode
              ? () => setState(() { _searchMode = false; _searchQuery = ''; _searchCtrl.clear(); })
              : () => Navigator.pop(context),
        ),
        title: _searchMode
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: AppTheme.onSurface, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Search messages…',
                  hintStyle: TextStyle(color: AppTheme.muted.withValues(alpha: 0.6)),
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
              )
            : GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => GroupInfoScreen(group: group)),
                ).then((_) => setState(() {})),
                child: Row(
                  children: [
                    UserAvatar(username: group.name, avatarUrl: group.avatarUrl, radius: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(group.name,
                              style: const TextStyle(color: AppTheme.onSurface, fontSize: 16, fontWeight: FontWeight.w700),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(
                            typingUser != null ? '$typingUser is typing…' : '${group.memberCount} members',
                            style: TextStyle(
                              color: typingUser != null ? AppTheme.primary : AppTheme.muted,
                              fontSize: 12,
                              fontStyle: typingUser != null ? FontStyle.italic : FontStyle.normal,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
        actions: _searchMode
            ? [
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: AppTheme.muted),
                  onPressed: () => setState(() { _searchMode = false; _searchQuery = ''; _searchCtrl.clear(); }),
                ),
              ]
            : [
          if (group.isAdmin && group.pendingCount > 0)
            Stack(
              children: [
                IconButton(
                  icon: const Icon(Icons.person_add_rounded, color: AppTheme.accent),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => GroupInfoScreen(group: group, showPending: true)),
                  ),
                ),
                Positioned(
                  right: 8, top: 8,
                  child: Container(
                    width: 16, height: 16,
                    decoration: const BoxDecoration(color: AppTheme.danger, shape: BoxShape.circle),
                    child: Center(
                      child: Text('${group.pendingCount}',
                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ],
            ),
          IconButton(
            icon: const Icon(Icons.call_rounded, color: AppTheme.onSurface),
            tooltip: 'Voice call',
            onPressed: () {
              context.read<GroupCallProvider>().startCall(
                groupId: group.id,
                groupName: group.name,
                isVideo: false,
              );
              Navigator.pushNamed(context, '/call/group');
            },
          ),
          IconButton(
            icon: const Icon(Icons.videocam_rounded, color: AppTheme.onSurface),
            tooltip: 'Video call',
            onPressed: () {
              context.read<GroupCallProvider>().startCall(
                groupId: group.id,
                groupName: group.name,
                isVideo: true,
              );
              Navigator.pushNamed(context, '/call/group');
            },
          ),
          IconButton(
            icon: const Icon(Icons.search_rounded, color: AppTheme.onSurface),
            tooltip: 'Search',
            onPressed: () => setState(() { _searchMode = true; _searchQuery = ''; }),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: AppTheme.onSurface),
            color: AppTheme.surface,
            onSelected: (value) {
              switch (value) {
                case 'starred':
                  _showStarredMessages(msgs);
                case 'mute':
                  _toggleMute();
                case 'info':
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => GroupInfoScreen(group: group)),
                  ).then((_) => setState(() {}));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'starred',
                child: Row(
                  children: [
                    Icon(Icons.star_rounded,
                        color: _starredIds.isNotEmpty ? Colors.amber : AppTheme.muted, size: 20),
                    const SizedBox(width: 12),
                    const Text('Starred messages'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'mute',
                child: Row(
                  children: [
                    Icon(
                      _isMuted ? Icons.notifications_rounded : Icons.notifications_off_rounded,
                      color: AppTheme.muted, size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(_isMuted ? 'Unmute' : 'Mute'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'info',
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded, color: AppTheme.muted, size: 20),
                    SizedBox(width: 12),
                    Text('Group info'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: GroupChatBackground(themeId: group.themeId)),
          Column(children: [
          // Pinned message banner
          if (group.pinnedMessageId != null)
            _PinnedBanner(
              content: group.pinnedMessageContent ?? '',
              attachmentType: group.pinnedMessageType,
              isAdmin: group.isAdmin,
              onTap: () => _scrollToMessage(group.pinnedMessageId!),
              onUnpin: group.isAdmin
                  ? () => context.read<GroupsProvider>().unpinMessage(widget.group.id)
                  : null,
            ),
          // Chat messages
          Expanded(
            child: displayMsgs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _searchMode ? Icons.search_off_rounded : Icons.group_rounded,
                          size: 56,
                          color: AppTheme.muted.withValues(alpha: 0.4),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _searchMode
                              ? 'No messages match your search'
                              : 'Start the conversation in ${group.name}',
                          style: TextStyle(color: AppTheme.muted.withValues(alpha: 0.7), fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _searchMode ? null : _scrollCtrl,
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    itemCount: displayMsgs.length,
                    itemBuilder: (_, idx) {
                      final m = displayMsgs[idx];
                      final prevMsg = idx > 0 ? displayMsgs[idx - 1] : null;
                      final showDate = prevMsg == null ||
                          !DateUtils.isSameDay(m.createdAt.toLocal(), prevMsg.createdAt.toLocal());
                      final nextAudioSource = _nextAudio(msgs, m);
                      final msgKey = _msgKeys.putIfAbsent(m.id, () => GlobalKey());
                      return Column(
                        key: msgKey,
                        children: [
                          if (showDate) _DateSeparator(date: m.createdAt),
                          _SwipeToReply(
                            onReply: () => setState(() => _replyTo = m),
                            child: _GroupMessageBubble(
                              message: m,
                              myId: _myId,
                              highlighted: _highlightedMessageId == m.id,
                              nextAudioSource: nextAudioSource,
                              replyTo: m.replyToId != null
                                  ? msgs.firstWhere((x) => x.id == m.replyToId,
                                      orElse: () => m)
                                  : null,
                              onLongPress: () => _showMessageOptions(m),
                              onReact: (emoji) => context.read<GroupsProvider>().addReaction(
                                groupId: widget.group.id,
                                messageId: m.id,
                                emoji: emoji,
                              ),
                              onReplyTap: m.replyToId != null
                                  ? () => _scrollToMessage(m.replyToId!)
                                  : null,
                              onVotePoll: (optionIndex) => context.read<GroupsProvider>().votePoll(
                                widget.group.id, m.id, optionIndex),
                              onSearchResultTap: _searchMode
                                  ? () => _jumpToMessage(m.id)
                                  : null,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          if (_uploading)
            const LinearProgressIndicator(color: AppTheme.primary, backgroundColor: Colors.transparent),
          // @mention suggestions
          if (_mentionSuggestions.isNotEmpty)
            _buildMentionSuggestions(),
          // Reply bar
          if (_replyTo != null) _buildReplyBar(),
          if (_editingMsg != null) _buildEditBar(),
          // Input bar
          _buildInputBar(),
        ],
          )],
      ),
    );
  }

  String? _nextAudio(List<GroupMessage> msgs, GroupMessage current) {
    if (current.attachmentType != 'audio' || current.attachmentUrl == null) return null;
    final idx = msgs.indexOf(current);
    for (int j = idx + 1; j < msgs.length; j++) {
      if (msgs[j].attachmentType == 'audio' && msgs[j].attachmentUrl != null) {
        return MediaService.fullUrl(msgs[j].attachmentUrl!);
      }
    }
    return null;
  }

  Widget _buildReplyBar() {
    final r = _replyTo!;
    return Container(
      color: AppTheme.inputBg,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Container(width: 3, height: 36, color: AppTheme.primary, margin: const EdgeInsets.only(right: 10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.isOutgoing ? 'You' : r.senderUsername,
                    style: const TextStyle(color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.w700)),
                Text(r.isDeleted ? 'Deleted message' : (r.content.isNotEmpty ? r.content : _attachmentLabel(r.attachmentType)),
                    style: const TextStyle(color: AppTheme.muted, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.close_rounded, color: AppTheme.muted, size: 20),
              onPressed: () => setState(() => _replyTo = null)),
        ],
      ),
    );
  }

  Widget _buildEditBar() {
    return Container(
      color: AppTheme.inputBg,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Container(width: 3, height: 36, color: AppTheme.accent, margin: const EdgeInsets.only(right: 10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Editing message', style: TextStyle(color: AppTheme.accent, fontSize: 12, fontWeight: FontWeight.w700)),
                Text(_editingMsg!.content, style: const TextStyle(color: AppTheme.muted, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.close_rounded, color: AppTheme.muted, size: 20),
              onPressed: () { setState(() { _editingMsg = null; _ctrl.clear(); }); }),
        ],
      ),
    );
  }

  Widget _buildMentionSuggestions() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      color: AppTheme.inputBg,
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _mentionSuggestions.length,
        itemBuilder: (_, i) {
          final m = _mentionSuggestions[i];
          return ListTile(
            dense: true,
            leading: UserAvatar(username: m.username, avatarUrl: m.avatarUrl, radius: 16),
            title: Text('@${m.username}',
                style: const TextStyle(color: AppTheme.onSurface, fontSize: 14)),
            onTap: () => _insertMention(m),
          );
        },
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      color: AppTheme.inputBg,
      child: SafeArea(
        top: false,
        child: _isRecording
            ? _buildRecordingBar()
            : Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file_rounded, color: AppTheme.muted),
                    onPressed: _showAttachSheet,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      maxLines: 4,
                      minLines: 1,
                      style: const TextStyle(color: AppTheme.onSurface, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Message',
                        hintStyle: TextStyle(color: AppTheme.muted.withValues(alpha: 0.6)),
                        filled: true,
                        fillColor: AppTheme.surface,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      ),
                      contentInsertionConfiguration: ContentInsertionConfiguration(
                        allowedMimeTypes: const [
                          'image/gif',
                          'image/png',
                          'image/jpeg',
                          'image/webp',
                        ],
                        onContentInserted: _onKeyboardMediaInserted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: _hasText ? _sendText : null,
                    onLongPress: _hasText ? null : _startRecording,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: _hasText ? AppTheme.primary : AppTheme.surface,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _hasText ? Icons.send_rounded : Icons.mic_rounded,
                        color: _hasText ? Colors.white : AppTheme.muted,
                        size: 22,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildRecordingBar() {
    return Row(
      children: [
        GestureDetector(
          onTap: _cancelRecording,
          child: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: AppTheme.danger.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: const Icon(Icons.delete_outline_rounded, color: AppTheme.danger, size: 22),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Row(
            children: [
              Container(
                width: 10, height: 10,
                decoration: const BoxDecoration(color: AppTheme.danger, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              const Text('Recording…', style: TextStyle(color: AppTheme.muted, fontSize: 14)),
            ],
          ),
        ),
        GestureDetector(
          onTap: _stopAndSendVoice,
          child: Container(
            width: 44, height: 44,
            decoration: const BoxDecoration(color: AppTheme.primary, shape: BoxShape.circle),
            child: const Icon(Icons.send_rounded, color: Colors.white, size: 22),
          ),
        ),
      ],
    );
  }
}

String _attachmentPreviewLabel(String? type) {
  switch (type) {
    case 'image': return '📷 Photo';
    case 'gif': return '🎞 GIF';
    case 'video': return '🎥 Video';
    case 'audio': return '🎤 Voice note';
    default: return '📎 Attachment';
  }
}

// ── Group message bubble ────────────────────────────────────

class _GroupMessageBubble extends StatelessWidget {
  final GroupMessage message;
  final String myId;
  final bool highlighted;
  final String? nextAudioSource;
  final GroupMessage? replyTo;
  final VoidCallback onLongPress;
  final void Function(String emoji) onReact;
  final VoidCallback? onReplyTap;
  final void Function(int optionIndex)? onVotePoll;
  final VoidCallback? onSearchResultTap;

  const _GroupMessageBubble({
    required this.message,
    required this.myId,
    this.highlighted = false,
    this.nextAudioSource,
    this.replyTo,
    required this.onLongPress,
    required this.onReact,
    this.onReplyTap,
    this.onVotePoll,
    this.onSearchResultTap,
  });

  static const _quickEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥'];

  void _showEmojiPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (_) => Align(
        alignment: message.isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(
            left: message.isOutgoing ? 72 : 12,
            right: message.isOutgoing ? 12 : 72,
            bottom: 80,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF2A3A4A),
            borderRadius: BorderRadius.circular(32),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 12)],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: _quickEmojis.map((e) {
              final reacted = message.reactions[e]?.contains(myId) == true;
              return GestureDetector(
                onTap: () { Navigator.pop(context); onReact(e); },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.all(6),
                  decoration: reacted
                      ? BoxDecoration(
                          color: const Color(0xFF5288C1).withValues(alpha: 0.35),
                          shape: BoxShape.circle)
                      : null,
                  child: Text(e, style: const TextStyle(fontSize: 26)),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMe = message.isOutgoing;
    final isDeleted = message.isDeleted;
    final bubbleColor = isMe ? AppTheme.outgoingBubble : AppTheme.incomingBubble;
    final reactions = message.reactions;
    final hasReactions = reactions.isNotEmpty;
    final time = DateFormat('HH:mm').format(message.createdAt.toLocal());
    final metaColor = Colors.white.withValues(alpha: isMe ? 0.6 : 0.45);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      color: highlighted ? Colors.amber.withValues(alpha: 0.15) : Colors.transparent,
      child: GestureDetector(
      onLongPress: onLongPress,
      onTap: onSearchResultTap,
      onDoubleTap: onSearchResultTap == null ? () => _showEmojiPicker(context) : null,
      child: Padding(
        padding: EdgeInsets.only(
          left: isMe ? 72 : 16,
          right: isMe ? 16 : 72,
          top: 2,
          bottom: hasReactions ? 18 : 2,
        ),
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 16),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 16),
                  ),
                  child: IntrinsicWidth(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Sender name for incoming group messages
                        if (!isMe && !isDeleted)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                            child: Text(
                              message.senderUsername,
                              style: TextStyle(
                                color: _senderColor(message.senderId),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        // Reply preview
                        if (replyTo != null && !isDeleted)
                          GestureDetector(
                            onTap: onReplyTap,
                            child: Container(
                              margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(10),
                                border: Border(left: BorderSide(
                                  color: isMe ? Colors.white : AppTheme.primary, width: 3)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    replyTo!.isOutgoing ? 'You' : replyTo!.senderUsername,
                                    style: TextStyle(
                                      color: isMe ? Colors.white : AppTheme.primary,
                                      fontSize: 12, fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    replyTo!.isDeleted ? 'Deleted message'
                                        : (replyTo!.content.isNotEmpty ? replyTo!.content : _attachmentPreviewLabel(replyTo!.attachmentType)),
                                    style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
                                    maxLines: 2, overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(10, 6, 10, hasReactions ? 10 : 6),
                          child: isDeleted
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.block_rounded, size: 14,
                                        color: Colors.white.withValues(alpha: isMe ? 0.5 : 0.4)),
                                    const SizedBox(width: 6),
                                    Text('Message deleted',
                                        style: TextStyle(
                                          color: Colors.white.withValues(alpha: isMe ? 0.5 : 0.4),
                                          fontSize: 14, fontStyle: FontStyle.italic)),
                                  ],
                                )
                              : _buildContent(context, time, metaColor, isMe),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Tail
              Positioned(
                right: isMe ? -7 : null,
                left: isMe ? null : -7,
                bottom: 0,
                child: CustomPaint(
                  size: const Size(10, 14),
                  painter: _TailPainter(color: bubbleColor, isMe: isMe),
                ),
              ),
              if (hasReactions)
                Positioned(
                  bottom: -13,
                  right: isMe ? 6 : null,
                  left: isMe ? null : 6,
                  child: _buildReactionPills(context, reactions),
                ),
            ],
          ),
        ),
      ),
    ),   // GestureDetector
    );   // AnimatedContainer
  }

  Widget _buildContent(BuildContext context, String time, Color metaColor, bool isMe) {
    final m = message;

    // Poll messages
    if (m.attachmentType == 'poll' && m.attachmentName != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          _GroupPollWidget(message: m, onVote: onVotePoll),
          const SizedBox(height: 2),
          Text(time, style: TextStyle(color: metaColor, fontSize: 11)),
        ],
      );
    }

    final hasAttachment = m.attachmentUrl != null;
    Widget? attachmentWidget;

    if (hasAttachment) {
      final url = MediaService.fullUrl(m.attachmentUrl!);
      final type = m.attachmentType ?? 'file';
      final filename = m.attachmentName ?? 'attachment';

      if (type == 'image' || type == 'gif') {
        final heroTag = 'group_media_${m.id}';
        attachmentWidget = GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => PhotoViewScreen(url: url, heroTag: heroTag, caption: filename)),
          ),
          child: Hero(
            tag: heroTag,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: url,
                width: 220,
                fit: BoxFit.cover,
                placeholder: (_, __) => const SizedBox(
                    width: 220, height: 160,
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                errorWidget: (_, __, ___) => const SizedBox(
                    width: 220, height: 80,
                    child: Center(child: Icon(Icons.broken_image_rounded, color: Colors.white54))),
              ),
            ),
          ),
        );
      } else if (type == 'video') {
        attachmentWidget = _GroupVideoThumbnail(url: url, filename: filename, size: m.attachmentSize);
      } else if (type == 'audio') {
        final effectId = filename.contains('#') ? filename.split('#').last : null;
        attachmentWidget = Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: VoiceNotePlayer(
            key: ValueKey(m.id),
            source: url,
            effectId: effectId,
            isOutgoing: isMe,
            nextSource: nextAudioSource,
          ),
        );
      } else {
        attachmentWidget = Container(
          width: 220,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(8)),
          child: Row(
            children: [
              const Icon(Icons.insert_drive_file_rounded, color: Colors.white70, size: 32),
              const SizedBox(width: 8),
              Expanded(child: Text(filename,
                  style: const TextStyle(color: Colors.white, fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis)),
            ],
          ),
        );
      }
    }

    final hasText = m.content.trim().isNotEmpty;
    final isEdited = m.editedAt != null;

    final urlRe = RegExp(
      r'(https?://[^\s]+|www\.[a-zA-Z0-9\-]+\.[^\s]+)',
      caseSensitive: false,
    );
    final firstUrl = hasText ? urlRe.firstMatch(m.content)?.group(0) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (attachmentWidget != null) ...[attachmentWidget, if (hasText) const SizedBox(height: 6)],
        if (hasText) _MentionLinkText(m.content, style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.35)),
        if (firstUrl != null) ...[const SizedBox(height: 6), LinkPreviewCard(firstUrl)],
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isEdited)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text('edited', style: TextStyle(color: metaColor, fontSize: 10, fontStyle: FontStyle.italic)),
              ),
            Text(time, style: TextStyle(color: metaColor, fontSize: 11)),
          ],
        ),
      ],
    );
  }

  Widget _buildReactionPills(BuildContext context, Map<String, List<String>> reactions) {
    return Wrap(
      spacing: 4,
      children: reactions.entries.map((e) {
        final iMine = e.value.contains(myId);
        return GestureDetector(
          onTap: () => onReact(e.key),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: iMine ? AppTheme.primary.withValues(alpha: 0.3) : const Color(0xFF2A3A4A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: iMine ? AppTheme.primary : Colors.white.withValues(alpha: 0.15), width: 1),
            ),
            child: Text(e.value.length > 1 ? '${e.key} ${e.value.length}' : e.key,
                style: const TextStyle(fontSize: 13)),
          ),
        );
      }).toList(),
    );
  }

  Color _senderColor(String userId) {
    const colors = [
      Color(0xFF58A6FF), Color(0xFF7EE787), Color(0xFFFF7B72),
      Color(0xFFD2A8FF), Color(0xFFFFA657), Color(0xFF79C0FF),
    ];
    return colors[userId.hashCode.abs() % colors.length];
  }
}

// ── Tail painter ────────────────────────────────────────────

class _TailPainter extends CustomPainter {
  final Color color;
  final bool isMe;
  const _TailPainter({required this.color, required this.isMe});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final path = Path();
    if (isMe) {
      path..moveTo(0, 0)..lineTo(size.width, size.height)..lineTo(0, size.height)..close();
    } else {
      path..moveTo(size.width, 0)..lineTo(0, size.height)..lineTo(size.width, size.height)..close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TailPainter old) => old.color != color || old.isMe != isMe;
}

// ── Date separator ──────────────────────────────────────────

class _DateSeparator extends StatelessWidget {
  final DateTime date;
  const _DateSeparator({required this.date});

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final msgDate = DateUtils.dateOnly(date.toLocal());
    String label;
    if (msgDate == today) {
      label = 'Today';
    } else if (msgDate == today.subtract(const Duration(days: 1))) {
      label = 'Yesterday';
    } else {
      label = DateFormat('MMMM d, y').format(date.toLocal());
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Group video thumbnail ─────────────────────────────────────

class _GroupVideoThumbnail extends StatefulWidget {
  final String url;
  final String filename;
  final int? size;
  const _GroupVideoThumbnail({required this.url, required this.filename, this.size});

  @override
  State<_GroupVideoThumbnail> createState() => _GroupVideoThumbnailState();
}

class _GroupVideoThumbnailState extends State<_GroupVideoThumbnail> {
  Uint8List? _thumb;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await MediaService.videoThumbnailBytes(widget.url);
    if (mounted) setState(() { _thumb = bytes; _loaded = true; });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => VideoPlayerScreen(url: widget.url, filename: widget.filename)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 220, height: 150,
              child: _loaded && _thumb != null
                  ? Image.memory(_thumb!, width: 220, height: 150, fit: BoxFit.cover)
                  : Container(color: Colors.black54,
                      child: const Icon(Icons.videocam_rounded, color: Colors.white12, size: 64)),
            ),
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), shape: BoxShape.circle),
              child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Attach option ────────────────────────────────────────────

class _AttachOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _AttachOption({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
        child: Icon(icon, color: color, size: 22),
      ),
      title: Text(label),
      onTap: onTap,
    );
  }
}

// ── Voice preview sheet ──────────────────────────────────────

class _VoicePreviewSheet extends StatefulWidget {
  final String path;
  final void Function(String? effectId) onSend;
  const _VoicePreviewSheet({required this.path, required this.onSend});

  @override
  State<_VoicePreviewSheet> createState() => _VoicePreviewSheetState();
}

class _VoicePreviewSheetState extends State<_VoicePreviewSheet> {
  String? _selectedEffect;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(color: AppTheme.muted.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)),
            ),
            const Text('Voice Note', style: TextStyle(color: AppTheme.onSurface, fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 20),
            VoiceNotePlayer(
              key: ValueKey(_selectedEffect ?? 'normal'),
              source: widget.path,
              isFile: true,
              autoLoad: true,
              effectId: _selectedEffect,
            ),
            const SizedBox(height: 16),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: kVoiceEffects.map((e) {
                  final selected = _selectedEffect == e.id || (e.id == 'normal' && _selectedEffect == null);
                  return GestureDetector(
                    onTap: () => setState(() => _selectedEffect = e.id == 'normal' ? null : e.id),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected ? AppTheme.primary.withValues(alpha: 0.2) : AppTheme.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: selected ? AppTheme.primary : Colors.transparent),
                      ),
                      child: Text('${e.emoji} ${e.label}',
                          style: TextStyle(color: selected ? AppTheme.primary : AppTheme.muted, fontSize: 13)),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: AppTheme.muted),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Discard', style: TextStyle(color: AppTheme.muted)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () { Navigator.pop(context); widget.onSend(_selectedEffect); },
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.send_rounded, size: 18),
                        SizedBox(width: 8),
                        Text('Send', style: TextStyle(fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Swipe-to-reply wrapper ────────────────────────────────────

class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;

  const _SwipeToReply({required this.child, required this.onReply});

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  late final AnimationController _snapBack;
  late Animation<double> _snapAnim;
  double _dragX = 0;
  bool _triggered = false;

  static const _threshold = 56.0;

  @override
  void initState() {
    super.initState();
    _snapBack = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200));
    _snapAnim = Tween<double>(begin: 0, end: 0).animate(_snapBack);
  }

  @override
  void dispose() {
    _snapBack.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final delta = d.delta.dx;
    if (delta < 0 && _dragX <= 0) return; // don't allow left swipe
    final next = (_dragX + delta).clamp(0.0, _threshold * 1.1);
    setState(() => _dragX = next);
    if (!_triggered && _dragX >= _threshold) {
      _triggered = true;
      HapticFeedback.lightImpact();
      widget.onReply();
    }
  }

  void _onDragEnd(DragEndDetails _) {
    final start = _dragX;
    _snapAnim = Tween<double>(begin: start, end: 0)
        .animate(CurvedAnimation(parent: _snapBack, curve: Curves.easeOut));
    _snapBack.forward(from: 0).then((_) {
      if (mounted) setState(() { _dragX = 0; _triggered = false; });
    });
    _snapBack.addListener(() {
      if (mounted) setState(() => _dragX = _snapAnim.value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_dragX / _threshold).clamp(0.0, 1.0);
    return GestureDetector(
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          // Reply icon revealed on the left as user swipes right
          if (_dragX > 4)
            Positioned(
              left: math.max(0, _dragX - 40),
              top: 0,
              bottom: 0,
              child: Center(
                child: Opacity(
                  opacity: progress,
                  child: Transform.scale(
                    scale: 0.6 + progress * 0.4,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.reply_rounded,
                          color: AppTheme.primary, size: 18),
                    ),
                  ),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(_dragX, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

// ── Pinned message banner ─────────────────────────────────────

class _PinnedBanner extends StatelessWidget {
  final String content;
  final String? attachmentType;
  final bool isAdmin;
  final VoidCallback onTap;
  final VoidCallback? onUnpin;

  const _PinnedBanner({
    required this.content,
    this.attachmentType,
    required this.isAdmin,
    required this.onTap,
    this.onUnpin,
  });

  String get _preview {
    if (content.isNotEmpty) return content;
    if (attachmentType == 'image') return '📷 Photo';
    if (attachmentType == 'video') return '🎥 Video';
    if (attachmentType == 'audio') return '🎤 Voice note';
    return '📎 Attachment';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: AppTheme.inputBg,
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Container(width: 3, height: 32, color: AppTheme.primary,
                margin: const EdgeInsets.only(right: 10)),
            const Icon(Icons.push_pin_rounded, color: AppTheme.primary, size: 14),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Pinned Message',
                      style: TextStyle(color: AppTheme.primary, fontSize: 11,
                          fontWeight: FontWeight.w700)),
                  Text(_preview,
                      style: const TextStyle(color: AppTheme.muted, fontSize: 13),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (onUnpin != null)
              IconButton(
                icon: const Icon(Icons.close_rounded, color: AppTheme.muted, size: 18),
                onPressed: onUnpin,
                tooltip: 'Unpin',
              ),
          ],
        ),
      ),
    );
  }
}

// ── Forward picker ───────────────────────────────────────────

class _ForwardPicker extends StatefulWidget {
  final String content;
  final String? attachmentUrl;
  final String? attachmentType;
  final String? attachmentName;
  final int? attachmentSize;

  const _ForwardPicker({
    required this.content,
    this.attachmentUrl,
    this.attachmentType,
    this.attachmentName,
    this.attachmentSize,
  });

  @override
  State<_ForwardPicker> createState() => _ForwardPickerState();
}

class _ForwardPickerState extends State<_ForwardPicker>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _forwardToDm(Contact contact) async {
    Navigator.pop(context);
    try {
      await context.read<MessagesProvider>().sendMessage(
        recipientId: contact.contactId,
        recipientVirtualId: contact.virtualId,
        recipientPublicKey: contact.publicKey,
        plaintext: widget.content,
        attachmentUrl: widget.attachmentUrl,
        attachmentType: widget.attachmentType,
        attachmentName: widget.attachmentName,
        attachmentSize: widget.attachmentSize,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Forwarded to ${contact.username}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to forward: $e')),
        );
      }
    }
  }

  Future<void> _forwardToGroup(Group group) async {
    Navigator.pop(context);
    try {
      await context.read<GroupsProvider>().sendMessage(
        groupId: group.id,
        content: widget.content,
        attachmentUrl: widget.attachmentUrl,
        attachmentType: widget.attachmentType,
        attachmentName: widget.attachmentName,
        attachmentSize: widget.attachmentSize,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Forwarded to ${group.name}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to forward: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactsProvider>().contacts;
    final groups = context.watch<GroupsProvider>().groups;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.85,
      expand: false,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: AppTheme.muted.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Text('Forward to',
                style: TextStyle(
                    color: AppTheme.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TabBar(
              controller: _tab,
              indicatorColor: AppTheme.primary,
              labelColor: AppTheme.primary,
              unselectedLabelColor: AppTheme.muted,
              tabs: const [Tab(text: 'People'), Tab(text: 'Groups')],
            ),
            Expanded(
              child: TabBarView(
                controller: _tab,
                children: [
                  // People tab
                  contacts.isEmpty
                      ? const Center(
                          child: Text('No contacts',
                              style: TextStyle(color: AppTheme.muted)))
                      : ListView.builder(
                          controller: scrollCtrl,
                          itemCount: contacts.length,
                          itemBuilder: (_, i) {
                            final c = contacts[i];
                            return ListTile(
                              leading: UserAvatar(
                                  username: c.username,
                                  avatarUrl: c.avatarUrl,
                                  radius: 20),
                              title: Text(c.username,
                                  style: const TextStyle(
                                      color: AppTheme.onSurface)),
                              subtitle: Text(c.virtualId,
                                  style: const TextStyle(
                                      color: AppTheme.muted, fontSize: 12)),
                              onTap: () => _forwardToDm(c),
                            );
                          },
                        ),
                  // Groups tab
                  groups.isEmpty
                      ? const Center(
                          child: Text('No groups',
                              style: TextStyle(color: AppTheme.muted)))
                      : ListView.builder(
                          controller: scrollCtrl,
                          itemCount: groups.length,
                          itemBuilder: (_, i) {
                            final g = groups[i];
                            return ListTile(
                              leading: UserAvatar(
                                  username: g.name,
                                  avatarUrl: g.avatarUrl,
                                  radius: 20),
                              title: Text(g.name,
                                  style: const TextStyle(
                                      color: AppTheme.onSurface)),
                              subtitle: Text('${g.memberCount} members',
                                  style: const TextStyle(
                                      color: AppTheme.muted, fontSize: 12)),
                              onTap: () => _forwardToGroup(g),
                            );
                          },
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Group poll widget ─────────────────────────────────────────

class _GroupPollWidget extends StatelessWidget {
  final GroupMessage message;
  final void Function(int optionIndex)? onVote;

  const _GroupPollWidget({required this.message, this.onVote});

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic> pollData;
    try {
      pollData = jsonDecode(message.attachmentName!) as Map<String, dynamic>;
    } catch (_) {
      return const Text('Invalid poll', style: TextStyle(color: Colors.white54));
    }
    final question = pollData['question'] as String? ?? '';
    final options = (pollData['options'] as List?)?.map((e) => e.toString()).toList() ?? [];
    final votes = message.pollVotes ?? {};
    final myVote = message.myPollVote;
    final totalVotes = votes.values.fold(0, (a, b) => a + b);

    return Container(
      width: 240,
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                const Icon(Icons.poll_rounded, color: Colors.white70, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(question,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          ...List.generate(options.length, (i) {
            final voteCount = votes[i] ?? 0;
            final frac = totalVotes > 0 ? voteCount / totalVotes : 0.0;
            final isSelected = myVote == i;
            return GestureDetector(
              onTap: onVote != null ? () => onVote!(i) : null,
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                child: Stack(
                  children: [
                    // Progress bar background
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: frac,
                        minHeight: 36,
                        backgroundColor: Colors.white.withValues(alpha: 0.1),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isSelected
                              ? AppTheme.primary.withValues(alpha: 0.45)
                              : Colors.white.withValues(alpha: 0.15),
                        ),
                      ),
                    ),
                    // Option label and vote %
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          children: [
                            if (isSelected)
                              const Padding(
                                padding: EdgeInsets.only(right: 6),
                                child: Icon(Icons.check_circle_rounded,
                                    color: AppTheme.primary, size: 14),
                              ),
                            Expanded(
                              child: Text(options[i],
                                  style: TextStyle(
                                      color: isSelected ? Colors.white : Colors.white70,
                                      fontSize: 13,
                                      fontWeight: isSelected
                                          ? FontWeight.w600
                                          : FontWeight.normal)),
                            ),
                            Text(
                              totalVotes > 0
                                  ? '${(frac * 100).round()}%'
                                  : '$voteCount',
                              style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.white54,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '$totalVotes vote${totalVotes == 1 ? '' : 's'}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Poll creator sheet ─────────────────────────────────────────

class _PollCreatorSheet extends StatefulWidget {
  final Future<void> Function(String question, List<String> options) onSubmit;

  const _PollCreatorSheet({required this.onSubmit});

  @override
  State<_PollCreatorSheet> createState() => _PollCreatorSheetState();
}

class _PollCreatorSheetState extends State<_PollCreatorSheet> {
  final _questionCtrl = TextEditingController();
  final List<TextEditingController> _optionCtrls = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _sending = false;

  @override
  void dispose() {
    _questionCtrl.dispose();
    for (final c in _optionCtrls) { c.dispose(); }
    super.dispose();
  }

  void _addOption() {
    if (_optionCtrls.length >= 5) return;
    setState(() => _optionCtrls.add(TextEditingController()));
  }

  void _removeOption(int i) {
    if (_optionCtrls.length <= 2) return;
    setState(() {
      _optionCtrls[i].dispose();
      _optionCtrls.removeAt(i);
    });
  }

  Future<void> _send() async {
    final question = _questionCtrl.text.trim();
    final options = _optionCtrls
        .map((c) => c.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (question.isEmpty || options.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a question and at least 2 options')),
      );
      return;
    }
    setState(() => _sending = true);
    try {
      await widget.onSubmit(question, options);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create poll: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36, height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                        color: AppTheme.muted.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const Text('Create Poll',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppTheme.onSurface,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 20),
                TextField(
                  controller: _questionCtrl,
                  style: const TextStyle(color: AppTheme.onSurface),
                  decoration: InputDecoration(
                    labelText: 'Question',
                    labelStyle: const TextStyle(color: AppTheme.muted),
                    filled: true,
                    fillColor: AppTheme.surface,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Options',
                    style: TextStyle(
                        color: AppTheme.muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                ...List.generate(_optionCtrls.length, (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _optionCtrls[i],
                          style: const TextStyle(color: AppTheme.onSurface),
                          decoration: InputDecoration(
                            hintText: 'Option ${i + 1}',
                            hintStyle: TextStyle(color: AppTheme.muted.withValues(alpha: 0.5)),
                            filled: true,
                            fillColor: AppTheme.surface,
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                          ),
                        ),
                      ),
                      if (_optionCtrls.length > 2)
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline_rounded,
                              color: AppTheme.danger, size: 20),
                          onPressed: () => _removeOption(i),
                        ),
                    ],
                  ),
                )),
                if (_optionCtrls.length < 5)
                  TextButton.icon(
                    onPressed: _addOption,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Add option'),
                    style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
                  ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _sending ? null : _send,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _sending
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Create Poll',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Mention + Link text ───────────────────────────────────────
// Renders @mentions in primary blue and URLs as tappable links.

class _MentionLinkText extends StatelessWidget {
  final String text;
  final TextStyle? style;

  static final _tokenRe = RegExp(
    r'(@\w+)|(https?://[^\s]+|www\.[a-zA-Z0-9\-]+\.[^\s]+)',
    caseSensitive: false,
  );

  const _MentionLinkText(this.text, {this.style});

  Future<void> _launch(String raw) async {
    final url = raw.startsWith('http') ? raw : 'https://$raw';
    final uri = Uri.tryParse(url);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final base = style ?? const TextStyle(color: Colors.white, fontSize: 15, height: 1.35);
    final matches = _tokenRe.allMatches(text).toList();
    if (matches.isEmpty) return Text(text, style: base);

    final spans = <InlineSpan>[];
    int cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, m.start)));
      }
      final token = m.group(0)!;
      if (token.startsWith('@')) {
        spans.add(TextSpan(
          text: token,
          style: base.copyWith(color: AppTheme.primary, fontWeight: FontWeight.w600),
        ));
      } else {
        spans.add(TextSpan(
          text: token,
          style: base.copyWith(
            color: const Color(0xFF7AB8F5),
            decoration: TextDecoration.underline,
            decorationColor: const Color(0xFF7AB8F5),
          ),
          recognizer: TapGestureRecognizer()..onTap = () => _launch(token),
        ));
      }
      cursor = m.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return RichText(text: TextSpan(style: base, children: spans));
  }
}
