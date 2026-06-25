import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import '../../../core/theme.dart';
import '../../../data/local/secure_storage.dart';
import '../../../data/models/group.dart';
import '../../../data/models/group_message.dart';
import '../../../providers/groups_provider.dart';
import '../../../services/media_service.dart';
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
  GroupMessage? _replyTo;
  GroupMessage? _editingMsg;
  DateTime? _lastTypingSent;
  String _myId = '';
  Timer? _pollTimer;

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
    await provider.loadMessages(widget.group.id);
    // Poll every 30s as fallback
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) provider.loadMessages(widget.group.id);
    });
  }

  @override
  void dispose() {
    context.read<GroupsProvider>().clearActiveGroup();
    _ctrl.dispose();
    _scrollCtrl.dispose();
    _recorder.dispose();
    _pollTimer?.cancel();
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = _ctrl.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
    // Typing indicator throttle
    final now = DateTime.now();
    if (hasText && (_lastTypingSent == null || now.difference(_lastTypingSent!).inSeconds >= 3)) {
      _lastTypingSent = now;
      context.read<GroupsProvider>().sendTyping(widget.group.id);
    }
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
      await context.read<GroupsProvider>().sendMessage(
        groupId: widget.group.id,
        content: '',
        replyToId: _replyTo?.id,
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
          ],
        ),
      ),
    );
  }

  void _showMessageOptions(GroupMessage m) {
    final isMe = m.senderId == _myId;
    final group = context.read<GroupsProvider>().groupById(widget.group.id);
    final isAdmin = group?.isAdmin ?? false;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 12),
              decoration: BoxDecoration(color: AppTheme.muted.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)),
            ),
            ListTile(
              leading: const Icon(Icons.reply_rounded, color: AppTheme.primary),
              title: const Text('Reply'),
              onTap: () { Navigator.pop(context); setState(() => _replyTo = m); },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded, color: AppTheme.muted),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(context);
                Clipboard.setData(ClipboardData(text: m.content));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
              },
            ),
            if (isMe && !m.isDeleted && m.attachmentUrl == null)
              ListTile(
                leading: const Icon(Icons.edit_rounded, color: AppTheme.accent),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(context);
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
                  Navigator.pop(context);
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

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.inputBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.onSurface),
          onPressed: () => Navigator.pop(context),
        ),
        title: GestureDetector(
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
        actions: [
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
            icon: const Icon(Icons.info_outline_rounded, color: AppTheme.onSurface),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => GroupInfoScreen(group: group)),
            ).then((_) => setState(() {})),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: GroupChatBackground(themeId: group.themeId)),
          Column(children: [
          // Chat messages
          Expanded(
            child: msgs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.group_rounded, size: 56, color: AppTheme.muted.withValues(alpha: 0.4)),
                        const SizedBox(height: 12),
                        Text('Start the conversation in ${group.name}',
                            style: TextStyle(color: AppTheme.muted.withValues(alpha: 0.7), fontSize: 14),
                            textAlign: TextAlign.center),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    reverse: true,
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    itemCount: msgs.length,
                    itemBuilder: (_, idx) {
                      // reversed: idx=0 is the last message
                      final reversedMsgs = msgs.reversed.toList();
                      final m = reversedMsgs[idx];
                      final prevMsg = idx < reversedMsgs.length - 1 ? reversedMsgs[idx + 1] : null;
                      final showDate = prevMsg == null ||
                          !DateUtils.isSameDay(m.createdAt.toLocal(), prevMsg.createdAt.toLocal());
                      final nextAudioSource = _nextAudio(msgs, m);
                      return Column(
                        children: [
                          if (showDate) _DateSeparator(date: m.createdAt),
                          _GroupMessageBubble(
                            message: m,
                            myId: _myId,
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
                          ),
                        ],
                      );
                    },
                  ),
          ),
          if (_uploading)
            const LinearProgressIndicator(color: AppTheme.primary, backgroundColor: Colors.transparent),
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
                Text(r.isDeleted ? 'Deleted message' : (r.content.isNotEmpty ? r.content : '📎 Attachment'),
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

// ── Group message bubble ────────────────────────────────────

class _GroupMessageBubble extends StatelessWidget {
  final GroupMessage message;
  final String myId;
  final String? nextAudioSource;
  final GroupMessage? replyTo;
  final VoidCallback onLongPress;
  final void Function(String emoji) onReact;

  const _GroupMessageBubble({
    required this.message,
    required this.myId,
    this.nextAudioSource,
    this.replyTo,
    required this.onLongPress,
    required this.onReact,
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

    return GestureDetector(
      onLongPress: onLongPress,
      onDoubleTap: () => _showEmojiPicker(context),
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
                          Container(
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
                                      : (replyTo!.content.isNotEmpty ? replyTo!.content : '📎 Attachment'),
                                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
                                  maxLines: 2, overflow: TextOverflow.ellipsis,
                                ),
                              ],
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
    );
  }

  Widget _buildContent(BuildContext context, String time, Color metaColor, bool isMe) {
    final m = message;
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (attachmentWidget != null) ...[attachmentWidget, if (hasText) const SizedBox(height: 6)],
        if (hasText) Text(m.content, style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.35)),
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
