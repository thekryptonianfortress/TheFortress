import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../data/models/contact.dart';

class ContactTile extends StatelessWidget {
  final Contact contact;
  final VoidCallback? onChat;
  final VoidCallback? onCall;
  final VoidCallback? onLongPress;

  const ContactTile({
    super.key,
    required this.contact,
    this.onChat,
    this.onCall,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onLongPress: onLongPress,
      leading: CircleAvatar(
        backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
        child: Text(
          contact.username.isNotEmpty ? contact.username[0].toUpperCase() : '?',
          style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
        ),
      ),
      title: Text(contact.username, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(contact.virtualId, style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: contact.isOnline ? AppTheme.accent : AppTheme.muted,
            ),
          ),
          if (onChat != null) ...[
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.chat_bubble_outline, color: AppTheme.primary),
              onPressed: onChat,
            ),
          ],
          if (onCall != null) ...[
            IconButton(
              icon: const Icon(Icons.call, color: AppTheme.accent),
              onPressed: onCall,
            ),
          ],
        ],
      ),
    );
  }
}
