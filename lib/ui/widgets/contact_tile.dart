import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../data/models/contact.dart';
import '../../data/models/message.dart';

class ContactTile extends StatelessWidget {
  final Contact contact;
  final Message? lastMessage;
  final String? lastMessageText;
  final int unreadCount;
  final VoidCallback? onChat;
  final VoidCallback? onCall;
  final VoidCallback? onLongPress;

  const ContactTile({
    super.key,
    required this.contact,
    this.lastMessage,
    this.lastMessageText,
    this.unreadCount = 0,
    this.onChat,
    this.onCall,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final avatarColor = AppTheme.avatarColor(contact.username);
    final initial =
        contact.username.isNotEmpty ? contact.username[0].toUpperCase() : '?';
    final hasMessage = lastMessage != null;
    final timeLabel = hasMessage ? _formatTime(lastMessage!.createdAt) : null;

    return InkWell(
      onTap: onChat,
      onLongPress: onLongPress,
      splashColor: AppTheme.primary.withValues(alpha: 0.08),
      highlightColor: AppTheme.primary.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // ── Avatar ───────────────────────────────────────
            Stack(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: avatarColor,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      initial,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                if (contact.isOnline)
                  Positioned(
                    right: 1,
                    bottom: 1,
                    child: Container(
                      width: 13,
                      height: 13,
                      decoration: BoxDecoration(
                        color: AppTheme.accent,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: AppTheme.background, width: 2.5),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 14),

            // ── Name + preview ───────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          contact.username,
                          style: TextStyle(
                            color: AppTheme.onSurface,
                            fontSize: 16,
                            fontWeight: unreadCount > 0
                                ? FontWeight.w700
                                : FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (timeLabel != null)
                        Text(
                          timeLabel,
                          style: TextStyle(
                            color: unreadCount > 0
                                ? AppTheme.accent
                                : AppTheme.muted,
                            fontSize: 12,
                            fontWeight: unreadCount > 0
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      // Status tick for outgoing last message
                      if (hasMessage && lastMessage!.isOutgoing)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: _MiniStatus(status: lastMessage!.status),
                        ),
                      Expanded(
                        child: Text(
                          _previewText(),
                          style: TextStyle(
                            color: unreadCount > 0
                                ? AppTheme.onSurface.withValues(alpha: 0.85)
                                : hasMessage
                                    ? AppTheme.muted
                                    : AppTheme.muted.withValues(alpha: 0.5),
                            fontSize: 13,
                            fontWeight: unreadCount > 0
                                ? FontWeight.w500
                                : FontWeight.normal,
                            fontStyle: hasMessage
                                ? FontStyle.normal
                                : FontStyle.italic,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (unreadCount > 0)
                        Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.accent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            unreadCount > 99 ? '99+' : '$unreadCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _previewText() {
    if (lastMessage == null) return 'Tap to start chatting';
    if (lastMessage!.isDeleted) return 'Message deleted';
    return lastMessageText ?? lastMessage!.encryptedContent;
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final local = dt.toLocal();
    if (DateUtils.isSameDay(local, now)) {
      final h = local.hour.toString().padLeft(2, '0');
      final m = local.minute.toString().padLeft(2, '0');
      return '$h:$m';
    } else if (DateUtils.isSameDay(
        local, now.subtract(const Duration(days: 1)))) {
      return 'Yesterday';
    } else if (now.difference(local).inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[local.weekday - 1];
    } else {
      return '${local.day}/${local.month}/${local.year % 100}';
    }
  }
}

class _MiniStatus extends StatelessWidget {
  final MessageStatus status;
  const _MiniStatus({required this.status});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case MessageStatus.pending:
        return const Icon(Icons.schedule_rounded,
            size: 13, color: AppTheme.muted);
      case MessageStatus.sent:
        return const Icon(Icons.check_rounded,
            size: 13, color: AppTheme.muted);
      case MessageStatus.delivered:
        return const Icon(Icons.done_all_rounded,
            size: 13, color: AppTheme.muted);
      case MessageStatus.read:
        return const Icon(Icons.done_all_rounded,
            size: 13, color: AppTheme.accent);
    }
  }
}
