import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../data/local/secure_storage.dart';
import '../../../data/models/group.dart';
import '../../../providers/groups_provider.dart';
import '../../../services/media_service.dart';
import '../../widgets/user_avatar.dart';
import 'group_themes.dart';

class GroupInfoScreen extends StatefulWidget {
  final Group group;
  final bool showPending;

  const GroupInfoScreen({super.key, required this.group, this.showPending = false});

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  bool _loadingMembers = false;
  String _myId = '';
  late Group _group;

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _init();
  }

  Future<void> _init() async {
    _myId = await SecureStorage.getUserId() ?? '';
    await _refreshMembers();
    if (widget.showPending && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPending());
    }
  }

  final _scrollCtrl = ScrollController();

  void _scrollToPending() {
    _scrollCtrl.animateTo(
      _scrollCtrl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOut,
    );
  }

  Future<void> _refreshMembers() async {
    setState(() => _loadingMembers = true);
    try {
      final provider = context.read<GroupsProvider>();
      final fresh = await provider.fetchGroupDetail(_group.id);
      if (mounted && fresh != null) setState(() => _group = fresh);
    } catch (_) {}
    if (mounted) setState(() => _loadingMembers = false);
  }

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: _group.joinCode));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Join code copied to clipboard')),
      );
    }
  }

  Future<void> _uploadAvatar() async {
    final file = await MediaService.pickFromGallery();
    if (file == null || !mounted) return;
    try {
      final token = await SecureStorage.getToken() ?? '';
      final meta = await MediaService.upload(file, token);
      if (!mounted) return;
      await context.read<GroupsProvider>().updateGroup(_group.id, avatarUrl: meta.url);
      await _refreshMembers();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _editDescription() async {
    final ctrl = TextEditingController(text: _group.description ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Edit Description', style: TextStyle(color: AppTheme.onSurface)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 200,
          maxLines: 3,
          style: const TextStyle(color: AppTheme.onSurface),
          decoration: const InputDecoration(
            hintText: 'Group description (optional)',
            hintStyle: TextStyle(color: AppTheme.muted),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Save', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      try {
        await context.read<GroupsProvider>().updateGroup(_group.id, description: result);
        await _refreshMembers();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _editName() async {
    final ctrl = TextEditingController(text: _group.name);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Edit Group Name', style: TextStyle(color: AppTheme.onSurface)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 50,
          style: const TextStyle(color: AppTheme.onSurface),
          decoration: const InputDecoration(hintText: 'Group name', hintStyle: TextStyle(color: AppTheme.muted)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Save', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && mounted) {
      try {
        await context.read<GroupsProvider>().updateGroup(_group.id, name: result);
        await _refreshMembers();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _memberOptions(GroupMember m) async {
    if (m.userId == _myId) return;
    final isAdmin = _group.isAdmin;
    if (!isAdmin) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              decoration: BoxDecoration(color: AppTheme.muted.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  UserAvatar(username: m.username, avatarUrl: m.avatarUrl, radius: 20),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.username, style: const TextStyle(color: AppTheme.onSurface, fontWeight: FontWeight.w700)),
                      Text(m.isAdmin ? 'Admin' : 'Member',
                          style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF2A3A4A)),
            if (!m.isAdmin)
              ListTile(
                leading: const Icon(Icons.admin_panel_settings_rounded, color: AppTheme.accent),
                title: const Text('Make admin'),
                onTap: () async {
                  Navigator.pop(context);
                  await context.read<GroupsProvider>().promoteToAdmin(_group.id, m.userId);
                  await _refreshMembers();
                },
              ),
            ListTile(
              leading: const Icon(Icons.person_remove_rounded, color: AppTheme.danger),
              title: const Text('Remove from group', style: TextStyle(color: AppTheme.danger)),
              onTap: () async {
                Navigator.pop(context);
                await context.read<GroupsProvider>().removeMember(_group.id, m.userId);
                await _refreshMembers();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _clearChat() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Clear Chat', style: TextStyle(color: AppTheme.onSurface)),
        content: const Text('This will clear all messages for everyone in the group. This cannot be undone.',
            style: TextStyle(color: AppTheme.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear', style: TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      try {
        await context.read<GroupsProvider>().clearMessages(_group.id);
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _pickTheme() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => GroupThemePickerSheet(
        currentThemeId: _group.themeId,
        onSelect: (themeId) async {
          try {
            await context.read<GroupsProvider>().updateGroup(_group.id, themeId: themeId);
            await _refreshMembers();
          } catch (e) {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
          }
        },
      ),
    );
  }

  Future<void> _leaveGroup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Leave Group', style: TextStyle(color: AppTheme.onSurface)),
        content: Text('Leave "${_group.name}"?', style: const TextStyle(color: AppTheme.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave', style: TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await context.read<GroupsProvider>().leaveGroup(_group.id);
      if (mounted) Navigator.popUntil(context, ModalRoute.withName('/home'));
    }
  }

  Future<void> _deleteGroup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Delete Group', style: TextStyle(color: AppTheme.danger)),
        content: Text('Delete "${_group.name}" permanently? This cannot be undone.',
            style: const TextStyle(color: AppTheme.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await context.read<GroupsProvider>().deleteGroup(_group.id);
      if (mounted) Navigator.popUntil(context, ModalRoute.withName('/home'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<GroupsProvider>();
    final freshGroup = provider.groupById(_group.id);
    if (freshGroup != null) _group = freshGroup;

    final activeMembers = _group.members.where((m) => m.isActive).toList();
    final pendingMembers = _group.members.where((m) => m.isPending).toList();
    final isAdmin = _group.isAdmin;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: CustomScrollView(
        controller: _scrollCtrl,
        slivers: [
          SliverAppBar(
            expandedHeight: 220,
            pinned: true,
            backgroundColor: AppTheme.inputBg,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.onSurface),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (_group.avatarUrl != null)
                    CachedNetworkImage(
                        imageUrl: MediaService.fullUrl(_group.avatarUrl!),
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(color: AppTheme.surface))
                  else
                    Container(
                      color: AppTheme.surface,
                      child: Center(
                        child: Text(_group.name.isNotEmpty ? _group.name[0].toUpperCase() : 'G',
                            style: const TextStyle(color: AppTheme.muted, fontSize: 72, fontWeight: FontWeight.w300)),
                      ),
                    ),
                  if (isAdmin)
                    Positioned(
                      right: 16, bottom: 16,
                      child: GestureDetector(
                        onTap: _uploadAvatar,
                        child: Container(
                          width: 40, height: 40,
                          decoration: const BoxDecoration(color: AppTheme.primary, shape: BoxShape.circle),
                          child: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 20),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name + edit
                  Row(
                    children: [
                      Expanded(
                        child: Text(_group.name,
                            style: const TextStyle(color: AppTheme.onSurface, fontSize: 22, fontWeight: FontWeight.w700)),
                      ),
                      if (isAdmin)
                        IconButton(
                          icon: const Icon(Icons.edit_rounded, color: AppTheme.muted, size: 20),
                          onPressed: _editName,
                        ),
                    ],
                  ),
                  if (_group.description != null && _group.description!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(_group.description!,
                              style: const TextStyle(color: AppTheme.muted, fontSize: 14)),
                        ),
                        if (isAdmin)
                          IconButton(
                            icon: const Icon(Icons.edit_rounded, color: AppTheme.muted, size: 18),
                            onPressed: _editDescription,
                          ),
                      ],
                    ),
                  ] else if (isAdmin) ...[
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: _editDescription,
                      child: const Text('Add description',
                          style: TextStyle(color: AppTheme.primary, fontSize: 14)),
                    ),
                  ],
                  const SizedBox(height: 20),

                  // Join code card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppTheme.primary.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42, height: 42,
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.15), shape: BoxShape.circle),
                          child: const Icon(Icons.link_rounded, color: AppTheme.primary, size: 22),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Invite Code', style: TextStyle(color: AppTheme.muted, fontSize: 12)),
                              Text(_group.joinCode,
                                  style: const TextStyle(
                                      color: AppTheme.onSurface, fontSize: 20,
                                      fontWeight: FontWeight.w700, letterSpacing: 4)),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy_rounded, color: AppTheme.primary),
                          onPressed: _copyCode,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),

          // Active members
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text('${activeMembers.length} Members',
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) {
                final m = activeMembers[i];
                final isMe = m.userId == _myId;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                  leading: UserAvatar(username: m.username, avatarUrl: m.avatarUrl, radius: 22),
                  title: Row(
                    children: [
                      Text(isMe ? 'You' : m.username,
                          style: const TextStyle(color: AppTheme.onSurface, fontWeight: FontWeight.w600)),
                      if (m.isAdmin) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text('admin',
                              style: TextStyle(color: AppTheme.accent, fontSize: 10, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(m.virtualId, style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                  onLongPress: isAdmin && !isMe ? () => _memberOptions(m) : null,
                );
              },
              childCount: activeMembers.length,
            ),
          ),

          // Pending join requests (admin only)
          if (isAdmin && pendingMembers.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
                child: Row(
                  children: [
                    const Icon(Icons.pending_rounded, color: AppTheme.accent, size: 16),
                    const SizedBox(width: 6),
                    Text('${pendingMembers.length} Pending Requests',
                        style: const TextStyle(color: AppTheme.accent, fontSize: 12, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final m = pendingMembers[i];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                    leading: UserAvatar(username: m.username, avatarUrl: m.avatarUrl, radius: 22),
                    title: Text(m.username, style: const TextStyle(color: AppTheme.onSurface, fontWeight: FontWeight.w600)),
                    subtitle: Text(m.virtualId, style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.check_circle_rounded, color: AppTheme.primary),
                          onPressed: () async {
                            await context.read<GroupsProvider>().approveRequest(_group.id, m.userId);
                            await _refreshMembers();
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.cancel_rounded, color: AppTheme.danger),
                          onPressed: () async {
                            await context.read<GroupsProvider>().rejectRequest(_group.id, m.userId);
                            await _refreshMembers();
                          },
                        ),
                      ],
                    ),
                  );
                },
                childCount: pendingMembers.length,
              ),
            ),
          ],

          // Management (admin only)
          if (isAdmin) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
                child: const Text('Management',
                    style: TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: AppTheme.surface,
                  leading: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.danger.withValues(alpha: 0.12), shape: BoxShape.circle),
                    child: const Icon(Icons.cleaning_services_rounded, color: AppTheme.danger, size: 20),
                  ),
                  title: const Text('Clear Chat',
                      style: TextStyle(color: AppTheme.onSurface, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Delete all messages for everyone',
                      style: TextStyle(color: AppTheme.muted, fontSize: 12)),
                  onTap: _clearChat,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
          ],

          // Appearance (admin only)
          if (isAdmin) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
                child: Text('Appearance',
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: AppTheme.surface,
                  leading: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: groupThemeById(_group.themeId).gradientColors,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(groupThemeById(_group.themeId).emoji,
                          style: const TextStyle(fontSize: 16)),
                    ),
                  ),
                  title: const Text('Chat Theme',
                      style: TextStyle(color: AppTheme.onSurface, fontWeight: FontWeight.w600)),
                  subtitle: Text(groupThemeById(_group.themeId).name,
                      style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
                  onTap: _pickTheme,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
          ],

          // Leave / Delete
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
              child: Column(
                children: [
                  if (!_group.isAdmin || _group.members.where((m) => m.isAdmin && m.userId != _myId).isNotEmpty)
                    ListTile(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      tileColor: AppTheme.surface,
                      leading: const Icon(Icons.exit_to_app_rounded, color: AppTheme.danger),
                      title: const Text('Leave Group', style: TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w600)),
                      onTap: _leaveGroup,
                    ),
                  if (isAdmin && _group.createdBy == _myId) ...[
                    const SizedBox(height: 8),
                    ListTile(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      tileColor: AppTheme.danger.withValues(alpha: 0.08),
                      leading: const Icon(Icons.delete_forever_rounded, color: AppTheme.danger),
                      title: const Text('Delete Group', style: TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w600)),
                      onTap: _deleteGroup,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

