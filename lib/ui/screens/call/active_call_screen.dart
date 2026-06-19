import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../providers/call_provider.dart';
import '../../../services/webrtc_service.dart';

class ActiveCallScreen extends StatefulWidget {
  const ActiveCallScreen({super.key});

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen> {
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
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
        // Pop when call ends
        if (call.callState == CallState.idle || call.callState == CallState.ended) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
          });
        }

        final peerName = call.activePeerUsername ?? 'Unknown';

        return Scaffold(
          backgroundColor: AppTheme.surface,
          body: SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const SizedBox(height: 48),
                Column(
                  children: [
                    CircleAvatar(
                      radius: 56,
                      backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
                      child: Text(
                        peerName.isNotEmpty ? peerName[0].toUpperCase() : '?',
                        style: const TextStyle(
                            fontSize: 48, color: AppTheme.primary, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(peerName,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(call.activePeerVirtualId ?? '',
                        style: const TextStyle(color: AppTheme.muted, fontSize: 13)),
                    const SizedBox(height: 12),
                    Text(_duration, style: const TextStyle(color: AppTheme.accent, fontSize: 18)),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 56),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _CallButton(
                        icon: call.isMuted ? Icons.mic_off : Icons.mic,
                        label: call.isMuted ? 'Unmute' : 'Mute',
                        color: call.isMuted ? AppTheme.primary : AppTheme.surfaceVariant,
                        onTap: call.toggleMute,
                      ),
                      _CallButton(
                        icon: Icons.call_end,
                        label: 'End',
                        color: AppTheme.danger,
                        onTap: () {
                          call.endCall();
                          Navigator.of(context).popUntil((r) => r.isFirst);
                        },
                        size: 72,
                      ),
                      _CallButton(
                        icon: call.isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                        label: call.isSpeakerOn ? 'Speaker' : 'Earpiece',
                        color: call.isSpeakerOn ? AppTheme.primary : AppTheme.surfaceVariant,
                        onTap: call.toggleSpeaker,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final double size;

  const _CallButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.size = 60,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            child: Icon(icon, color: Colors.white, size: size * 0.45),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
      ],
    );
  }
}
