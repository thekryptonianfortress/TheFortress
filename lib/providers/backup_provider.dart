import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/local/secure_storage.dart';
import '../services/backup_service.dart';

enum BackupCycle { off, manual, daily, weekly, monthly }

extension BackupCycleLabel on BackupCycle {
  String get label => switch (this) {
        BackupCycle.off => 'Off',
        BackupCycle.manual => 'Manual only',
        BackupCycle.daily => 'Daily',
        BackupCycle.weekly => 'Weekly',
        BackupCycle.monthly => 'Monthly',
      };
}

class BackupProvider extends ChangeNotifier {
  static const _keyCycle = 'backup_cycle';
  static const _keyIncludeMessages = 'backup_include_messages';
  static const _keyIncludeMedia = 'backup_include_media';
  static const _keyLastTime = 'backup_last_time';
  static const _keyLastPath = 'backup_last_path';

  final _service = BackupService();

  BackupCycle _cycle = BackupCycle.off;
  bool _includeMessages = true;
  bool _includeMedia = false;
  DateTime? _lastBackupTime;
  String? _lastBackupPath;
  bool _isRunning = false;
  String? _error;

  BackupCycle get cycle => _cycle;
  bool get includeMessages => _includeMessages;
  bool get includeMedia => _includeMedia;
  DateTime? get lastBackupTime => _lastBackupTime;
  String? get lastBackupPath => _lastBackupPath;
  bool get isRunning => _isRunning;
  String? get error => _error;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _cycle = BackupCycle.values.firstWhere(
      (c) => c.name == (prefs.getString(_keyCycle) ?? 'off'),
      orElse: () => BackupCycle.off,
    );
    _includeMessages = prefs.getBool(_keyIncludeMessages) ?? true;
    _includeMedia = prefs.getBool(_keyIncludeMedia) ?? false;
    final ts = prefs.getString(_keyLastTime);
    _lastBackupTime = ts != null ? DateTime.tryParse(ts) : null;
    _lastBackupPath = prefs.getString(_keyLastPath);
    notifyListeners();
  }

  Future<void> setCycle(BackupCycle c) async {
    _cycle = c;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCycle, c.name);
    notifyListeners();
  }

  Future<void> setIncludeMessages(bool v) async {
    _includeMessages = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyIncludeMessages, v);
    notifyListeners();
  }

  Future<void> setIncludeMedia(bool v) async {
    _includeMedia = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyIncludeMedia, v);
    notifyListeners();
  }

  /// Called on app start. Runs a backup automatically if the schedule is due.
  Future<void> checkScheduled() async {
    if (_cycle == BackupCycle.off || _cycle == BackupCycle.manual) return;
    if (_isRunning) return;
    if (_lastBackupTime != null) {
      final diff = DateTime.now().difference(_lastBackupTime!);
      final due = switch (_cycle) {
        BackupCycle.daily => diff.inHours >= 24,
        BackupCycle.weekly => diff.inDays >= 7,
        BackupCycle.monthly => diff.inDays >= 30,
        _ => false,
      };
      if (!due) return;
    }
    await runBackup();
  }

  /// Runs a full backup. Returns the resulting [File] or null on failure.
  Future<File?> runBackup() async {
    _isRunning = true;
    _error = null;
    notifyListeners();
    try {
      final userId = await SecureStorage.getUserId() ?? '';
      final username = await SecureStorage.getUsername() ?? '';
      final virtualId = await SecureStorage.getVirtualId() ?? '';
      if (userId.isEmpty) throw Exception('Not logged in');

      final file = await _service.createBackup(
        userId: userId,
        username: username,
        virtualId: virtualId,
        includeMessages: _includeMessages,
        includeMedia: _includeMedia,
      );

      _lastBackupTime = DateTime.now();
      _lastBackupPath = file.path;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyLastTime, _lastBackupTime!.toIso8601String());
      await prefs.setString(_keyLastPath, file.path);
      return file;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      return null;
    } finally {
      _isRunning = false;
      notifyListeners();
    }
  }

  /// Restores data from a ZIP file path. Throws on error.
  Future<void> restore(String zipPath) async {
    _isRunning = true;
    _error = null;
    notifyListeners();
    try {
      await _service.restoreBackup(zipPath);
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      rethrow;
    } finally {
      _isRunning = false;
      notifyListeners();
    }
  }

  Future<List<File>> listBackups() => _service.listBackups();
  Future<void> deleteBackup(String path) => _service.deleteBackup(path);
}
