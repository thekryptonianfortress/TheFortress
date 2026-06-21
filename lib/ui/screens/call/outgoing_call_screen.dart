import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../data/models/contact.dart';
import '../../../providers/call_provider.dart';
import '../../../services/webrtc_service.dart';

class OutgoingCallScreen extends StatefulWidget {
  final Contact contact;
  const OutgoingCallScreen({super.key, required this.contact});
  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
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
    } else if (state == CallState.ended) {
      _navigating = true;
      context.read<CallProvider>().removeListener(_onStateChange);
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    // Guard: remove listener if screen disposed before call transitions
    try { context.read<CallProvider>().removeListener(_onStateChange); } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CallProvider>(
      builder: (context, call, _) {

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
                        widget.contact.username[0].toUpperCase(),
                        style: const TextStyle(
                            fontSize: 48,
                            color: AppTheme.primary,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(widget.contact.username,
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(widget.contact.virtualId,
                        style: const TextStyle(
                            color: AppTheme.muted, fontSize: 13)),
                    const SizedBox(height: 12),
                    const Text('Calling...',
                        style:
                            TextStyle(color: AppTheme.muted, fontSize: 16)),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 56),
                  child: Column(
                    children: [
                      GestureDetector(
                        onTap: () {
                          call.endCall();
                          // _onStateChange handles navigation when state → ended
                        },
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: const BoxDecoration(
                              shape: BoxShape.circle, color: AppTheme.danger),
                          child: const Icon(Icons.call_end,
                              color: Colors.white, size: 32),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text('Cancel',
                          style: TextStyle(
                              color: AppTheme.muted, fontSize: 12)),
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
