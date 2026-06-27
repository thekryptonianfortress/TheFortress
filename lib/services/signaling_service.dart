import 'dart:async';
import 'dart:developer' as dev;
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../core/constants.dart';
import '../data/local/secure_storage.dart';
import 'lan_transport.dart';

enum SignalingEvent {
  connected,
  disconnected,
  callOfferAck,
  incomingCall,
  callAnswered,
  callRejected,
  callEnded,
  iceCandidate,
  newMessage,
  messageDelivered,
  messageAck,
  presenceUpdate,
  contactsPresence,
  userTyping,
  messagesRead,
  messageEdited,
  messageDeleted,
  reactionAdded,
  // Group events
  groupMessage,
  groupMessageAck,
  groupMessageEdited,
  groupMessageDeleted,
  groupReactionAdded,
  groupUserTyping,
  groupJoinRequest,
  groupMemberApproved,
  groupMemberRejected,
  groupMemberJoined,
  groupMemberLeft,
  groupMemberPromoted,
  groupUpdated,
  groupDeleted,
  groupChatCleared,
  contactAutoAdded,
}

class SignalingMessage {
  final SignalingEvent event;
  final Map<String, dynamic> data;
  const SignalingMessage(this.event, this.data);
}

class SignalingService {
  io.Socket? _socket;
  final _controller = StreamController<SignalingMessage>.broadcast();
  bool _isConnected = false;
  LanTransport? _lan;

  Stream<SignalingMessage> get stream => _controller.stream;
  bool get isConnected => _isConnected;

  /// Wire up LAN transport — call this once after the transport is created.
  void setLanTransport(LanTransport lan) {
    _lan = lan;
    lan.setInjectCallback((event, data) {
      final sigEvent = _lanEventMap[event];
      if (sigEvent != null) _emit(sigEvent, data);
    });
  }

  /// Inject a synthetic event into the stream (used for LAN-received events).
  void injectEvent(SignalingEvent event, Map<String, dynamic> data) {
    _emit(event, data);
  }

  static const Map<String, SignalingEvent> _lanEventMap = {
    'new-message': SignalingEvent.newMessage,
    'message-ack': SignalingEvent.messageAck,
    'incoming-call': SignalingEvent.incomingCall,
    'call-answered': SignalingEvent.callAnswered,
    'call-rejected': SignalingEvent.callRejected,
    'call-ended': SignalingEvent.callEnded,
    'ice-candidate': SignalingEvent.iceCandidate,
    'user-typing': SignalingEvent.userTyping,
    'messages-read': SignalingEvent.messagesRead,
    'message-edited': SignalingEvent.messageEdited,
    'message-deleted': SignalingEvent.messageDeleted,
    'reaction-added': SignalingEvent.reactionAdded,
  };

  Future<void> connect() async {
    if (_socket != null) return;
    final token = await SecureStorage.getToken();
    if (token == null) return;

    _socket = io.io(
      AppConstants.wsUrl,
      io.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .setAuth({'token': token})
          .enableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(double.infinity)
          .setReconnectionDelay(2000)
          .build(),
    );

    _socket!.onConnect((_) {
      dev.log('[SignalingService] connected');
      _isConnected = true;
      _emit(SignalingEvent.connected, {});
    });

    _socket!.onDisconnect((_) {
      dev.log('[SignalingService] disconnected');
      _isConnected = false;
      _emit(SignalingEvent.disconnected, {});
    });

    _socket!.onConnectError((err) => dev.log('[SignalingService] connect_error: $err'));
    _socket!.onError((err) => dev.log('[SignalingService] error: $err'));

    _socket!.on('call-offer-ack', (data) =>
        _emit(SignalingEvent.callOfferAck, Map<String, dynamic>.from(data as Map)));
    _socket!.on('incoming-call', (data) =>
        _emit(SignalingEvent.incomingCall, Map<String, dynamic>.from(data as Map)));
    _socket!.on('call-answered', (data) =>
        _emit(SignalingEvent.callAnswered, Map<String, dynamic>.from(data as Map)));
    _socket!.on('call-rejected', (data) =>
        _emit(SignalingEvent.callRejected, Map<String, dynamic>.from(data as Map)));
    _socket!.on('call-ended', (data) =>
        _emit(SignalingEvent.callEnded, Map<String, dynamic>.from(data as Map)));
    _socket!.on('ice-candidate', (data) =>
        _emit(SignalingEvent.iceCandidate, Map<String, dynamic>.from(data as Map)));
    _socket!.on('new-message', (data) =>
        _emit(SignalingEvent.newMessage, Map<String, dynamic>.from(data as Map)));
    _socket!.on('message-delivered', (data) =>
        _emit(SignalingEvent.messageDelivered, Map<String, dynamic>.from(data as Map)));
    _socket!.on('message-ack', (data) =>
        _emit(SignalingEvent.messageAck, Map<String, dynamic>.from(data as Map)));
    _socket!.on('presence-update', (data) =>
        _emit(SignalingEvent.presenceUpdate, Map<String, dynamic>.from(data as Map)));
    _socket!.on('user-typing', (data) =>
        _emit(SignalingEvent.userTyping, Map<String, dynamic>.from(data as Map)));
    _socket!.on('messages-read', (data) =>
        _emit(SignalingEvent.messagesRead, Map<String, dynamic>.from(data as Map)));
    _socket!.on('message-edited', (data) =>
        _emit(SignalingEvent.messageEdited, Map<String, dynamic>.from(data as Map)));
    _socket!.on('message-deleted', (data) =>
        _emit(SignalingEvent.messageDeleted, Map<String, dynamic>.from(data as Map)));
    _socket!.on('reaction-added', (data) =>
        _emit(SignalingEvent.reactionAdded, Map<String, dynamic>.from(data as Map)));
    _socket!.on('contacts-presence', (data) {
      final list = (data as List).cast<Map<dynamic, dynamic>>();
      _emit(SignalingEvent.contactsPresence, {'list': list});
    });

    // Group events
    _socket!.on('group-message', (data) =>
        _emit(SignalingEvent.groupMessage, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-message-ack', (data) =>
        _emit(SignalingEvent.groupMessageAck, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-message-edited', (data) =>
        _emit(SignalingEvent.groupMessageEdited, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-message-deleted', (data) =>
        _emit(SignalingEvent.groupMessageDeleted, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-reaction-added', (data) =>
        _emit(SignalingEvent.groupReactionAdded, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-user-typing', (data) =>
        _emit(SignalingEvent.groupUserTyping, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-join-request', (data) =>
        _emit(SignalingEvent.groupJoinRequest, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-member-approved', (data) =>
        _emit(SignalingEvent.groupMemberApproved, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-member-rejected', (data) =>
        _emit(SignalingEvent.groupMemberRejected, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-member-joined', (data) =>
        _emit(SignalingEvent.groupMemberJoined, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-member-left', (data) =>
        _emit(SignalingEvent.groupMemberLeft, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-member-promoted', (data) =>
        _emit(SignalingEvent.groupMemberPromoted, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-updated', (data) =>
        _emit(SignalingEvent.groupUpdated, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-deleted', (data) =>
        _emit(SignalingEvent.groupDeleted, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-chat-cleared', (data) =>
        _emit(SignalingEvent.groupChatCleared, Map<String, dynamic>.from(data as Map)));
    _socket!.on('contact-auto-added', (data) =>
        _emit(SignalingEvent.contactAutoAdded, Map<String, dynamic>.from(data as Map)));
  }

  void _emit(SignalingEvent event, Map<String, dynamic> data) {
    if (!_controller.isClosed) _controller.add(SignalingMessage(event, data));
  }

  // ── Outbound: Calls ────────────────────────────────────────

  void sendCallOffer({
    required String targetVirtualId,
    required Map<String, dynamic> sdp,
    required String callerUsername,
    required String callerVirtualId,
  }) {
    if (_lan != null && _lan!.isReachable(targetVirtualId)) {
      // Generate callId locally (normally the server assigns this)
      final callId = _lan!.generateCallId();
      _lan!.trackCall(callId, targetVirtualId);
      _lan!.send(targetVirtualId, 'incoming-call', {
        'call_id': callId,
        'caller_virtual_id': callerVirtualId,
        'caller_username': callerUsername,
        'sdp': sdp,
      });
      // Inject call-offer-ack locally so CallProvider gets the callId
      _emit(SignalingEvent.callOfferAck, {'call_id': callId});
      return;
    }
    _socket?.emit('call-offer', {
      'target_virtual_id': targetVirtualId,
      'sdp': sdp,
      'caller_username': callerUsername,
      'caller_virtual_id': callerVirtualId,
    });
  }

  void sendCallAnswer({required String callId, required Map<String, dynamic> sdp}) {
    if (_lan != null) {
      final peerVId = _lan!.getPeerForCall(callId);
      if (peerVId != null && _lan!.isReachable(peerVId)) {
        _lan!.send(peerVId, 'call-answered', {'call_id': callId, 'sdp': sdp});
        return;
      }
    }
    _socket?.emit('call-answer', {'call_id': callId, 'sdp': sdp});
  }

  void sendCallReject(String callId) {
    if (_lan != null) {
      final peerVId = _lan!.getPeerForCall(callId);
      if (peerVId != null && _lan!.isReachable(peerVId)) {
        _lan!.send(peerVId, 'call-rejected', {'call_id': callId});
        _lan!.clearCall(callId);
        return;
      }
    }
    _socket?.emit('call-reject', {'call_id': callId});
  }

  void sendCallEnd(String callId) {
    if (_lan != null) {
      final peerVId = _lan!.getPeerForCall(callId);
      if (peerVId != null && _lan!.isReachable(peerVId)) {
        _lan!.send(peerVId, 'call-ended', {'call_id': callId});
        _lan!.clearCall(callId);
        return;
      }
    }
    _socket?.emit('call-end', {'call_id': callId});
  }

  void sendIceCandidate(
      {required String callId, required Map<String, dynamic> candidate}) {
    if (_lan != null) {
      final peerVId = _lan!.getPeerForCall(callId);
      if (peerVId != null && _lan!.isReachable(peerVId)) {
        _lan!.send(peerVId, 'ice-candidate', {'call_id': callId, 'candidate': candidate});
        return;
      }
    }
    _socket?.emit('ice-candidate', {'call_id': callId, 'candidate': candidate});
  }

  // ── Outbound: Messaging ────────────────────────────────────

  void sendMessage({
    required String recipientVirtualId,
    required String messageId,
    required String encryptedContent,
    required String nonce,
    String? replyToId,
    String? attachmentUrl,
    String? attachmentType,
    String? attachmentName,
    int? attachmentSize,
    String? createdAt,
  }) {
    _socket?.emit('send-message', {
      'recipient_virtual_id': recipientVirtualId,
      'message_id': messageId,
      'encrypted_content': encryptedContent,
      'nonce': nonce,
      if (replyToId != null) 'reply_to_id': replyToId,
      if (attachmentUrl != null) 'attachment_url': attachmentUrl,
      if (attachmentType != null) 'attachment_type': attachmentType,
      if (attachmentName != null) 'attachment_name': attachmentName,
      if (attachmentSize != null) 'attachment_size': attachmentSize,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  void sendTyping({required String recipientVirtualId}) {
    if (_lan != null && _lan!.isReachable(recipientVirtualId)) {
      _lan!.send(recipientVirtualId, 'user-typing', {
        'sender_id': _lan!.myUserId,
      });
      return;
    }
    _socket?.emit('typing', {'recipient_virtual_id': recipientVirtualId});
  }

  void sendReadReceipt(
      {required List<String> messageIds, required String senderId}) {
    if (!_isConnected && _lan != null) {
      // senderId = the peer's userId (original message sender we're acking)
      final peerVId = _lan!.getVirtualIdForUser(senderId);
      if (peerVId != null && _lan!.isReachable(peerVId)) {
        _lan!.send(peerVId, 'messages-read', {
          'message_ids': messageIds,
          'reader_id': _lan!.myUserId,
        });
        return;
      }
    }
    _socket?.emit('read-receipt', {
      'message_ids': messageIds,
      'sender_id': senderId,
    });
  }

  void emitEditMessage({
    required String messageId,
    required String newContent,
    required String recipientVirtualId,
  }) {
    // Only prefer LAN when server is unreachable — if connected, always use server
    // so the edit persists server-side (critical for flush-on-reconnect correctness).
    if (!_isConnected && _lan != null && _lan!.isReachable(recipientVirtualId)) {
      _lan!.send(recipientVirtualId, 'message-edited', {
        'message_id': messageId,
        'new_content': newContent,
        'edited_at': DateTime.now().toUtc().toIso8601String(),
      });
      return;
    }
    _socket?.emit('edit-message', {
      'message_id': messageId,
      'new_content': newContent,
      'recipient_virtual_id': recipientVirtualId,
    });
  }

  void emitDeleteMessage({
    required String messageId,
    required String recipientVirtualId,
  }) {
    // Only prefer LAN when server is unreachable.
    if (!_isConnected && _lan != null && _lan!.isReachable(recipientVirtualId)) {
      _lan!.send(recipientVirtualId, 'message-deleted', {
        'message_id': messageId,
      });
      return;
    }
    _socket?.emit('delete-message', {
      'message_id': messageId,
      'recipient_virtual_id': recipientVirtualId,
    });
  }

  void emitReaction({
    required String messageId,
    required String emoji,
    required String recipientVirtualId,
  }) {
    _socket?.emit('add-reaction', {
      'message_id': messageId,
      'emoji': emoji,
      'recipient_virtual_id': recipientVirtualId,
    });
  }

  // ── Outbound: Groups ───────────────────────────────────────

  void sendGroupMessage({
    required String groupId,
    required String messageId,
    required String content,
    String? replyToId,
    String? attachmentUrl,
    String? attachmentType,
    String? attachmentName,
    int? attachmentSize,
  }) {
    _socket?.emit('group-send-message', {
      'group_id': groupId,
      'message_id': messageId,
      'content': content,
      if (replyToId != null) 'reply_to_id': replyToId,
      if (attachmentUrl != null) 'attachment_url': attachmentUrl,
      if (attachmentType != null) 'attachment_type': attachmentType,
      if (attachmentName != null) 'attachment_name': attachmentName,
      if (attachmentSize != null) 'attachment_size': attachmentSize,
    });
  }

  void sendGroupTyping({required String groupId}) {
    _socket?.emit('group-typing', {'group_id': groupId});
  }

  void emitGroupEditMessage({
    required String messageId,
    required String groupId,
    required String newContent,
  }) {
    _socket?.emit('group-edit-message', {
      'message_id': messageId,
      'group_id': groupId,
      'new_content': newContent,
    });
  }

  void emitGroupDeleteMessage({
    required String messageId,
    required String groupId,
  }) {
    _socket?.emit('group-delete-message', {
      'message_id': messageId,
      'group_id': groupId,
    });
  }

  void emitGroupReaction({
    required String messageId,
    required String groupId,
    required String emoji,
  }) {
    _socket?.emit('group-add-reaction', {
      'message_id': messageId,
      'group_id': groupId,
      'emoji': emoji,
    });
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _isConnected = false;
  }

  void dispose() {
    disconnect();
    _controller.close();
  }
}
