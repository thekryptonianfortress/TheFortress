import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../core/crypto_utils.dart';
import '../data/local/database.dart';
import '../data/local/secure_storage.dart';
import '../data/models/message.dart';
import 'signaling_service.dart';

class MessagingService {
  final SignalingService _signaling;
  final LocalDatabase _db = LocalDatabase.instance;
  final _uuid = const Uuid();

  MessagingService(this._signaling);

  /// Send a message (plaintext, no encryption for now).
  Future<Message> sendMessage({
    required String recipientId,
    required String recipientVirtualId,
    required String recipientPublicKey,
    required String plaintext,
  }) async {
    final myId = await SecureStorage.getUserId() ?? '';
    final msgId = _uuid.v4();
    final msg = Message(
      id: msgId,
      senderId: myId,
      recipientId: recipientId,
      encryptedContent: plaintext,
      nonce: '',
      status: MessageStatus.pending,
      createdAt: DateTime.now(),
      isOutgoing: true,
    );

    await _db.upsertMessage(msg);

    if (_signaling.isConnected) {
      _signaling.sendMessage(
        recipientVirtualId: recipientVirtualId,
        messageId: msgId,
        encryptedContent: plaintext,
        nonce: '',
      );
    } else {
      await _db.queueMessage({
        'id': msgId,
        'sender_id': myId,
        'recipient_id': recipientId,
        'encrypted_content': plaintext,
        'nonce': '',
        'recipient_virtual_id': recipientVirtualId,
        'created_at': DateTime.now().toIso8601String(),
      });
    }

    return msg;
  }

  /// Return message content as-is (no decryption).
  Future<String> decryptMessage({
    required String encryptedContent,
    required String nonce,
    required String senderPublicKey,
  }) async {
    return encryptedContent;
  }

  /// Flush pending (offline-queued) messages when back online.
  Future<void> flushPendingMessages() async {
    if (!_signaling.isConnected) return;
    final pending = await _db.getPendingMessages();
    for (final p in pending) {
      _signaling.sendMessage(
        recipientVirtualId: p['recipient_virtual_id'] as String,
        messageId: p['id'] as String,
        encryptedContent: p['encrypted_content'] as String,
        nonce: p['nonce'] as String,
      );
      await _db.deletePendingMessage(p['id'] as String);
      await _db.updateMessageStatus(p['id'] as String, MessageStatus.sent);
    }
  }

  static String _clearKey(String peerId) => 'chat_cleared_$peerId';

  /// Record the time this chat was cleared so server messages before it are ignored.
  static Future<void> saveClearTimestamp(String peerId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_clearKey(peerId), DateTime.now().toIso8601String());
  }

  static Future<DateTime?> _clearTimestamp(String peerId) async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_clearKey(peerId));
    return s != null ? DateTime.tryParse(s) : null;
  }

  /// Fetch message history from server and cache locally.
  /// Messages older than the last clear are silently ignored.
  Future<List<Message>> fetchMessages(String peerId) async {
    final token = await SecureStorage.getToken();
    final myId = await SecureStorage.getUserId() ?? '';
    if (token == null) return _db.getMessages(myId, peerId);

    final clearedAt = await _clearTimestamp(peerId);

    try {
      final res = await http.get(
        Uri.parse('${AppConstants.serverBaseUrl}/messages/$peerId'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List;
        for (final json in list) {
          final msg = Message.fromJson(json as Map<String, dynamic>, myId);
          // Skip messages that existed before this user cleared the chat
          if (clearedAt != null && !msg.createdAt.isAfter(clearedAt)) continue;
          await _db.upsertMessage(msg);
        }
      }
    } catch (_) {
      // Offline — serve from cache
    }
    return _db.getMessages(myId, peerId);
  }
}
