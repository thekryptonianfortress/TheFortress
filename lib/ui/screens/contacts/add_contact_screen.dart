import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/contacts_provider.dart';
import '../../../core/theme.dart';

class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});
  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final id = _ctrl.text.trim();
    if (id.isEmpty) return;
    final provider = context.read<ContactsProvider>();
    final ok = await provider.addContact(id);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact added')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ContactsProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Add Contact')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the phone number of the person you want to add. Use international format (e.g. +254712345678).',
              style: TextStyle(color: AppTheme.muted),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _ctrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone Number',
                hintText: '+254712345678',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
            if (provider.error != null) ...[
              const SizedBox(height: 12),
              Text(provider.error!, style: const TextStyle(color: AppTheme.danger)),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: provider.isLoading ? null : _add,
              child: provider.isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Add Contact'),
            ),
          ],
        ),
      ),
    );
  }
}
