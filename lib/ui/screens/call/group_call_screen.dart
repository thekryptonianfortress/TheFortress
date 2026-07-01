import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../providers/contacts_provider.dart';
import '../../../providers/group_call_provider.dart';
import '../../widgets/user_avatar.dart';

class GroupCallScreen extends StatelessWidget {
  const GroupCallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<GroupCallProvider>(
      builder: (context, gc, _) {
        // ── Incoming group call screen (not yet joined) ──────────────────────
        if (gc.hasIncomingGroupCall) {
          return _IncomingGroupCallScreen(gc: gc);
        }

        // ── In-call screen ───────────────────────────────────────────────────
        if (gc.inCall) {
          return gc.isVideo
              ? _VideoGroupCallScreen(gc: gc)
              : _AudioGroupCallScreen(gc: gc);
        }

        // ── Fallback: nothing to show, pop ───────────────────────────────────
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        });
        return const Scaffold(backgroundColor: Color(0xFF0A0F1A));
      },
    );
  }
}

// ── Incoming group call UI ────────────────────────────────────────────────────

class _IncomingGroupCallScreen extends StatelessWidget {
  final GroupCallProvider gc;
  const _IncomingGroupCallScreen({required this.gc});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D1117), Color(0xFF111827), Color(0xFF0F2027)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 52),
                child: Column(
                  children: [
                    Icon(
                      gc.incomingIsVideo ? Icons.videocam_rounded : Icons.call_rounded,
                      color: AppTheme.accent, size: 20,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      gc.incomingIsVideo ? 'Incoming Video Call' : 'Incoming Voice Call',
                      style: const TextStyle(color: AppTheme.muted, fontSize: 15, letterSpacing: 0.4),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              UserAvatar(username: gc.incomingGroupName ?? 'Group', radius: 64, fontSize: 44),
              const SizedBox(height: 20),
              Text(
                gc.incomingGroupName ?? 'Group',
                style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700),
              ),
              if (gc.incomingCallerName != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Started by ${gc.incomingCallerName}',
                  style: const TextStyle(color: AppTheme.muted, fontSize: 13),
                ),
              ],
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  gc.incomingIsVideo ? 'Video Call' : 'Voice Call',
                  style: const TextStyle(color: AppTheme.accent, fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),

              const Spacer(),

              Padding(
                padding: const EdgeInsets.only(bottom: 60, left: 32, right: 32),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _RingButton(
                      icon: Icons.call_end_rounded,
                      label: 'Decline',
                      color: AppTheme.danger,
                      onTap: () {
                        gc.declineGroupCall();
                        Navigator.of(context).pop();
                      },
                    ),
                    _RingButton(
                      icon: gc.incomingIsVideo ? Icons.videocam_rounded : Icons.call_rounded,
                      label: 'Join',
                      color: AppTheme.accent,
                      onTap: () async {
                        await gc.joinCall(
                          groupId: gc.incomingGroupId!,
                          groupName: gc.incomingGroupName!,
                          isVideo: gc.incomingIsVideo,
                        );
                        // Screen rebuilds to in-call layout once notifyListeners fires
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Audio group call UI ───────────────────────────────────────────────────────

class _AudioGroupCallScreen extends StatelessWidget {
  final GroupCallProvider gc;
  const _AudioGroupCallScreen({required this.gc});

  @override
  Widget build(BuildContext context) {
    final participants = gc.participants;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0A0F1A), Color(0xFF0D1822), Color(0xFF0F2032)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                child: Row(
                  children: [
                    const Icon(Icons.groups_rounded, color: AppTheme.accent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        gc.groupName ?? 'Group Call',
                        style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '${participants.length + 1} in call',
                      style: const TextStyle(color: AppTheme.muted, fontSize: 13),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // Participant avatar grid
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Wrap(
                  spacing: 20,
                  runSpacing: 20,
                  alignment: WrapAlignment.center,
                  children: [
                    // Local user
                    _AudioParticipantTile(
                      username: 'You',
                      isMuted: gc.isMuted,
                    ),
                    // Remote peers
                    ...participants.map((p) => _AudioParticipantTile(username: p.username)),
                  ],
                ),
              ),

              const Spacer(),

              // Controls
              Padding(
                padding: const EdgeInsets.only(bottom: 56, left: 16, right: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _ControlButton(
                      icon: gc.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                      label: gc.isMuted ? 'Unmute' : 'Mute',
                      active: gc.isMuted,
                      activeColor: AppTheme.primary,
                      onTap: gc.toggleMute,
                    ),
                    _ControlButton(
                      icon: Icons.person_add_rounded,
                      label: 'Add',
                      active: false,
                      activeColor: AppTheme.primary,
                      onTap: () => _showAddParticipantSheet(context, gc),
                    ),
                    _EndButton(onTap: () {
                      gc.leaveCall();
                      Navigator.of(context).pop();
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AudioParticipantTile extends StatelessWidget {
  final String username;
  final bool isMuted;
  const _AudioParticipantTile({required this.username, this.isMuted = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          alignment: Alignment.bottomRight,
          children: [
            UserAvatar(username: username, radius: 36, fontSize: 26),
            if (isMuted)
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: AppTheme.danger,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF0A0F1A), width: 1.5),
                ),
                child: const Icon(Icons.mic_off_rounded, color: Colors.white, size: 10),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 72,
          child: Text(
            username,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

// ── Video group call UI ───────────────────────────────────────────────────────

class _VideoGroupCallScreen extends StatelessWidget {
  final GroupCallProvider gc;
  const _VideoGroupCallScreen({required this.gc});

  @override
  Widget build(BuildContext context) {
    final participants = gc.participants;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Participant video grid
          Positioned.fill(
            child: _VideoGrid(gc: gc, participants: participants),
          ),

          // Top bar gradient scrim
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              height: 100,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withValues(alpha: 0.7), Colors.transparent],
                ),
              ),
            ),
          ),

          // Top bar content — must be Positioned so Stack doesn't shrink-wrap to it
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    const Icon(Icons.groups_rounded, color: Colors.white70, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        gc.groupName ?? 'Group Call',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '${participants.length + 1} in call',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Controls bar at bottom
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black.withValues(alpha: 0.8), Colors.transparent],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _ControlButton(
                        icon: gc.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                        label: gc.isMuted ? 'Unmute' : 'Mute',
                        active: gc.isMuted,
                        activeColor: AppTheme.primary,
                        onTap: gc.toggleMute,
                      ),
                      _ControlButton(
                        icon: gc.isCameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                        label: gc.isCameraOn ? 'Camera' : 'Cam Off',
                        active: !gc.isCameraOn,
                        activeColor: Colors.red,
                        onTap: gc.toggleCamera,
                      ),
                      _ControlButton(
                        icon: Icons.person_add_rounded,
                        label: 'Add',
                        active: false,
                        activeColor: AppTheme.primary,
                        onTap: () => _showAddParticipantSheet(context, gc),
                      ),
                      _EndButton(onTap: () {
                        gc.leaveCall();
                        Navigator.of(context).pop();
                      }),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoGrid extends StatelessWidget {
  final GroupCallProvider gc;
  final List<GroupCallParticipant> participants;
  const _VideoGrid({required this.gc, required this.participants});

  @override
  Widget build(BuildContext context) {
    // Tiles: local + each remote peer
    final tiles = <Widget>[
      _VideoTile(
        label: 'You',
        renderer: gc.localRenderer,
        // Show video only if camera is on AND we actually have a local stream
        hasVideo: gc.isCameraOn && gc.localRenderer.srcObject != null,
        isLocal: true,
      ),
      ...participants.map((p) => _VideoTile(
        label: p.username,
        renderer: p.renderer,
        // Show video if renderer has a stream (regardless of track count)
        hasVideo: p.renderer.srcObject != null,
      )),
    ];

    if (tiles.length == 1) {
      return tiles.first;
    } else if (tiles.length == 2) {
      return Column(children: tiles.map((t) => Expanded(child: t)).toList());
    } else if (tiles.length <= 4) {
      return GridView.count(
        crossAxisCount: 2,
        physics: const NeverScrollableScrollPhysics(),
        children: tiles,
      );
    } else {
      return GridView.count(
        crossAxisCount: 3,
        children: tiles,
      );
    }
  }
}

class _VideoTile extends StatelessWidget {
  final String label;
  final RTCVideoRenderer renderer;
  final bool hasVideo;
  final bool isLocal;
  const _VideoTile({
    required this.label,
    required this.renderer,
    required this.hasVideo,
    this.isLocal = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1F2E),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasVideo)
            RTCVideoView(
              renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              mirror: isLocal,
            )
          else
            Center(
              child: UserAvatar(username: label, radius: 32, fontSize: 24),
            ),
          Positioned(
            bottom: 6, left: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 11)),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared button widgets ─────────────────────────────────────────────────────

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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 62, height: 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? activeColor : Colors.white.withValues(alpha: 0.1),
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
        ),
        const SizedBox(height: 10),
        Text(label,
            style: const TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w500)),
      ],
    );
  }
}

void _showAddParticipantSheet(BuildContext context, GroupCallProvider gc) {
  final currentVirtualIds = {
    ...gc.participants.map((p) => p.virtualId),
  };
  final contacts = context.read<ContactsProvider>().contacts
      .where((c) => !currentVirtualIds.contains(c.virtualId))
      .toList();

  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF111827),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Container(width: 40, height: 4, decoration: BoxDecoration(
          color: Colors.white24, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        const Text('Add to Call',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (contacts.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No other contacts available',
                style: TextStyle(color: AppTheme.muted)),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: contacts.length,
              itemBuilder: (_, i) {
                final c = contacts[i];
                return ListTile(
                  leading: UserAvatar(username: c.username, radius: 20, fontSize: 15),
                  title: Text(c.username,
                      style: const TextStyle(color: Colors.white, fontSize: 15)),
                  onTap: () {
                    gc.inviteParticipant(c.virtualId);
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Inviting ${c.username}…'),
                        duration: const Duration(seconds: 2),
                        backgroundColor: AppTheme.primary,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        const SizedBox(height: 16),
      ],
    ),
  );
}

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
            width: 72, height: 72,
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
            child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 10),
        const Text('Leave',
            style: TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w500)),
      ],
    );
  }
}

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
            width: 76, height: 76,
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
        Text(label,
            style: const TextStyle(color: AppTheme.muted, fontSize: 13, fontWeight: FontWeight.w500)),
      ],
    );
  }
}
