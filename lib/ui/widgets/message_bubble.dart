import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/theme.dart';
import '../../data/models/message.dart';

class MessageBubble extends StatefulWidget {
  final Message message;
  final String? decryptedText;
  final String? replyToSender;
  final String? replyToText;
  final String myUserId;
  final String peerName;
  final VoidCallback? onReply;
  final VoidCallback? onLongPress;
  final void Function(String emoji)? onReact;

  const MessageBubble({
    super.key,
    required this.message,
    required this.myUserId,
    required this.peerName,
    this.decryptedText,
    this.replyToSender,
    this.replyToText,
    this.onReply,
    this.onLongPress,
    this.onReact,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {
  double _dragOffset = 0;
  bool _replyTriggered = false;
  late AnimationController _bounceCtrl;
  late Animation<double> _bounceAnim;

  @override
  void initState() {
    super.initState();
    _bounceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _bounceAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _bounceCtrl, curve: Curves.elasticOut),
    );
  }

  @override
  void dispose() {
    _bounceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMe = widget.message.isOutgoing;

    return GestureDetector(
      onLongPress: widget.onLongPress,
      onHorizontalDragUpdate: (d) {
        if (d.delta.dx > 0) {
          setState(() {
            _dragOffset = (_dragOffset + d.delta.dx).clamp(0.0, 72.0);
          });
          if (_dragOffset >= 60 && !_replyTriggered) {
            _replyTriggered = true;
            widget.onReply?.call();
            _bounceCtrl.forward(from: 0);
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
      child: AnimatedBuilder(
        animation: _bounceAnim,
        builder: (_, __) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Reply icon (revealed on swipe)
              if (_dragOffset > 8)
                Positioned(
                  left: isMe ? null : 4,
                  right: isMe ? 4 : null,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Opacity(
                      opacity: (_dragOffset / 60).clamp(0.0, 1.0),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: AppTheme.muted.withValues(alpha: 0.3),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.reply_rounded,
                            size: 18, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              Transform.translate(
                offset: Offset(_dragOffset, 0),
                child: _buildBubble(context),
              ),
            ],
          );
        },
      ),
    );
  }

  static const _quickEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥'];

  void _showWhoReacted(
      BuildContext context, String emoji, List<String> userIds) {
    final iMine = userIds.contains(widget.myUserId);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF232E3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.muted.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text(emoji, style: const TextStyle(fontSize: 40)),
              const SizedBox(height: 12),
              ...userIds.map((uid) {
                final isMe = uid == widget.myUserId;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: AppTheme.avatarColor(
                              isMe ? 'me' : widget.peerName),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            isMe
                                ? 'Y'
                                : widget.peerName.isNotEmpty
                                    ? widget.peerName[0].toUpperCase()
                                    : '?',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          isMe ? 'You' : widget.peerName,
                          style: const TextStyle(
                              color: AppTheme.onSurface,
                              fontSize: 15,
                              fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                );
              }),
              if (iMine) ...[
                const SizedBox(height: 8),
                const Divider(color: Color(0xFF2A3A4A)),
                ListTile(
                  leading: const Icon(Icons.remove_circle_outline,
                      color: AppTheme.danger),
                  title: const Text('Remove my reaction',
                      style: TextStyle(color: AppTheme.danger)),
                  onTap: () {
                    Navigator.pop(context);
                    widget.onReact?.call(emoji);
                  },
                ),
              ],
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }

  void _showEmojiPicker(BuildContext context) {
    final isMe = widget.message.isOutgoing;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (_) => Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(
            left: isMe ? 72 : 12,
            right: isMe ? 12 : 72,
            bottom: 80,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF2A3A4A),
            borderRadius: BorderRadius.circular(32),
            boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 12)],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: _quickEmojis.map((e) {
              final alreadyReacted =
                  widget.message.reactions[e]?.contains(widget.myUserId) == true;
              return GestureDetector(
                onTap: () {
                  Navigator.pop(context);
                  widget.onReact?.call(e);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.all(6),
                  decoration: alreadyReacted
                      ? BoxDecoration(
                          color: const Color(0xFF5288C1).withValues(alpha: 0.35),
                          shape: BoxShape.circle,
                        )
                      : null,
                  child: Text(e, style: const TextStyle(fontSize: 26)),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildBubble(BuildContext context) {
    final isMe = widget.message.isOutgoing;
    final isDeleted = widget.message.isDeleted;
    final text = widget.decryptedText ??
        widget.message.decryptedContent ??
        widget.message.encryptedContent;
    final time =
        DateFormat('HH:mm').format(widget.message.createdAt.toLocal());
    final isEdited = widget.message.editedAt != null && !isDeleted;
    final bubbleColor =
        isMe ? AppTheme.outgoingBubble : AppTheme.incomingBubble;

    final reactions = widget.message.reactions;
    final hasReactions = reactions.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(
        left: isMe ? 72 : 16,
        right: isMe ? 16 : 72,
        top: 2,
        bottom: hasReactions ? 0 : 2,
      ),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // ── Bubble body ───────────────────────────────────
                Container(
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isMe ? 16 : 4),
                      bottomRight: Radius.circular(isMe ? 4 : 16),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isMe ? 16 : 4),
                      bottomRight: Radius.circular(isMe ? 4 : 16),
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
                          // Content
                          Padding(
                            padding:
                                const EdgeInsets.fromLTRB(10, 6, 10, 6),
                            child: isDeleted
                                ? _deletedContent(isMe)
                                : _messageContent(
                                    context, text, time, isEdited, isMe),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // ── Tail ─────────────────────────────────────────
                Positioned(
                  right: isMe ? -7 : null,
                  left: isMe ? null : -7,
                  bottom: 0,
                  child: CustomPaint(
                    size: const Size(10, 14),
                    painter: _TailPainter(color: bubbleColor, isMe: isMe),
                  ),
                ),
              ],
            ),
          ),
          if (hasReactions)
            Padding(
              padding: const EdgeInsets.only(top: 3, bottom: 4),
              child: Wrap(
                spacing: 4,
                children: reactions.entries.map((e) {
                  final count = e.value.length;
                  final iMine = e.value.contains(widget.myUserId);
                  return GestureDetector(
                    onTap: () => _showWhoReacted(context, e.key, e.value),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: iMine
                            ? AppTheme.primary.withValues(alpha: 0.3)
                            : const Color(0xFF2A3A4A),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: iMine
                              ? AppTheme.primary
                              : Colors.white.withValues(alpha: 0.1),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        count > 1 ? '${e.key} $count' : e.key,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _deletedContent(bool isMe) {
    final color =
        isMe ? Colors.white.withValues(alpha: 0.5) : AppTheme.muted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.block_rounded, size: 14, color: color),
        const SizedBox(width: 6),
        Text(
          'Message deleted',
          style: TextStyle(
            color: color,
            fontSize: 14,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  Widget _messageContent(BuildContext context, String text, String time,
      bool isEdited, bool isMe) {
    final textColor = Colors.white;
    final metaColor = Colors.white.withValues(alpha: isMe ? 0.6 : 0.45);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: TextStyle(
            color: textColor,
            fontSize: 15,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 2),
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
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            Text(
              time,
              style: TextStyle(color: metaColor, fontSize: 11),
            ),
            if (isMe) ...[
              const SizedBox(width: 3),
              _StatusIcon(status: widget.message.status),
            ],
          ],
        ),
      ],
    );
  }
}

// ── Tail painter ────────────────────────────────────────────

class _TailPainter extends CustomPainter {
  final Color color;
  final bool isMe;
  const _TailPainter({required this.color, required this.isMe});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    if (isMe) {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
    } else {
      path
        ..moveTo(size.width, 0)
        ..lineTo(0, size.height)
        ..lineTo(size.width, size.height)
        ..close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TailPainter old) =>
      old.color != color || old.isMe != isMe;
}

// ── Reply preview ────────────────────────────────────────────

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
    final accentColor = isMe ? Colors.white : AppTheme.primary;
    final bgColor = Colors.black.withValues(alpha: 0.18);

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(color: accentColor, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            senderName,
            style: TextStyle(
              color: accentColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 12,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ── Status icon ──────────────────────────────────────────────

class _StatusIcon extends StatelessWidget {
  final MessageStatus status;
  const _StatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case MessageStatus.pending:
        return Icon(Icons.schedule_rounded,
            size: 13, color: Colors.white.withValues(alpha: 0.55));
      case MessageStatus.sent:
        return Icon(Icons.check_rounded,
            size: 14, color: Colors.white.withValues(alpha: 0.55));
      case MessageStatus.delivered:
        return Icon(Icons.done_all_rounded,
            size: 14, color: Colors.white.withValues(alpha: 0.55));
      case MessageStatus.read:
        return const Icon(Icons.done_all_rounded,
            size: 14, color: AppTheme.accent);
    }
  }
}
