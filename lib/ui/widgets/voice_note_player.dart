import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../../core/theme.dart';
import '../../services/media_service.dart';

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

// Auto-pause: only one player plays at a time
final _nowPlaying = ValueNotifier<Object?>(null);

// Auto-play next: set to the source URL that should start playing next
final _autoPlaySource = ValueNotifier<String?>(null);

// ── Player widget ───────────────────────────────────────────

class VoiceNotePlayer extends StatefulWidget {
  /// Absolute URL (for network) or local file path (when [isFile] is true).
  final String source;
  final bool isFile;
  final String? effectId;
  final bool isOutgoing;
  /// Load and prepare the audio immediately (used in preview sheets with local files).
  final bool autoLoad;
  /// Source URL of the next voice note in the list. When this player finishes,
  /// it signals [_autoPlaySource] so the next player auto-starts.
  final String? nextSource;
  /// If false, the audio is not downloaded until the user taps play.
  final bool shouldAutoDownload;

  const VoiceNotePlayer({
    super.key,
    required this.source,
    this.isFile = false,
    this.effectId,
    this.isOutgoing = false,
    this.autoLoad = false,
    this.nextSource,
    this.shouldAutoDownload = true,
  });

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer>
    with TickerProviderStateMixin {
  late final AudioPlayer _player;

  // Playback state
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _loaded = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // Scrubbing state
  bool _isScrubbing = false;
  double _scrubProgress = 0.0;
  double _waveformWidth = 0.0; // set by LayoutBuilder

  // Playback speed: cycles 1× → 1.5× → 2×
  double _speedMultiplier = 1.0;
  static const _speeds = [1.0, 1.5, 2.0];

  // Animation controllers
  late final AnimationController _sweepAnim;  // gradient sweep while playing
  late final AnimationController _pulseAnim;  // waveform bar breathing

  @override
  void initState() {
    super.initState();

    _player = AudioPlayer();

    _sweepAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _pulseAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );

    _player.positionStream.listen((pos) {
      if (mounted && !_isScrubbing) setState(() => _position = pos);
    });
    _player.durationStream.listen((dur) {
      if (mounted && dur != null) setState(() => _duration = dur);
    });
    _player.playerStateStream.listen((s) {
      if (!mounted) return;
      final done = s.processingState == ProcessingState.completed;
      final playing = s.playing && !done;
      setState(() => _isPlaying = playing);
      if (playing) {
        _sweepAnim.repeat();
        _pulseAnim.repeat(reverse: true);
        _nowPlaying.value = this;
      } else {
        _sweepAnim.stop();
        _pulseAnim.stop();
        _pulseAnim.reset();
        if (_nowPlaying.value == this) _nowPlaying.value = null;
      }
      if (done) {
        _player.seek(Duration.zero);
        _player.pause();
        setState(() => _position = Duration.zero);
        // Signal the next voice note to auto-play
        if (widget.nextSource != null) {
          _autoPlaySource.value = widget.nextSource;
        }
      }
    });

    // Auto-pause when another player starts
    _nowPlaying.addListener(_onNowPlayingChanged);
    // Auto-play when signaled as next
    _autoPlaySource.addListener(_onAutoPlaySource);

    // Network sources: download & cache if auto-download is enabled.
    // When disabled, user taps play to trigger download on demand.
    // Local files (preview sheet): load right away.
    if (!widget.isFile) {
      if (widget.shouldAutoDownload) _downloadAndLoad();
    } else if (widget.autoLoad || widget.isFile) {
      _load();
    }
  }

  void _onNowPlayingChanged() {
    if (_nowPlaying.value != this && _isPlaying) {
      _player.pause();
    }
  }

  void _onAutoPlaySource() {
    if (_autoPlaySource.value == widget.source && !_isPlaying && mounted) {
      _autoPlaySource.value = null; // consume the signal
      _togglePlay();
    }
  }

  @override
  void dispose() {
    _nowPlaying.removeListener(_onNowPlayingChanged);
    _autoPlaySource.removeListener(_onAutoPlaySource);
    _sweepAnim.dispose();
    _pulseAnim.dispose();
    _player.dispose();
    super.dispose();
  }

  /// Download to local cache then load into player. Used for network URLs.
  Future<void> _downloadAndLoad() async {
    if (_loaded || _isLoading) return;
    setState(() => _isLoading = true);
    try {
      final filename = widget.source.split('/').last;
      final file = await MediaService.downloadFile(widget.source, filename);
      if (!mounted) return;
      final effect = voiceEffectById(widget.effectId);
      await _player.setFilePath(file.path);
      await _player.setSpeed(effect.speed * _speedMultiplier);
      await _player.setPitch(effect.pitch);
      if (mounted) setState(() { _loaded = true; _isLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Load from local file path directly. Used for recorded files in preview sheet.
  Future<void> _load() async {
    if (_loaded || _isLoading) return;
    setState(() => _isLoading = true);
    try {
      final effect = voiceEffectById(widget.effectId);
      await _player.setFilePath(widget.source);
      await _player.setSpeed(effect.speed * _speedMultiplier);
      await _player.setPitch(effect.pitch);
      if (mounted) setState(() { _loaded = true; _isLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _togglePlay() async {
    if (_isLoading) return;
    if (!_loaded) {
      await (widget.isFile ? _load() : _downloadAndLoad());
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

  Future<void> _cycleSpeed() async {
    final nextIdx = (_speeds.indexOf(_speedMultiplier) + 1) % _speeds.length;
    setState(() => _speedMultiplier = _speeds[nextIdx]);
    if (_loaded) {
      final effect = voiceEffectById(widget.effectId);
      await _player.setSpeed(effect.speed * _speedMultiplier);
    }
  }

  void _onScrubStart(DragStartDetails details) {
    if (!_loaded || _duration == Duration.zero) return;
    final progress = (details.localPosition.dx / _waveformWidth).clamp(0.0, 1.0);
    setState(() {
      _isScrubbing = true;
      _scrubProgress = progress;
    });
  }

  void _onScrubUpdate(DragUpdateDetails details) {
    if (!_loaded || _duration == Duration.zero) return;
    final progress = (details.localPosition.dx / _waveformWidth).clamp(0.0, 1.0);
    setState(() => _scrubProgress = progress);
  }

  void _onScrubEnd(DragEndDetails details) {
    if (!_loaded || _duration == Duration.zero) return;
    final seekPos = _duration * _scrubProgress;
    _player.seek(seekPos);
    setState(() {
      _isScrubbing = false;
      _position = seekPos;
    });
  }

  void _onWaveformTap(TapDownDetails details) {
    if (!_loaded || _duration == Duration.zero || _waveformWidth == 0) return;
    final progress = (details.localPosition.dx / _waveformWidth).clamp(0.0, 1.0);
    final seekPos = _duration * progress;
    _player.seek(seekPos);
    setState(() => _position = seekPos);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final displayProgress = _isScrubbing
        ? _scrubProgress
        : (_duration.inMilliseconds > 0
            ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
            : 0.0);

    final activeColor = widget.isOutgoing ? Colors.white : AppTheme.primary;
    final dimColor =
        (widget.isOutgoing ? Colors.white : AppTheme.muted).withValues(alpha: 0.28);

    // Timer label: show scrub position while dragging, else normal
    final String timeLabel;
    if (_isScrubbing && _duration > Duration.zero) {
      timeLabel = _fmt(_duration * _scrubProgress);
    } else if (_isPlaying || _position > Duration.zero) {
      timeLabel = _fmt(_position);
    } else {
      timeLabel = _duration > Duration.zero ? _fmt(_duration) : '--:--';
    }

    // Speed badge label
    final speedLabel = _speedMultiplier == 1.0
        ? '1×'
        : _speedMultiplier == 1.5
            ? '1.5×'
            : '2×';

    return AnimatedBuilder(
      animation: Listenable.merge([_sweepAnim, _pulseAnim]),
      builder: (context, _) {
        final sweep = _sweepAnim.value;
        final glowOpacity = _isPlaying ? 0.18 : 0.0;
        final gradient = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            activeColor.withValues(alpha: 0.0),
            activeColor.withValues(alpha: glowOpacity),
            activeColor.withValues(alpha: glowOpacity * 0.6),
            activeColor.withValues(alpha: 0.0),
          ],
          stops: [
            ((sweep - 0.35).clamp(0.0, 1.0)),
            ((sweep - 0.05).clamp(0.0, 1.0)),
            ((sweep + 0.15).clamp(0.0, 1.0)),
            ((sweep + 0.40).clamp(0.0, 1.0)),
          ],
        );

        return Container(
          width: 240,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: gradient,
          ),
          child: Row(
            children: [
              // Play / pause button
              GestureDetector(
                onTap: _togglePlay,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _isPlaying
                        ? activeColor.withValues(alpha: 0.28)
                        : activeColor.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                    boxShadow: _isPlaying
                        ? [
                            BoxShadow(
                              color: activeColor.withValues(alpha: 0.35),
                              blurRadius: 10,
                              spreadRadius: 1,
                            )
                          ]
                        : [],
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
              const SizedBox(width: 8),
              // Waveform + timer
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Scrubable waveform
                    LayoutBuilder(
                      builder: (context, constraints) {
                        _waveformWidth = constraints.maxWidth;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: _onScrubStart,
                          onHorizontalDragUpdate: _onScrubUpdate,
                          onHorizontalDragEnd: _onScrubEnd,
                          onTapDown: _onWaveformTap,
                          child: SizedBox(
                            height: 36,
                            width: double.infinity,
                            child: CustomPaint(
                              painter: _WaveformPainter(
                                progress: displayProgress,
                                activeColor: activeColor,
                                dimColor: dimColor,
                                pulseValue: _isPlaying && !_isScrubbing
                                    ? _pulseAnim.value
                                    : 0.0,
                                isScrubbing: _isScrubbing,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          timeLabel,
                          style: TextStyle(
                            color: activeColor.withValues(alpha: 0.65),
                            fontSize: 10,
                          ),
                        ),
                        const Spacer(),
                        // Speed toggle button
                        GestureDetector(
                          onTap: _cycleSpeed,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: _speedMultiplier != 1.0
                                  ? activeColor.withValues(alpha: 0.22)
                                  : activeColor.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              speedLabel,
                              style: TextStyle(
                                color: activeColor.withValues(alpha: 0.80),
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
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
        );
      },
    );
  }
}

// ── Waveform painter ────────────────────────────────────────

class _WaveformPainter extends CustomPainter {
  final double progress;
  final Color activeColor;
  final Color dimColor;
  final double pulseValue; // 0.0–1.0 breathing animation for unplayed bars
  final bool isScrubbing;

  const _WaveformPainter({
    required this.progress,
    required this.activeColor,
    required this.dimColor,
    required this.pulseValue,
    required this.isScrubbing,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const barW = 3.0;
    const gap = 2.0;
    const step = barW + gap;
    final count = (size.width / step).floor();
    final doneAt = (progress * count).round();

    // Scrub thumb line
    if (isScrubbing) {
      final thumbX = progress * size.width;
      canvas.drawLine(
        Offset(thumbX, 0),
        Offset(thumbX, size.height),
        Paint()
          ..color = activeColor.withValues(alpha: 0.6)
          ..strokeWidth = 2,
      );
    }

    for (int i = 0; i < count; i++) {
      final base = _waveBars[i % _waveBars.length];
      double h;
      if (i < doneAt) {
        // Played bars: full height, solid active color
        h = (base * size.height).clamp(4.0, size.height);
      } else {
        // Unplayed bars: breathe gently while playing
        final breathe = 1.0 + 0.18 * sin(pulseValue * pi + i * 0.55);
        h = (base * size.height * breathe).clamp(4.0, size.height);
      }
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
      old.progress != progress ||
      old.activeColor != activeColor ||
      old.pulseValue != pulseValue ||
      old.isScrubbing != isScrubbing;
}
