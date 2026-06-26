import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../providers/auto_download_provider.dart';

class DataUsageScreen extends StatefulWidget {
  const DataUsageScreen({super.key});
  @override
  State<DataUsageScreen> createState() => _DataUsageScreenState();
}

class _DataUsageScreenState extends State<DataUsageScreen> {
  int _cacheBytes = 0;
  bool _loadingCache = false;
  bool _clearingCache = false;

  @override
  void initState() {
    super.initState();
    _computeCache();
  }

  Future<void> _computeCache() async {
    setState(() => _loadingCache = true);
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/pager_media');
      int total = 0;
      if (dir.existsSync()) {
        await for (final e in dir.list(recursive: true)) {
          if (e is File) total += await e.length();
        }
      }
      if (mounted) setState(() { _cacheBytes = total; _loadingCache = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingCache = false);
    }
  }

  Future<void> _clearCache() async {
    setState(() => _clearingCache = true);
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/pager_media');
      if (dir.existsSync()) await dir.delete(recursive: true);
      if (mounted) setState(() { _cacheBytes = 0; _clearingCache = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cache cleared')),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AutoDownloadProvider>();

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.inputBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.onSurface),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Storage & Data',
            style: TextStyle(color: AppTheme.onSurface, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ── Media Auto-Download ───────────────────────────
          _SectionHeader(title: 'Media Auto-Download'),
          _AutoDownloadGroup(
            icon: Icons.wifi_rounded,
            iconColor: AppTheme.primary,
            label: 'When on Wi-Fi',
            subtitle: _describeTypes(provider.wifiTypes),
            types: provider.wifiTypes,
            onChanged: (types) => provider.setTypes('wifi', types),
          ),
          const SizedBox(height: 8),
          _AutoDownloadGroup(
            icon: Icons.signal_cellular_alt_rounded,
            iconColor: AppTheme.accent,
            label: 'When using mobile data',
            subtitle: _describeTypes(provider.mobileTypes),
            types: provider.mobileTypes,
            onChanged: (types) => provider.setTypes('mobile', types),
          ),
          const SizedBox(height: 8),
          _AutoDownloadGroup(
            icon: Icons.public_rounded,
            iconColor: AppTheme.muted,
            label: 'When roaming',
            subtitle: _describeTypes(provider.roamingTypes),
            types: provider.roamingTypes,
            onChanged: (types) => provider.setTypes('roaming', types),
          ),

          // ── Network Usage ─────────────────────────────────
          _SectionHeader(title: 'Network Usage'),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: AppTheme.accent.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.bar_chart_rounded,
                          color: AppTheme.accent, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Media downloaded',
                              style: TextStyle(color: AppTheme.muted, fontSize: 12)),
                          const SizedBox(height: 2),
                          Text(_fmtBytes(provider.bytesUsed),
                              style: const TextStyle(
                                  color: AppTheme.onSurface,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Since ${DateFormat('MMM d, y').format(provider.usageResetDate)}',
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          backgroundColor: AppTheme.surface,
                          title: const Text('Reset Statistics',
                              style: TextStyle(color: AppTheme.onSurface)),
                          content: const Text(
                              'This resets the media download counter to zero.',
                              style: TextStyle(color: AppTheme.muted)),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel')),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Reset',
                                  style: TextStyle(color: AppTheme.danger)),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true && mounted) {
                        await context.read<AutoDownloadProvider>().resetDataUsage();
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                      side: const BorderSide(color: AppTheme.danger),
                    ),
                    child: const Text('Reset statistics'),
                  ),
                ),
              ],
            ),
          ),

          // ── Cache ─────────────────────────────────────────
          _SectionHeader(title: 'Storage'),
          _Card(
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.folder_rounded,
                          color: AppTheme.primary, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Media cache',
                              style: TextStyle(
                                  color: AppTheme.onSurface,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(
                            _loadingCache ? 'Calculating…' : _fmtBytes(_cacheBytes),
                            style: const TextStyle(
                                color: AppTheme.muted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _clearingCache ? null : _clearCache,
                      child: _clearingCache
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppTheme.danger))
                          : const Text('Clear',
                              style: TextStyle(color: AppTheme.danger)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Voice notes, videos, and files are cached here for offline playback.',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _describeTypes(Set<MediaType> types) {
    if (types.isEmpty) return 'No media';
    if (types.length == MediaType.values.length) return 'All media';
    return types.map((t) => t.label).join(', ');
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

// ── Auto-download group ────────────────────────────────────────

class _AutoDownloadGroup extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String subtitle;
  final Set<MediaType> types;
  final void Function(Set<MediaType>) onChanged;

  const _AutoDownloadGroup({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.subtitle,
    required this.types,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            // Header row
            ListTile(
              leading: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              title: Text(label,
                  style: const TextStyle(
                      color: AppTheme.onSurface, fontWeight: FontWeight.w600)),
              subtitle: Text(subtitle,
                  style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
              contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            ),
            const Divider(color: Color(0xFF2A3A4A), height: 1),
            // Checkboxes
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: MediaType.values.map((t) {
                  final checked = types.contains(t);
                  return Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        final updated = Set<MediaType>.from(types);
                        if (checked) {
                          updated.remove(t);
                        } else {
                          updated.add(t);
                        }
                        onChanged(updated);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _iconFor(t),
                              size: 20,
                              color: checked ? iconColor : AppTheme.muted,
                            ),
                            const SizedBox(height: 4),
                            Text(t.label,
                                style: TextStyle(
                                  color: checked ? AppTheme.onSurface : AppTheme.muted,
                                  fontSize: 10,
                                  fontWeight: checked ? FontWeight.w600 : FontWeight.normal,
                                )),
                            const SizedBox(height: 4),
                            Container(
                              width: 18, height: 18,
                              decoration: BoxDecoration(
                                color: checked
                                    ? iconColor
                                    : AppTheme.muted.withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: checked ? iconColor : AppTheme.muted,
                                  width: 1.5,
                                ),
                              ),
                              child: checked
                                  ? const Icon(Icons.check_rounded,
                                      size: 12, color: Colors.white)
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(MediaType t) => switch (t) {
        MediaType.photos => Icons.photo_library_rounded,
        MediaType.audio => Icons.headphones_rounded,
        MediaType.videos => Icons.videocam_rounded,
        MediaType.files => Icons.insert_drive_file_rounded,
      };
}

// ── Helpers ────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(title.toUpperCase(),
            style: const TextStyle(
                color: AppTheme.muted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8)),
      );
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
  @override
  Widget build(BuildContext context) => Padding(
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
