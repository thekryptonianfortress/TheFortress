import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // SystemUiOverlayStyle
import 'package:video_player/video_player.dart';
import '../../../services/media_service.dart';

class VideoPlayerScreen extends StatefulWidget {
  final String url;
  final String filename;

  const VideoPlayerScreen({
    super.key,
    required this.url,
    required this.filename,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _downloading = false;
  double _downloadProgress = 0;
  bool _showControls = true;
  double _playbackSpeed = 1.0;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
    });
    try {
      final file = await MediaService.downloadFile(
        widget.url,
        widget.filename,
        onProgress: (p) {
          if (mounted) setState(() => _downloadProgress = p);
        },
      );
      if (!mounted) return;
      await _initController(file);
    } catch (e) {
      if (mounted) {
        setState(() => _downloading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load video: $e')),
        );
      }
    }
  }

  Future<void> _initController(File file) async {
    final controller = VideoPlayerController.file(file);
    await controller.initialize();
    if (!mounted) {
      controller.dispose();
      return;
    }
    controller.addListener(_onVideoUpdate);
    setState(() {
      _controller = controller;
      _initialized = true;
      _downloading = false;
    });
    controller.play();
    _scheduleHideControls();
  }

  void _onVideoUpdate() {
    if (!mounted) return;
    final c = _controller!;
    // Auto-reset to beginning when finished
    if (c.value.position >= c.value.duration && c.value.duration.inSeconds > 0) {
      c.seekTo(Duration.zero);
      c.pause();
    }
    setState(() {});
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHideControls();
  }

  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  void _showSpeedPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A2332),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Playback Speed',
                  style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5)),
            ),
            ..._speeds.map((s) {
              final selected = s == _playbackSpeed;
              return ListTile(
                leading: Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: selected ? Colors.white : Colors.white38,
                  size: 20,
                ),
                title: Text(
                  s == 1.0 ? 'Normal (1×)' : '${s}×',
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _playbackSpeed = s);
                  _controller?.setPlaybackSpeed(s);
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _togglePlayPause() {
    final c = _controller!;
    if (c.value.isPlaying) {
      c.pause();
      setState(() => _showControls = true);
      _hideTimer?.cancel();
    } else {
      c.play();
      _scheduleHideControls();
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final isPlaying = c?.value.isPlaying ?? false;
    final position = c?.value.position ?? Duration.zero;
    final duration = c?.value.duration ?? Duration.zero;
    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: _showControls
            ? Colors.black.withValues(alpha: 0.6)
            : Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        iconTheme: IconThemeData(
            color: _showControls ? Colors.white : Colors.transparent),
        leading: _showControls ? null : const SizedBox.shrink(),
        title: _showControls
            ? Text(
                widget.filename,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.normal),
                overflow: TextOverflow.ellipsis,
              )
            : null,
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _initialized ? _toggleControls : null,
        onLongPress: _initialized ? _showSpeedPicker : null,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // ── Video ────────────────────────────────────────────
            if (_initialized && c != null)
              Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              ),

            // ── Download progress ────────────────────────────────
            if (_downloading)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 72,
                    height: 72,
                    child: CircularProgressIndicator(
                      value: _downloadProgress > 0 ? _downloadProgress : null,
                      color: Colors.white,
                      strokeWidth: 3,
                    ),
                  ),
                  if (_downloadProgress > 0) ...[
                    const SizedBox(height: 14),
                    Text(
                      '${(_downloadProgress * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ],
              ),

            // ── Centre play/pause ────────────────────────────────
            if (_initialized && _showControls)
              GestureDetector(
                onTap: _togglePlayPause,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 38,
                  ),
                ),
              ),

            // ── Bottom controls bar ──────────────────────────────
            if (_initialized && _showControls && c != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.8),
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Seek bar
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          thumbShape:
                              const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape:
                              const RoundSliderOverlayShape(overlayRadius: 14),
                          trackHeight: 2.5,
                          activeTrackColor: Colors.white,
                          inactiveTrackColor:
                              Colors.white.withValues(alpha: 0.3),
                          thumbColor: Colors.white,
                          overlayColor: Colors.white24,
                        ),
                        child: Slider(
                          value: progress.clamp(0.0, 1.0),
                          onChanged: (v) {
                            c.seekTo(Duration(
                                milliseconds:
                                    (v * duration.inMilliseconds).round()));
                            _scheduleHideControls();
                          },
                        ),
                      ),
                      // Time row + speed indicator
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            Text(_fmt(position),
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                            const Spacer(),
                            if (_playbackSpeed != 1.0)
                              GestureDetector(
                                onTap: _showSpeedPicker,
                                child: Container(
                                  margin: const EdgeInsets.only(right: 8),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '${_playbackSpeed}×',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            Text(_fmt(duration),
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
