import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../services/notification_service.dart';
import '../../../core/theme.dart';
import '../../../data/local/database.dart';
import '../../../data/models/call_record.dart';
import '../../../providers/call_provider.dart';
import '../../../providers/group_call_provider.dart';
import '../../../providers/contacts_provider.dart';
import '../../../providers/messages_provider.dart';
import 'dart:async';
import '../../../services/signaling_service.dart';
import '../../../services/webrtc_service.dart' show CallState;
import '../contacts/contacts_screen.dart';
import '../groups/groups_list_screen.dart';
import '../settings/settings_screen.dart';
import '../../widgets/user_avatar.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/backup_provider.dart';
import '../../../providers/groups_provider.dart';
import '../settings/profile_edit_screen.dart';
import 'package:intl/intl.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;
  List<CallRecord> _callHistory = [];
  CallState? _prevCallState;
  bool _prevHadIncoming = false;
  int _unseenMissedCount = 0;
  DateTime _lastCallsViewed = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<SignalingMessage>? _presenceSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initLastCallsViewed();
    _loadCallHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _subscribePresence();
      await context.read<ContactsProvider>().loadContacts();
      if (mounted) _checkPendingNotificationChat();
      if (mounted) _checkPendingGroupCall();
      // Load backup settings and run scheduled backup if due
      if (mounted) {
        final backup = context.read<BackupProvider>();
        await backup.load();
        await backup.checkScheduled();
      }
    });
  }

  void _subscribePresence() {
    _presenceSub = context.read<SignalingService>().stream.listen((msg) {
      if (!mounted) return;
      final contacts = context.read<ContactsProvider>();

      if (msg.event == SignalingEvent.presenceUpdate) {
        final userId = msg.data['user_id'] as String?;
        final isOnline = msg.data['is_online'] as bool? ?? false;
        final lastSeenStr = msg.data['last_seen'] as String?;
        final lastSeen = lastSeenStr != null ? DateTime.tryParse(lastSeenStr) : null;
        if (userId != null) {
          contacts.updatePresence(userId, isOnline, lastSeen: lastSeen);
        }
      } else if (msg.event == SignalingEvent.contactsPresence) {
        final list = (msg.data['list'] as List).cast<Map<dynamic, dynamic>>();
        for (final entry in list) {
          final userId = entry['user_id'] as String?;
          final isOnline = entry['is_online'] as bool? ?? false;
          if (userId != null) {
            contacts.updatePresence(userId, isOnline);
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _presenceSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPendingNotificationChat();
      if (mounted) {
        // Re-sync contacts from server and refresh all message previews from
        // local DB so the chat list is always current when the app comes back.
        context.read<ContactsProvider>().loadContacts();
        context.read<MessagesProvider>().refreshFromDb();
      }
    }
  }

  Future<void> _checkPendingNotificationChat() async {
    // Primary: set by NotificationService (init or MethodChannel handler)
    String? virtualId = NotificationService.pendingOpenChatVirtualId;
    if (virtualId == null) {
      // Fallback: native onNewIntent wrote to SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      virtualId = prefs.getString('pending_open_chat');
      if (virtualId != null && virtualId.isNotEmpty) {
        await prefs.remove('pending_open_chat');
      }
    }
    if (virtualId == null || virtualId.isEmpty || !mounted) return;
    NotificationService.clearPendingOpenChat();
    final contacts = context.read<ContactsProvider>().contacts;
    final contact = contacts.where((c) => c.virtualId == virtualId).firstOrNull;
    if (contact != null) {
      Navigator.pushNamed(context, '/chat', arguments: contact);
    }
  }

  void _checkPendingGroupCall() {
    if (!NotificationService.pendingGroupCallOpen) return;
    NotificationService.pendingGroupCallOpen = false;
    Navigator.of(context).pushNamed('/call/group');
  }

  Future<void> _initLastCallsViewed() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt('last_calls_tab_viewed') ?? 0;
    if (mounted) setState(() => _lastCallsViewed = DateTime.fromMillisecondsSinceEpoch(ms));
  }

  Future<void> _loadCallHistory() async {
    final records = await LocalDatabase.instance.getCallRecords();
    if (!mounted) return;
    final unseen = records
        .where((r) => r.status == CallStatus.missed && r.startedAt.isAfter(_lastCallsViewed))
        .length;
    setState(() {
      _callHistory = records;
      _unseenMissedCount = unseen;
    });
  }

  Future<void> _deleteCallRecord(CallRecord r) async {
    await LocalDatabase.instance.deleteCallRecord(r.id);
    await _loadCallHistory();
  }

  Future<void> _clearAllCallRecords() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear call history'),
        content: const Text('Delete all call logs?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear all', style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await LocalDatabase.instance.clearCallRecords();
      await _loadCallHistory();
    }
  }

  Future<void> _markCallsViewed() async {
    _lastCallsViewed = DateTime.now();
    setState(() => _unseenMissedCount = 0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('last_calls_tab_viewed', _lastCallsViewed.millisecondsSinceEpoch);
    await _loadCallHistory();
  }

  @override
  Widget build(BuildContext context) {
    final call = context.watch<CallProvider>();

    if (_prevCallState != null &&
        (_prevCallState == CallState.active ||
            _prevCallState == CallState.calling) &&
        call.callState == CallState.idle) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _loadCallHistory());
    }
    _prevCallState = call.callState;

    // Reload when an incoming call disappears (missed / rejected by us)
    final hasIncoming = call.incomingCall != null;
    if (_prevHadIncoming && !hasIncoming) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _loadCallHistory());
    }
    _prevHadIncoming = hasIncoming;

    final callState = context.watch<CallProvider>().callState;
    final isCallActive = callState == CallState.active || callState == CallState.calling;
    final gc = context.watch<GroupCallProvider>();

    // Handle group call notification tap while home screen is already mounted
    if (NotificationService.pendingGroupCallOpen) {
      NotificationService.pendingGroupCallOpen = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pushNamed('/call/group');
      });
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: _tab == 3
          ? null // Settings has its own AppBar via SliverAppBar
          : AppBar(
              backgroundColor: AppTheme.inputBg,
              elevation: 0,
              title: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppTheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _tab == 0 ? 'Chats' : _tab == 1 ? 'Calls' : 'Groups',
                    style: const TextStyle(
                      color: AppTheme.onSurface,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              actions: [
                if (_tab == 0)
                  IconButton(
                    icon: const Icon(Icons.person_add_rounded,
                        color: AppTheme.onSurface, size: 22),
                    onPressed: () =>
                        Navigator.pushNamed(context, '/contacts/add'),
                    tooltip: 'Add contact',
                  ),
                if (_tab == 1 && _callHistory.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.delete_sweep_rounded,
                        color: AppTheme.onSurface, size: 22),
                    tooltip: 'Clear all calls',
                    onPressed: _clearAllCallRecords,
                  ),
                if (_tab == 2)
                  IconButton(
                    icon: const Icon(Icons.add_rounded,
                        color: AppTheme.onSurface, size: 26),
                    onPressed: () {
                      showModalBottomSheet(
                        context: context,
                        backgroundColor: AppTheme.surface,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                        ),
                        builder: (_) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 36, height: 4,
                                margin: const EdgeInsets.only(top: 12, bottom: 12),
                                decoration: BoxDecoration(
                                  color: AppTheme.muted.withValues(alpha: 0.4),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              ListTile(
                                leading: const Icon(Icons.group_add_rounded, color: AppTheme.primary),
                                title: const Text('Create group'),
                                onTap: () {
                                  Navigator.pop(context);
                                  Navigator.pushNamed(context, '/groups/create');
                                },
                              ),
                              ListTile(
                                leading: const Icon(Icons.link_rounded, color: AppTheme.accent),
                                title: const Text('Join with code'),
                                onTap: () {
                                  Navigator.pop(context);
                                  Navigator.pushNamed(context, '/groups/join');
                                },
                              ),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      );
                    },
                    tooltip: 'Create or join group',
                  ),
                const SizedBox(width: 4),
              ],
            ),
      body: Column(
        children: [
          // ── Incoming group call banner ──────────────────────────────────────
          if (gc.hasIncomingGroupCall)
            GestureDetector(
              onTap: () => Navigator.of(context).pushNamed('/call/group'),
              child: Container(
                width: double.infinity,
                color: const Color(0xFF1E7E34),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      gc.incomingIsVideo ? Icons.videocam_rounded : Icons.call_rounded,
                      color: Colors.white, size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${gc.incomingCallerName ?? 'Someone'} is calling — Tap to join',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: gc.declineGroupCall,
                      child: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
                    ),
                  ],
                ),
              ),
            ),

          // ── Rejoin group call banner ────────────────────────────────────────
          if (gc.canRejoin)
            Container(
              width: double.infinity,
              color: AppTheme.primary.withValues(alpha: 0.92),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    gc.rejoinIsVideo ? Icons.videocam_rounded : Icons.call_rounded,
                    color: Colors.white, size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      onTap: () async {
                        await gc.rejoinCall();
                        if (mounted) Navigator.of(context).pushNamed('/call/group');
                      },
                      child: Text(
                        'Ongoing call: ${gc.rejoinGroupName ?? ''} — Tap to rejoin',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: gc.clearRejoin,
                    child: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
                  ),
                ],
              ),
            ),

          // ── Active call banner (WhatsApp-style tap to return) ──────────────
          if (isCallActive)
            GestureDetector(
              onTap: () => Navigator.of(context).pushNamed('/call/active'),
              child: Container(
                width: double.infinity,
                color: AppTheme.accent.withValues(alpha: 0.92),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      context.read<CallProvider>().isVideo
                          ? Icons.videocam_rounded
                          : Icons.call_rounded,
                      color: Colors.white, size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        callState == CallState.calling
                            ? 'Calling…   Tap to return'
                            : 'Call in progress   Tap to return',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Icon(Icons.keyboard_arrow_up_rounded, color: Colors.white, size: 20),
                  ],
                ),
              ),
            ),
          // ── Phone number reminder banner ─────────────────────────────────────
          if (!context.watch<AuthProvider>().hasPhoneNumber)
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileEditScreen()),
              ),
              child: Container(
                width: double.infinity,
                color: const Color(0xFFE1B05C).withValues(alpha: 0.18),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.phone_android_rounded,
                        color: Color(0xFFE1B05C), size: 18),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Add your phone number to secure your account',
                        style: TextStyle(
                          color: Color(0xFFE1B05C),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded,
                        color: Color(0xFFE1B05C), size: 18),
                  ],
                ),
              ),
            ),

          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                const ContactsScreen(),
                _CallHistoryTab(
                  records: _callHistory,
                  onDelete: _deleteCallRecord,
                  onCallBack: (r) {
                    final contact = context
                        .read<ContactsProvider>()
                        .getByVirtualId(r.peerVirtualId);
                    if (contact != null) {
                      Navigator.pushNamed(context, '/call/outgoing',
                          arguments: contact);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${r.peerUsername} is not in your contacts')),
                      );
                    }
                  },
                ),
                const GroupsListScreen(),
                const SettingsScreen(),
              ],
            ),
          ),
        ],
      ),      // Column
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        backgroundColor: AppTheme.inputBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          if (i == 1) _markCallsViewed();
          if (i == 2) context.read<GroupsProvider>().loadGroups();
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: _MissedBadge(count: _unseenMissedCount, child: const Icon(Icons.call_outlined)),
            selectedIcon: _MissedBadge(count: _unseenMissedCount, child: const Icon(Icons.call_rounded)),
            label: 'Calls',
          ),
          NavigationDestination(
            icon: _GroupsBadge(child: const Icon(Icons.group_outlined)),
            selectedIcon: _GroupsBadge(child: const Icon(Icons.group_rounded)),
            label: 'Groups',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

// ── Missed calls badge on Calls tab ───────────────────────────

class _MissedBadge extends StatelessWidget {
  final int count;
  final Widget child;
  const _MissedBadge({required this.count, required this.child});

  @override
  Widget build(BuildContext context) {
    if (count == 0) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -4,
          top: -4,
          child: Container(
            constraints: const BoxConstraints(minWidth: 14),
            height: 14,
            padding: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: AppTheme.danger,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Center(
              child: Text(
                count > 9 ? '9+' : '$count',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Call history ──────────────────────────────────────────────

class _GroupsBadge extends StatelessWidget {
  final Widget child;
  const _GroupsBadge({required this.child});

  @override
  Widget build(BuildContext context) {
    final pending = context.watch<GroupsProvider>().totalPendingRequests;
    if (pending == 0) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -4, top: -4,
          child: Container(
            width: 14, height: 14,
            decoration: const BoxDecoration(color: AppTheme.accent, shape: BoxShape.circle),
            child: Center(
              child: Text('$pending',
                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ],
    );
  }
}

class _CallHistoryTab extends StatelessWidget {
  final List<CallRecord> records;
  final void Function(CallRecord r) onCallBack;
  final void Function(CallRecord r) onDelete;

  const _CallHistoryTab({
    required this.records,
    required this.onCallBack,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: AppTheme.surface,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.call_outlined,
                  size: 44, color: AppTheme.muted),
            ),
            const SizedBox(height: 20),
            const Text(
              'No call history',
              style: TextStyle(
                  color: AppTheme.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your recent calls will appear here',
              style: TextStyle(color: AppTheme.muted, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: records.length,
      itemBuilder: (_, i) {
        final r = records[i];
        final isOutgoing = r.direction == CallDirection.outgoing;
        final isMissed = r.status == CallStatus.missed;
        final tile = _buildTile(context, r, isOutgoing, isMissed);
        return Dismissible(
          key: ValueKey(r.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: AppTheme.danger.withValues(alpha: 0.85),
            child: const Icon(Icons.delete_rounded, color: Colors.white),
          ),
          onDismissed: (_) => onDelete(r),
          child: tile,
        );
      },
    );
  }

  Widget _buildTile(BuildContext context, CallRecord r, bool isOutgoing, bool isMissed) {

        Color iconColor;
        IconData iconData;
        if (isMissed) {
          iconColor = AppTheme.danger;
          iconData = Icons.call_missed_rounded;
        } else if (isOutgoing) {
          iconColor = AppTheme.primary;
          iconData = Icons.call_made_rounded;
        } else {
          iconColor = AppTheme.accent;
          iconData = Icons.call_received_rounded;
        }

        final peerAvatarUrl = context.read<ContactsProvider>()
            .getByVirtualId(r.peerVirtualId)?.avatarUrl;

        return Material(
          color: isMissed
              ? AppTheme.danger.withValues(alpha: 0.06)
              : Colors.transparent,
          child: InkWell(
            onTap: () => onCallBack(r),
            splashColor: (isMissed ? AppTheme.danger : AppTheme.primary)
                .withValues(alpha: 0.08),
            child: Container(
              decoration: isMissed
                  ? const BoxDecoration(
                      border: Border(
                        left: BorderSide(color: AppTheme.danger, width: 3),
                      ),
                    )
                  : null,
              padding: EdgeInsets.only(
                left: isMissed ? 13 : 16,
                right: 16,
                top: 10,
                bottom: 10,
              ),
              child: Row(
                children: [
                  // Avatar
                  UserAvatar(
                    username: r.peerUsername,
                    avatarUrl: peerAvatarUrl,
                    radius: 26,
                  ),
                  const SizedBox(width: 14),
                  // Info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.peerUsername,
                          style: TextStyle(
                            color: isMissed
                                ? AppTheme.danger
                                : AppTheme.onSurface,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(iconData, size: 14, color: iconColor),
                            const SizedBox(width: 4),
                            if (isMissed)
                              Text(
                                'Missed · ',
                                style: TextStyle(
                                  color: AppTheme.danger
                                      .withValues(alpha: 0.8),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            Text(
                              DateFormat('MMM d, HH:mm').format(r.startedAt),
                              style: const TextStyle(
                                  color: AppTheme.muted, fontSize: 12),
                            ),
                            if (r.durationSeconds != null) ...[
                              const Text(' · ',
                                  style: TextStyle(
                                      color: AppTheme.muted, fontSize: 12)),
                              Text(
                                _formatDuration(r.durationSeconds!),
                                style: const TextStyle(
                                    color: AppTheme.muted, fontSize: 12),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Call back button
                  GestureDetector(
                    onTap: () => onCallBack(r),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: (isMissed ? AppTheme.danger : AppTheme.accent)
                            .withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.call_rounded,
                          size: 18,
                          color: isMissed ? AppTheme.danger : AppTheme.accent),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
  }

  String _formatDuration(int secs) {
    final m = secs ~/ 60;
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
