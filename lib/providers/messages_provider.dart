import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';
import '../data/local/database.dart';
import '../data/local/secure_storage.dart';
import '../data/models/message.dart';
import '../services/messaging_service.dart';
import '../services/signaling_service.dart';

class MessagesProvider extends ChangeNotifier {
  final MessagingService _messaging;
  final SignalingService _signaling;
  final _db = LocalDatabase.instance;

  final Map<String, List<Message>> _chats = {};
  StreamSubscription<SignalingMessage>? _sub;

  MessagesProvider(this._messaging, this._signaling) {
    _listenToSignaling();
  }

  List<Message> getChat(String peerId) => _chats[peerId] ?? [];

  void _listenToSignaling() {
    _sub = _signaling.stream.listen((msg) async {
      if (msg.event == SignalingEvent.newMessage) {
        await _handleIncomingMessage(msg.data);
      } else if (msg.event == SignalingEvent.messageDelivered) {
        final msgId = msg.data['message_id'] as String;
        final recipId = msg.data['recipient_id'] as String;
        await _db.updateMessageStatus(msgId, MessageStatus.delivered);
        _updateStatusInCache(recipId, msgId, MessageStatus.delivered);
      } else if (msg.event == SignalingEvent.connected) {
        await _messaging.flushPendingMessages();
      }
    });
  }

  Future<void> _handleIncomingMessage(Map<String, dynamic> data) async {
    final myId = await SecureStorage.getUserId() ?? '';
    final senderId = data['sender_id'] as String;
    final senderPublicKey = data['sender_public_key'] as String;

    final msg = Message(
      id: data['message_id'] as String,
      senderId: senderId,
      recipientId: myId,
      encryptedContent: data['encrypted_content'] as String,
      nonce: data['nonce'] as String,
      status: MessageStatus.delivered,
      createdAt: DateTime.now(),
      isOutgoing: false,
    );

    // No encryption — content is plaintext
    final plaintext = msg.encryptedContent;

    final decrypted = msg.copyWith(decryptedContent: plaintext);
    await _db.upsertMessage(msg);

    _chats[senderId] = [...(_chats[senderId] ?? []), decrypted];
    notifyListeners();
  }

  Future<void> loadChat(String peerId) async {
    final msgs = await _messaging.fetchMessages(peerId);
    // Preserve decryptedContent for messages already in cache
    final existing = {for (final m in (_chats[peerId] ?? [])) m.id: m};
    _chats[peerId] = msgs.map((m) {
      final cached = existing[m.id];
      if (cached?.decryptedContent != null) {
        return m.copyWith(decryptedContent: cached!.decryptedContent);
      }
      return m;
    }).toList();
    notifyListeners();
  }

  Future<void> sendMessage({
    required String recipientId,
    required String recipientVirtualId,
    required String recipientPublicKey,
    required String plaintext,
  }) async {
    final msg = await _messaging.sendMessage(
      recipientId: recipientId,
      recipientVirtualId: recipientVirtualId,
      recipientPublicKey: recipientPublicKey,
      plaintext: plaintext,
    );

    // Show optimistic decrypted version in UI
    final shown = msg.copyWith(decryptedContent: plaintext, status: MessageStatus.pending);
    _chats[recipientId] = [...(_chats[recipientId] ?? []), shown];
    notifyListeners();
  }

  void _updateStatusInCache(String peerId, String msgId, MessageStatus status) {
    final chat = _chats[peerId];
    if (chat == null) return;
    final idx = chat.indexWhere((m) => m.id == msgId);
    if (idx != -1) {
      _chats[peerId]![idx] = chat[idx].copyWith(status: status);
      notifyListeners();
    }
  }

  Future<void> clearChat(String peerId) async {
    // Save timestamp BEFORE deleting so fetchMessages filters correctly
    await MessagingService.saveClearTimestamp(peerId);
    final myId = await SecureStorage.getUserId() ?? '';
    await _db.clearChat(myId, peerId);
    _chats.remove(peerId);
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
