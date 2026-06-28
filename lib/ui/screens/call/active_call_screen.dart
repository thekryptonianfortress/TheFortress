import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../providers/call_provider.dart';
import '../../../providers/contacts_provider.dart';
import '../../../services/webrtc_service.dart';
import '../../widgets/user_avatar.dart';

class ActiveCallScreen extends StatefulWidget {
  const ActiveCallScreen({super.key});

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen>
    with SingleTickerProviderStateMixin {
  Timer? _timer;
  int _seconds = 0;
  late final AnimationController _reconnectCtrl;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
    // Spinner shown when reconnecting
    _reconnectCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _reconnectCtrl.dispose();
    super.dispose();
  }

  String get _duration {
    final m = _seconds ~/ 60;
    final s = _seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CallProvider>(
      builder: (context, call, _) {
        if (call.callState == CallState.idle || call.callState == CallState.ended) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
          });
        }

        final peerName = call.activePeerUsername ?? 'Unknown';
        final peerAvatar = context
            .read<ContactsProvider>()
            .getByVirtualId(call.activePeerVirtualId ?? '')
            ?.avatarUrl;
        final quality = call.callQuality;
        final isReconnecting = quality == CallQuality.reconnecting ||
            quality == CallQuality.poor;

        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF0A0F1A),
                  Color(0xFF0D1822),
                  Color(0xFF0F2032),
                ],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  // ── Top bar: timer + quality ──────────────────────
                  Padding(
                    padding: const EdgeInsets.only(top: 32, bottom: 16),
                    child: Column(
                      children: [
                        // Timer
                        Text(
                          _duration,
                          style: const TextStyle(
                            color: AppTheme.accent,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 2,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Quality badge
                        _QualityBadge(
                          quality: quality,
                          reconnectCtrl: _reconnectCtrl,
                          isReconnecting: isReconnecting,
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  // ── Avatar ────────────────────────────────────────
                  UserAvatar(
                    username: peerName,
                    avatarUrl: peerAvatar,
                    radius: 72,
                    fontSize: 52,
                  ),
                  const SizedBox(height: 24),

                  // ── Peer name ─────────────────────────────────────
                  Text(
                    peerName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isReconnecting ? 'Reconnecting...' : 'Connected',
                    style: TextStyle(
                      color: isReconnecting
                          ? Colors.amber.shade400
                          : AppTheme.accent,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  const Spacer(),

                  // ── Controls ──────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.only(bottom: 56, left: 16, right: 16),
                    child: Column(
                      children: [
                        // Main row: Mute | End | Speaker
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _ControlButton(
                              icon: call.isMuted
                                  ? Icons.mic_off_rounded
                                  : Icons.mic_rounded,
                              label: call.isMuted ? 'Unmute' : 'Mute',
                              active: call.isMuted,
                              activeColor: AppTheme.primary,
                              onTap: call.toggleMute,
                            ),
                            // End call (larger)
                            _EndButton(
                              onTap: () {
                                call.endCall();
                                Navigator.of(context).popUntil((r) => r.isFirst);
                              },
                            ),
                            _ControlButton(
                              icon: call.isSpeakerOn
                                  ? Icons.volume_up_rounded
                                  : Icons.volume_down_rounded,
                              label: call.isSpeakerOn ? 'Speaker' : 'Earpiece',
                              active: call.isSpeakerOn,
                              activeColor: AppTheme.primary,
                              onTap: call.toggleSpeaker,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── Quality badge ─────────────────────────────────────────────────────────────

class _QualityBadge extends StatelessWidget {
  final CallQuality quality;
  final AnimationController reconnectCtrl;
  final bool isReconnecting;

  const _QualityBadge({
    required this.quality,
    required this.reconnectCtrl,
    required this.isReconnecting,
  });

  @override
  Widget build(BuildContext context) {
    if (isReconnecting) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: AnimatedBuilder(
              animation: reconnectCtrl,
              builder: (context, child) => Transform.rotate(
                angle: reconnectCtrl.value * 2 * 3.14159,
                child: child,
              ),
              child: const Icon(Icons.sync_rounded,
                  color: Colors.amber, size: 14),
            ),
          ),
          const SizedBox(width: 5),
          Text(
            quality == CallQuality.poor ? 'Poor connection' : 'Reconnecting',
            style: TextStyle(
              color: Colors.amber.shade400,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    // Show signal bars for good/connecting
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SignalBars(quality: quality),
        const SizedBox(width: 6),
        Text(
          quality == CallQuality.good ? 'Good' : 'Connecting',
          style: TextStyle(
            color: quality == CallQuality.good
                ? AppTheme.accent
                : AppTheme.muted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _SignalBars extends StatelessWidget {
  final CallQuality quality;
  const _SignalBars({required this.quality});

  @override
  Widget build(BuildContext context) {
    final color = quality == CallQuality.good ? AppTheme.accent : AppTheme.muted;
    final filled = quality == CallQuality.good ? 3 : 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(3, (i) {
        return Container(
          width: 3,
          height: 5.0 + i * 3.0,
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: i < filled
                ? color
                : color.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }
}

// ── Control button ────────────────────────────────────────────────────────────

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = active
        ? activeColor
        : Colors.white.withValues(alpha: 0.1);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: bgColor,
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.muted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ── End call button ───────────────────────────────────────────────────────────

class _EndButton extends StatelessWidget {
  final VoidCallback onTap;
  const _EndButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.danger,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.danger.withValues(alpha: 0.4),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(Icons.call_end_rounded,
                color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'End',
          style: TextStyle(
            color: AppTheme.muted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
