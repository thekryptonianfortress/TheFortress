import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../providers/call_provider.dart';
import '../../../providers/contacts_provider.dart';
import '../../../providers/group_call_provider.dart';
import '../../../services/webrtc_service.dart';
import '../../widgets/user_avatar.dart';
import 'group_call_screen.dart';

class ActiveCallScreen extends StatefulWidget {
  const ActiveCallScreen({super.key});

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen>
    with TickerProviderStateMixin {
  Timer? _durationTimer;
  int _seconds = 0;

  // Video call: auto-hiding controls
  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _pipSwapped = false; // swap local ↔ remote in PiP

  late final AnimationController _reconnectCtrl;
  late final AnimationController _controlsFadeCtrl;
  late final Animation<double> _controlsFade;

  // Guard: prevent duplicate navigation when state notifies multiple times
  bool _handlingCallEnd = false;

  @override
  void initState() {
    super.initState();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final callProvider = context.read<CallProvider>();
      callProvider.onUpgradeToGroup = (groupId, groupName, isVideo) async {
        final gc = context.read<GroupCallProvider>();
        await gc.startCall(groupId: groupId, groupName: groupName, isVideo: isVideo);
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const GroupCallScreen()),
          );
        }
      };
      // Listen for call-end / call-upgraded transitions — outside the builder
      // so navigation fires exactly once regardless of how many rebuilds occur.
      callProvider.addListener(_onCallStateChanged);
    });

    _reconnectCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _controlsFadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: 1.0,
    );
    _controlsFade = CurvedAnimation(parent: _controlsFadeCtrl, curve: Curves.easeInOut);

    _scheduleHide();
  }

  void _onCallStateChanged() {
    if (!mounted || _handlingCallEnd) return;
    final call = context.read<CallProvider>();
    if ((call.callState == CallState.idle || call.callState == CallState.ended)
        && !call.upgradingToGroup) {
      _handlingCallEnd = true;
      _handleCallEnd(call);
    }
  }

  Future<void> _handleCallEnd(CallProvider call) async {
    final gc = context.read<GroupCallProvider>();
    final joinInfo = call.pendingGroupJoin;
    if (joinInfo != null) {
      // Our 1:1 was upgraded by the peer — auto-join the group call.
      call.clearPendingGroupJoin();
      try {
        await gc.joinCall(
          groupId: joinInfo['groupId'] as String,
          groupName: joinInfo['groupName'] as String,
          isVideo: joinInfo['isVideo'] as bool,
        );
      } catch (_) {}
      if (mounted) Navigator.of(context).pushReplacementNamed('/call/group');
    } else if (gc.hasIncomingGroupCall) {
      if (mounted) Navigator.of(context).pushReplacementNamed('/call/group');
    } else {
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _hideTimer?.cancel();
    _reconnectCtrl.dispose();
    _controlsFadeCtrl.dispose();
    final cp = context.read<CallProvider>();
    cp.removeListener(_onCallStateChanged);
    // If we're mid-upgrade, clean up the 1:1 WebRTC side now that we've navigated away
    if (cp.upgradingToGroup) cp.finishUpgrade();
    cp.onUpgradeToGroup = null;
    super.dispose();
  }

  String get _duration {
    final m = _seconds ~/ 60;
    final s = _seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _controlsVisible) {
        setState(() => _controlsVisible = false);
        _controlsFadeCtrl.reverse();
      }
    });
  }

  void _onTapScreen() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
      _controlsFadeCtrl.forward();
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
      _controlsFadeCtrl.reverse();
    }
  }

  void _onControlTap(VoidCallback action) {
    action();
    // Reset auto-hide after interacting
    if (_controlsVisible) _scheduleHide();
  }

  void _showAddParticipantSheet(BuildContext context, CallProvider call) {
    final contacts = context.read<ContactsProvider>().contacts;
    final available = contacts
        .where((c) => c.virtualId != call.activePeerVirtualId)
        .toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D1117),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36, height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Add to call',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          if (available.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No other contacts to add', style: TextStyle(color: Colors.white54)),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: available.length,
                itemBuilder: (ctx, i) {
                  final c = available[i];
                  return ListTile(
                    leading: UserAvatar(username: c.username, avatarUrl: c.avatarUrl, radius: 20, fontSize: 15),
                    title: Text(c.username, style: const TextStyle(color: Colors.white)),
                    subtitle: Text(c.virtualId, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    onTap: () {
                      Navigator.pop(ctx);
                      call.addParticipant(
                        targetVirtualId: c.virtualId,
                        targetUsername: c.username,
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

  @override
  Widget build(BuildContext context) {
    return Consumer<CallProvider>(
      builder: (context, call, _) {
        final peerName = call.activePeerUsername ?? 'Unknown';
        final peerAvatar = context
            .read<ContactsProvider>()
            .getByVirtualId(call.activePeerVirtualId ?? '')
            ?.avatarUrl;
        final quality = call.callQuality;
        final isReconnecting = quality == CallQuality.reconnecting ||
            quality == CallQuality.poor;
        final isConnecting = quality == CallQuality.connecting;

        // ── VIDEO CALL layout ──────────────────────────────────────────────
        if (call.isVideo) {
          // While waiting for remote stream, always show controls so the user
          // can see their own camera preview and has access to end-call.
          if (!call.hasRemoteStream && !_controlsVisible) {
            _controlsVisible = true;
            _controlsFadeCtrl.value = 1.0;
          }

          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: Scaffold(
              backgroundColor: Colors.black,
              body: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onTapScreen,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // ── Main video (remote, or local if swapped) ──────────
                    Positioned.fill(
                      child: _pipSwapped
                          ? (call.isCameraOn
                              ? RTCVideoView(call.localRenderer,
                                  mirror: true,
                                  objectFit: RTCVideoViewObjectFit
                                      .RTCVideoViewObjectFitCover)
                              : _CameraOffBackground(name: peerName))
                          : RTCVideoView(call.remoteRenderer,
                              objectFit: RTCVideoViewObjectFit
                                  .RTCVideoViewObjectFitCover),
                    ),

                    // ── "Waiting for video" overlay ───────────────────────
                    // Shown until the remote stream actually arrives —
                    // quality alone is NOT reliable (ICE can connect before
                    // the first video frame is decoded).
                    if (!_pipSwapped && !call.hasRemoteStream)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.88),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              UserAvatar(
                                username: peerName,
                                avatarUrl: peerAvatar,
                                radius: 56,
                                fontSize: 40,
                              ),
                              const SizedBox(height: 20),
                              Text(
                                peerName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 10),
                              _StatusDots(
                                text: isReconnecting
                                    ? 'Reconnecting'
                                    : isConnecting
                                        ? 'Connecting'
                                        : 'Waiting for video',
                                color: isReconnecting
                                    ? Colors.amber
                                    : Colors.white70,
                              ),
                            ],
                          ),
                        ),
                      ),

                    // ── Top gradient scrim ────────────────────────────────
                    Positioned(
                      top: 0, left: 0, right: 0,
                      child: FadeTransition(
                        opacity: _controlsFade,
                        child: Container(
                          height: 160,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.75),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ── Top bar ───────────────────────────────────────────
                    Positioned(
                      top: 0, left: 0, right: 0,
                      child: FadeTransition(
                      opacity: _controlsFade,
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
                          child: Row(
                            children: [
                              // Back (minimize) button
                              IconButton(
                                icon: const Icon(Icons.keyboard_arrow_down_rounded,
                                    color: Colors.white, size: 30),
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                              // Peer info
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      peerName,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      _duration,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 13,
                                        fontFeatures: [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // Add participant
                              IconButton(
                                icon: const Icon(Icons.person_add_rounded, color: Colors.white70, size: 22),
                                tooltip: 'Add to call',
                                onPressed: () => _showAddParticipantSheet(context, call),
                              ),
                              // Quality badge
                              _QualityBadge(
                                quality: quality,
                                reconnectCtrl: _reconnectCtrl,
                                isReconnecting: isReconnecting,
                              ),
                            ],
                          ),
                        ),
                      ),
                      ),
                    ),

                    // ── Local PiP (bottom-right, above controls) ──────────
                    Positioned(
                      bottom: 130,
                      right: 16,
                      child: SafeArea(
                        top: false,
                        child: GestureDetector(
                          onTap: () {
                            setState(() => _pipSwapped = !_pipSwapped);
                            _scheduleHide();
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 108,
                            height: 160,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.4),
                                width: 1.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.4),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(15),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  _pipSwapped
                                      ? RTCVideoView(call.remoteRenderer,
                                          objectFit: RTCVideoViewObjectFit
                                              .RTCVideoViewObjectFitCover)
                                      : (call.isCameraOn
                                          ? RTCVideoView(call.localRenderer,
                                              mirror: true,
                                              objectFit: RTCVideoViewObjectFit
                                                  .RTCVideoViewObjectFitCover)
                                          : _CameraOffBackground(name: 'You')),
                                  // Swap hint
                                  Positioned(
                                    top: 6, right: 6,
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.4),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Icon(
                                        Icons.swap_horiz_rounded,
                                        color: Colors.white70,
                                        size: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ── Bottom gradient scrim ─────────────────────────────
                    Positioned(
                      bottom: 0, left: 0, right: 0,
                      child: FadeTransition(
                        opacity: _controlsFade,
                        child: Container(
                          height: 220,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.85),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ── Bottom controls ───────────────────────────────────
                    Positioned(
                      bottom: 0, left: 0, right: 0,
                      child: FadeTransition(
                        opacity: _controlsFade,
                        child: SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Reconnecting banner
                                if (isReconnecting)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Colors.amber.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                          color: Colors.amber.withValues(alpha: 0.5)),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        AnimatedBuilder(
                                          animation: _reconnectCtrl,
                                          builder: (_, child) => Transform.rotate(
                                            angle: _reconnectCtrl.value * 2 * 3.14159,
                                            child: child,
                                          ),
                                          child: const Icon(Icons.sync_rounded,
                                              color: Colors.amber, size: 14),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          quality == CallQuality.poor
                                              ? 'Poor connection'
                                              : 'Reconnecting...',
                                          style: TextStyle(
                                              color: Colors.amber.shade300,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500),
                                        ),
                                      ],
                                    ),
                                  ),
                                // Main controls row
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    _VideoControl(
                                      icon: call.isMuted
                                          ? Icons.mic_off_rounded
                                          : Icons.mic_rounded,
                                      label: call.isMuted ? 'Unmute' : 'Mute',
                                      active: call.isMuted,
                                      onTap: () => _onControlTap(call.toggleMute),
                                    ),
                                    _VideoControl(
                                      icon: call.isCameraOn
                                          ? Icons.videocam_rounded
                                          : Icons.videocam_off_rounded,
                                      label: call.isCameraOn ? 'Camera' : 'No cam',
                                      active: !call.isCameraOn,
                                      activeColor: const Color(0xFF444444),
                                      onTap: () => _onControlTap(call.toggleVideo),
                                    ),
                                    // End call — larger, centre
                                    _EndCallButton(
                                      onTap: () {
                                        call.endCall();
                                        Navigator.of(context)
                                            .popUntil((r) => r.isFirst);
                                      },
                                    ),
                                    _VideoControl(
                                      icon: Icons.flip_camera_ios_rounded,
                                      label: 'Flip',
                                      active: false,
                                      onTap: () => _onControlTap(call.toggleCamera),
                                    ),
                                    _VideoControl(
                                      icon: call.isSpeakerOn
                                          ? Icons.volume_up_rounded
                                          : Icons.volume_off_rounded,
                                      label: call.isSpeakerOn ? 'Speaker' : 'Muted spk',
                                      active: call.isSpeakerOn,
                                      onTap: () =>
                                          _onControlTap(call.toggleSpeaker),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );    // AnnotatedRegion
        }

        // ── AUDIO CALL layout ──────────────────────────────────────────────
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
                  // Top bar
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_down_rounded,
                              color: AppTheme.onSurface, size: 28),
                          onPressed: () =>
                              Navigator.of(context).popUntil((r) => r.isFirst),
                        ),
                        const Spacer(),
                        _QualityBadge(
                          quality: quality,
                          reconnectCtrl: _reconnectCtrl,
                          isReconnecting: isReconnecting,
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  UserAvatar(
                      username: peerName,
                      avatarUrl: peerAvatar,
                      radius: 72,
                      fontSize: 52),
                  const SizedBox(height: 24),

                  Text(
                    peerName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3),
                  ),
                  const SizedBox(height: 8),

                  // Duration / status
                  Text(
                    isReconnecting ? 'Reconnecting...' : _duration,
                    style: TextStyle(
                      color: isReconnecting
                          ? Colors.amber.shade400
                          : AppTheme.accent,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),

                  const Spacer(),

                  // Controls
                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: 52, left: 24, right: 24),
                    child: Row(
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
                        _EndButton(onTap: () {
                          call.endCall();
                          Navigator.of(context).popUntil((r) => r.isFirst);
                        }),
                        _ControlButton(
                          icon: call.isSpeakerOn
                              ? Icons.volume_up_rounded
                              : Icons.volume_off_rounded,
                          label: call.isSpeakerOn ? 'Speaker' : 'Earpiece',
                          active: call.isSpeakerOn,
                          activeColor: AppTheme.primary,
                          onTap: call.toggleSpeaker,
                        ),
                        _ControlButton(
                          icon: Icons.person_add_rounded,
                          label: 'Add',
                          active: false,
                          activeColor: AppTheme.primary,
                          onTap: () => _showAddParticipantSheet(context, call),
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

// ── Camera-off placeholder ─────────────────────────────────────────────────────

class _CameraOffBackground extends StatelessWidget {
  final String name;
  const _CameraOffBackground({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1F2E),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserAvatar(username: name, radius: 28, fontSize: 20),
            const SizedBox(height: 8),
            const Icon(Icons.videocam_off_rounded, color: Colors.white38, size: 18),
          ],
        ),
      ),
    );
  }
}

// ── Animated status dots ──────────────────────────────────────────────────────

class _StatusDots extends StatefulWidget {
  final String text;
  final Color color;
  const _StatusDots({required this.text, required this.color});

  @override
  State<_StatusDots> createState() => _StatusDotsState();
}

class _StatusDotsState extends State<_StatusDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.text,
            style: TextStyle(
                color: widget.color, fontSize: 14, fontWeight: FontWeight.w500)),
        const SizedBox(width: 4),
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => Row(
            children: List.generate(3, (i) {
              final phase = (_ctrl.value - i / 3 + 1.0) % 1.0;
              final bounce = phase < 0.5 ? phase * 2 : 2 - phase * 2;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Transform.translate(
                  offset: Offset(0, -bounce * 4),
                  child: Container(
                    width: 4, height: 4,
                    decoration: BoxDecoration(
                      color: widget.color.withValues(alpha: 0.5 + bounce * 0.5),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
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
      return AnimatedBuilder(
        animation: reconnectCtrl,
        builder: (_, child) => Transform.rotate(
          angle: reconnectCtrl.value * 2 * 3.14159,
          child: child,
        ),
        child: Icon(
          Icons.sync_rounded,
          color: quality == CallQuality.poor ? Colors.redAccent : Colors.amber,
          size: 18,
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(3, (i) {
        final filled = quality == CallQuality.good ? 3 : 1;
        final color = quality == CallQuality.good ? AppTheme.accent : AppTheme.muted;
        return Container(
          width: 3,
          height: 5.0 + i * 3.5,
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: i < filled ? color : color.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(1.5),
          ),
        );
      }),
    );
  }
}

// ── Video call control button ─────────────────────────────────────────────────

class _VideoControl extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color? activeColor;
  final VoidCallback onTap;

  const _VideoControl({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final bg = active
        ? (activeColor ?? Colors.white.withValues(alpha: 0.25))
        : Colors.white.withValues(alpha: 0.15);

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ── End call button (video) ───────────────────────────────────────────────────

class _EndCallButton extends StatelessWidget {
  final VoidCallback onTap;
  const _EndCallButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 68, height: 68,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.danger,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.danger.withValues(alpha: 0.5),
                  blurRadius: 18,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 30),
          ),
          const SizedBox(height: 8),
          const Text(
            'End',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Audio call control button ─────────────────────────────────────────────────

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
            width: 64, height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? activeColor : Colors.white.withValues(alpha: 0.1),
            ),
            child: Icon(icon, color: Colors.white, size: 27),
          ),
        ),
        const SizedBox(height: 10),
        Text(label,
            style: const TextStyle(
                color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w500)),
      ],
    );
  }
}

// ── Audio end call button ─────────────────────────────────────────────────────

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
            width: 74, height: 74,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.danger,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.danger.withValues(alpha: 0.45),
                  blurRadius: 22,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 10),
        const Text('End',
            style: TextStyle(
                color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w500)),
      ],
    );
  }
}
