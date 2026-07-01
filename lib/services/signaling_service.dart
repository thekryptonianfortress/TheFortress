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
  groupPinChanged,
  groupPollVoted,
  contactAutoAdded,
  // Group call events
  groupCallIncoming,
  groupCallJoined,
  groupCallMemberJoined,
  groupCallMemberLeft,
  gcIncomingOffer,
  gcCallAnswered,
  gcIceCandidate,
  gcPeerEnded,
  groupCallMissed,
  callUpgradeAck,
  callUpgraded, // 1:1 call upgraded by peer — auto-join the group call
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
    // Group events over LAN
    'group-message': SignalingEvent.groupMessage,
    'group-message-edited': SignalingEvent.groupMessageEdited,
    'group-message-deleted': SignalingEvent.groupMessageDeleted,
    'group-reaction-added': SignalingEvent.groupReactionAdded,
    'group-user-typing': SignalingEvent.groupUserTyping,
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
    _socket!.on('group-pin-changed', (data) =>
        _emit(SignalingEvent.groupPinChanged, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-poll-voted', (data) =>
        _emit(SignalingEvent.groupPollVoted, Map<String, dynamic>.from(data as Map)));
    _socket!.on('contact-auto-added', (data) =>
        _emit(SignalingEvent.contactAutoAdded, Map<String, dynamic>.from(data as Map)));
    // Group call room events
    _socket!.on('group-call-incoming', (data) =>
        _emit(SignalingEvent.groupCallIncoming, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-call-joined', (data) =>
        _emit(SignalingEvent.groupCallJoined, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-call-member-joined', (data) =>
        _emit(SignalingEvent.groupCallMemberJoined, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-call-member-left', (data) =>
        _emit(SignalingEvent.groupCallMemberLeft, Map<String, dynamic>.from(data as Map)));
    // Group call P2P events
    _socket!.on('gc-incoming-offer', (data) =>
        _emit(SignalingEvent.gcIncomingOffer, Map<String, dynamic>.from(data as Map)));
    _socket!.on('gc-call-answered', (data) =>
        _emit(SignalingEvent.gcCallAnswered, Map<String, dynamic>.from(data as Map)));
    _socket!.on('gc-ice-candidate', (data) =>
        _emit(SignalingEvent.gcIceCandidate, Map<String, dynamic>.from(data as Map)));
    _socket!.on('gc-peer-ended', (data) =>
        _emit(SignalingEvent.gcPeerEnded, Map<String, dynamic>.from(data as Map)));
    _socket!.on('group-call-missed', (data) =>
        _emit(SignalingEvent.groupCallMissed, Map<String, dynamic>.from(data as Map)));
    _socket!.on('call-upgrade-ack', (data) =>
        _emit(SignalingEvent.callUpgradeAck, Map<String, dynamic>.from(data as Map)));
    _socket!.on('call-upgraded', (data) =>
        _emit(SignalingEvent.callUpgraded, Map<String, dynamic>.from(data as Map)));
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
    bool isVideo = false,
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
        'is_video': isVideo,
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
      'is_video': isVideo,
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

  // ── Outbound: Group Calls ──────────────────────────────────

  void sendGroupCallStart(String groupId, bool isVideo, String virtualId, String username) {
    _socket?.emit('group-call-start', {
      'group_id': groupId, 'is_video': isVideo, 'virtual_id': virtualId, 'username': username,
    });
  }

  void sendGroupCallJoin(String groupId, String virtualId, String username) {
    _socket?.emit('group-call-join', {
      'group_id': groupId, 'virtual_id': virtualId, 'username': username,
    });
  }

  void sendGroupCallLeave(String groupId, String virtualId) {
    _socket?.emit('group-call-leave', {'group_id': groupId, 'virtual_id': virtualId});
  }

  void sendGroupCallInvite(String groupId, String targetVirtualId) {
    _socket?.emit('group-call-invite', {'group_id': groupId, 'target_virtual_id': targetVirtualId});
  }

  void sendGcOffer({
    required String targetVirtualId,
    required Map<String, dynamic> sdp,
    required String fromVirtualId,
    required String fromUsername,
    required String groupId,
    required String connId,
    required bool isVideo,
  }) {
    _socket?.emit('gc-offer', {
      'target_virtual_id': targetVirtualId, 'sdp': sdp,
      'from_virtual_id': fromVirtualId, 'from_username': fromUsername,
      'group_id': groupId, 'conn_id': connId, 'is_video': isVideo,
    });
  }

  void sendGcAnswer({
    required String targetVirtualId,
    required Map<String, dynamic> sdp,
    required String connId,
  }) {
    _socket?.emit('gc-answer', {'target_virtual_id': targetVirtualId, 'sdp': sdp, 'conn_id': connId});
  }

  void sendGcIce({
    required String targetVirtualId,
    required Map<String, dynamic> candidate,
    required String connId,
  }) {
    _socket?.emit('gc-ice', {'target_virtual_id': targetVirtualId, 'candidate': candidate, 'conn_id': connId});
  }

  void sendGcPeerEnd({required String targetVirtualId}) {
    _socket?.emit('gc-peer-end', {'target_virtual_id': targetVirtualId});
  }

  void sendCallUpgrade({
    required String callId,
    required String addVirtualId,
    required String groupId,
    required String groupName,
    required bool isVideo,
  }) {
    _socket?.emit('call-upgrade', {
      'call_id': callId,
      'add_virtual_id': addVirtualId,
      'group_id': groupId,
      'group_name': groupName,
      'is_video': isVideo,
    });
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
    String senderUsername = '',
    List<String> memberVirtualIds = const [],
    String? replyToId,
    String? attachmentUrl,
    String? attachmentType,
    String? attachmentName,
    int? attachmentSize,
  }) {
    if (!_isConnected && _lan != null) {
      _lan!.broadcastToGroup(memberVirtualIds, 'group-message', {
        'id': messageId,
        'group_id': groupId,
        'sender_id': _lan!.myUserId,
        'sender_username': senderUsername,
        'content': content,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        if (replyToId != null) 'reply_to_id': replyToId,
        if (attachmentUrl != null) 'attachment_url': attachmentUrl,
        if (attachmentType != null) 'attachment_type': attachmentType,
        if (attachmentName != null) 'attachment_name': attachmentName,
        if (attachmentSize != null) 'attachment_size': attachmentSize,
      });
      return;
    }
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

  void sendGroupTyping({required String groupId, List<String> memberVirtualIds = const []}) {
    if (!_isConnected && _lan != null) {
      _lan!.broadcastToGroup(memberVirtualIds, 'group-user-typing', {
        'group_id': groupId,
        'user_id': _lan!.myUserId,
      });
      return;
    }
    _socket?.emit('group-typing', {'group_id': groupId});
  }

  void emitGroupEditMessage({
    required String messageId,
    required String groupId,
    required String newContent,
    List<String> memberVirtualIds = const [],
  }) {
    if (!_isConnected && _lan != null) {
      _lan!.broadcastToGroup(memberVirtualIds, 'group-message-edited', {
        'message_id': messageId,
        'group_id': groupId,
        'new_content': newContent,
        'edited_at': DateTime.now().toUtc().toIso8601String(),
      });
      return;
    }
    _socket?.emit('group-edit-message', {
      'message_id': messageId,
      'group_id': groupId,
      'new_content': newContent,
    });
  }

  void emitGroupDeleteMessage({
    required String messageId,
    required String groupId,
    List<String> memberVirtualIds = const [],
  }) {
    if (!_isConnected && _lan != null) {
      _lan!.broadcastToGroup(memberVirtualIds, 'group-message-deleted', {
        'message_id': messageId,
        'group_id': groupId,
      });
      return;
    }
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
