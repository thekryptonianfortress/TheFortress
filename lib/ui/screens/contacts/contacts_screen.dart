import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/contacts_provider.dart';
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

  void _onCallContact(Contact contact) {
    Navigator.pushNamed(context, '/call/outgoing', arguments: contact);
  }

  void _onChatContact(Contact contact) {
    Navigator.pushNamed(context, '/chat', arguments: contact);
  }

  void _onLongPress(BuildContext context, Contact contact) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Remove contact', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                context.read<ContactsProvider>().removeContact(contact.contactId, contact.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ContactsProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_outlined),
            onPressed: () => Navigator.pushNamed(context, '/contacts/add'),
          ),
        ],
      ),
      body: provider.isLoading && provider.contacts.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : provider.contacts.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.people_outline, size: 64, color: Colors.grey),
                      SizedBox(height: 12),
                      Text('No contacts yet', style: TextStyle(color: Colors.grey)),
                      SizedBox(height: 4),
                      Text('Add a contact by their Pager ID', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: provider.contacts.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final c = provider.contacts[i];
                    return Dismissible(
                      key: Key(c.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete_outline, color: Colors.white),
                      ),
                      confirmDismiss: (_) async {
                        return await showDialog<bool>(
                          context: ctx,
                          builder: (_) => AlertDialog(
                            title: const Text('Remove contact'),
                            content: Text('Remove ${c.username} from your contacts?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Remove', style: TextStyle(color: Colors.red)),
                              ),
                            ],
                          ),
                        ) ?? false;
                      },
                      onDismissed: (_) {
                        context.read<ContactsProvider>().removeContact(c.contactId, c.id);
                      },
                      child: ContactTile(
                        contact: c,
                        onChat: () => _onChatContact(c),
                        onCall: () => _onCallContact(c),
                        onLongPress: () => _onLongPress(ctx, c),
                      ),
                    );
                  },
                ),
    );
  }
}
