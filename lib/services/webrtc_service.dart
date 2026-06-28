import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants.dart';
import 'signaling_service.dart';

enum CallState { idle, calling, ringing, active, ended }

enum CallQuality { connecting, good, reconnecting, poor }

class WebRTCService {
  final SignalingService _signaling;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  CallState _state = CallState.idle;
  CallQuality _quality = CallQuality.connecting;
  String? _activeCallId;
  DateTime? _callStartTime;
  bool _hasRemoteDescription = false;
  bool _iceRestartAttempted = false;
  Timer? _disconnectGraceTimer;

  // Buffer outbound ICE candidates until server assigns a call_id
  final List<Map<String, dynamic>> _pendingLocalCandidates = [];
  // Buffer inbound ICE candidates until setRemoteDescription completes
  final List<Map<String, dynamic>> _pendingRemoteCandidates = [];

  /// Called when the peer connection fails irrecoverably during an active call.
  VoidCallback? onCallDisconnected;

  /// Called whenever call quality changes.
  void Function(CallQuality)? onQualityChanged;

  final _stateController = StreamController<CallState>.broadcast();
  Stream<CallState> get stateStream => _stateController.stream;
  CallState get state => _state;
  CallQuality get quality => _quality;
  String? get activeCallId => _activeCallId;

  WebRTCService(this._signaling);

  Future<List<Map<String, dynamic>>> _getIceServers() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(AppConstants.iceServersCacheKey);
    final expiry = prefs.getInt(AppConstants.iceServersCacheExpiryKey) ?? 0;

    if (cached != null && DateTime.now().millisecondsSinceEpoch < expiry) {
      final list = jsonDecode(cached) as List;
      return list.map((e) {
        final map = Map<String, dynamic>.from(e as Map);
        if (map['urls'] is List) {
          map['urls'] = (map['urls'] as List).map((u) => u.toString()).toList();
        }
        return map;
      }).toList();
    }
    return AppConstants.defaultIceServers;
  }

  Future<void> _createPeerConnection() async {
    final iceServers = await _getIceServers();
    final config = {
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      // 'all' = P2P via STUN first, TURN relay as fallback.
      // 'relay' would force TURN-only, breaking calls without a TURN server.
      'iceTransportPolicy': 'all',
    };

    _pc = await createPeerConnection(config);

    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
      }
    };

    _pc!.onIceCandidate = (candidate) {
      final callId = _activeCallId;
      if (callId != null) {
        _signaling.sendIceCandidate(callId: callId, candidate: candidate.toMap());
      } else {
        // No call_id yet — buffer until confirmCallId() provides it
        _pendingLocalCandidates.add(candidate.toMap());
      }
    };

    _pc!.onIceConnectionState = (iceState) {
      switch (iceState) {
        case RTCIceConnectionState.RTCIceConnectionStateChecking:
          _setQuality(CallQuality.connecting);
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _disconnectGraceTimer?.cancel();
          _iceRestartAttempted = false;
          _setQuality(CallQuality.good);
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          _setQuality(CallQuality.reconnecting);
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _setQuality(CallQuality.poor);
        default:
          break;
      }
    };

    _pc!.onConnectionState = (connState) {
      // Only act on mid-call drops — not during initial setup
      if (_state != CallState.active) return;

      switch (connState) {
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          // Transient — give 5 seconds for ICE to self-heal before ending
          _disconnectGraceTimer?.cancel();
          _disconnectGraceTimer = Timer(const Duration(seconds: 5), () {
            if (_state == CallState.active) {
              _invokeDisconnected();
            }
          });
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _disconnectGraceTimer?.cancel();
          if (!_iceRestartAttempted) {
            // First failure — attempt ICE restart (renegotiates STUN/TURN)
            _iceRestartAttempted = true;
            _pc?.restartIce();
          } else {
            // Second failure — give up
            _invokeDisconnected();
          }
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _disconnectGraceTimer?.cancel();
          _iceRestartAttempted = false;
        default:
          break;
      }
    };
  }

  void _invokeDisconnected() {
    if (onCallDisconnected != null) {
      onCallDisconnected!();
    } else {
      endCall();
    }
  }

  Future<Map<String, dynamic>> startCall({required String targetVirtualId}) async {
    await _createPeerConnection();
    _localStream = await _getLocalAudio();
    for (final track in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    final offer = await _pc!.createOffer({'offerToReceiveAudio': true});
    await _pc!.setLocalDescription(offer);
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
    _hasRemoteDescription = true;

    // Flush any remote ICE candidates that arrived before setRemoteDescription
    for (final c in _pendingRemoteCandidates) {
      await _addRemoteCandidate(c);
    }
    _pendingRemoteCandidates.clear();

    final answer = await _pc!.createAnswer({'offerToReceiveAudio': true});
    await _pc!.setLocalDescription(answer);
    _callStartTime = DateTime.now();
    _setState(CallState.active);

    return {'type': answer.type, 'sdp': answer.sdp};
  }

  /// Called when the server acks the offer with the assigned call_id.
  /// Flushes any buffered outbound ICE candidates.
  void confirmCallId(String callId) {
    if (_activeCallId == callId) return;
    _activeCallId = callId;
    for (final c in _pendingLocalCandidates) {
      _signaling.sendIceCandidate(callId: callId, candidate: c);
    }
    _pendingLocalCandidates.clear();
  }

  Future<void> handleAnswer(Map<String, dynamic> sdp, {required String callId}) async {
    confirmCallId(callId);
    await _pc?.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'] as String, sdp['type'] as String),
    );
    _hasRemoteDescription = true;

    // Flush any buffered remote candidates
    for (final c in _pendingRemoteCandidates) {
      await _addRemoteCandidate(c);
    }
    _pendingRemoteCandidates.clear();

    _callStartTime = DateTime.now();
    _setState(CallState.active);
  }

  Future<void> addIceCandidate(Map<String, dynamic> candidateMap) async {
    if (!_hasRemoteDescription || _pc == null) {
      // Remote description not set yet — buffer until it is
      _pendingRemoteCandidates.add(candidateMap);
      return;
    }
    await _addRemoteCandidate(candidateMap);
  }

  Future<void> _addRemoteCandidate(Map<String, dynamic> candidateMap) async {
    try {
      final candidate = RTCIceCandidate(
        candidateMap['candidate'] as String,
        candidateMap['sdpMid'] as String?,
        candidateMap['sdpMLineIndex'] as int?,
      );
      await _pc?.addCandidate(candidate);
    } catch (_) {}
  }

  void setMicMute(bool muted) {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
  }

  int? get callDurationSeconds {
    if (_callStartTime == null) return null;
    return DateTime.now().difference(_callStartTime!).inSeconds;
  }

  void endCall() {
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = null;
    _pendingLocalCandidates.clear();
    _pendingRemoteCandidates.clear();
    _hasRemoteDescription = false;
    _iceRestartAttempted = false;
    // Stop tracks explicitly to release the microphone
    _localStream?.getTracks().forEach((t) => t.stop());
    _remoteStream?.getTracks().forEach((t) => t.stop());
    _pc?.close();
    _pc = null;
    _localStream?.dispose();
    _localStream = null;
    _remoteStream = null;
    _activeCallId = null;
    _callStartTime = null;
    _quality = CallQuality.connecting;
    _setState(CallState.ended);
    Future.delayed(const Duration(milliseconds: 300), () => _setState(CallState.idle));
  }

  Future<MediaStream> _getLocalAudio() async {
    return navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
  }

  void _setState(CallState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  void _setQuality(CallQuality q) {
    if (_quality == q) return;
    _quality = q;
    onQualityChanged?.call(q);
  }

  void dispose() {
    endCall();
    _stateController.close();
  }
}
