import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/local/database.dart';
import '../data/local/secure_storage.dart';
import '../data/models/call_record.dart';
import '../services/signaling_service.dart';
import '../services/webrtc_service.dart';
import '../services/notification_service.dart';

class IncomingCallInfo {
  final String callId;
  final String callerVirtualId;
  final String callerUsername;
  final Map<String, dynamic> offerSdp;
  const IncomingCallInfo({
    required this.callId,
    required this.callerVirtualId,
    required this.callerUsername,
    required this.offerSdp,
  });
}

class CallProvider extends ChangeNotifier {
  final SignalingService _signaling;
  final WebRTCService _webrtc;
  final LocalDatabase _db = LocalDatabase.instance;

  IncomingCallInfo? _incomingCall;
  String? _activePeerUsername;
  String? _activePeerVirtualId;
  CallDirection _callDirection = CallDirection.outgoing;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  StreamSubscription<SignalingMessage>? _sigSub;
  StreamSubscription<CallState>? _stateSub;
  Timer? _callTimeoutTimer;

  IncomingCallInfo? get incomingCall => _incomingCall;
  CallState get callState => _webrtc.state;
  CallQuality get callQuality => _webrtc.quality;
  bool get isMuted => _isMuted;
  bool get isSpeakerOn => _isSpeakerOn;
  String? get activePeerUsername => _activePeerUsername;
  String? get activePeerVirtualId => _activePeerVirtualId;

  CallProvider(this._signaling, this._webrtc) {
    _listenSignaling();
    _stateSub = _webrtc.stateStream.listen((_) => notifyListeners());
    // Wire notification action buttons (answer/reject) to this provider
    NotificationService.onCallAction = (action) {
      if (action == 'answer') answerCall();
      if (action == 'reject') rejectCall();
    };
    // When ICE fails mid-call, send signaling before local cleanup
    _webrtc.onCallDisconnected = () {
      if (_webrtc.activeCallId != null) {
        _signaling.sendCallEnd(_webrtc.activeCallId!);
      }
      _saveCallRecord(CallStatus.completed);
      _webrtc.endCall();
      _clearState();
    };
    // Bubble quality changes to the UI
    _webrtc.onQualityChanged = (_) => notifyListeners();
  }

  void _listenSignaling() {
    _sigSub = _signaling.stream.listen((msg) async {
      try {
        switch (msg.event) {
          case SignalingEvent.callOfferAck:
            final callId = msg.data['call_id'] as String;
            dev.log('[CallProvider] call-offer-ack callId=$callId');
            _webrtc.confirmCallId(callId);
          case SignalingEvent.incomingCall:
            _handleIncomingCall(msg.data);
          case SignalingEvent.callAnswered:
            dev.log('[CallProvider] call-answered');
            _cancelCallTimeout();
            await _webrtc.handleAnswer(
              Map<String, dynamic>.from(msg.data['sdp'] as Map),
              callId: msg.data['call_id'] as String,
            );
          case SignalingEvent.callRejected:
            _cancelCallTimeout();
            NotificationService.stopRingtone();
            NotificationService.cancelAll();
            await _saveCallRecord(CallStatus.rejected);
            _clearCall();
          case SignalingEvent.callEnded:
            _cancelCallTimeout();
            NotificationService.stopRingtone();
            NotificationService.cancelAll();
            _incomingCall = null;
            await _saveCallRecord(CallStatus.completed);
            _webrtc.endCall();
            _clearState();
          case SignalingEvent.iceCandidate:
            await _webrtc.addIceCandidate(
              Map<String, dynamic>.from(msg.data['candidate'] as Map),
            );
          default:
            break;
        }
      } catch (e, st) {
        dev.log('[CallProvider] signaling error on ${msg.event}: $e\n$st');
      }
    });
  }

  void _handleIncomingCall(Map<String, dynamic> data) {
    _incomingCall = IncomingCallInfo(
      callId: data['call_id'] as String,
      callerVirtualId: data['caller_virtual_id'] as String,
      callerUsername: data['caller_username'] as String,
      offerSdp: Map<String, dynamic>.from(data['sdp'] as Map),
    );
    NotificationService.showCallNotification(
      callerName: _incomingCall!.callerUsername,
      callerVirtualId: _incomingCall!.callerVirtualId,
      callId: _incomingCall!.callId,
    );
    NotificationService.startRingtone();
    notifyListeners();
  }

  Future<void> startCall({
    required String targetVirtualId,
    required String targetUsername,
  }) async {
    _activePeerVirtualId = targetVirtualId;
    _activePeerUsername = targetUsername;
    _callDirection = CallDirection.outgoing;
    final offerSdp = await _webrtc.startCall(targetVirtualId: targetVirtualId);
    final myUsername = await SecureStorage.getUsername() ?? '';
    final myVirtualId = await SecureStorage.getVirtualId() ?? '';
    _signaling.sendCallOffer(
      targetVirtualId: targetVirtualId,
      sdp: offerSdp,
      callerUsername: myUsername,
      callerVirtualId: myVirtualId,
    );
    // Default to earpiece (speaker off) — user can toggle if desired
    _isSpeakerOn = false;
    Helper.setSpeakerphoneOn(false);

    // Auto-cancel after 60 seconds if not answered — save as missed
    _cancelCallTimeout();
    _callTimeoutTimer = Timer(const Duration(seconds: 60), () {
      if (_webrtc.state == CallState.calling) {
        dev.log('[CallProvider] call timeout — saving as missed');
        _saveCallRecord(CallStatus.missed);
        endCall();
      }
    });

    notifyListeners();
  }

  Future<void> answerCall() async {
    if (_incomingCall == null) return;
    final info = _incomingCall!;
    _activePeerVirtualId = info.callerVirtualId;
    _activePeerUsername = info.callerUsername;
    _callDirection = CallDirection.incoming;

    NotificationService.stopRingtone();
    NotificationService.cancelAll();

    final answerSdp = await _webrtc.answerCall(
      callId: info.callId,
      offerSdp: info.offerSdp,
    );
    _signaling.sendCallAnswer(callId: info.callId, sdp: answerSdp);
    _incomingCall = null;
    // Default to earpiece — user can switch to speaker
    _isSpeakerOn = false;
    Helper.setSpeakerphoneOn(false);
    notifyListeners();
  }

  void rejectCall() {
    if (_incomingCall == null) return;
    NotificationService.stopRingtone();
    NotificationService.cancelAll();
    _signaling.sendCallReject(_incomingCall!.callId);
    _incomingCall = null;
    notifyListeners();
  }

  void endCall() {
    _cancelCallTimeout();
    if (_webrtc.activeCallId != null) {
      _signaling.sendCallEnd(_webrtc.activeCallId!);
    }
    _saveCallRecord(CallStatus.completed);
    _webrtc.endCall();
    _clearState();
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    _webrtc.setMicMute(_isMuted);
    notifyListeners();
  }

  void toggleSpeaker() {
    _isSpeakerOn = !_isSpeakerOn;
    Helper.setSpeakerphoneOn(_isSpeakerOn);
    notifyListeners();
  }

  void _cancelCallTimeout() {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
  }

  void _clearCall() {
    _cancelCallTimeout();
    _webrtc.endCall();
    _clearState();
  }

  void _clearState() {
    _activePeerUsername = null;
    _activePeerVirtualId = null;
    _isMuted = false;
    _isSpeakerOn = false;
    notifyListeners();
  }

  Future<void> _saveCallRecord(CallStatus status) async {
    final peerVirtualId = _activePeerVirtualId;
    final peerUsername = _activePeerUsername;
    final callId = _webrtc.activeCallId;
    final direction = _callDirection;
    final duration = _webrtc.callDurationSeconds;

    if (peerVirtualId == null) return;

    try {
      final myId = await SecureStorage.getUserId() ?? '';
      final record = CallRecord(
        id: callId ?? DateTime.now().millisecondsSinceEpoch.toString(),
        callerId: myId,
        calleeId: '',
        peerVirtualId: peerVirtualId,
        peerUsername: peerUsername ?? '',
        status: status,
        direction: direction,
        startedAt: DateTime.now(),
        durationSeconds: duration,
      );
      await _db.insertCallRecord(record);
    } catch (e) {
      dev.log('[CallProvider] Failed to save call record: $e');
    }
  }

  @override
  void dispose() {
    _cancelCallTimeout();
    NotificationService.onCallAction = null;
    _webrtc.onCallDisconnected = null;
    _webrtc.onQualityChanged = null;
    _sigSub?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }
}
