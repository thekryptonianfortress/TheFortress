import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/theme.dart';
import '../../data/models/message.dart';

class MessageBubble extends StatefulWidget {
  final Message message;
  final String? decryptedText;
  final String? replyToSender;
  final String? replyToText;
  final VoidCallback? onReply;
  final VoidCallback? onLongPress;

  const MessageBubble({
    super.key,
    required this.message,
    this.decryptedText,
    this.replyToSender,
    this.replyToText,
    this.onReply,
    this.onLongPress,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  double _dragOffset = 0;
  bool _replyTriggered = false;

  @override
  Widget build(BuildContext context) {
    final isMe = widget.message.isOutgoing;

    return GestureDetector(
      onLongPress: widget.onLongPress,
      onHorizontalDragUpdate: (details) {
        if (details.delta.dx > 0) {
          setState(() {
            _dragOffset = (_dragOffset + details.delta.dx).clamp(0.0, 72.0);
          });
          if (_dragOffset >= 64 && !_replyTriggered) {
            _replyTriggered = true;
            widget.onReply?.call();
          }
        }
      },
      onHorizontalDragEnd: (_) => setState(() {
        _dragOffset = 0;
        _replyTriggered = false;
      }),
      onHorizontalDragCancel: () => setState(() {
        _dragOffset = 0;
        _replyTriggered = false;
      }),
      child: Stack(
        children: [
          // Swipe reply icon
          if (_dragOffset > 8)
            Positioned(
              left: isMe ? null : (_dragOffset - 16).clamp(0.0, 40.0),
              right: isMe ? (_dragOffset - 16).clamp(0.0, 40.0) : null,
              top: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment.center,
                child: Opacity(
                  opacity: (_dragOffset / 64).clamp(0.0, 1.0),
                  child: const Icon(Icons.reply_rounded,
                      size: 20, color: AppTheme.muted),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: _buildBubble(context),
          ),
        ],
      ),
    );
  }

  Widget _buildBubble(BuildContext context) {
    final isMe = widget.message.isOutgoing;
    final isDeleted = widget.message.isDeleted;
    final text = widget.decryptedText ??
        widget.message.decryptedContent ??
        widget.message.encryptedContent;
    final time = DateFormat('HH:mm').format(widget.message.createdAt.toLocal());
    final isEdited = widget.message.editedAt != null && !isDeleted;

    final bubbleColor =
        isMe ? AppTheme.primary : const Color(0xFF252525);
    final textColor = isMe ? Colors.white : AppTheme.onSurface;
    final metaColor = isMe
        ? Colors.white.withValues(alpha: 0.65)
        : AppTheme.muted;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          left: isMe ? 60 : 12,
          right: isMe ? 12 : 60,
          top: 2,
          bottom: 2,
        ),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isMe ? 18 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 18),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isMe ? 18 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 18),
          ),
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Reply preview
                if (widget.replyToText != null && !isDeleted)
                  _ReplyPreview(
                    senderName: widget.replyToSender ?? '',
                    text: widget.replyToText!,
                    isMe: isMe,
                  ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isDeleted)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.block_rounded,
                                size: 14, color: metaColor),
                            const SizedBox(width: 6),
                            Text(
                              'Message deleted',
                              style: TextStyle(
                                color: metaColor,
                                fontSize: 14,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        )
                      else
                        Text(
                          text,
                          style: TextStyle(color: textColor, fontSize: 15, height: 1.35),
                        ),

                      const SizedBox(height: 3),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isEdited)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Text(
                                'edited',
                                style: TextStyle(
                                    color: metaColor,
                                    fontSize: 10,
                                    fontStyle: FontStyle.italic),
                              ),
                            ),
                          Text(
                            time,
                            style: TextStyle(color: metaColor, fontSize: 11),
                          ),
                          if (isMe) ...[
                            const SizedBox(width: 4),
                            _StatusIcon(
                                status: widget.message.status, color: metaColor),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReplyPreview extends StatelessWidget {
  final String senderName;
  final String text;
  final bool isMe;

  const _ReplyPreview({
    required this.senderName,
    required this.text,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final accentColor = isMe
        ? Colors.white.withValues(alpha: 0.9)
        : AppTheme.primary;
    final bgColor = isMe
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.15);
    final textColor = isMe ? Colors.white : AppTheme.onSurface;
    final mutedColor = isMe
        ? Colors.white.withValues(alpha: 0.65)
        : AppTheme.muted;

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: accentColor, width: 3),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            senderName,
            style: TextStyle(
                color: accentColor,
                fontSize: 12,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            text,
            style: TextStyle(color: mutedColor, fontSize: 12),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final MessageStatus status;
  final Color color;
  const _StatusIcon({required this.status, required this.color});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case MessageStatus.pending:
        return Icon(Icons.schedule_rounded, size: 13, color: color);
      case MessageStatus.sent:
        return Icon(Icons.check_rounded, size: 13, color: color);
      case MessageStatus.delivered:
        return Icon(Icons.done_all_rounded, size: 13, color: color);
      case MessageStatus.read:
        return const Icon(Icons.done_all_rounded,
            size: 13, color: AppTheme.accent);
    }
  }
}
