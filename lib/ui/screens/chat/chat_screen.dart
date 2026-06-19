import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../data/models/contact.dart';
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

  @override
  void initState() {
    super.initState();
    _msgService = MessagingService(context.read<SignalingService>());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<MessagesProvider>().loadChat(widget.contact.contactId);
      await _decryptAll();
      _scrollToBottom();
    });
  }

  /// Returns the freshest known public key for the contact (server-synced preferred).
  String _senderPublicKey() {
    final fresh = context.read<ContactsProvider>().getById(widget.contact.contactId);
    return fresh?.publicKey ?? widget.contact.publicKey;
  }

  Future<void> _decryptAll() async {
    final msgs = context.read<MessagesProvider>().getChat(widget.contact.contactId);
    final senderKey = _senderPublicKey();
    for (final m in msgs) {
      // Skip if already decrypted (real-time messages have decryptedContent set)
      if (m.decryptedContent != null) continue;
      if (!m.isOutgoing && !_decryptedCache.containsKey(m.id)) {
        try {
          final plain = await _msgService.decryptMessage(
            encryptedContent: m.encryptedContent,
            nonce: m.nonce,
            senderPublicKey: senderKey,
          );
          _decryptedCache[m.id] = plain;
        } catch (_) {
          _decryptedCache[m.id] = '[unable to decrypt]';
        }
      }
    }
    if (mounted) setState(() {});
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();
    try {
      // Use the freshest public key from the provider (re-synced from server on login)
      final freshContact = context.read<ContactsProvider>().getById(widget.contact.contactId);
      final recipientPublicKey = freshContact?.publicKey ?? widget.contact.publicKey;
      await context.read<MessagesProvider>().sendMessage(
            recipientId: widget.contact.contactId,
            recipientVirtualId: widget.contact.virtualId,
            recipientPublicKey: recipientPublicKey,
            plaintext: text,
          );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final msgs = context.watch<MessagesProvider>().getChat(widget.contact.contactId);

    // Decrypt newly arrived incoming messages that don't yet have decryptedContent
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool changed = false;
      final senderKey = _senderPublicKey();
      for (final m in msgs) {
        if (m.decryptedContent != null) continue; // already decrypted
        if (!m.isOutgoing && !_decryptedCache.containsKey(m.id)) {
          try {
            final plain = await _msgService.decryptMessage(
              encryptedContent: m.encryptedContent,
              nonce: m.nonce,
              senderPublicKey: senderKey,
            );
            _decryptedCache[m.id] = plain;
            changed = true;
          } catch (_) {
            _decryptedCache[m.id] = '[unable to decrypt]';
            changed = true;
          }
        }
      }
      if (changed && mounted) setState(() {});
    });

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.contact.username),
            Text(widget.contact.virtualId,
                style: const TextStyle(fontSize: 11, color: AppTheme.muted)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.call),
            onPressed: () =>
                Navigator.pushNamed(context, '/call/outgoing', arguments: widget.contact),
          ),
          PopupMenuButton<String>(
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
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Clear', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
                if (confirm == true && mounted) {
                  await context.read<MessagesProvider>().clearChat(widget.contact.contactId);
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
            child: msgs.isEmpty
                ? const Center(
                    child: Text('No messages yet', style: TextStyle(color: AppTheme.muted)))
                : ListView.builder(
                    controller: _scrollCtrl,
                    itemCount: msgs.length,
                    itemBuilder: (_, i) {
                      final m = msgs[i];
                      // Use decryptedContent first (real-time messages), then cache (DB-loaded)
                      final plain = m.decryptedContent ?? _decryptedCache[m.id];
                      return MessageBubble(message: m, decryptedText: plain);
                    },
                  ),
          ),
          _InputBar(ctrl: _ctrl, onSend: _send),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController ctrl;
  final VoidCallback onSend;
  const _InputBar({required this.ctrl, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.surfaceVariant,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                textCapitalization: TextCapitalization.sentences,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Message',
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.send_rounded, color: AppTheme.primary),
              onPressed: onSend,
            ),
          ],
        ),
      ),
    );
  }
}
