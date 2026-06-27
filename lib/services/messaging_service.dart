import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../data/local/database.dart';
import '../data/local/secure_storage.dart';
import '../data/models/message.dart';
import 'lan_transport.dart';
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
    String? attachmentUrl,
    String? attachmentType,
    String? attachmentName,
    int? attachmentSize,
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
      attachmentUrl: attachmentUrl,
      attachmentType: attachmentType,
      attachmentName: attachmentName,
      attachmentSize: attachmentSize,
    );

    await _db.upsertMessage(msg);

    final serverConnected = _signaling.isConnected;
    final lanReachable =
        !serverConnected && LanTransport.instance.isReachable(recipientVirtualId);

    if (lanReachable) {
      // Deliver directly over LAN with full sender context so the recipient's
      // MessagesProvider can construct the Message without a server lookup.
      final myVirtualId = await SecureStorage.getVirtualId() ?? '';
      final myUsername = await SecureStorage.getUsername() ?? '';
      LanTransport.instance.send(recipientVirtualId, 'new-message', {
        'message_id': msgId,
        'sender_id': myId,
        'sender_virtual_id': myVirtualId,
        'sender_username': myUsername,
        'encrypted_content': plaintext,
        'nonce': '',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        if (replyToId != null) 'reply_to_id': replyToId,
        if (attachmentUrl != null) 'attachment_url': attachmentUrl,
        if (attachmentType != null) 'attachment_type': attachmentType,
        if (attachmentName != null) 'attachment_name': attachmentName,
        if (attachmentSize != null) 'attachment_size': attachmentSize,
      });
      // Also queue so the message is synced to the server when connectivity
      // returns — ensures history and delivery receipts are preserved.
      await _db.queueMessage({
        'id': msgId,
        'sender_id': myId,
        'recipient_id': recipientId,
        'encrypted_content': plaintext,
        'nonce': '',
        'recipient_virtual_id': recipientVirtualId,
        'created_at': DateTime.now().toIso8601String(),
        'reply_to_id': replyToId,
        if (attachmentUrl != null) 'attachment_url': attachmentUrl,
        if (attachmentType != null) 'attachment_type': attachmentType,
        if (attachmentName != null) 'attachment_name': attachmentName,
        if (attachmentSize != null) 'attachment_size': attachmentSize,
      });
    } else if (serverConnected) {
      _signaling.sendMessage(
        recipientVirtualId: recipientVirtualId,
        messageId: msgId,
        encryptedContent: plaintext,
        nonce: '',
        replyToId: replyToId,
        attachmentUrl: attachmentUrl,
        attachmentType: attachmentType,
        attachmentName: attachmentName,
        attachmentSize: attachmentSize,
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
        if (attachmentUrl != null) 'attachment_url': attachmentUrl,
        if (attachmentType != null) 'attachment_type': attachmentType,
        if (attachmentName != null) 'attachment_name': attachmentName,
        if (attachmentSize != null) 'attachment_size': attachmentSize,
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
    if (!_signaling.isConnected) {
      // Queue so the server learns about this edit when we reconnect
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getStringList('pending_lan_edits') ?? [];
      pending.add(jsonEncode({
        'message_id': messageId,
        'new_content': newContent,
        'recipient_virtual_id': recipientVirtualId,
      }));
      await prefs.setStringList('pending_lan_edits', pending);
    }
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
    if (!_signaling.isConnected) {
      // Queue so the server learns about this delete when we reconnect
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getStringList('pending_lan_deletes') ?? [];
      pending.add(jsonEncode({
        'message_id': messageId,
        'recipient_virtual_id': recipientVirtualId,
      }));
      await prefs.setStringList('pending_lan_deletes', pending);
    }
    _signaling.emitDeleteMessage(
      messageId: messageId,
      recipientVirtualId: recipientVirtualId,
    );
  }

  /// Flush edits, deletes, and reactions queued during LAN-only sessions
  /// to the server now that we're back online.
  Future<void> flushPendingLanOps() async {
    if (!_signaling.isConnected) return;
    final prefs = await SharedPreferences.getInstance();

    final edits = prefs.getStringList('pending_lan_edits') ?? [];
    if (edits.isNotEmpty) {
      for (final e in edits) {
        try {
          final d = jsonDecode(e) as Map<String, dynamic>;
          _signaling.emitEditMessage(
            messageId: d['message_id'] as String,
            newContent: d['new_content'] as String,
            recipientVirtualId: d['recipient_virtual_id'] as String,
          );
        } catch (_) {}
      }
      await prefs.remove('pending_lan_edits');
    }

    final deletes = prefs.getStringList('pending_lan_deletes') ?? [];
    if (deletes.isNotEmpty) {
      for (final d in deletes) {
        try {
          final data = jsonDecode(d) as Map<String, dynamic>;
          _signaling.emitDeleteMessage(
            messageId: data['message_id'] as String,
            recipientVirtualId: data['recipient_virtual_id'] as String,
          );
        } catch (_) {}
      }
      await prefs.remove('pending_lan_deletes');
    }

    final reactions = prefs.getStringList('pending_lan_reactions') ?? [];
    if (reactions.isNotEmpty) {
      for (final r in reactions) {
        try {
          final d = jsonDecode(r) as Map<String, dynamic>;
          _signaling.emitReaction(
            messageId: d['message_id'] as String,
            emoji: d['emoji'] as String,
            recipientVirtualId: d['recipient_virtual_id'] as String,
          );
        } catch (_) {}
      }
      await prefs.remove('pending_lan_reactions');
    }

    final readReceipts = prefs.getStringList('pending_lan_read_receipts') ?? [];
    if (readReceipts.isNotEmpty) {
      for (final r in readReceipts) {
        try {
          final d = jsonDecode(r) as Map<String, dynamic>;
          _signaling.sendReadReceipt(
            messageIds: List<String>.from(d['message_ids'] as List),
            senderId: d['sender_id'] as String,
          );
        } catch (_) {}
      }
      await prefs.remove('pending_lan_read_receipts');
    }
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
        attachmentUrl: p['attachment_url'] as String?,
        attachmentType: p['attachment_type'] as String?,
        attachmentName: p['attachment_name'] as String?,
        attachmentSize: p['attachment_size'] as int?,
        createdAt: p['created_at'] as String?,
      );
      await _db.deletePendingMessage(p['id'] as String);
      // Only upgrade pending → sent; never downgrade delivered/read back to sent
      await _db.updateMessageStatusIfPending(p['id'] as String, MessageStatus.sent);
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
      ).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List;
        for (final json in list) {
          final msg = Message.fromJson(json as Map<String, dynamic>, myId);
          // Merge strategy: don't let server overwrite local-only edits/deletes/reactions
          await _db.upsertMessageFromServer(msg);
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
