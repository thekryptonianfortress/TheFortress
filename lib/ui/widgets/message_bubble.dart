import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auto_download_provider.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import '../../core/theme.dart';
import '../../data/models/message.dart';
import '../../services/media_service.dart';
import '../screens/media/photo_view_screen.dart';
import '../screens/media/video_player_screen.dart';
import 'voice_note_player.dart';

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
  final String? nextAudioSource;

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
    this.nextAudioSource,
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
        bottom: hasReactions ? 18 : 2,
      ),
      child: Align(
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
                        padding: EdgeInsets.fromLTRB(
                            10, 6, 10, hasReactions ? 10 : 6),
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
            // ── Reactions (overlapping bottom edge) ───────────
            if (hasReactions)
              Positioned(
                bottom: -13,
                right: isMe ? 6 : null,
                left: isMe ? null : 6,
                child: _buildReactionPills(context, reactions, isMe),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildReactionPills(
    BuildContext context,
    Map<String, List<String>> reactions,
    bool isMe,
  ) {
    return Wrap(
      spacing: 4,
      children: reactions.entries.map((e) {
        final count = e.value.length;
        final iMine = e.value.contains(widget.myUserId);
        return GestureDetector(
          onTap: () => _showWhoReacted(context, e.key, e.value),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: iMine
                  ? AppTheme.primary.withValues(alpha: 0.3)
                  : const Color(0xFF2A3A4A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: iMine
                    ? AppTheme.primary
                    : Colors.white.withValues(alpha: 0.15),
                width: 1,
              ),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black38,
                    blurRadius: 4,
                    offset: Offset(0, 1)),
              ],
            ),
            child: Text(
              count > 1 ? '${e.key} $count' : e.key,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        );
      }).toList(),
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
    final metaColor = Colors.white.withValues(alpha: isMe ? 0.6 : 0.45);
    final msg = widget.message;
    final hasAttachment = msg.attachmentUrl != null;
    final autoDownload = context.read<AutoDownloadProvider>();

    Widget? attachmentWidget;
    if (hasAttachment) {
      final url = MediaService.fullUrl(msg.attachmentUrl!);
      final type = msg.attachmentType ?? 'file';
      final filename = msg.attachmentName ?? 'attachment';
      final heroTag = 'media_${msg.id}';

      if (type == 'image' || type == 'gif') {
        attachmentWidget = GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PhotoViewScreen(
                url: url,
                heroTag: heroTag,
                caption: filename,
              ),
            ),
          ),
          child: Hero(
            tag: heroTag,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: url,
                width: 220,
                fit: BoxFit.cover,
                placeholder: (_, __) => const SizedBox(
                  width: 220,
                  height: 160,
                  child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
                errorWidget: (_, __, ___) => const SizedBox(
                  width: 220,
                  height: 80,
                  child: Center(
                      child: Icon(Icons.broken_image_rounded,
                          color: Colors.white54)),
                ),
              ),
            ),
          ),
        );
      } else if (type == 'video') {
        attachmentWidget = _VideoThumbnailBubble(
          url: url,
          filename: filename,
          size: msg.attachmentSize,
          shouldAutoDownload: autoDownload.shouldAutoDownload(MediaType.videos),
        );
      } else if (type == 'audio') {
        // Effect id is encoded in attachmentName after '#', e.g. "voice_note.m4a#deep"
        final effectId = filename.contains('#') ? filename.split('#').last : null;
        attachmentWidget = Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: VoiceNotePlayer(
            key: ValueKey(msg.id),
            source: url,
            effectId: effectId,
            isOutgoing: isMe,
            nextSource: widget.nextAudioSource,
            shouldAutoDownload: autoDownload.shouldAutoDownload(MediaType.audio),
          ),
        );
      } else {
        // Generic file — download with progress dialog
        attachmentWidget = GestureDetector(
          onTap: () => _openFile(context, url, filename),
          child: Container(
            width: 240,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.insert_drive_file_rounded,
                    color: Colors.white70, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        filename,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (msg.attachmentSize != null)
                        Text(
                          MediaService.formatSize(msg.attachmentSize!),
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 11),
                        ),
                    ],
                  ),
                ),
                const Icon(Icons.download_rounded,
                    color: Colors.white54, size: 20),
              ],
            ),
          ),
        );
      }
    }

    final hasText = text.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (attachmentWidget != null) ...[
          attachmentWidget,
          if (hasText) const SizedBox(height: 6),
        ],
        if (hasText)
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
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

  void _openFile(BuildContext context, String url, String filename) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _FileDownloadDialog(url: url, filename: filename),
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

// ── Video thumbnail bubble ────────────────────────────────────

class _VideoThumbnailBubble extends StatefulWidget {
  final String url;
  final String filename;
  final int? size;
  final bool shouldAutoDownload;

  const _VideoThumbnailBubble({
    required this.url,
    required this.filename,
    this.size,
    this.shouldAutoDownload = true,
  });

  @override
  State<_VideoThumbnailBubble> createState() => _VideoThumbnailBubbleState();
}

class _VideoThumbnailBubbleState extends State<_VideoThumbnailBubble> {
  Uint8List? _thumb;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    if (widget.shouldAutoDownload) _loadThumb();
  }

  Future<void> _loadThumb() async {
    final bytes = await MediaService.videoThumbnailBytes(widget.url);
    if (mounted) setState(() { _thumb = bytes; _loaded = true; });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (!_loaded) _loadThumb();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                VideoPlayerScreen(url: widget.url, filename: widget.filename),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Thumbnail or placeholder
            SizedBox(
              width: 240,
              height: 160,
              child: _loaded && _thumb != null
                  ? Image.memory(_thumb!, width: 240, height: 160, fit: BoxFit.cover)
                  : Container(
                      color: Colors.black54,
                      child: const Icon(Icons.videocam_rounded,
                          color: Colors.white12, size: 72),
                    ),
            ),
            // Play button overlay
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 34),
            ),
            // Duration / size label bottom-right
            if (widget.size != null)
              Positioned(
                bottom: 6,
                right: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    MediaService.formatSize(widget.size!),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── File download dialog ──────────────────────────────────────

class _FileDownloadDialog extends StatefulWidget {
  final String url;
  final String filename;

  const _FileDownloadDialog({required this.url, required this.filename});

  @override
  State<_FileDownloadDialog> createState() => _FileDownloadDialogState();
}

class _FileDownloadDialogState extends State<_FileDownloadDialog> {
  double _progress = 0;
  bool _alreadyCached = false;

  @override
  void initState() {
    super.initState();
    _download();
  }

  Future<void> _download() async {
    try {
      // Check cache before showing progress
      final cached = await MediaService.isCached(widget.filename);
      if (mounted && cached) setState(() => _alreadyCached = true);

      final file = await MediaService.downloadFile(
        widget.url,
        widget.filename,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      Navigator.pop(context);
      await OpenFile.open(file.path);
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E2C3A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        widget.filename,
        style: const TextStyle(
            color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: _alreadyCached ? 1.0 : (_progress > 0 ? _progress : null),
            backgroundColor: Colors.white12,
            color: AppTheme.primary,
            minHeight: 3,
          ),
          const SizedBox(height: 12),
          Text(
            _alreadyCached
                ? 'Opening…'
                : _progress > 0
                    ? '${(_progress * 100).toStringAsFixed(0)}%'
                    : 'Downloading…',
            style: const TextStyle(color: Colors.white60, fontSize: 13),
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
