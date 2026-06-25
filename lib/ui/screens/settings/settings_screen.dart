import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/backup_provider.dart';
import 'backup_screen.dart';
import 'profile_edit_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final username = auth.username ?? '';
    final virtualId = auth.virtualId ?? '';
    final avatarUrl = auth.avatarUrl;
    final initial = username.isNotEmpty ? username[0].toUpperCase() : 'P';
    final avatarColor = AppTheme.avatarColor(username.isNotEmpty ? username : 'P');

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: CustomScrollView(
        slivers: [
          // ── Telegram-style collapsing header ──────────────────
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: AppTheme.inputBg,
            elevation: 0,
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.pin,
              background: _ProfileHeader(
                username: username,
                virtualId: virtualId,
                avatarUrl: avatarUrl,
                initial: initial,
                avatarColor: avatarColor,
                onEdit: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const ProfileEditScreen()),
                ),
              ),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.edit_rounded,
                    color: AppTheme.primary, size: 20),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const ProfileEditScreen()),
                ),
                tooltip: 'Edit profile',
              ),
            ],
          ),

          // ── Body ──────────────────────────────────────────────
          SliverList(
            delegate: SliverChildListDelegate([
              const SizedBox(height: 8),

              // Account
              _SectionHeader(title: 'Account'),
              _SettingsTile(
                icon: Icons.person_rounded,
                iconColor: AppTheme.primary,
                title: 'Edit Profile',
                subtitle: 'Change name and photo',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const ProfileEditScreen()),
                ),
              ),
              _SettingsTile(
                icon: Icons.tag_rounded,
                iconColor: AppTheme.primary,
                title: 'Pager ID',
                subtitle: virtualId,
                trailing: IconButton(
                  icon: const Icon(Icons.copy_rounded,
                      size: 16, color: AppTheme.muted),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: virtualId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Pager ID copied')),
                    );
                  },
                ),
              ),
              _SettingsTile(
                icon: Icons.lock_rounded,
                iconColor: AppTheme.primary,
                title: 'Change Password',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          const ProfileEditScreen(showPasswordSection: true)),
                ),
              ),

              const SizedBox(height: 8),

              // Privacy & Security
              _SectionHeader(title: 'Privacy & Security'),
              _SettingsTile(
                icon: Icons.shield_rounded,
                iconColor: const Color(0xFF4DD5A6),
                title: 'End-to-End Encryption',
                subtitle: 'All messages are encrypted',
                trailing: const Icon(Icons.check_circle_rounded,
                    size: 18, color: Color(0xFF4DD5A6)),
              ),
              _SettingsTile(
                icon: Icons.key_rounded,
                iconColor: const Color(0xFF4DD5A6),
                title: 'Encryption Keys',
                subtitle: 'RSA-2048 + AES-256 key pair',
              ),
              _SettingsTile(
                icon: Icons.visibility_off_rounded,
                iconColor: const Color(0xFF4DD5A6),
                title: 'Last Seen',
                subtitle: 'Visible to contacts only',
              ),

              const SizedBox(height: 8),

              // Notifications
              _SectionHeader(title: 'Notifications'),
              _SwitchTile(
                icon: Icons.notifications_rounded,
                iconColor: const Color(0xFFE1B05C),
                title: 'Message Notifications',
                subtitle: 'Show alerts for new messages',
                value: true,
                onChanged: (_) {},
              ),
              _SwitchTile(
                icon: Icons.call_rounded,
                iconColor: const Color(0xFFE1B05C),
                title: 'Call Notifications',
                subtitle: 'Show alerts for incoming calls',
                value: true,
                onChanged: (_) {},
              ),

              const SizedBox(height: 8),

              // Backup & Restore
              _SectionHeader(title: 'Backup & Restore'),
              _BackupTile(),

              const SizedBox(height: 8),

              // Data & Storage
              _SectionHeader(title: 'Data & Storage'),
              _SettingsTile(
                icon: Icons.photo_library_rounded,
                iconColor: const Color(0xFF6FB9F0),
                title: 'Media Auto-Download',
                subtitle: 'Images auto-download on Wi-Fi',
              ),
              _SettingsTile(
                icon: Icons.delete_sweep_rounded,
                iconColor: const Color(0xFF6FB9F0),
                title: 'Clear Cache',
                subtitle: 'Free up device storage',
                onTap: () => _confirmClearCache(context),
              ),

              const SizedBox(height: 8),

              // The Fortress Features
              _SectionHeader(title: 'The Fortress Features'),
              _SettingsTile(
                icon: Icons.lock_person_rounded,
                iconColor: const Color(0xFF9371E8),
                title: 'Zero-Knowledge Architecture',
                subtitle:
                    'Server never sees your message content',
                trailing: const Icon(Icons.check_circle_rounded,
                    size: 18, color: Color(0xFF9371E8)),
              ),
              _SettingsTile(
                icon: Icons.router_rounded,
                iconColor: const Color(0xFF9371E8),
                title: 'LAN Mesh Fallback',
                subtitle:
                    'Works on local network without internet',
                trailing: const Icon(Icons.check_circle_rounded,
                    size: 18, color: Color(0xFF9371E8)),
              ),
              _SettingsTile(
                icon: Icons.fingerprint_rounded,
                iconColor: const Color(0xFF9371E8),
                title: 'Identity Verification',
                subtitle: 'Cryptographic key-based identity',
                trailing: const Icon(Icons.check_circle_rounded,
                    size: 18, color: Color(0xFF9371E8)),
              ),
              _SettingsTile(
                icon: Icons.phone_disabled_rounded,
                iconColor: const Color(0xFF9371E8),
                title: 'No SIM Required',
                subtitle:
                    'Full calling and messaging without a carrier',
                trailing: const Icon(Icons.check_circle_rounded,
                    size: 18, color: Color(0xFF9371E8)),
              ),

              const SizedBox(height: 8),

              // Sign out
              _SettingsTile(
                icon: Icons.logout_rounded,
                iconColor: AppTheme.danger,
                title: 'Sign Out',
                titleColor: AppTheme.danger,
                onTap: () => _confirmSignOut(context, auth),
              ),

              const SizedBox(height: 32),

              // Version footer
              Center(
                child: Text(
                  'Pager v1.0.0',
                  style: const TextStyle(
                      color: AppTheme.muted, fontSize: 12),
                ),
              ),
              const SizedBox(height: 24),
            ]),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Cache'),
        content: const Text(
            'This will delete locally cached media files. Downloaded files will need to be re-downloaded.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Clear', style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      try {
        final tmpDir = await getTemporaryDirectory();
        final files = tmpDir.listSync();
        for (final f in files) {
          try {
            f.deleteSync(recursive: true);
          } catch (_) {}
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cache cleared')),
          );
        }
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to clear cache')),
          );
        }
      }
    }
  }

  Future<void> _confirmSignOut(
      BuildContext context, AuthProvider auth) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Sign Out',
                style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await auth.logout();
      if (context.mounted) {
        Navigator.pushReplacementNamed(context, '/login');
      }
    }
  }
}

// ── Backup tile ────────────────────────────────────────────────

class _BackupTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final backup = context.watch<BackupProvider>();
    String subtitle;
    if (backup.cycle == BackupCycle.off) {
      subtitle = 'Off';
    } else if (backup.lastBackupTime != null) {
      final local = backup.lastBackupTime!.toLocal();
      final now = DateTime.now();
      if (DateUtils.isSameDay(local, now)) {
        subtitle = 'Last backup today at ${DateFormat('HH:mm').format(local)}';
      } else {
        subtitle = 'Last backup ${DateFormat('MMM d').format(local)}';
      }
    } else {
      subtitle = '${backup.cycle.label} · Never backed up';
    }

    return _SettingsTile(
      icon: Icons.backup_rounded,
      iconColor: const Color(0xFF4DD5A6),
      title: 'Backup & Restore',
      subtitle: subtitle,
      trailing: backup.isRunning
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFF4DD5A6)))
          : null,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const BackupScreen()),
      ),
    );
  }
}

// ── Profile header widget ──────────────────────────────────────

class _ProfileHeader extends StatelessWidget {
  final String username;
  final String virtualId;
  final String? avatarUrl;
  final String initial;
  final Color avatarColor;
  final VoidCallback onEdit;

  const _ProfileHeader({
    required this.username,
    required this.virtualId,
    required this.avatarUrl,
    required this.initial,
    required this.avatarColor,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.inputBg,
      padding: const EdgeInsets.fromLTRB(20, 72, 20, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Avatar
          GestureDetector(
            onTap: onEdit,
            child: Stack(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: avatarColor,
                    shape: BoxShape.circle,
                  ),
                  child: avatarUrl != null && avatarUrl!.isNotEmpty
                      ? ClipOval(
                          child: CachedNetworkImage(
                            imageUrl: avatarUrl!,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Center(
                              child: Text(
                                initial,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 32,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            errorWidget: (_, __, ___) => Center(
                              child: Text(
                                initial,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 32,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        )
                      : Center(
                          child: Text(
                            initial,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 32,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: AppTheme.primary,
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: AppTheme.inputBg, width: 2),
                    ),
                    child: const Icon(Icons.edit_rounded,
                        size: 12, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          // Name + ID
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  username,
                  style: const TextStyle(
                    color: AppTheme.onSurface,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      virtualId,
                      style: const TextStyle(
                          color: AppTheme.primary, fontSize: 14),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () {
                        Clipboard.setData(
                            ClipboardData(text: virtualId));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Pager ID copied')),
                        );
                      },
                      child: const Icon(Icons.copy_rounded,
                          size: 14, color: AppTheme.muted),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Reusable components ────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppTheme.primary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.titleColor,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: AppTheme.primary.withValues(alpha: 0.06),
      child: Container(
        color: AppTheme.surface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Icon container
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            // Text
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: titleColor ?? AppTheme.onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                          color: AppTheme.muted, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            trailing ?? (onTap != null
                ? const Icon(Icons.chevron_right_rounded,
                    color: AppTheme.muted, size: 20)
                : const SizedBox.shrink()),
          ],
        ),
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppTheme.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                        color: AppTheme.muted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppTheme.primary,
            activeTrackColor: AppTheme.primary.withValues(alpha: 0.5),
          ),
        ],
      ),
    );
  }
}
