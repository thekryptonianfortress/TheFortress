import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../data/local/database.dart';
import '../data/local/secure_storage.dart';
import '../data/models/message.dart';
import 'signaling_service.dart';

class MessagingService {
  final SignalingService _signaling;
  final LocalDatabase _db = LocalDatabase.instance;
  final _uuid = const Uuid();

  MessagingService(this._signaling);

  Future<Message> sendMessage({
    required String recipientId,
    required String recipientVirtualId,
    required String recipientPublicKey,
    required String plaintext,
    String? replyToId,
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
      replyToId: replyToId,
    );

    await _db.upsertMessage(msg);

    if (_signaling.isConnected) {
      _signaling.sendMessage(
        recipientVirtualId: recipientVirtualId,
        messageId: msgId,
        encryptedContent: plaintext,
        nonce: '',
        replyToId: replyToId,
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
        'reply_to_id': replyToId,
      });
    }

    return msg;
  }

  Future<void> editMessage({
    required String messageId,
    required String newContent,
    required String recipientId,
    required String recipientVirtualId,
  }) async {
    final editedAt = DateTime.now();
    await _db.updateMessageContent(messageId, newContent, editedAt);
    _signaling.emitEditMessage(
      messageId: messageId,
      newContent: newContent,
      recipientVirtualId: recipientVirtualId,
    );
  }

  Future<void> deleteMessage({
    required String messageId,
    required String recipientVirtualId,
  }) async {
    await _db.markMessageDeleted(messageId);
    _signaling.emitDeleteMessage(
      messageId: messageId,
      recipientVirtualId: recipientVirtualId,
    );
  }

  /// Return message content as-is (no encryption in current build).
  Future<String> decryptMessage({
    required String encryptedContent,
    required String nonce,
    required String senderPublicKey,
  }) async {
    return encryptedContent;
  }

  Future<void> flushPendingMessages() async {
    if (!_signaling.isConnected) return;
    final pending = await _db.getPendingMessages();
    for (final p in pending) {
      _signaling.sendMessage(
        recipientVirtualId: p['recipient_virtual_id'] as String,
        messageId: p['id'] as String,
        encryptedContent: p['encrypted_content'] as String,
        nonce: p['nonce'] as String,
        replyToId: p['reply_to_id'] as String?,
      );
      await _db.deletePendingMessage(p['id'] as String);
      await _db.updateMessageStatus(p['id'] as String, MessageStatus.sent);
    }
  }

  Future<List<Message>> fetchMessages(String peerId, {DateTime? since}) async {
    final token = await SecureStorage.getToken();
    final myId = await SecureStorage.getUserId() ?? '';
    if (token == null) return _db.getMessages(myId, peerId);

    try {
      var url = '${AppConstants.serverBaseUrl}/messages/$peerId';
      if (since != null) {
        url += '?since=${Uri.encodeComponent(since.toUtc().toIso8601String())}';
      }
      final res = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List;
        for (final json in list) {
          final msg = Message.fromJson(json as Map<String, dynamic>, myId);
          await _db.upsertMessage(msg);
        }
      }
    } catch (_) {
      // Offline — serve from cache
    }
    return _db.getMessages(myId, peerId);
  }

  /// Tells the server to hide all messages before NOW() for this user+peer pair.
  /// Survives client reinstalls because the clear record lives on the server.
  Future<void> clearChatOnServer(String peerId) async {
    final token = await SecureStorage.getToken();
    if (token == null) return;
    try {
      await http.delete(
        Uri.parse('${AppConstants.serverBaseUrl}/messages/$peerId'),
        headers: {'Authorization': 'Bearer $token'},
      );
    } catch (_) {}
  }
  /// Send a quick reply via virtual ID — used for notification inline replies.
  Future<void> sendMessageByVirtualId({
    required String recipientVirtualId,
    required String plaintext,
  }) async {
    final myId = await SecureStorage.getUserId() ?? '';
    final contact = await _db.getContactByVirtualId(myId, recipientVirtualId);
    if (contact == null) return;
    await sendMessage(
      recipientId: contact.contactId,
      recipientVirtualId: recipientVirtualId,
      recipientPublicKey: contact.publicKey,
      plaintext: plaintext,
    );
  }


}
