import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // kept for SystemUiOverlayStyle

class PhotoViewScreen extends StatefulWidget {
  final String url;
  final String heroTag;
  final String? caption;

  const PhotoViewScreen({
    super.key,
    required this.url,
    required this.heroTag,
    this.caption,
  });

  @override
  State<PhotoViewScreen> createState() => _PhotoViewScreenState();
}

class _PhotoViewScreenState extends State<PhotoViewScreen> {
  final _transformController = TransformationController();
  bool _showUi = true;
  TapDownDetails? _lastDoubleTapDetails;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    if (_transformController.value != Matrix4.identity()) {
      _transformController.value = Matrix4.identity();
      return;
    }
    final pos = _lastDoubleTapDetails?.localPosition ?? const Offset(0, 0);
    _transformController.value = Matrix4.identity()
      ..translate(-pos.dx * 1.5, -pos.dy * 1.5)
      ..scale(2.5);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: _showUi
            ? Colors.black.withValues(alpha: 0.6)
            : Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        iconTheme: IconThemeData(
            color: _showUi ? Colors.white : Colors.transparent),
        title: _showUi && widget.caption != null
            ? Text(
                widget.caption!,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.normal),
                overflow: TextOverflow.ellipsis,
              )
            : null,
        // Hide the back button visually when controls are hidden
        // but keep it tappable so swipe-back still works
        leading: _showUi
            ? null
            : const SizedBox.shrink(),
      ),
      body: GestureDetector(
        onTap: () => setState(() => _showUi = !_showUi),
        onDoubleTapDown: (d) => _lastDoubleTapDetails = d,
        onDoubleTap: _handleDoubleTap,
        child: Center(
          child: Hero(
            tag: widget.heroTag,
            child: InteractiveViewer(
              transformationController: _transformController,
              minScale: 0.5,
              maxScale: 6.0,
              child: CachedNetworkImage(
                imageUrl: widget.url,
                fit: BoxFit.contain,
                placeholder: (_, __) => const Center(
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2),
                ),
                errorWidget: (_, __, ___) => const Center(
                  child: Icon(Icons.broken_image_rounded,
                      color: Colors.white38, size: 64),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
