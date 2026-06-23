import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../providers/call_provider.dart';
import '../../../providers/contacts_provider.dart';
import '../../widgets/user_avatar.dart';

class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({super.key});
  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  // Prevent auto-pop from firing when we're intentionally navigating away
  bool _answering = false;

  @override
  Widget build(BuildContext context) {
    final call = context.watch<CallProvider>();
    final info = call.incomingCall;

    // Caller cancelled / call ended — pop back automatically
    if (info == null && !_answering) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const Scaffold(backgroundColor: AppTheme.surface);
    }

    if (info == null) return const Scaffold(backgroundColor: AppTheme.surface);

    return Scaffold(
      backgroundColor: AppTheme.surface,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const SizedBox(height: 64),
            Column(
              children: [
                UserAvatar(
                  username: info.callerUsername,
                  avatarUrl: context.read<ContactsProvider>()
                      .getByVirtualId(info.callerVirtualId)?.avatarUrl,
                  radius: 56,
                  backgroundColor: AppTheme.accent.withValues(alpha: 0.2),
                  fontSize: 48,
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
