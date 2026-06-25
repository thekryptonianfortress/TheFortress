import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../data/local/database.dart';

/// Represents the metadata stored inside every backup ZIP.
class BackupMeta {
  final String version;
  final String createdAt;
  final String userId;
  final String username;
  final String virtualId;
  final bool includeMessages;
  final bool includeMedia;

  const BackupMeta({
    required this.version,
    required this.createdAt,
    required this.userId,
    required this.username,
    required this.virtualId,
    required this.includeMessages,
    required this.includeMedia,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'created_at': createdAt,
        'user_id': userId,
        'username': username,
        'virtual_id': virtualId,
        'include_messages': includeMessages,
        'include_media': includeMedia,
      };

  factory BackupMeta.fromJson(Map<String, dynamic> j) => BackupMeta(
        version: j['version'] as String? ?? '1.0',
        createdAt: j['created_at'] as String? ?? '',
        userId: j['user_id'] as String? ?? '',
        username: j['username'] as String? ?? '',
        virtualId: j['virtual_id'] as String? ?? '',
        includeMessages: j['include_messages'] as bool? ?? true,
        includeMedia: j['include_media'] as bool? ?? false,
      );
}

/// Core backup and restore logic.
///
/// Designed to be destination-agnostic: [createBackup] returns a [File] that
/// can be saved locally (current) or uploaded to Google Drive (future).
class BackupService {
  static const _backupVersion = '1.0';
  static const _metaFile = 'backup_meta.json';
  static const _contactsFile = 'contacts.json';
  static const _messagesFile = 'messages.json';
  static const _groupMessagesFile = 'group_messages.json';

  final LocalDatabase _db = LocalDatabase.instance;

  /// Creates a backup ZIP and saves it to the app documents directory.
  /// Returns the [File] on success.
  Future<File> createBackup({
    required String userId,
    required String username,
    required String virtualId,
    bool includeMessages = true,
    bool includeMedia = false,
  }) async {
    final d = await _db.db;
    final archive = Archive();

    // ── Meta ──────────────────────────────────────────────────
    final meta = BackupMeta(
      version: _backupVersion,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      userId: userId,
      username: username,
      virtualId: virtualId,
      includeMessages: includeMessages,
      includeMedia: includeMedia,
    );
    _addJson(archive, _metaFile, meta.toJson());

    // ── Contacts ──────────────────────────────────────────────
    final contacts = await d.query(
      'contacts',
      where: 'user_id = ?',
      whereArgs: [userId],
    );
    _addJson(archive, _contactsFile, contacts);

    // ── Messages ──────────────────────────────────────────────
    if (includeMessages) {
      final messages = await d.rawQuery(
        'SELECT * FROM messages WHERE sender_id = ? OR recipient_id = ?',
        [userId, userId],
      );
      _addJson(archive, _messagesFile, messages);

      final groupMessages = await d.query('group_messages');
      _addJson(archive, _groupMessagesFile, groupMessages);
    }

    // ── Encode ZIP ────────────────────────────────────────────
    final zipBytes = ZipEncoder().encode(archive)!;

    final dir = await getApplicationDocumentsDirectory();
    final dateStr = DateTime.now().toIso8601String().substring(0, 10);
    final file = File('${dir.path}/pager_backup_$dateStr.zip');
    await file.writeAsBytes(zipBytes);
    return file;
  }

  /// Restores data from a backup ZIP into local SQLite.
  /// Existing rows are replaced on conflict (upsert behaviour).
  Future<BackupMeta> restoreBackup(String zipPath) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final d = await _db.db;

    // Validate meta
    final metaFile = archive.findFile(_metaFile);
    if (metaFile == null) throw Exception('Not a valid Pager backup file');
    final meta = BackupMeta.fromJson(
      jsonDecode(utf8.decode(metaFile.content as List<int>)) as Map<String, dynamic>,
    );

    // Restore contacts
    final contactsFile = archive.findFile(_contactsFile);
    if (contactsFile != null) {
      final rows = jsonDecode(utf8.decode(contactsFile.content as List<int>)) as List;
      for (final row in rows) {
        await d.insert(
          'contacts',
          Map<String, dynamic>.from(row as Map),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }

    // Restore DM messages
    final messagesFile = archive.findFile(_messagesFile);
    if (messagesFile != null) {
      final rows = jsonDecode(utf8.decode(messagesFile.content as List<int>)) as List;
      for (final row in rows) {
        await d.insert(
          'messages',
          Map<String, dynamic>.from(row as Map),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }

    // Restore group messages
    final groupFile = archive.findFile(_groupMessagesFile);
    if (groupFile != null) {
      final rows = jsonDecode(utf8.decode(groupFile.content as List<int>)) as List;
      for (final row in rows) {
        await d.insert(
          'group_messages',
          Map<String, dynamic>.from(row as Map),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }

    return meta;
  }

  /// Lists all backup ZIP files in the app documents directory,
  /// sorted newest-first.
  Future<List<File>> listBackups() async {
    final dir = await getApplicationDocumentsDirectory();
    final all = dir.listSync().whereType<File>().where(
          (f) => f.path.contains('pager_backup_') && f.path.endsWith('.zip'),
        );
    final files = all.toList();
    files.sort((a, b) =>
        b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  /// Deletes a specific backup file.
  Future<void> deleteBackup(String path) => File(path).delete();

  // ── Helpers ───────────────────────────────────────────────

  void _addJson(Archive archive, String name, dynamic data) {
    final bytes = utf8.encode(jsonEncode(data));
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
}
