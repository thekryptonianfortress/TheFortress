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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<CallProvider>().startCall(
            targetVirtualId: widget.contact.virtualId,
            targetUsername: widget.contact.username,
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CallProvider>(
      builder: (context, call, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (call.callState == CallState.active) {
            Navigator.of(context).pushReplacementNamed('/call/active');
          } else if (call.callState == CallState.ended) {
            // Only pop on 'ended' — never on 'idle'.
            // 'idle' is the initial state BEFORE the call starts; popping on it
            // would dismiss the screen the moment the audio permission dialog closes.
            Navigator.of(context).pop();
          }
        });

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
                          Navigator.of(context).pop();
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
