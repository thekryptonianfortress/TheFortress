import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/theme.dart';
import '../../data/models/message.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final String? decryptedText;

  const MessageBubble({super.key, required this.message, this.decryptedText});

  @override
  Widget build(BuildContext context) {
    final isMe = message.isOutgoing;
    final text = decryptedText ?? message.decryptedContent ?? '[encrypted]';
    final time = DateFormat('HH:mm').format(message.createdAt);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: isMe ? AppTheme.primary : AppTheme.surfaceVariant,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(text, style: const TextStyle(color: AppTheme.onSurface, fontSize: 15)),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(time, style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  _statusIcon(message.status),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusIcon(MessageStatus status) {
    switch (status) {
      case MessageStatus.pending:
        return const Icon(Icons.schedule, size: 12, color: AppTheme.muted);
      case MessageStatus.sent:
        return const Icon(Icons.check, size: 12, color: AppTheme.muted);
      case MessageStatus.delivered:
        return const Icon(Icons.done_all, size: 12, color: AppTheme.muted);
      case MessageStatus.read:
        return const Icon(Icons.done_all, size: 12, color: AppTheme.accent);
    }
  }
}
