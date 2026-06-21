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

  String? _typingPeerId;
  Timer? _typingTimer;

  MessagesProvider(this._messaging, this._signaling) {
    _listenToSignaling();
  }

  List<Message> getChat(String peerId) => _chats[peerId] ?? [];
  bool isTyping(String peerId) => _typingPeerId == peerId;

  void _listenToSignaling() {
    _sub = _signaling.stream.listen((msg) async {
      switch (msg.event) {
        case SignalingEvent.newMessage:
          await _handleIncomingMessage(msg.data);

        case SignalingEvent.messageDelivered:
          final msgId = msg.data['message_id'] as String;
          final recipId = msg.data['recipient_id'] as String;
          await _db.updateMessageStatus(msgId, MessageStatus.delivered);
          _updateStatusInCache(recipId, msgId, MessageStatus.delivered);

        case SignalingEvent.messageAck:
          final msgId = msg.data['message_id'] as String;
          final recipId = msg.data['recipient_id'] as String;
          final status = (msg.data['status'] as String?) == 'delivered'
              ? MessageStatus.delivered
              : MessageStatus.sent;
          await _db.updateMessageStatus(msgId, status);
          _updateStatusInCache(recipId, msgId, status);

        case SignalingEvent.connected:
          await _messaging.flushPendingMessages();

        case SignalingEvent.userTyping:
          _typingPeerId = msg.data['sender_id'] as String;
          _typingTimer?.cancel();
          _typingTimer = Timer(const Duration(seconds: 4), () {
            _typingPeerId = null;
            notifyListeners();
          });
          notifyListeners();

        case SignalingEvent.messagesRead:
          final msgIds = (msg.data['message_ids'] as List).cast<String>();
          final peerId = msg.data['reader_id'] as String;
          for (final id in msgIds) {
            await _db.updateMessageStatus(id, MessageStatus.read);
            _updateStatusInCache(peerId, id, MessageStatus.read);
          }

        case SignalingEvent.messageEdited:
          final msgId = msg.data['message_id'] as String;
          final newContent = msg.data['new_content'] as String;
          final editedAt =
              DateTime.tryParse(msg.data['edited_at'] as String? ?? '') ??
                  DateTime.now();
          await _db.updateMessageContent(msgId, newContent, editedAt);
          _updateEditedInCache(msgId, newContent, editedAt);

        case SignalingEvent.messageDeleted:
          final msgId = msg.data['message_id'] as String;
          await _db.markMessageDeleted(msgId);
          _updateDeletedInCache(msgId);

        default:
          break;
      }
    });
  }

  Future<void> _handleIncomingMessage(Map<String, dynamic> data) async {
    final myId = await SecureStorage.getUserId() ?? '';
    final senderId = data['sender_id'] as String;
    final createdAt = data['created_at'] != null
        ? DateTime.tryParse(data['created_at'] as String) ?? DateTime.now()
        : DateTime.now();

    final msg = Message(
      id: data['message_id'] as String,
      senderId: senderId,
      recipientId: myId,
      encryptedContent: data['encrypted_content'] as String,
      nonce: data['nonce'] as String? ?? '',
      status: MessageStatus.delivered,
      createdAt: createdAt,
      isOutgoing: false,
      replyToId: data['reply_to_id'] as String?,
    );

    // No encryption — content is plaintext
    final decrypted = msg.copyWith(decryptedContent: msg.encryptedContent);
    await _db.upsertMessage(msg);

    final existing = _chats[senderId] ?? [];
    if (!existing.any((m) => m.id == msg.id)) {
      _chats[senderId] = [...existing, decrypted];
      notifyListeners();
    }
  }

  Future<void> loadChat(String peerId) async {
    final msgs = await _messaging.fetchMessages(peerId);
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
    String? replyToId,
  }) async {
    final msg = await _messaging.sendMessage(
      recipientId: recipientId,
      recipientVirtualId: recipientVirtualId,
      recipientPublicKey: recipientPublicKey,
      plaintext: plaintext,
      replyToId: replyToId,
    );

    final shown =
        msg.copyWith(decryptedContent: plaintext, status: MessageStatus.pending);
    _chats[recipientId] = [...(_chats[recipientId] ?? []), shown];
    notifyListeners();
  }

  Future<void> editMessage({
    required String peerId,
    required String messageId,
    required String newContent,
    required String recipientVirtualId,
  }) async {
    final editedAt = DateTime.now();
    await _messaging.editMessage(
      messageId: messageId,
      newContent: newContent,
      recipientId: peerId,
      recipientVirtualId: recipientVirtualId,
    );
    _updateEditedInCache(messageId, newContent, editedAt);
    notifyListeners();
  }

  Future<void> deleteMessage({
    required String peerId,
    required String messageId,
    required String recipientVirtualId,
  }) async {
    await _messaging.deleteMessage(
      messageId: messageId,
      recipientVirtualId: recipientVirtualId,
    );
    _updateDeletedInCache(messageId);
    notifyListeners();
  }

  /// Mark all incoming unread messages in a chat as read and notify the sender.
  Future<void> markMessagesRead(String peerId) async {
    final chat = _chats[peerId] ?? [];
    final unread = chat
        .where((m) => !m.isOutgoing && m.status != MessageStatus.read)
        .toList();
    if (unread.isEmpty) return;

    final ids = unread.map((m) => m.id).toList();
    _signaling.sendReadReceipt(messageIds: ids, senderId: peerId);

    for (final id in ids) {
      await _db.updateMessageStatus(id, MessageStatus.read);
    }
    _chats[peerId] = chat.map((m) {
      if (!m.isOutgoing && m.status != MessageStatus.read) {
        return m.copyWith(status: MessageStatus.read);
      }
      return m;
    }).toList();
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

  void _updateEditedInCache(
      String msgId, String newContent, DateTime editedAt) {
    for (final peerId in _chats.keys) {
      final chat = _chats[peerId]!;
      final idx = chat.indexWhere((m) => m.id == msgId);
      if (idx != -1) {
        _chats[peerId]![idx] = chat[idx].copyWith(
          encryptedContent: newContent,
          decryptedContent: newContent,
          editedAt: editedAt,
        );
        notifyListeners();
        break;
      }
    }
  }

  void _updateDeletedInCache(String msgId) {
    for (final peerId in _chats.keys) {
      final chat = _chats[peerId]!;
      final idx = chat.indexWhere((m) => m.id == msgId);
      if (idx != -1) {
        _chats[peerId]![idx] = chat[idx].copyWith(isDeleted: true);
        notifyListeners();
        break;
      }
    }
  }

  Future<void> clearChat(String peerId) async {
    await MessagingService.saveClearTimestamp(peerId);
    final myId = await SecureStorage.getUserId() ?? '';
    await _db.clearChat(myId, peerId);
    _chats.remove(peerId);
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _typingTimer?.cancel();
    super.dispose();
  }
}
