import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/contact.dart';
import '../models/group_message.dart';
import '../models/message.dart';
import '../models/call_record.dart';
import '../../core/constants.dart';

class LocalDatabase {
  static LocalDatabase? _instance;
  static Database? _db;

  LocalDatabase._();
  static LocalDatabase get instance => _instance ??= LocalDatabase._();

  Future<Database> get db async => _db ??= await _initDb();

  Future<Database> _initDb() async {
    final path = join(await getDatabasesPath(), AppConstants.dbName);
    return openDatabase(
      path,
      version: 7,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE pending_messages ADD COLUMN recipient_virtual_id TEXT NOT NULL DEFAULT ""',
      );
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE messages ADD COLUMN edited_at TEXT');
      await db.execute(
          'ALTER TABLE messages ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE messages ADD COLUMN reply_to_id TEXT');
      await db.execute('ALTER TABLE pending_messages ADD COLUMN reply_to_id TEXT');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE messages ADD COLUMN reactions TEXT');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE messages ADD COLUMN attachment_url TEXT');
      await db.execute('ALTER TABLE messages ADD COLUMN attachment_type TEXT');
      await db.execute('ALTER TABLE messages ADD COLUMN attachment_name TEXT');
      await db.execute('ALTER TABLE messages ADD COLUMN attachment_size INTEGER');
      await db.execute('ALTER TABLE pending_messages ADD COLUMN attachment_url TEXT');
      await db.execute('ALTER TABLE pending_messages ADD COLUMN attachment_type TEXT');
      await db.execute('ALTER TABLE pending_messages ADD COLUMN attachment_name TEXT');
      await db.execute('ALTER TABLE pending_messages ADD COLUMN attachment_size INTEGER');
    }
    if (oldVersion < 6) {
      await db.execute('ALTER TABLE contacts ADD COLUMN avatar_url TEXT');
    }
    if (oldVersion < 7) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS group_messages (
          id TEXT PRIMARY KEY,
          group_id TEXT NOT NULL,
          sender_id TEXT NOT NULL,
          sender_username TEXT NOT NULL,
          sender_avatar_url TEXT,
          content TEXT NOT NULL DEFAULT '',
          attachment_url TEXT,
          attachment_type TEXT,
          attachment_name TEXT,
          attachment_size INTEGER,
          reply_to_id TEXT,
          reactions TEXT,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          edited_at TEXT,
          created_at TEXT NOT NULL,
          is_outgoing INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE contacts (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        contact_id TEXT NOT NULL,
        virtual_id TEXT NOT NULL,
        username TEXT NOT NULL,
        public_key TEXT NOT NULL,
        last_seen TEXT,
        avatar_url TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        sender_id TEXT NOT NULL,
        recipient_id TEXT NOT NULL,
        encrypted_content TEXT NOT NULL,
        nonce TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        edited_at TEXT,
        is_outgoing INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        reply_to_id TEXT,
        reactions TEXT,
        attachment_url TEXT,
        attachment_type TEXT,
        attachment_name TEXT,
        attachment_size INTEGER
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_participants
      ON messages (sender_id, recipient_id, created_at)
    ''');

    await db.execute('''
      CREATE TABLE call_records (
        id TEXT PRIMARY KEY,
        caller_id TEXT NOT NULL,
        callee_id TEXT NOT NULL,
        peer_virtual_id TEXT NOT NULL,
        peer_username TEXT NOT NULL,
        status TEXT NOT NULL,
        direction TEXT NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        duration_seconds INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_messages (
        id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        sender_username TEXT NOT NULL,
        sender_avatar_url TEXT,
        content TEXT NOT NULL DEFAULT '',
        attachment_url TEXT,
        attachment_type TEXT,
        attachment_name TEXT,
        attachment_size INTEGER,
        reply_to_id TEXT,
        reactions TEXT,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        edited_at TEXT,
        created_at TEXT NOT NULL,
        is_outgoing INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE pending_messages (
        id TEXT PRIMARY KEY,
        sender_id TEXT NOT NULL,
        recipient_id TEXT NOT NULL,
        recipient_virtual_id TEXT NOT NULL DEFAULT "",
        encrypted_content TEXT NOT NULL,
        nonce TEXT NOT NULL,
        created_at TEXT NOT NULL,
        reply_to_id TEXT,
        attachment_url TEXT,
        attachment_type TEXT,
        attachment_name TEXT,
        attachment_size INTEGER
      )
    ''');
  }

  // ── Contacts ──────────────────────────────────────────────
  Future<void> upsertContact(Contact c) async {
    final d = await db;
    await d.insert('contacts', c.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Contact>> getContacts(String myUserId) async {
    final d = await db;
    final rows =
        await d.query('contacts', where: 'user_id = ?', whereArgs: [myUserId]);
    return rows.map(Contact.fromDbMap).toList();
  }

  Future<Contact?> getContactByVirtualId(
      String myUserId, String virtualId) async {
    final d = await db;
    final rows = await d.query(
      'contacts',
      where: 'user_id = ? AND virtual_id = ?',
      whereArgs: [myUserId, virtualId],
    );
    return rows.isNotEmpty ? Contact.fromDbMap(rows.first) : null;
  }

  Future<void> deleteContact(String id) async {
    final d = await db;
    await d.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }

  // ── Messages ───────────────────────────────────────────────
  Future<void> upsertMessage(Message m) async {
    final d = await db;
    await d.insert('messages', m.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Message>> getMessages(String myId, String peerId,
      {int limit = 100}) async {
    final d = await db;
    // Fetch newest messages first so the limit always includes the most recent.
    final rows = await d.query(
      'messages',
      where:
          '(sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?)',
      whereArgs: [myId, peerId, peerId, myId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    // Parse then sort by DateTime so timezone differences between locally-stored
    // timestamps (local time) and server timestamps (UTC) are handled correctly.
    final messages = rows.map(Message.fromDbMap).toList();
    messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return messages;
  }

  Future<void> updateMessageStatus(String id, MessageStatus status) async {
    final d = await db;
    await d.update('messages', {'status': status.name},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateMessageContent(
      String id, String newContent, DateTime editedAt) async {
    final d = await db;
    await d.update(
      'messages',
      {
        'encrypted_content': newContent,
        'edited_at': editedAt.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateMessageReactions(
      String id, Map<String, List<String>> reactions) async {
    final d = await db;
    await d.update(
      'messages',
      {'reactions': reactions.isEmpty ? null : jsonEncode(reactions)},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markMessageDeleted(String id) async {
    final d = await db;
    await d.update('messages', {'is_deleted': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  // ── Pending (offline queue) ────────────────────────────────
  Future<void> queueMessage(Map<String, dynamic> payload) async {
    final d = await db;
    await d.insert('pending_messages', payload,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getPendingMessages() async {
    final d = await db;
    return d.query('pending_messages', orderBy: 'created_at ASC');
  }

  Future<void> deletePendingMessage(String id) async {
    final d = await db;
    await d.delete('pending_messages', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearChat(String myId, String peerId) async {
    final d = await db;
    await d.delete(
      'messages',
      where:
          '(sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?)',
      whereArgs: [myId, peerId, peerId, myId],
    );
  }

  /// Returns the most recent message per peer (for seeding the contact tile preview on startup).
  Future<Map<String, Message>> getLastMessages(String myId) async {
    final d = await db;
    // Fetch recent messages ordered newest-first; take the first per peer in Dart
    final rows = await d.query(
      'messages',
      where: 'sender_id = ? OR recipient_id = ?',
      whereArgs: [myId, myId],
      orderBy: 'created_at DESC',
      limit: 500,
    );
    final Map<String, Message> result = {};
    for (final row in rows) {
      final msg = Message.fromDbMap(row);
      final peerId = msg.senderId == myId ? msg.recipientId : msg.senderId;
      result.putIfAbsent(peerId, () => msg);
    }
    return result;
  }

  /// Returns a map of senderId → unread count for all conversations.
  Future<Map<String, int>> getUnreadCounts(String myId) async {
    final d = await db;
    final rows = await d.rawQuery(
      '''
      SELECT sender_id, COUNT(*) as cnt
      FROM messages
      WHERE recipient_id = ? AND is_outgoing = 0 AND status != 'read'
      GROUP BY sender_id
      ''',
      [myId],
    );
    return {for (final r in rows) r['sender_id'] as String: r['cnt'] as int};
  }

  // ── Group Messages ─────────────────────────────────────────
  Future<void> upsertGroupMessage(GroupMessage m) async {
    final d = await db;
    await d.insert('group_messages', m.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<GroupMessage>> getGroupMessages(String groupId, {int limit = 100}) async {
    final d = await db;
    final rows = await d.query(
      'group_messages',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    final msgs = rows.map(GroupMessage.fromDbMap).toList();
    msgs.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return msgs;
  }

  Future<void> updateGroupMessageContent(String id, String content, DateTime editedAt) async {
    final d = await db;
    await d.update('group_messages',
        {'content': content, 'edited_at': editedAt.toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateGroupMessageReactions(String id, Map<String, List<String>> reactions) async {
    final d = await db;
    await d.update('group_messages',
        {'reactions': reactions.isEmpty ? null : jsonEncode(reactions)},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markGroupMessageDeleted(String id) async {
    final d = await db;
    await d.update('group_messages', {'is_deleted': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<GroupMessage?> getLastGroupMessage(String groupId) async {
    final d = await db;
    final rows = await d.query('group_messages',
        where: 'group_id = ? AND is_deleted = 0', whereArgs: [groupId],
        orderBy: 'created_at DESC', limit: 1);
    return rows.isNotEmpty ? GroupMessage.fromDbMap(rows.first) : null;
  }

  Future<void> clearGroupMessages(String groupId) async {
    final d = await db;
    await d.delete('group_messages', where: 'group_id = ?', whereArgs: [groupId]);
  }

  // ── Call Records ───────────────────────────────────────────
  Future<void> insertCallRecord(CallRecord r) async {
    final d = await db;
    await d.insert('call_records', r.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<CallRecord>> getCallRecords({int limit = 50}) async {
    final d = await db;
    final rows = await d.query('call_records',
        orderBy: 'started_at DESC', limit: limit);
    return rows.map(CallRecord.fromDbMap).toList();
  }
}
