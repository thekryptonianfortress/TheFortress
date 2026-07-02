import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
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
  bool _isVideo = false;
  bool _isFrontCamera = true;
  Timer? _disconnectGraceTimer;

  // Buffer outbound ICE candidates until server assigns a call_id
  final List<Map<String, dynamic>> _pendingLocalCandidates = [];
  // Buffer inbound ICE candidates until setRemoteDescription completes
  final List<Map<String, dynamic>> _pendingRemoteCandidates = [];

  /// Called when the peer connection fails irrecoverably during an active call.
  VoidCallback? onCallDisconnected;
  /// Called when remote stream is available (video calls).
  void Function(MediaStream)? onRemoteStream;
  /// Called whenever call quality changes.
  void Function(CallQuality)? onQualityChanged;

  bool get isVideo => _isVideo;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

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
      // plan-b reliably fires onAddStream on Android; unified-plan often
      // delivers empty event.streams in onTrack, causing blank video screens.
      'sdpSemantics': 'plan-b',
      'iceTransportPolicy': 'all',
    };

    _pc = await createPeerConnection(config);

    // onAddTrack fires for BOTH local and remote track additions in flutter_webrtc.
    // Guard against local stream by comparing stream IDs.
    _pc!.onAddTrack = (stream, track) {
      if (stream.id == _localStream?.id) return; // skip local
      if (_remoteStream != null) return;
      _remoteStream = stream;
      onRemoteStream?.call(stream);
    };

    // onAddStream as secondary fallback (some devices/versions fire this instead).
    _pc!.onAddStream = (stream) {
      if (_remoteStream != null) return;
      _remoteStream = stream;
      onRemoteStream?.call(stream);
    };

    // onTrack as tertiary fallback — keep synchronous to avoid unhandled futures.
    _pc!.onTrack = (event) {
      if (_remoteStream != null) return;
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        onRemoteStream?.call(_remoteStream!);
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

  Future<Map<String, dynamic>> startCall({
    required String targetVirtualId,
    bool isVideo = false,
  }) async {
    _isVideo = isVideo;
    await _createPeerConnection();
    _localStream = isVideo ? await _getLocalVideo() : await _getLocalAudio();
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    final constraints = isVideo
        ? {'offerToReceiveAudio': true, 'offerToReceiveVideo': true}
        : {'offerToReceiveAudio': true};
    final offer = await _pc!.createOffer(constraints);
    await _pc!.setLocalDescription(offer);
    _setState(CallState.calling);

    return {'type': offer.type, 'sdp': offer.sdp};
  }

  Future<Map<String, dynamic>> answerCall({
    required String callId,
    required Map<String, dynamic> offerSdp,
    bool isVideo = false,
  }) async {
    _isVideo = isVideo;
    _activeCallId = callId;
    await _createPeerConnection();
    _localStream = isVideo ? await _getLocalVideo() : await _getLocalAudio();
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    await _pc!.setRemoteDescription(
      RTCSessionDescription(offerSdp['sdp'] as String, offerSdp['type'] as String),
    );
    _hasRemoteDescription = true;

    for (final c in _pendingRemoteCandidates) {
      await _addRemoteCandidate(c);
    }
    _pendingRemoteCandidates.clear();

    final constraints = isVideo
        ? {'offerToReceiveAudio': true, 'offerToReceiveVideo': true}
        : {'offerToReceiveAudio': true};
    final answer = await _pc!.createAnswer(constraints);
    await _pc!.setLocalDescription(answer);
    _callStartTime = DateTime.now();
    _setState(CallState.active);

    return {'type': answer.type, 'sdp': answer.sdp};
  }

  Future<void> toggleCamera() async {
    if (!_isVideo || _localStream == null) return;
    _isFrontCamera = !_isFrontCamera;
    final videoTrack = _localStream!.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      await Helper.switchCamera(videoTrack);
    }
  }

  void setVideoEnabled(bool enabled) {
    _localStream?.getVideoTracks().forEach((t) => t.enabled = enabled);
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

    // ICE candidates sent while callee's socket was dead are lost.
    // Restart ICE so both sides re-gather and exchange fresh candidates.
    _pc?.restartIce();

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
    _isVideo = false;
    _quality = CallQuality.connecting;
    _setState(CallState.ended);
    Future.delayed(const Duration(milliseconds: 300), () => _setState(CallState.idle));
  }

  Future<MediaStream> _getLocalAudio() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw Exception('Microphone permission denied');
    }
    return navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': false,
    });
  }

  Future<MediaStream> _getLocalVideo() async {
    final statuses = await [Permission.microphone, Permission.camera].request();
    if (!statuses[Permission.microphone]!.isGranted) {
      throw Exception('Microphone permission denied');
    }
    if (!statuses[Permission.camera]!.isGranted) {
      throw Exception('Camera permission denied');
    }
    return navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': {'facingMode': 'user', 'width': 640, 'height': 480},
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
