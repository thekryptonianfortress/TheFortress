import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../data/models/contact.dart';
import '../../../providers/call_provider.dart';
import '../../widgets/user_avatar.dart';
import '../../../services/webrtc_service.dart';

class OutgoingCallScreen extends StatefulWidget {
  final Contact contact;
  const OutgoingCallScreen({super.key, required this.contact});
  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen>
    with TickerProviderStateMixin {
  bool _navigating = false;

  late final AnimationController _pulseCtrl;
  late final AnimationController _dotsCtrl;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    _dotsCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<CallProvider>().startCall(
            targetVirtualId: widget.contact.virtualId,
            targetUsername: widget.contact.username,
          );
      context.read<CallProvider>().addListener(_onStateChange);
    });
  }

  void _onStateChange() {
    if (!mounted || _navigating) return;
    final state = context.read<CallProvider>().callState;
    if (state == CallState.active) {
      _navigating = true;
      context.read<CallProvider>().removeListener(_onStateChange);
      Navigator.of(context).pushReplacementNamed('/call/active');
    } else if (state == CallState.ended || state == CallState.idle) {
      _navigating = true;
      context.read<CallProvider>().removeListener(_onStateChange);
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    try {
      context.read<CallProvider>().removeListener(_onStateChange);
    } catch (_) {}
    _pulseCtrl.dispose();
    _dotsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CallProvider>(
      builder: (context, call, _) {
        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF0D1117),
                  Color(0xFF111827),
                  Color(0xFF0F2027),
                ],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  // Top status
                  Padding(
                    padding: const EdgeInsets.only(top: 52),
                    child: Column(
                      children: [
                        const Icon(Icons.call_rounded,
                            color: AppTheme.primary, size: 20),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Calling',
                              style: TextStyle(
                                color: AppTheme.muted,
                                fontSize: 15,
                                letterSpacing: 0.4,
                              ),
                            ),
                            const SizedBox(width: 4),
                            _AnimatedDots(controller: _dotsCtrl),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  // Pulsating avatar
                  AnimatedBuilder(
                    animation: _pulseCtrl,
                    builder: (context, child) {
                      return CustomPaint(
                        painter: _PulseRingPainter(
                          value: _pulseCtrl.value,
                          color: AppTheme.primary,
                          avatarRadius: 72,
                        ),
                        child: child,
                      );
                    },
                    child: SizedBox(
                      width: 240,
                      height: 240,
                      child: Center(
                        child: UserAvatar(
                          username: widget.contact.username,
                          avatarUrl: widget.contact.avatarUrl,
                          radius: 72,
                          fontSize: 52,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 28),

                  Text(
                    widget.contact.username,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),

                  const Spacer(),

                  // End call button
                  Padding(
                    padding: const EdgeInsets.only(bottom: 60),
                    child: Column(
                      children: [
                        GestureDetector(
                          onTap: () => call.endCall(),
                          child: Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppTheme.danger,
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.danger.withValues(alpha: 0.4),
                                  blurRadius: 16,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: const Icon(Icons.call_end_rounded,
                                color: Colors.white, size: 34),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Cancel',
                          style: TextStyle(
                            color: AppTheme.muted,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
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

// ── Pulsating ring painter ────────────────────────────────────────────────────

class _PulseRingPainter extends CustomPainter {
  final double value;
  final Color color;
  final double avatarRadius;

  const _PulseRingPainter({
    required this.value,
    required this.color,
    required this.avatarRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const numRings = 3;
    for (int i = 0; i < numRings; i++) {
      final phase = (value + i / numRings) % 1.0;
      final opacity = math.pow(1.0 - phase, 2).toDouble() * 0.45;
      final radius = avatarRadius + phase * 48;
      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_PulseRingPainter old) => old.value != value;
}

// ── Animated bouncing dots ────────────────────────────────────────────────────

class _AnimatedDots extends StatelessWidget {
  final AnimationController controller;
  const _AnimatedDots({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final delay = i / 3;
            final phase = (controller.value - delay + 1.0) % 1.0;
            final bounce = phase < 0.5 ? phase * 2 : 2 - phase * 2;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Transform.translate(
                offset: Offset(0, -bounce * 5),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: AppTheme.muted.withValues(alpha: 0.5 + bounce * 0.5),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
