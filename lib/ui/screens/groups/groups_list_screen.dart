import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../data/models/group.dart';
import '../../../providers/groups_provider.dart';
import '../../widgets/user_avatar.dart';
import 'create_group_screen.dart';
import 'group_chat_screen.dart';
import 'join_group_screen.dart';

class GroupsListScreen extends StatefulWidget {
  const GroupsListScreen({super.key});

  @override
  State<GroupsListScreen> createState() => _GroupsListScreenState();
}

class _GroupsListScreenState extends State<GroupsListScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GroupsProvider>().loadGroups();
    });
  }

  void _openGroup(Group g) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GroupChatScreen(group: g)),
    ).then((_) => context.read<GroupsProvider>().loadGroups());
  }

  void _showAddSheet() {
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
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
                ).then((_) => context.read<GroupsProvider>().loadGroups());
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded, color: AppTheme.accent),
              title: const Text('Join with code'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const JoinGroupScreen()),
                ).then((_) => context.read<GroupsProvider>().loadGroups());
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<GroupsProvider>();
    final groups = provider.groups;
    final pendingTotal = provider.totalPendingRequests;

    if (provider.isLoading && groups.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: AppTheme.primary));
    }

    if (groups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88, height: 88,
              decoration: BoxDecoration(color: AppTheme.surface, shape: BoxShape.circle),
              child: const Icon(Icons.group_outlined, size: 44, color: AppTheme.muted),
            ),
            const SizedBox(height: 20),
            const Text('No groups yet',
                style: TextStyle(color: AppTheme.onSurface, fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('Create or join a private group',
                style: TextStyle(color: AppTheme.muted, fontSize: 14)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _showAddSheet,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Create or Join'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                minimumSize: Size.zero,
              ),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        ListView.builder(
          itemCount: groups.length,
          itemBuilder: (ctx, i) {
            final g = groups[i];
            final unread = provider.getUnreadCount(g.id);
            final hasPending = g.isAdmin && g.pendingCount > 0;

            return InkWell(
              onTap: () => _openGroup(g),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        UserAvatar(username: g.name, avatarUrl: g.avatarUrl, radius: 26),
                        if (hasPending)
                          Positioned(
                            right: 0, top: 0,
                            child: Container(
                              width: 14, height: 14,
                              decoration: const BoxDecoration(
                                color: AppTheme.accent, shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text('${g.pendingCount}',
                                    style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(g.name,
                                    style: const TextStyle(
                                        color: AppTheme.onSurface, fontSize: 16, fontWeight: FontWeight.w600),
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                              if (unread > 0)
                                Container(
                                  margin: const EdgeInsets.only(left: 6),
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppTheme.primary,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text('$unread',
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              if (g.pinnedMessageId != null)
                                const Padding(
                                  padding: EdgeInsets.only(right: 4),
                                  child: Icon(Icons.push_pin_rounded, size: 12, color: AppTheme.muted),
                                ),
                              Expanded(
                                child: Text(
                                  g.lastMessage ?? '${g.memberCount} members',
                                  style: TextStyle(
                                    color: unread > 0 ? AppTheme.onSurface : AppTheme.muted,
                                    fontSize: 13,
                                    fontWeight: unread > 0 ? FontWeight.w500 : FontWeight.normal,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        // FAB for pending requests badge
        if (pendingTotal > 0)
          Positioned(
            bottom: 16,
            right: 16,
            child: FloatingActionButton.extended(
              onPressed: () => _openPendingRequests(context, provider),
              backgroundColor: AppTheme.accent,
              icon: const Icon(Icons.person_add_rounded, color: Colors.white),
              label: Text('$pendingTotal pending',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
      ],
    );
  }

  void _openPendingRequests(BuildContext context, GroupsProvider provider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ChangeNotifierProvider.value(
        value: provider,
        child: const _PendingRequestsSheet(),
      ),
    );
  }
}

class _PendingRequestsSheet extends StatelessWidget {
  const _PendingRequestsSheet();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<GroupsProvider>();
    final requests = provider.pendingRequests;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      expand: false,
      builder: (_, ctrl) => Column(
        children: [
          Container(
            width: 36, height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 16),
            decoration: BoxDecoration(
              color: AppTheme.muted.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Icon(Icons.person_add_rounded, color: AppTheme.accent, size: 22),
                SizedBox(width: 10),
                Text('Join Requests',
                    style: TextStyle(color: AppTheme.onSurface, fontSize: 18, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: requests.isEmpty
                ? const Center(child: Text('No pending requests', style: TextStyle(color: AppTheme.muted)))
                : ListView.builder(
                    controller: ctrl,
                    itemCount: requests.length,
                    itemBuilder: (_, i) {
                      final r = requests[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        child: Row(
                          children: [
                            UserAvatar(username: r.username, avatarUrl: r.avatarUrl, radius: 22),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(r.username,
                                      style: const TextStyle(
                                          color: AppTheme.onSurface, fontWeight: FontWeight.w600)),
                                  Text(r.groupName,
                                      style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.check_circle_rounded, color: AppTheme.primary),
                              onPressed: () => provider.approveRequest(r.groupId, r.userId),
                            ),
                            IconButton(
                              icon: const Icon(Icons.cancel_rounded, color: AppTheme.danger),
                              onPressed: () => provider.rejectRequest(r.groupId, r.userId),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
