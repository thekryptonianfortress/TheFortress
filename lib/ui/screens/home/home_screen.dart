import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../services/notification_service.dart';
import '../../../core/theme.dart';
import '../../../data/local/database.dart';
import '../../../data/models/call_record.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/call_provider.dart';
import '../../../providers/contacts_provider.dart';
import '../../../services/webrtc_service.dart';
import '../contacts/contacts_screen.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadCallHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<ContactsProvider>().loadContacts();
      if (mounted) _checkPendingNotificationChat();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPendingNotificationChat();
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

  Future<void> _loadCallHistory() async {
    final records = await LocalDatabase.instance.getCallRecords();
    if (mounted) setState(() => _callHistory = records);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final call = context.watch<CallProvider>();

    if (_prevCallState != null &&
        (_prevCallState == CallState.active ||
            _prevCallState == CallState.calling) &&
        call.callState == CallState.idle) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _loadCallHistory());
    }
    _prevCallState = call.callState;

    final initial = auth.username?.isNotEmpty == true
        ? auth.username![0].toUpperCase()
        : 'P';
    final avatarColor = AppTheme.avatarColor(auth.username ?? 'P');

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
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
              _tab == 0 ? 'Chats' : 'Calls',
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
          PopupMenuButton<void>(
            color: AppTheme.surface,
            icon: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: avatarColor,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
            itemBuilder: (_) => <PopupMenuEntry<void>>[
              PopupMenuItem<void>(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      auth.username ?? '',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.onSurface,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          auth.virtualId ?? '',
                          style: const TextStyle(
                              color: AppTheme.muted, fontSize: 12),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () {
                            Clipboard.setData(
                                ClipboardData(text: auth.virtualId ?? ''));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Pager ID copied')),
                            );
                          },
                          child: const Icon(Icons.copy_rounded,
                              size: 13, color: AppTheme.muted),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<void>(
                onTap: () async {
                  await auth.logout();
                  if (context.mounted) {
                    Navigator.pushReplacementNamed(context, '/login');
                  }
                },
                child: const Row(
                  children: [
                    Icon(Icons.logout_rounded,
                        size: 18, color: AppTheme.onSurface),
                    SizedBox(width: 10),
                    Text('Sign out'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          const ContactsScreen(),
          _CallHistoryTab(records: _callHistory),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        backgroundColor: AppTheme.inputBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          if (i == 1) _loadCallHistory();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.call_outlined),
            selectedIcon: Icon(Icons.call_rounded),
            label: 'Calls',
          ),
        ],
      ),
    );
  }
}

// ── Call history ──────────────────────────────────────────────

class _CallHistoryTab extends StatelessWidget {
  final List<CallRecord> records;
  const _CallHistoryTab({required this.records});

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

        final avatarColor = AppTheme.avatarColor(r.peerUsername);
        final initial = r.peerUsername.isNotEmpty
            ? r.peerUsername[0].toUpperCase()
            : '?';

        return InkWell(
          onTap: () {},
          splashColor: AppTheme.primary.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 10),
            child: Row(
              children: [
                // Avatar
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: avatarColor,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      initial,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
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
                          Text(
                            DateFormat('MMM d, HH:mm')
                                .format(r.startedAt),
                            style: const TextStyle(
                                color: AppTheme.muted, fontSize: 12),
                          ),
                          if (r.durationSeconds != null) ...[
                            const Text(' · ',
                                style: TextStyle(
                                    color: AppTheme.muted,
                                    fontSize: 12)),
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
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppTheme.accent.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.call_rounded,
                      size: 18, color: AppTheme.accent),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(int secs) {
    final m = secs ~/ 60;
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
