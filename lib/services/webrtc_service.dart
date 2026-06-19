import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants.dart';
import 'signaling_service.dart';

enum CallState { idle, calling, ringing, active, ended }

class WebRTCService {
  final SignalingService _signaling;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  CallState _state = CallState.idle;
  String? _activeCallId;
  DateTime? _callStartTime;

  // Buffer ICE candidates until we have the real server-assigned call_id
  final List<Map<String, dynamic>> _pendingCandidates = [];

  final _stateController = StreamController<CallState>.broadcast();
  Stream<CallState> get stateStream => _stateController.stream;
  CallState get state => _state;
  String? get activeCallId => _activeCallId;

  WebRTCService(this._signaling);

  Future<List<Map<String, dynamic>>> _getIceServers() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(AppConstants.iceServersCacheKey);
    final expiry = prefs.getInt(AppConstants.iceServersCacheExpiryKey) ?? 0;

    if (cached != null && DateTime.now().millisecondsSinceEpoch < expiry) {
      return List<Map<String, dynamic>>.from(jsonDecode(cached));
    }
    return AppConstants.defaultIceServers;
  }

  Future<void> _createPeerConnection() async {
    final iceServers = await _getIceServers();
    final config = {
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    };

    _pc = await createPeerConnection(config);

    _pc!.onIceCandidate = (candidate) {
      final callId = _activeCallId;
      if (callId != null) {
        // We have the real call_id — send immediately
        _signaling.sendIceCandidate(
          callId: callId,
          candidate: candidate.toMap(),
        );
      } else {
        // No call_id yet — buffer until handleAnswer provides it
        _pendingCandidates.add(candidate.toMap());
      }
    };

    _pc!.onConnectionState = (state) {
      // Only end an already-active call on disconnect/fail.
      // During setup (calling/ringing), ICE may transiently report failure
      // (e.g. STUN timeout) — don't kill the call before it starts.
      if (_state == CallState.active &&
          (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
              state == RTCPeerConnectionState.RTCPeerConnectionStateFailed)) {
        endCall();
      }
    };
  }

  Future<Map<String, dynamic>> startCall({required String targetVirtualId}) async {
    await _createPeerConnection();
    _localStream = await _getLocalAudio();
    for (final track in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    final offer = await _pc!.createOffer({'offerToReceiveAudio': true});
    await _pc!.setLocalDescription(offer);

    // _activeCallId is intentionally NOT set here.
    // The server generates the canonical call_id and returns it in 'call-answered'.
    // ICE candidates are buffered in _pendingCandidates until handleAnswer() sets it.
    _setState(CallState.calling);

    return {'type': offer.type, 'sdp': offer.sdp};
  }

  Future<Map<String, dynamic>> answerCall({
    required String callId,
    required Map<String, dynamic> offerSdp,
  }) async {
    _activeCallId = callId;
    await _createPeerConnection();
    _localStream = await _getLocalAudio();
    for (final track in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    await _pc!.setRemoteDescription(
      RTCSessionDescription(offerSdp['sdp'] as String, offerSdp['type'] as String),
    );

    final answer = await _pc!.createAnswer({'offerToReceiveAudio': true});
    await _pc!.setLocalDescription(answer);
    _callStartTime = DateTime.now();
    _setState(CallState.active);

    return {'type': answer.type, 'sdp': answer.sdp};
  }

  /// Called when the server acknowledges the call-offer with the assigned call_id.
  /// Flushes any buffered ICE candidates immediately.
  void confirmCallId(String callId) {
    if (_activeCallId == callId) return; // already set
    _activeCallId = callId;
    for (final c in _pendingCandidates) {
      _signaling.sendIceCandidate(callId: callId, candidate: c);
    }
    _pendingCandidates.clear();
  }

  Future<void> handleAnswer(Map<String, dynamic> sdp, {required String callId}) async {
    // Ensure call_id is set (may already be set by confirmCallId from offer-ack)
    confirmCallId(callId);

    await _pc?.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'] as String, sdp['type'] as String),
    );
    _callStartTime = DateTime.now();
    _setState(CallState.active);
  }

  Future<void> addIceCandidate(Map<String, dynamic> candidateMap) async {
    final candidate = RTCIceCandidate(
      candidateMap['candidate'] as String,
      candidateMap['sdpMid'] as String?,
      candidateMap['sdpMLineIndex'] as int?,
    );
    await _pc?.addCandidate(candidate);
  }

  void setMicMute(bool muted) {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
  }

  int? get callDurationSeconds {
    if (_callStartTime == null) return null;
    return DateTime.now().difference(_callStartTime!).inSeconds;
  }

  void endCall() {
    _pendingCandidates.clear();
    _pc?.close();
    _pc = null;
    _localStream?.dispose();
    _localStream = null;
    _activeCallId = null;
    _callStartTime = null;
    _setState(CallState.ended);
    Future.delayed(const Duration(milliseconds: 300), () => _setState(CallState.idle));
  }

  Future<MediaStream> _getLocalAudio() async {
    return navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
  }

  void _setState(CallState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  void dispose() {
    endCall();
    _stateController.close();
  }
}
