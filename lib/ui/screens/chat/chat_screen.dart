import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import '../../../core/theme.dart';
import '../../../data/local/secure_storage.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/message.dart';
import '../../../providers/contacts_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/messages_provider.dart';
import '../../../services/lan_transport.dart';
import '../../../services/media_service.dart';
import '../../../services/messaging_service.dart';
import '../../../services/signaling_service.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/user_avatar.dart';
import '../../widgets/voice_note_player.dart';

class ChatScreen extends StatefulWidget {
  final Contact contact;
  const ChatScreen({super.key, required this.contact});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final Map<String, String> _decryptedCache = {};
  final Map<String, GlobalKey> _msgKeys = {};
  late final MessagingService _msgService;

  Message? _replyTo;
  Message? _editingMsg;
  bool _showScrollToBottom = false;
  bool _uploading = false;
  Timer? _pollTimer;
  DateTime? _lastTypingSent;

  // Voice note recording
  final _recorder = AudioRecorder();
  bool _hasText = false;
  bool _isRecording = false;
  Duration _recordDuration = Duration.zero;
  Timer? _recordTimer;
  double _cancelSlide = 0;

  @override
  void initState() {
    super.initState();
    _msgService = MessagingService(context.read<SignalingService>());
    _scrollCtrl.addListener(_onScroll);
    _ctrl.addListener(_onTextFieldChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      context.read<MessagesProvider>().setActiveChat(widget.contact.contactId);
      await context.read<MessagesProvider>().loadChat(widget.contact.contactId);
      await context
          .read<MessagesProvider>()
          .markMessagesRead(widget.contact.contactId);
      await _decryptAll();
      // reverse: true ListView always opens at the bottom — no manual scroll needed.
    });

    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) {
        context.read<MessagesProvider>().loadChat(widget.contact.contactId);
      }
    });
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    // With reverse: true, position 0 is the bottom (latest messages).
    final nearBottom = _scrollCtrl.position.pixels <= 120;
    if (nearBottom == _showScrollToBottom) {
      setState(() => _showScrollToBottom = !nearBottom);
    }
  }

  String _senderPublicKey() {
    final fresh =
        context.read<ContactsProvider>().getById(widget.contact.contactId);
    return fresh?.publicKey ?? widget.contact.publicKey;
  }

  Future<void> _decryptAll() async {
    final msgs =
        context.read<MessagesProvider>().getChat(widget.contact.contactId);
    final senderKey = _senderPublicKey();
    for (final m in msgs) {
      if (m.decryptedContent != null) continue;
      if (!_decryptedCache.containsKey(m.id)) {
        try {
          final plain = await _msgService.decryptMessage(
            encryptedContent: m.encryptedContent,
            nonce: m.nonce,
            senderPublicKey: senderKey,
          );
          _decryptedCache[m.id] = plain;
        } catch (_) {
          _decryptedCache[m.id] = m.encryptedContent;
        }
      }
    }
    if (mounted) setState(() {});
  }

  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      // With reverse: true, position 0 is the bottom.
      if (animated) {
        _scrollCtrl.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        _scrollCtrl.jumpTo(0);
      }
    });
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
  }

  void _onTextChanged(String text) {
    if (text.isEmpty) return;
    final now = DateTime.now();
    if (_lastTypingSent == null ||
        now.difference(_lastTypingSent!).inSeconds >= 3) {
      _lastTypingSent = now;
      context
          .read<SignalingService>()
          .sendTyping(recipientVirtualId: widget.contact.virtualId);
    }
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;

    if (_editingMsg != null) {
      final msg = _editingMsg!;
      _ctrl.clear();
      setState(() => _editingMsg = null);
      _decryptedCache[msg.id] = text;
      try {
        await context.read<MessagesProvider>().editMessage(
              peerId: widget.contact.contactId,
              messageId: msg.id,
              newContent: text,
              recipientVirtualId: widget.contact.virtualId,
            );
      } catch (e) {
        if (mounted) _showError('Failed to edit: $e');
      }
      return;
    }

    final replyToId = _replyTo?.id;
    _ctrl.clear();
    setState(() => _replyTo = null);

    try {
      final freshContact =
          context.read<ContactsProvider>().getById(widget.contact.contactId);
      final recipientPublicKey =
          freshContact?.publicKey ?? widget.contact.publicKey;
      await context.read<MessagesProvider>().sendMessage(
            recipientId: widget.contact.contactId,
            recipientVirtualId: widget.contact.virtualId,
            recipientPublicKey: recipientPublicKey,
            plaintext: text,
            replyToId: replyToId,
          );
      _scrollToBottom();
    } catch (e) {
      if (mounted) _showError('Failed to send: $e');
    }
  }

  /// Called when the user picks a GIF/image from the keyboard's media panel.
  Future<void> _onKeyboardMediaInserted(KeyboardInsertedContent content) async {
    final bytes = content.data;
    if (bytes == null || bytes.isEmpty) return;

    // Derive extension from MIME type
    final ext = content.mimeType.split('/').last; // e.g. 'gif', 'png'
    final tmpDir = await getTemporaryDirectory();
    final tmpFile = File(
        '${tmpDir.path}/keyboard_insert_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await tmpFile.writeAsBytes(bytes);

    await _pickAndSendDirect(() async => tmpFile);
  }

  Future<void> _pickAndSend(Future<File?> Function() picker) async {
    Navigator.pop(context);
    await _pickAndSendDirect(picker);
  }

  Future<void> _pickAndSendDirect(Future<File?> Function() picker) async {
    File? file;
    try {
      file = await picker();
    } catch (_) {
      if (mounted) _showError('Could not access file');
      return;
    }
    if (file == null) return;

    setState(() => _uploading = true);
    try {
      final token = await SecureStorage.getToken() ?? '';
      final meta = await MediaService.upload(file, token);
      if (!mounted) return;
      final freshContact =
          context.read<ContactsProvider>().getById(widget.contact.contactId);
      final recipientPublicKey =
          freshContact?.publicKey ?? widget.contact.publicKey;
      await context.read<MessagesProvider>().sendMessage(
            recipientId: widget.contact.contactId,
            recipientVirtualId: widget.contact.virtualId,
            recipientPublicKey: recipientPublicKey,
            plaintext: '',
            replyToId: _replyTo?.id,
            attachmentUrl: meta.url,
            attachmentType: meta.type,
            attachmentName: meta.name,
            attachmentSize: meta.size,
          );
      setState(() => _replyTo = null);
      _scrollToBottom();
    } catch (e) {
      if (mounted) _showError('Upload failed: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showAttachmentPicker() {
    // Unfocus the text field BEFORE opening the picker.
    // Without this, Android's input method tries to commit the selected
    // media directly into the focused TextField → "can't enter content here".
    FocusManager.instance.primaryFocus?.unfocus();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.muted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _OptionTile(
              icon: Icons.camera_alt_rounded,
              label: 'Camera photo',
              onTap: () => _pickAndSend(MediaService.pickFromCamera),
            ),
            _OptionTile(
              icon: Icons.videocam_rounded,
              label: 'Record video',
              onTap: () async {
                Navigator.pop(context);
                final statuses = await [
                  Permission.camera,
                  Permission.microphone,
                ].request();
                final denied = statuses.values
                    .any((s) => s.isDenied || s.isPermanentlyDenied);
                if (denied) {
                  if (mounted) {
                    _showError('Camera and microphone permissions are required');
                  }
                  return;
                }
                if (mounted) _pickAndSendDirect(MediaService.recordVideo);
              },
            ),
            _OptionTile(
              icon: Icons.photo_library_rounded,
              label: 'Gallery',
              onTap: () => _pickAndSend(MediaService.pickFromGallery),
            ),
            _OptionTile(
              icon: Icons.video_library_rounded,
              label: 'Video from gallery',
              onTap: () => _pickAndSend(MediaService.pickVideoFromGallery),
            ),
            _OptionTile(
              icon: Icons.insert_drive_file_rounded,
              label: 'File',
              onTap: () => _pickAndSend(MediaService.pickFile),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _startEditing(Message m, String text) {
    setState(() {
      _editingMsg = m;
      _replyTo = null;
    });
    _ctrl.text = text;
    _ctrl.selection =
        TextSelection.fromPosition(TextPosition(offset: text.length));
  }

  static const _quickEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥'];

  void _showMessageOptions(Message m, String? decryptedText) {
    final provider = context.read<MessagesProvider>();
    final myUserId = context.read<AuthProvider>().userId ?? '';
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 12),
              decoration: BoxDecoration(
                color: AppTheme.muted.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // ── Emoji reaction bar ────────────────────────────
            if (!m.isDeleted)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: _quickEmojis.map((emoji) {
                    final reacted =
                        m.reactions[emoji]?.contains(myUserId) == true;
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        provider.addReaction(
                          peerId: widget.contact.contactId,
                          messageId: m.id,
                          emoji: emoji,
                          recipientVirtualId: widget.contact.virtualId,
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: reacted
                            ? BoxDecoration(
                                color: AppTheme.primary
                                    .withValues(alpha: 0.25),
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: AppTheme.primary, width: 1.5),
                              )
                            : null,
                        child: Text(emoji,
                            style: const TextStyle(fontSize: 26)),
                      ),
                    );
                  }).toList(),
                ),
              ),
            const Divider(height: 1, color: Color(0xFF2A3A4A)),
            if (decryptedText != null && !m.isDeleted)
              _OptionTile(
                icon: Icons.copy_rounded,
                label: 'Copy',
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: decryptedText));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                },
              ),
            if (!m.isDeleted)
              _OptionTile(
                icon: Icons.reply_rounded,
                label: 'Reply',
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _replyTo = m);
                },
              ),
            if (!m.isDeleted)
              _OptionTile(
                icon: Icons.forward_rounded,
                label: 'Forward',
                onTap: () {
                  Navigator.pop(context);
                  _showForwardPicker(m, decryptedText);
                },
              ),
            if (m.isOutgoing && !m.isDeleted)
              _OptionTile(
                icon: Icons.edit_rounded,
                label: 'Edit',
                onTap: () {
                  Navigator.pop(context);
                  _startEditing(m, decryptedText ?? '');
                },
              ),
            if (m.isOutgoing && !m.isDeleted)
              _OptionTile(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                color: AppTheme.danger,
                onTap: () {
                  Navigator.pop(context);
                  _confirmDelete(m);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(Message m) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete message'),
        content: const Text(
            'This message will be deleted for both you and the recipient.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child:
                const Text('Delete', style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      try {
        await context.read<MessagesProvider>().deleteMessage(
              peerId: widget.contact.contactId,
              messageId: m.id,
              recipientVirtualId: widget.contact.virtualId,
            );
      } catch (e) {
        if (mounted) _showError('Failed to delete: $e');
      }
    }
  }

  void _showForwardPicker(Message m, String? decryptedText) {
    final contacts = context.read<ContactsProvider>().contacts;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.muted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Forward to...',
                style: TextStyle(
                    color: AppTheme.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w500),
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2A3A4A)),
            if (contacts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('No contacts',
                    style: TextStyle(color: AppTheme.muted)),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight:
                        MediaQuery.of(ctx).size.height * 0.5),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: contacts.length,
                  itemBuilder: (_, i) {
                    final c = contacts[i];
                    return ListTile(
                      leading: UserAvatar(
                        username: c.username,
                        avatarUrl: c.avatarUrl,
                        radius: 22,
                      ),
                      title: Text(c.username,
                          style: const TextStyle(
                              color: AppTheme.onSurface, fontSize: 15)),
                      subtitle: Text(c.virtualId,
                          style: const TextStyle(
                              color: AppTheme.muted, fontSize: 12)),
                      onTap: () {
                        Navigator.pop(ctx);
                        _doForward(m, decryptedText, c);
                      },
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _doForward(
      Message m, String? decryptedText, Contact target) async {
    try {
      final freshTarget =
          context.read<ContactsProvider>().getById(target.contactId);
      final recipientPublicKey =
          freshTarget?.publicKey ?? target.publicKey;
      await context.read<MessagesProvider>().sendMessage(
            recipientId: target.contactId,
            recipientVirtualId: target.virtualId,
            recipientPublicKey: recipientPublicKey,
            plaintext: decryptedText ?? '',
            attachmentUrl: m.attachmentUrl,
            attachmentType: m.attachmentType,
            attachmentName: m.attachmentName,
            attachmentSize: m.attachmentSize,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Forwarded to ${target.username}')),
        );
      }
    } catch (e) {
      if (mounted) _showError('Forward failed: $e');
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  // ── Voice note recording ─────────────────────────────────

  void _onTextFieldChanged() {
    final hasText = _ctrl.text.isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  String _fmtRecordDuration(Duration d) {
    final m = d.inMinutes.toString();
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) _showError('Microphone permission required for voice notes');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
        ),
        path: path,
      );
      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _recordDuration = Duration.zero;
        _cancelSlide = 0;
      });
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordDuration += const Duration(seconds: 1));
      });
    } catch (e) {
      if (mounted) _showError('Could not start recording: $e');
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    _recordTimer?.cancel();
    final path = await _recorder.stop();
    final duration = _recordDuration;
    if (mounted) setState(() { _isRecording = false; _cancelSlide = 0; });
    if (path != null && duration.inSeconds >= 1 && mounted) {
      _showVoiceNotePreview(path);
    }
  }

  Future<void> _cancelRecording() async {
    if (!_isRecording) return;
    _recordTimer?.cancel();
    await _recorder.cancel();
    if (mounted) setState(() { _isRecording = false; _cancelSlide = 0; });
  }

  void _showVoiceNotePreview(String path) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _VoiceNotePreviewSheet(
        path: path,
        onSend: (effectId) => _uploadAndSendVoiceNote(path, effectId),
      ),
    );
  }

  Future<void> _uploadAndSendVoiceNote(String path, String? effectId) async {
    setState(() => _uploading = true);
    try {
      final token = await SecureStorage.getToken() ?? '';
      final file = File(path);
      final meta = await MediaService.upload(file, token);
      if (!mounted) return;
      final freshContact =
          context.read<ContactsProvider>().getById(widget.contact.contactId);
      final recipientPublicKey =
          freshContact?.publicKey ?? widget.contact.publicKey;
      final effectiveName =
          (effectId != null && effectId != 'normal')
              ? 'voice_note.m4a#$effectId'
              : 'voice_note.m4a';
      await context.read<MessagesProvider>().sendMessage(
            recipientId: widget.contact.contactId,
            recipientVirtualId: widget.contact.virtualId,
            recipientPublicKey: recipientPublicKey,
            plaintext: '',
            attachmentUrl: meta.url,
            attachmentType: 'audio',
            attachmentName: effectiveName,
            attachmentSize: meta.size,
          );
      _scrollToBottom();
    } catch (e) {
      if (mounted) _showError('Failed to send voice note: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _recordTimer?.cancel();
    _recorder.dispose();
    _ctrl.removeListener(_onTextFieldChanged);
    _ctrl.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    // Let provider know this chat is no longer active
    try {
      context.read<MessagesProvider>().clearActiveChat();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessagesProvider>();
    final myUserId = context.read<AuthProvider>().userId ?? '';
    final msgs = provider.getChat(widget.contact.contactId);
    final isTyping = provider.isTyping(widget.contact.contactId);

    // Decrypt newly arrived messages
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool changed = false;
      final senderKey = _senderPublicKey();
      for (final m in msgs) {
        if (m.decryptedContent != null) continue;
        if (!_decryptedCache.containsKey(m.id)) {
          try {
            final plain = await _msgService.decryptMessage(
              encryptedContent: m.encryptedContent,
              nonce: m.nonce,
              senderPublicKey: senderKey,
            );
            _decryptedCache[m.id] = plain;
            changed = true;
          } catch (_) {
            _decryptedCache[m.id] = m.encryptedContent;
            changed = true;
          }
        }
      }
      if (changed && mounted) setState(() {});
    });

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: _buildAppBar(isTyping),
      body: Stack(
        children: [
          // Background
          const Positioned.fill(child: _ChatBackground()),
          // Main content
          Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    _buildMessageList(msgs, isTyping, provider, myUserId),
                    if (_showScrollToBottom)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: _ScrollToBottomFab(onTap: _scrollToBottom),
                      ),
                  ],
                ),
              ),
              if (_replyTo != null) _buildReplyBar(),
              if (_editingMsg != null) _buildEditBar(),
              _buildInputBar(),
            ],
          ),
        ],
      ),
    );
  }

  String _lastSeenLabel(Contact c) {
    if (c.isOnline) return 'online';
    if (c.lastSeen == null) return c.virtualId;
    final ls = c.lastSeen!.toLocal();
    final now = DateTime.now();
    final today = DateUtils.isSameDay(ls, now);
    final yesterday =
        DateUtils.isSameDay(ls, now.subtract(const Duration(days: 1)));
    final timeStr = DateFormat('HH:mm').format(ls);
    if (today) return 'last seen today at $timeStr';
    if (yesterday) return 'last seen yesterday at $timeStr';
    return 'last seen ${DateFormat('d MMM').format(ls)} at $timeStr';
  }

  Contact get _liveContact =>
      context.read<ContactsProvider>().getById(widget.contact.contactId) ?? widget.contact;

  void _showContactInfo() {
    final contact = _liveContact;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ContactInfoSheet(contact: contact),
    );
  }

  PreferredSizeWidget _buildAppBar(bool isTyping) {
    final contact = context.watch<ContactsProvider>().getById(widget.contact.contactId) ?? widget.contact;
    return AppBar(
      backgroundColor: AppTheme.inputBg,
      titleSpacing: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () => Navigator.pop(context),
      ),
      title: GestureDetector(
        onTap: _showContactInfo,
        behavior: HitTestBehavior.opaque,
        child: Row(
        children: [
          Stack(
            children: [
              UserAvatar(
                username: contact.username,
                avatarUrl: contact.avatarUrl,
                radius: 20,
              ),
              if (contact.isOnline)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: AppTheme.accent,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppTheme.inputBg, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  contact.username,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.onSurface),
                  overflow: TextOverflow.ellipsis,
                ),
                StreamBuilder<Set<String>>(
                  stream: LanTransport.instance.reachableStream,
                  initialData: LanTransport.instance.reachablePeers,
                  builder: (context, snap) {
                    final serverConnected = context.read<SignalingService>().isConnected;
                    final lanReachable = !serverConnected &&
                        (snap.data?.contains(widget.contact.virtualId) ?? false);
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: isTyping
                          ? const Text(
                              'typing...',
                              key: ValueKey('typing'),
                              style: TextStyle(
                                fontSize: 12,
                                color: AppTheme.accent,
                                fontStyle: FontStyle.italic,
                              ),
                            )
                          : lanReachable
                              ? const Row(
                                  key: ValueKey('lan'),
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.wifi_rounded,
                                        size: 12, color: AppTheme.accent),
                                    SizedBox(width: 4),
                                    Text(
                                      'LAN',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.accent,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                )
                              : Text(
                                  _lastSeenLabel(contact),
                                  key: const ValueKey('status'),
                                  style: const TextStyle(
                                      fontSize: 12, color: AppTheme.muted),
                                  overflow: TextOverflow.ellipsis,
                                ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.call_rounded, color: AppTheme.onSurface),
          onPressed: () => Navigator.pushNamed(context, '/call/outgoing',
              arguments: widget.contact),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded, color: AppTheme.onSurface),
          color: AppTheme.surface,
          onSelected: (value) async {
            if (value == 'clear') {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Clear chat'),
                  content: const Text('Delete all messages in this chat?'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Clear',
                          style: TextStyle(color: AppTheme.danger)),
                    ),
                  ],
                ),
              );
              if (confirm == true && mounted) {
                await context
                    .read<MessagesProvider>()
                    .clearChat(widget.contact.contactId);
                _decryptedCache.clear();
              }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'clear', child: Text('Clear chat')),
          ],
        ),
      ],
    );
  }

  Widget _buildMessageList(List<Message> msgs, bool isTyping, MessagesProvider provider, String myUserId) {
    if (msgs.isEmpty && !isTyping) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppTheme.surface.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Icon(Icons.chat_bubble_outline_rounded,
                      size: 48, color: AppTheme.muted.withValues(alpha: 0.6)),
                  const SizedBox(height: 8),
                  Text(
                    'No messages yet',
                    style: TextStyle(
                        color: AppTheme.muted.withValues(alpha: 0.8),
                        fontSize: 14),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final items = <Widget>[];
    DateTime? prevDate;

    for (int i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      final msgDate = DateUtils.dateOnly(m.createdAt.toLocal());
      if (prevDate == null || msgDate != prevDate) {
        items.add(_DateSeparator(date: m.createdAt));
        prevDate = msgDate;
      }

      final plain = m.decryptedContent ?? _decryptedCache[m.id];
      String? replyText;
      String? replySenderName;
      if (m.replyToId != null) {
        final idx = msgs.indexWhere((x) => x.id == m.replyToId);
        if (idx != -1) {
          final rm = msgs[idx];
          replyText = rm.decryptedContent ?? _decryptedCache[rm.id] ?? '...';
          replySenderName = rm.isOutgoing ? 'You' : widget.contact.username;
        }
      }

      // Find the next audio message after this one for auto-play chaining
      String? nextAudioSource;
      if (m.attachmentType == 'audio' && m.attachmentUrl != null) {
        for (int j = i + 1; j < msgs.length; j++) {
          if (msgs[j].attachmentType == 'audio' && msgs[j].attachmentUrl != null) {
            nextAudioSource = MediaService.fullUrl(msgs[j].attachmentUrl!);
            break;
          }
        }
      }

      final msgKey = _msgKeys.putIfAbsent(m.id, () => GlobalKey());
      items.add(SizedBox(
        key: msgKey,
        child: MessageBubble(
          key: ValueKey(m.id),
          message: m,
          myUserId: myUserId,
          peerName: widget.contact.username,
          decryptedText: plain,
          replyToText: replyText,
          replyToSender: replySenderName,
          onReply: () => setState(() => _replyTo = m),
          onReplyTap: m.replyToId != null
              ? () => _scrollToMessage(m.replyToId!)
              : null,
          onLongPress: () => _showMessageOptions(m, plain),
          onReact: (emoji) => provider.addReaction(
            peerId: widget.contact.contactId,
            messageId: m.id,
            emoji: emoji,
            recipientVirtualId: widget.contact.virtualId,
          ),
          nextAudioSource: nextAudioSource,
        ),
      ));
    }

    // Typing bubble at the bottom
    if (isTyping) {
      items.add(const _TypingBubble());
    }

    return ListView(
      controller: _scrollCtrl,
      reverse: true,
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      children: items.reversed.toList(),
    );
  }

  Widget _buildReplyBar() {
    final m = _replyTo!;
    final text = m.decryptedContent ?? _decryptedCache[m.id] ?? '...';
    final sender = m.isOutgoing ? 'You' : widget.contact.username;

    return Container(
      color: AppTheme.inputBg,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 38,
            decoration: BoxDecoration(
              color: AppTheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(sender,
                    style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(text,
                    style: const TextStyle(
                        color: AppTheme.muted, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                size: 18, color: AppTheme.muted),
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  Widget _buildEditBar() {
    return Container(
      color: AppTheme.inputBg,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          const Icon(Icons.edit_rounded, size: 18, color: AppTheme.primary),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Editing message',
              style: TextStyle(
                  color: AppTheme.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                size: 18, color: AppTheme.muted),
            onPressed: () {
              setState(() => _editingMsg = null);
              _ctrl.clear();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    final isEditing = _editingMsg != null;
    final showSend = _hasText || isEditing;

    return Container(
      color: AppTheme.inputBg,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_uploading)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  color: AppTheme.primary,
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // ── Recording active: show recording indicator ──
                if (_isRecording)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, bottom: 11),
                      child: Row(
                        children: [
                          const _PulsingRecordDot(),
                          const SizedBox(width: 8),
                          Text(
                            _fmtRecordDuration(_recordDuration),
                            style: const TextStyle(
                              color: AppTheme.danger,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Icon(Icons.arrow_back_ios_rounded,
                              size: 13,
                              color: AppTheme.muted.withValues(alpha: 0.5)),
                          const SizedBox(width: 2),
                          Text(
                            'Slide to cancel',
                            style: TextStyle(
                              color: AppTheme.muted.withValues(alpha: 0.5),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                      ),
                    ),
                  )
                // ── Normal: attachment + text field ─────────────
                else ...[
                  if (!isEditing)
                    GestureDetector(
                      onTap: _uploading ? null : _showAttachmentPicker,
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.attach_file_rounded,
                          color: _uploading
                              ? AppTheme.muted.withValues(alpha: 0.4)
                              : AppTheme.muted,
                          size: 22,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const SizedBox(width: 14),
                          Expanded(
                            child: TextField(
                              controller: _ctrl,
                              textCapitalization: TextCapitalization.sentences,
                              minLines: 1,
                              maxLines: 5,
                              onChanged: _onTextChanged,
                              style: const TextStyle(
                                  color: AppTheme.onSurface, fontSize: 15),
                              decoration: const InputDecoration(
                                hintText: 'Message',
                                hintStyle: TextStyle(color: AppTheme.muted),
                                contentPadding:
                                    EdgeInsets.symmetric(vertical: 12),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                filled: false,
                              ),
                              onSubmitted: (_) => _send(),
                              contentInsertionConfiguration:
                                  ContentInsertionConfiguration(
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
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                // ── Send button (when typing / editing) ─────────
                if (showSend)
                  GestureDetector(
                    onTap: _uploading ? null : _send,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _uploading
                            ? AppTheme.primary.withValues(alpha: 0.5)
                            : AppTheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isEditing ? Icons.check_rounded : Icons.send_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  )
                // ── Mic button (long-press to record) ───────────
                else
                  GestureDetector(
                    onLongPressStart: (_) => _startRecording(),
                    onLongPressMoveUpdate: (d) {
                      final dx = d.offsetFromOrigin.dx;
                      setState(() => _cancelSlide = dx);
                      if (dx < -80 && _isRecording) _cancelRecording();
                    },
                    onLongPressEnd: (_) {
                      if (_isRecording) _stopRecording();
                    },
                    onLongPressCancel: () {
                      if (_isRecording) _cancelRecording();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _isRecording
                            ? AppTheme.danger
                            : AppTheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.mic_rounded,
                          color: Colors.white, size: 22),
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

// ── Chat Background ─────────────────────────────────────────

class _ChatBackground extends StatelessWidget {
  const _ChatBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0F1923), Color(0xFF17212B), Color(0xFF1A2535)],
          stops: [0.0, 0.5, 1.0],
        ),
      ),
      child: CustomPaint(
        painter: _BackgroundPatternPainter(),
        size: Size.infinite,
      ),
    );
  }
}

class _BackgroundPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1E3045).withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;

    const spacing = 52.0;
    const r = 2.5;

    for (double row = 0; row * spacing < size.height + spacing; row++) {
      final yOff = row * spacing;
      final xShift = (row.toInt() % 2 == 0) ? 0.0 : spacing / 2;
      for (double col = -1; col * spacing < size.width + spacing; col++) {
        canvas.drawCircle(Offset(col * spacing + xShift, yOff), r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}

// ── Typing bubble with animated dots ────────────────────────

class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with TickerProviderStateMixin {
  final List<AnimationController> _ctrls = [];
  final List<Animation<double>> _anims = [];

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 3; i++) {
      final c = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 500),
      );
      final a = Tween<double>(begin: 0, end: -7).animate(
        CurvedAnimation(parent: c, curve: Curves.easeInOut),
      );
      _ctrls.add(c);
      _anims.add(a);
    }
    _startBounce();
  }

  void _startBounce() async {
    while (mounted) {
      for (int i = 0; i < 3; i++) {
        if (!mounted) return;
        _ctrls[i].forward(from: 0).then((_) {
          if (mounted) _ctrls[i].reverse();
        });
        await Future.delayed(const Duration(milliseconds: 160));
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 2, bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppTheme.incomingBubble,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(4),
              bottomRight: Radius.circular(16),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(
              3,
              (i) => AnimatedBuilder(
                animation: _anims[i],
                builder: (_, __) => Transform.translate(
                  offset: Offset(0, _anims[i].value),
                  child: Container(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 3),
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: AppTheme.muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Date separator ───────────────────────────────────────────

class _DateSeparator extends StatelessWidget {
  final DateTime date;
  const _DateSeparator({required this.date});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final local = date.toLocal();
    final String label;
    if (DateUtils.isSameDay(local, now)) {
      label = 'Today';
    } else if (DateUtils.isSameDay(
        local, now.subtract(const Duration(days: 1)))) {
      label = 'Yesterday';
    } else {
      label = DateFormat('MMMM d, y').format(local);
    }

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: AppTheme.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: const TextStyle(
              color: AppTheme.muted,
              fontSize: 12,
              fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

// ── Scroll-to-bottom FAB ─────────────────────────────────────

class _ScrollToBottomFab extends StatelessWidget {
  final VoidCallback onTap;
  const _ScrollToBottomFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppTheme.surface,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Icon(Icons.keyboard_arrow_down_rounded,
            color: AppTheme.muted, size: 22),
      ),
    );
  }
}

// ── Option tile ───────────────────────────────────────────────

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _OptionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.onSurface;
    return ListTile(
      leading: Icon(icon, color: c, size: 22),
      title: Text(label, style: TextStyle(color: c, fontSize: 15)),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      minLeadingWidth: 24,
    );
  }
}

// ── Contact Info Bottom Sheet ──────────────────────────────────────────────

class _ContactInfoSheet extends StatelessWidget {
  final Contact contact;
  const _ContactInfoSheet({required this.contact});

  String _lastSeenFull() {
    if (contact.isOnline) return 'online';
    if (contact.lastSeen == null) return 'last seen: unknown';
    final ls = contact.lastSeen!.toLocal();
    final now = DateTime.now();
    final today = DateUtils.isSameDay(ls, now);
    final yesterday =
        DateUtils.isSameDay(ls, now.subtract(const Duration(days: 1)));
    final timeStr = DateFormat('HH:mm').format(ls);
    if (today) return 'last seen today at $timeStr';
    if (yesterday) return 'last seen yesterday at $timeStr';
    return 'last seen ${DateFormat('d MMM yyyy').format(ls)} at $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    final avatarColor = AppTheme.avatarColor(contact.username);

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.muted.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // Avatar
          Stack(
            children: [
              UserAvatar(
                username: contact.username,
                avatarUrl: contact.avatarUrl,
                radius: 48,
                backgroundColor: avatarColor,
              ),
              if (contact.isOnline)
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: AppTheme.accent,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppTheme.surface, width: 2.5),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),

          // Username
          Text(
            contact.username,
            style: const TextStyle(
              color: AppTheme.onSurface,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),

          // Last seen
          Text(
            _lastSeenFull(),
            style: TextStyle(
              color: contact.isOnline ? AppTheme.accent : AppTheme.muted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 24),

          // Divider
          Divider(height: 1, color: AppTheme.divider),

          // Pager ID row
          ListTile(
            leading: const Icon(Icons.tag_rounded, color: AppTheme.primary, size: 22),
            title: const Text('Pager ID',
                style: TextStyle(color: AppTheme.muted, fontSize: 12)),
            subtitle: Text(
              contact.virtualId,
              style: const TextStyle(
                  color: AppTheme.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w500),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.copy_rounded, size: 18, color: AppTheme.muted),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: contact.virtualId));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Pager ID copied')),
                );
              },
            ),
          ),

          Divider(height: 1, color: AppTheme.divider),

          // Action buttons
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ActionButton(
                  icon: Icons.message_rounded,
                  label: 'Message',
                  color: AppTheme.primary,
                  onTap: () => Navigator.pop(context),
                ),
                _ActionButton(
                  icon: Icons.call_rounded,
                  label: 'Call',
                  color: AppTheme.accent,
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.pushNamed(context, '/call/outgoing',
                        arguments: contact);
                  },
                ),
              ],
            ),
          ),

          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

// ── Pulsing red dot shown during recording ────────────────────

class _PulsingRecordDot extends StatefulWidget {
  const _PulsingRecordDot();

  @override
  State<_PulsingRecordDot> createState() => _PulsingRecordDotState();
}

class _PulsingRecordDotState extends State<_PulsingRecordDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700))
      ..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.35, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: AppTheme.danger,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

// ── Voice note preview / send sheet ──────────────────────────

class _VoiceNotePreviewSheet extends StatefulWidget {
  final String path;
  final void Function(String? effectId) onSend;

  const _VoiceNotePreviewSheet({
    required this.path,
    required this.onSend,
  });

  @override
  State<_VoiceNotePreviewSheet> createState() =>
      _VoiceNotePreviewSheetState();
}

class _VoiceNotePreviewSheetState extends State<_VoiceNotePreviewSheet> {
  String _effectId = 'normal';
  bool _dubMode = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: AppTheme.muted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Player preview
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.inputBg,
                borderRadius: BorderRadius.circular(16),
              ),
              child: VoiceNotePlayer(
                key: ValueKey('preview_$_effectId'),
                source: widget.path,
                isFile: true,
                effectId: _effectId,
                isOutgoing: false,
                autoLoad: true,
              ),
            ),

            // Voice effect picker (shown when dub mode active)
            if (_dubMode) ...[
              const SizedBox(height: 16),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'VOICE EFFECT',
                  style: TextStyle(
                    color: AppTheme.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: kVoiceEffects.map((effect) {
                    final selected = _effectId == effect.id;
                    return GestureDetector(
                      onTap: () => setState(() => _effectId = effect.id),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: selected
                              ? AppTheme.primary.withValues(alpha: 0.18)
                              : AppTheme.inputBg,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: selected
                                ? AppTheme.primary
                                : Colors.white.withValues(alpha: 0.1),
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(effect.emoji,
                                style: const TextStyle(fontSize: 18)),
                            const SizedBox(width: 6),
                            Text(
                              effect.label,
                              style: TextStyle(
                                color: selected
                                    ? AppTheme.primary
                                    : AppTheme.onSurface,
                                fontSize: 13,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],

            const SizedBox(height: 20),

            // Action buttons
            Row(
              children: [
                // Discard
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: const Text('Discard'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                      side: BorderSide(
                          color: AppTheme.danger.withValues(alpha: 0.5)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Dub voice toggle
                OutlinedButton.icon(
                  onPressed: () => setState(() => _dubMode = !_dubMode),
                  icon: Icon(
                    _dubMode
                        ? Icons.mic_rounded
                        : Icons.auto_fix_high_rounded,
                    size: 18,
                  ),
                  label: Text(_dubMode ? 'Normal' : 'Dub Voice'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _dubMode
                        ? AppTheme.primary
                        : AppTheme.onSurface,
                    side: BorderSide(
                      color: _dubMode
                          ? AppTheme.primary
                          : AppTheme.muted.withValues(alpha: 0.4),
                    ),
                    padding: const EdgeInsets.symmetric(
                        vertical: 12, horizontal: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(width: 8),
                // Send
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onSend(
                          _effectId == 'normal' ? null : _effectId);
                    },
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: const Text('Send'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
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

