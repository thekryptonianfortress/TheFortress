import 'dart:async';
import 'dart:developer' as dev;
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../core/constants.dart';
import '../data/local/secure_storage.dart';

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
  presenceUpdate,
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

  Stream<SignalingMessage> get stream => _controller.stream;
  bool get isConnected => _isConnected;

  Future<void> connect() async {
    if (_socket != null) return; // already connected or connecting
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

    _socket!.onConnectError((err) {
      dev.log('[SignalingService] connect_error: $err');
    });

    _socket!.onError((err) {
      dev.log('[SignalingService] error: $err');
    });

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

    _socket!.on('presence-update', (data) =>
        _emit(SignalingEvent.presenceUpdate, Map<String, dynamic>.from(data as Map)));
  }

  void _emit(SignalingEvent event, Map<String, dynamic> data) {
    if (!_controller.isClosed) {
      _controller.add(SignalingMessage(event, data));
    }
  }

  // ── Outbound ───────────────────────────────────────────────

  void sendCallOffer({
    required String targetVirtualId,
    required Map<String, dynamic> sdp,
    required String callerUsername,
    required String callerVirtualId,
  }) {
    _socket?.emit('call-offer', {
      'target_virtual_id': targetVirtualId,
      'sdp': sdp,
      'caller_username': callerUsername,
      'caller_virtual_id': callerVirtualId,
    });
  }

  void sendCallAnswer({required String callId, required Map<String, dynamic> sdp}) {
    _socket?.emit('call-answer', {'call_id': callId, 'sdp': sdp});
  }

  void sendCallReject(String callId) {
    _socket?.emit('call-reject', {'call_id': callId});
  }

  void sendCallEnd(String callId) {
    _socket?.emit('call-end', {'call_id': callId});
  }

  void sendIceCandidate({required String callId, required Map<String, dynamic> candidate}) {
    _socket?.emit('ice-candidate', {'call_id': callId, 'candidate': candidate});
  }

  void sendMessage({
    required String recipientVirtualId,
    required String messageId,
    required String encryptedContent,
    required String nonce,
  }) {
    _socket?.emit('send-message', {
      'recipient_virtual_id': recipientVirtualId,
      'message_id': messageId,
      'encrypted_content': encryptedContent,
      'nonce': nonce,
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
