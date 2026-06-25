import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../providers/contacts_provider.dart';
import '../../../providers/messages_provider.dart';
import '../../../data/models/contact.dart';
import '../../widgets/contact_tile.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ContactsProvider>().loadContacts();
    });
  }

  void _openChat(Contact c) =>
      Navigator.pushNamed(context, '/chat', arguments: c);

  void _openCall(Contact c) =>
      Navigator.pushNamed(context, '/call/outgoing', arguments: c);

  void _showOptions(Contact c) {
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
                  color: AppTheme.muted.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2)),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline_rounded,
                  color: AppTheme.primary),
              title: const Text('Send message'),
              onTap: () {
                Navigator.pop(context);
                _openChat(c);
              },
            ),
            ListTile(
              leading: const Icon(Icons.call_rounded, color: AppTheme.accent),
              title: const Text('Voice call'),
              onTap: () {
                Navigator.pop(context);
                _openCall(c);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.person_remove_outlined, color: AppTheme.danger),
              title: const Text('Remove contact',
                  style: TextStyle(color: AppTheme.danger)),
              onTap: () {
                Navigator.pop(context);
                _confirmRemove(c);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(Contact c) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove contact'),
        content: Text('Remove ${c.username} from your contacts?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove',
                style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      context.read<ContactsProvider>().removeContact(c.contactId, c.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ContactsProvider>();
    final msgProvider = context.watch<MessagesProvider>();

    if (provider.isLoading && provider.contacts.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppTheme.primary),
      );
    }

    if (provider.contacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: AppTheme.surface,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.people_outline_rounded,
                  size: 44, color: AppTheme.muted),
            ),
            const SizedBox(height: 20),
            const Text(
              'No contacts yet',
              style: TextStyle(
                  color: AppTheme.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Add someone by their Pager ID',
              style: TextStyle(color: AppTheme.muted, fontSize: 14),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => Navigator.pushNamed(context, '/contacts/add'),
              icon: const Icon(Icons.person_add_rounded, size: 18),
              label: const Text('Add Contact'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 12),
                minimumSize: Size.zero,
              ),
            ),
          ],
        ),
      );
    }

    // Sort contacts so the most recently active conversation is always at top.
    final contacts = provider.contacts.toList()
      ..sort((a, b) {
        final aChat = msgProvider.getChat(a.contactId);
        final bChat = msgProvider.getChat(b.contactId);
        final aTime = aChat.isNotEmpty ? aChat.last.createdAt : DateTime(0);
        final bTime = bChat.isNotEmpty ? bChat.last.createdAt : DateTime(0);
        return bTime.compareTo(aTime);
      });

    return ListView.builder(
      itemCount: contacts.length,
      itemBuilder: (ctx, i) {
        final c = contacts[i];
        final chat = msgProvider.getChat(c.contactId);
        final last = chat.isNotEmpty ? chat.last : null;
        final lastText = last != null
            ? (last.decryptedContent ?? last.encryptedContent)
            : null;

        return ContactTile(
          contact: c,
          lastMessage: last,
          lastMessageText: lastText,
          unreadCount: msgProvider.getUnreadCount(c.contactId),
          onChat: () => _openChat(c),
          onCall: () => _openCall(c),
          onLongPress: () => _showOptions(c),
        );
      },
    );
  }
}
