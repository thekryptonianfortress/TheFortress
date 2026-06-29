import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../providers/call_provider.dart';
import '../../../providers/contacts_provider.dart';
import '../../../services/webrtc_service.dart' show CallState;
import '../../widgets/user_avatar.dart';

class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({super.key});
  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with TickerProviderStateMixin {
  bool _answering = false;

  late final AnimationController _pulseCtrl;
  late final AnimationController _buttonCtrl;
  late final Animation<double> _buttonScale;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    _buttonCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _buttonScale = CurvedAnimation(parent: _buttonCtrl, curve: Curves.elasticOut);
    _buttonCtrl.forward();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _buttonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = context.watch<CallProvider>();
    final info = call.incomingCall;

    if (info == null && !_answering) {
      final state = call.callState;
      // Notification "Answer" path: answerCall() sets callState=active before
      // clearing incomingCall. Don't pop when call is active — _IncomingCallListener
      // will push /call/active on top of us.
      if (state != CallState.active) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).maybePop();
        });
      }
      return const Scaffold(backgroundColor: Color(0xFF0D1117));
    }

    if (info == null) return const Scaffold(backgroundColor: Color(0xFF0D1117));

    final avatarUrl = context
        .read<ContactsProvider>()
        .getByVirtualId(info.callerVirtualId)
        ?.avatarUrl;

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
              // Top label
              Padding(
                padding: const EdgeInsets.only(top: 52),
                child: Column(
                  children: [
                    Icon(
                      info.isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                      color: AppTheme.accent,
                      size: 20,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      info.isVideo ? 'Incoming Video Call' : 'Incoming Voice Call',
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 15,
                        letterSpacing: 0.4,
                      ),
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
                      color: AppTheme.accent,
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
                      username: info.callerUsername,
                      avatarUrl: avatarUrl,
                      radius: 72,
                      fontSize: 52,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // Caller name
              Text(
                info.callerUsername,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              // Subtle "voice call" tag
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  info.isVideo ? 'Video Call' : 'Voice Call',
                  style: const TextStyle(
                    color: AppTheme.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),

              const Spacer(),

              // Action buttons
              ScaleTransition(
                scale: _buttonScale,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 60, left: 32, right: 32),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _RingButton(
                        icon: Icons.call_end_rounded,
                        label: 'Decline',
                        color: AppTheme.danger,
                        onTap: () {
                          call.rejectCall();
                          Navigator.pop(context);
                        },
                      ),
                      _RingButton(
                        icon: Icons.call_rounded,
                        label: 'Answer',
                        color: AppTheme.accent,
                        onTap: () async {
                          _answering = true;
                          await call.answerCall();
                          if (mounted) {
                            Navigator.pushReplacementNamed(context, '/call/active');
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
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

// ── Ring action button ────────────────────────────────────────────────────────

class _RingButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _RingButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.4),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 34),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.muted,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
