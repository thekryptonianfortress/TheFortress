import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/message.dart';
import '../../../providers/contacts_provider.dart';
import '../../../providers/messages_provider.dart';
import '../../../services/messaging_service.dart';
import '../../../services/signaling_service.dart';
import '../../widgets/message_bubble.dart';

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
  late final MessagingService _msgService;

  Message? _replyTo;
  Message? _editingMsg;
  bool _showScrollToBottom = false;
  Timer? _pollTimer;
  DateTime? _lastTypingSent;

  @override
  void initState() {
    super.initState();
    _msgService = MessagingService(context.read<SignalingService>());
    _scrollCtrl.addListener(_onScroll);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<MessagesProvider>().loadChat(widget.contact.contactId);
      await context.read<MessagesProvider>().markMessagesRead(widget.contact.contactId);
      await _decryptAll();
      _scrollToBottom();
    });

    // Polling fallback every 30s
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        context.read<MessagesProvider>().loadChat(widget.contact.contactId);
      }
    });
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final nearBottom =
        _scrollCtrl.position.pixels >= _scrollCtrl.position.maxScrollExtent - 120;
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
      if (_scrollCtrl.hasClients) {
        if (animated) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        } else {
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        }
      }
    });
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

  void _startEditing(Message m, String text) {
    setState(() {
      _editingMsg = m;
      _replyTo = null;
    });
    _ctrl.text = text;
    _ctrl.selection =
        TextSelection.fromPosition(TextPosition(offset: text.length));
  }

  void _showMessageOptions(Message m, String? decryptedText) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surfaceVariant,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              decoration: BoxDecoration(
                color: AppTheme.muted,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (decryptedText != null && !m.isDeleted)
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('Copy'),
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: decryptedText));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                },
              ),
            if (!m.isDeleted)
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _replyTo = m);
                },
              ),
            if (m.isOutgoing && !m.isDeleted)
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(context);
                  _startEditing(m, decryptedText ?? '');
                },
              ),
            if (m.isOutgoing && !m.isDeleted)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline_rounded, color: AppTheme.danger),
                title: const Text('Delete',
                    style: TextStyle(color: AppTheme.danger)),
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
            child: const Text('Delete',
                style: TextStyle(color: AppTheme.danger)),
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

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _ctrl.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessagesProvider>();
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
      appBar: AppBar(
        titleSpacing: 0,
        title: GestureDetector(
          onTap: () {}, // future: contact profile
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
                child: Text(
                  widget.contact.username.isNotEmpty
                      ? widget.contact.username[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                      color: AppTheme.primary, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.contact.username,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  Text(
                    isTyping ? 'typing...' : widget.contact.virtualId,
                    style: TextStyle(
                      fontSize: 11,
                      color: isTyping ? AppTheme.accent : AppTheme.muted,
                      fontStyle: isTyping
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.call_rounded),
            onPressed: () => Navigator.pushNamed(context, '/call/outgoing',
                arguments: widget.contact),
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'clear') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Clear chat'),
                    content:
                        const Text('Delete all messages in this chat?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Clear',
                            style: TextStyle(color: Colors.red)),
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
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                msgs.isEmpty
                    ? const Center(
                        child: Text('No messages yet',
                            style: TextStyle(color: AppTheme.muted)))
                    : _buildMessageList(msgs),
                if (_showScrollToBottom)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: FloatingActionButton.small(
                      heroTag: 'scroll_bottom',
                      onPressed: () => _scrollToBottom(),
                      backgroundColor: AppTheme.surfaceVariant,
                      elevation: 4,
                      child: const Icon(Icons.keyboard_arrow_down_rounded,
                          color: AppTheme.onSurface),
                    ),
                  ),
              ],
            ),
          ),
          if (_replyTo != null) _buildReplyBar(),
          if (_editingMsg != null) _buildEditBar(),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildMessageList(List<Message> msgs) {
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

      // Find reply preview
      String? replyText;
      String? replySenderName;
      if (m.replyToId != null) {
        final idx = msgs.indexWhere((x) => x.id == m.replyToId);
        if (idx != -1) {
          final rm = msgs[idx];
          replyText = rm.decryptedContent ?? _decryptedCache[rm.id] ?? '...';
          replySenderName =
              rm.isOutgoing ? 'You' : widget.contact.username;
        }
      }

      items.add(MessageBubble(
        key: ValueKey(m.id),
        message: m,
        decryptedText: plain,
        replyToText: replyText,
        replyToSender: replySenderName,
        onReply: () => setState(() => _replyTo = m),
        onLongPress: () => _showMessageOptions(m, plain),
      ));
    }

    return ListView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: items,
    );
  }

  Widget _buildReplyBar() {
    final m = _replyTo!;
    final text = m.decryptedContent ?? _decryptedCache[m.id] ?? '...';
    final sender = m.isOutgoing ? 'You' : widget.contact.username;

    return Container(
      color: AppTheme.surfaceVariant,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 36,
            decoration: BoxDecoration(
              color: AppTheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(sender,
                    style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                Text(
                  text,
                  style:
                      const TextStyle(color: AppTheme.muted, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  Widget _buildEditBar() {
    return Container(
      color: AppTheme.surfaceVariant,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          const Icon(Icons.edit_rounded, size: 18, color: AppTheme.primary),
          const SizedBox(width: 10),
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
            icon: const Icon(Icons.close_rounded, size: 18),
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
    return Container(
      color: AppTheme.surfaceVariant,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _ctrl,
                  textCapitalization: TextCapitalization.sentences,
                  minLines: 1,
                  maxLines: 5,
                  onChanged: _onTextChanged,
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _send,
              child: Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: AppTheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _editingMsg != null
                      ? Icons.check_rounded
                      : Icons.send_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Supporting widgets ──────────────────────────────────────

class _DateSeparator extends StatelessWidget {
  final DateTime date;
  const _DateSeparator({required this.date});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final local = date.toLocal();
    String label;

    if (DateUtils.isSameDay(local, now)) {
      label = 'Today';
    } else if (DateUtils.isSameDay(
        local, now.subtract(const Duration(days: 1)))) {
      label = 'Yesterday';
    } else {
      label = DateFormat('MMMM d, y').format(local);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const Expanded(child: Divider(indent: 16, endIndent: 8)),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.surfaceVariant,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              style:
                  const TextStyle(color: AppTheme.muted, fontSize: 11),
            ),
          ),
          const Expanded(child: Divider(indent: 8, endIndent: 16)),
        ],
      ),
    );
  }
}
