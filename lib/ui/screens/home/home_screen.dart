import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
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

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  List<CallRecord> _callHistory = [];

  CallState? _prevCallState;

  @override
  void initState() {
    super.initState();
    _loadCallHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ContactsProvider>().loadContacts();
    });
  }

  Future<void> _loadCallHistory() async {
    final records = await LocalDatabase.instance.getCallRecords();
    if (mounted) setState(() => _callHistory = records);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final call = context.watch<CallProvider>();

    // Reload call history when a call finishes
    if (_prevCallState != null &&
        (_prevCallState == CallState.active || _prevCallState == CallState.calling) &&
        call.callState == CallState.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadCallHistory());
    }
    _prevCallState = call.callState;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.wifi_calling_3_rounded, color: AppTheme.primary, size: 22),
            const SizedBox(width: 8),
            const Text('Pager', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          PopupMenuButton<void>(
            icon: CircleAvatar(
              radius: 16,
              backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
              child: Text(
                auth.username?.isNotEmpty == true ? auth.username![0].toUpperCase() : 'P',
                style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
              ),
            ),
            itemBuilder: (_) => <PopupMenuEntry<void>>[
              PopupMenuItem<void>(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(auth.username ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
                    Row(
                      children: [
                        Text(auth.virtualId ?? '', style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: auth.virtualId ?? ''));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Pager ID copied')),
                            );
                          },
                          child: const Icon(Icons.copy, size: 14, color: AppTheme.muted),
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
                  if (context.mounted) Navigator.pushReplacementNamed(context, '/login');
                },
                child: const Row(
                  children: [
                    Icon(Icons.logout, size: 18),
                    SizedBox(width: 8),
                    Text('Sign out'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
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
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          if (i == 1) _loadCallHistory();
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'Contacts'),
          NavigationDestination(icon: Icon(Icons.history_outlined), selectedIcon: Icon(Icons.history), label: 'Calls'),
        ],
      ),
    );
  }
}

class _CallHistoryTab extends StatelessWidget {
  final List<CallRecord> records;
  const _CallHistoryTab({required this.records});

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.call_outlined, size: 64, color: Colors.grey),
            SizedBox(height: 12),
            Text('No call history', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: records.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r = records[i];
        final isOutgoing = r.direction == CallDirection.outgoing;
        Color iconColor;
        IconData iconData;
        if (r.status == CallStatus.missed) {
          iconColor = AppTheme.danger;
          iconData = Icons.call_missed;
        } else if (isOutgoing) {
          iconColor = AppTheme.primary;
          iconData = Icons.call_made;
        } else {
          iconColor = AppTheme.accent;
          iconData = Icons.call_received;
        }
        return ListTile(
          leading: Icon(iconData, color: iconColor),
          title: Text(r.peerUsername),
          subtitle: Text(
            '${r.peerVirtualId}  •  ${DateFormat('MMM d, HH:mm').format(r.startedAt)}',
            style: const TextStyle(fontSize: 12, color: AppTheme.muted),
          ),
          trailing: r.durationSeconds != null
              ? Text(
                  '${r.durationSeconds! ~/ 60}:${(r.durationSeconds! % 60).toString().padLeft(2, '0')}',
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                )
              : null,
        );
      },
    );
  }
}
