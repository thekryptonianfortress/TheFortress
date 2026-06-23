import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../../core/theme.dart';

// ── Voice effect definitions ────────────────────────────────

class VoiceEffect {
  final String id;
  final String label;
  final String emoji;
  final double pitch;
  final double speed;
  const VoiceEffect({
    required this.id,
    required this.label,
    required this.emoji,
    required this.pitch,
    required this.speed,
  });
}

const kVoiceEffects = [
  VoiceEffect(id: 'normal',   label: 'Normal',   emoji: '🎤', pitch: 1.00, speed: 1.00),
  VoiceEffect(id: 'deep',     label: 'Deep',     emoji: '🔊', pitch: 0.65, speed: 0.92),
  VoiceEffect(id: 'chipmunk', label: 'Chipmunk', emoji: '🐿️', pitch: 1.75, speed: 1.10),
  VoiceEffect(id: 'robot',    label: 'Robot',    emoji: '🤖', pitch: 0.82, speed: 1.00),
  VoiceEffect(id: 'alien',    label: 'Alien',    emoji: '👽', pitch: 1.35, speed: 1.15),
];

VoiceEffect voiceEffectById(String? id) {
  if (id == null) return kVoiceEffects.first;
  return kVoiceEffects.firstWhere((e) => e.id == id,
      orElse: () => kVoiceEffects.first);
}

// Static waveform bar heights (pseudo-random visual pattern)
const _waveBars = [
  0.30, 0.50, 0.80, 0.40, 0.90, 0.60, 0.30, 0.70, 0.50, 0.80,
  0.40, 0.60, 0.90, 0.30, 0.55, 0.70, 0.40, 0.85, 0.60, 0.30,
  0.70, 0.50, 0.90, 0.40, 0.65, 0.80, 0.35, 0.55, 0.75, 0.45,
];

// ── Player widget ───────────────────────────────────────────

class VoiceNotePlayer extends StatefulWidget {
  /// Absolute URL (for network) or local file path (when [isFile] is true).
  final String source;
  final bool isFile;
  final String? effectId;
  final bool isOutgoing;
  /// Load and prepare the audio immediately (useful in preview sheets).
  final bool autoLoad;

  const VoiceNotePlayer({
    super.key,
    required this.source,
    this.isFile = false,
    this.effectId,
    this.isOutgoing = false,
    this.autoLoad = false,
  });

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  late final AudioPlayer _player;
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _loaded = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _player.durationStream.listen((dur) {
      if (mounted && dur != null) setState(() => _duration = dur);
    });
    _player.playerStateStream.listen((s) {
      if (!mounted) return;
      final done = s.processingState == ProcessingState.completed;
      setState(() => _isPlaying = s.playing && !done);
      if (done) {
        _player.seek(Duration.zero);
        _player.pause();
        setState(() => _position = Duration.zero);
      }
    });
    if (widget.autoLoad) _load();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loaded || _isLoading) return;
    setState(() => _isLoading = true);
    try {
      final effect = voiceEffectById(widget.effectId);
      if (widget.isFile) {
        await _player.setFilePath(widget.source);
      } else {
        await _player.setUrl(widget.source);
      }
      await _player.setSpeed(effect.speed);
      await _player.setPitch(effect.pitch);
      if (mounted) setState(() { _loaded = true; _isLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _togglePlay() async {
    if (_isLoading) return;
    if (!_loaded) {
      await _load();
      if (!_loaded) return;
    }
    if (_isPlaying) {
      await _player.pause();
    } else {
      if (_duration > Duration.zero && _position >= _duration) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    final activeColor = widget.isOutgoing ? Colors.white : AppTheme.primary;
    final dimColor =
        (widget.isOutgoing ? Colors.white : AppTheme.muted).withValues(alpha: 0.28);

    final timeLabel = _isPlaying || _position > Duration.zero
        ? _fmt(_position)
        : (_duration > Duration.zero ? _fmt(_duration) : '--:--');

    return SizedBox(
      width: 210,
      child: Row(
        children: [
          // Play / pause button
          GestureDetector(
            onTap: _togglePlay,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: activeColor.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: _isLoading
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: activeColor),
                    )
                  : Icon(
                      _isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: activeColor,
                      size: 26,
                    ),
            ),
          ),
          const SizedBox(width: 10),
          // Waveform + timer
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 28,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _WaveformPainter(
                      progress: progress,
                      activeColor: activeColor,
                      dimColor: dimColor,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  timeLabel,
                  style: TextStyle(
                    color: activeColor.withValues(alpha: 0.65),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Waveform painter ────────────────────────────────────────

class _WaveformPainter extends CustomPainter {
  final double progress;
  final Color activeColor;
  final Color dimColor;

  const _WaveformPainter({
    required this.progress,
    required this.activeColor,
    required this.dimColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const barW = 3.0;
    const gap = 2.0;
    const step = barW + gap;
    final count = (size.width / step).floor();
    final doneAt = (progress * count).round();

    for (int i = 0; i < count; i++) {
      final h = (_waveBars[i % _waveBars.length] * size.height).clamp(4.0, size.height);
      final x = i * step;
      final y = (size.height - h) / 2;
      canvas.drawRRect(
        RRect.fromLTRBR(x, y, x + barW, y + h, const Radius.circular(1.5)),
        Paint()..color = i < doneAt ? activeColor : dimColor,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress || old.activeColor != activeColor;
}
