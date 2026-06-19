import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../providers/call_provider.dart';

class IncomingCallScreen extends StatelessWidget {
  const IncomingCallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final call = context.watch<CallProvider>();
    final info = call.incomingCall;
    if (info == null) return const SizedBox.shrink();

    return Scaffold(
      backgroundColor: AppTheme.surface,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const SizedBox(height: 64),
            Column(
              children: [
                CircleAvatar(
                  radius: 56,
                  backgroundColor: AppTheme.accent.withValues(alpha: 0.2),
                  child: Text(
                    info.callerUsername.isNotEmpty ? info.callerUsername[0].toUpperCase() : '?',
                    style: const TextStyle(fontSize: 48, color: AppTheme.accent, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 20),
                Text(info.callerUsername, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(info.callerVirtualId, style: const TextStyle(color: AppTheme.muted)),
                const SizedBox(height: 12),
                const Text('Incoming Call', style: TextStyle(color: AppTheme.muted, fontSize: 16)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 56),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ActionButton(
                    icon: Icons.call_end,
                    label: 'Decline',
                    color: AppTheme.danger,
                    onTap: () {
                      call.rejectCall();
                      Navigator.pop(context);
                    },
                  ),
                  _ActionButton(
                    icon: Icons.call,
                    label: 'Answer',
                    color: AppTheme.accent,
                    onTap: () async {
                      await call.answerCall();
                      if (context.mounted) {
                        Navigator.pushReplacementNamed(context, '/call/active');
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionButton({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: AppTheme.muted)),
      ],
    );
  }
}
