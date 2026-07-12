import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../providers/backup_provider.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  Future<void> _backupNow() async {
    final provider = context.read<BackupProvider>();
    final file = await provider.runBackup();
    if (!mounted) return;
    if (file != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup created successfully')),
      );
    } else if (provider.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup failed: ${provider.error}')),
      );
    }
  }

  Future<void> _restoreFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Restore Backup',
            style: TextStyle(color: AppTheme.onSurface)),
        content: const Text(
          'This will merge the backup data into your current chats. '
          'Existing messages will not be deleted.',
          style: TextStyle(color: AppTheme.muted),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore',
                style: TextStyle(
                    color: AppTheme.primary, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    try {
      await context.read<BackupProvider>().restore(path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup restored successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<BackupProvider>();

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.inputBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.onSurface),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Backup & Restore',
            style: TextStyle(color: AppTheme.onSurface, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ── Status card ───────────────────────────────────────
          _SectionHeader(title: 'Status'),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.cloud_done_rounded,
                          color: AppTheme.primary, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Last Backup',
                              style: TextStyle(
                                  color: AppTheme.muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500)),
                          const SizedBox(height: 2),
                          Text(
                            provider.lastBackupTime != null
                                ? _formatDateTime(provider.lastBackupTime!)
                                : 'Never',
                            style: const TextStyle(
                                color: AppTheme.onSurface,
                                fontSize: 15,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: provider.isRunning ? null : _backupNow,
                    icon: provider.isRunning
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.backup_rounded, size: 18),
                    label: Text(provider.isRunning ? 'Backing up…' : 'Back Up Now'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Schedule ──────────────────────────────────────────
          _SectionHeader(title: 'Backup Schedule'),
          _Card(
            child: Column(
              children: BackupCycle.values.map((c) {
                return RadioListTile<BackupCycle>(
                  value: c,
                  groupValue: provider.cycle,
                  onChanged: (v) => provider.setCycle(v!),
                  title: Text(c.label,
                      style: const TextStyle(color: AppTheme.onSurface)),
                  activeColor: AppTheme.primary,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                );
              }).toList(),
            ),
          ),

          // ── What to include ───────────────────────────────────
          _SectionHeader(title: 'Include in Backup'),
          _Card(
            child: Column(
              children: [
                SwitchListTile(
                  value: provider.includeMessages,
                  onChanged: provider.setIncludeMessages,
                  title: const Text('Messages',
                      style: TextStyle(color: AppTheme.onSurface)),
                  subtitle: const Text('DMs and group chats',
                      style: TextStyle(color: AppTheme.muted, fontSize: 12)),
                  secondary: const Icon(Icons.chat_bubble_outline_rounded,
                      color: AppTheme.primary),
                  activeThumbColor: AppTheme.primary,
                  contentPadding: EdgeInsets.zero,
                ),
                const Divider(color: Color(0xFF2A3A4A), height: 1),
                SwitchListTile(
                  value: provider.includeMedia,
                  onChanged: provider.setIncludeMedia,
                  title: const Text('Media references',
                      style: TextStyle(color: AppTheme.onSurface)),
                  subtitle: const Text(
                      'Attachment URLs included (files re-download when online)',
                      style: TextStyle(color: AppTheme.muted, fontSize: 12)),
                  secondary: const Icon(Icons.photo_library_rounded,
                      color: AppTheme.accent),
                  activeThumbColor: AppTheme.primary,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),

          // ── Restore ───────────────────────────────────────────
          _SectionHeader(title: 'Restore'),
          _Card(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: AppTheme.accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.restore_rounded,
                    color: AppTheme.accent, size: 22),
              ),
              title: const Text('Restore from file',
                  style: TextStyle(color: AppTheme.onSurface, fontWeight: FontWeight.w600)),
              subtitle: const Text('Select a .zip backup file from your device',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
              onTap: provider.isRunning ? null : _restoreFromFile,
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    if (DateUtils.isSameDay(local, now)) {
      return 'Today at ${DateFormat('HH:mm').format(local)}';
    } else if (DateUtils.isSameDay(local, now.subtract(const Duration(days: 1)))) {
      return 'Yesterday at ${DateFormat('HH:mm').format(local)}';
    }
    return DateFormat('MMM d, y · HH:mm').format(local);
  }
}

// ── Helpers ───────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Text(title.toUpperCase(),
          style: const TextStyle(
              color: AppTheme.muted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8)),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: child,
      ),
    );
  }
}
