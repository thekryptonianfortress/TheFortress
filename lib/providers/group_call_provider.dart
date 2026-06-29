import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/local/secure_storage.dart';
import '../services/signaling_service.dart';

class GroupCallParticipant {
  final String virtualId;
  final String username;
  final RTCVideoRenderer renderer;
  bool hasVideo;

  GroupCallParticipant({
    required this.virtualId,
    required this.username,
    required this.renderer,
    this.hasVideo = false,
  });
}

class _GroupPeer {
  final String virtualId;
  final String username;
  final String connId;
  RTCPeerConnection? pc;
  MediaStream? remoteStream;
  final RTCVideoRenderer renderer = RTCVideoRenderer();
  bool hasRemoteDescription = false;
  final List<Map<String, dynamic>> pendingCandidates = [];

  _GroupPeer({required this.virtualId, required this.username, required this.connId});

  Future<void> init() => renderer.initialize();

  void dispose() {
    try {
      remoteStream?.getTracks().forEach((t) => t.stop());
      pc?.close();
      renderer.dispose();
    } catch (_) {}
  }
}

class GroupCallProvider extends ChangeNotifier {
  final SignalingService _signaling;
  StreamSubscription<SignalingMessage>? _sigSub;

  String? _groupId;
  String? _groupName;
  bool _isVideo = false;
  bool _inCall = false;
  bool _isMuted = false;
  bool _isCameraOn = true;

  MediaStream? _localStream;
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  bool _localRendererInit = false;

  final Map<String, _GroupPeer> _peers = {};

  String? _myVirtualId;
  String? _myUsername;

  // Incoming group call info
  String? incomingGroupId;
  String? incomingGroupName;
  bool incomingIsVideo = false;
  String? incomingCallerName;

  bool get inCall => _inCall;
  bool get isMuted => _isMuted;
  bool get isCameraOn => _isCameraOn;
  bool get isVideo => _isVideo;
  String? get groupId => _groupId;
  String? get groupName => _groupName;
  bool get hasIncomingGroupCall => incomingGroupId != null && !_inCall;

  List<GroupCallParticipant> get participants => _peers.values.map((p) => GroupCallParticipant(
    virtualId: p.virtualId,
    username: p.username,
    renderer: p.renderer,
    hasVideo: p.remoteStream?.getVideoTracks().isNotEmpty == true,
  )).toList();

  GroupCallProvider(this._signaling) {
    _listenSignaling();
  }

  void _listenSignaling() {
    _sigSub = _signaling.stream.listen((msg) async {
      try {
        switch (msg.event) {
          case SignalingEvent.groupCallIncoming:
            _handleGroupCallIncoming(msg.data);
          case SignalingEvent.groupCallJoined:
            await _handleGroupCallJoined(msg.data);
          case SignalingEvent.groupCallMemberJoined:
            // UI update only — the newcomer initiates the offer to us
            notifyListeners();
          case SignalingEvent.groupCallMemberLeft:
            final vId = msg.data['virtual_id'] as String?;
            if (vId != null && _inCall) await _removePeer(vId);
          case SignalingEvent.gcIncomingOffer:
            await _handleGcOffer(msg.data);
          case SignalingEvent.gcCallAnswered:
            await _handleGcAnswer(msg.data);
          case SignalingEvent.gcIceCandidate:
            await _handleGcIce(msg.data);
          case SignalingEvent.gcPeerEnded:
            final vId = msg.data['from_virtual_id'] as String?;
            if (vId != null && _inCall) await _removePeer(vId);
          default:
            break;
        }
      } catch (e, st) {
        dev.log('[GroupCallProvider] error ${msg.event}: $e\n$st');
      }
    });
  }

  void _handleGroupCallIncoming(Map<String, dynamic> data) {
    if (_inCall) return;
    incomingGroupId = data['group_id'] as String?;
    incomingGroupName = data['group_name'] as String?;
    incomingIsVideo = data['is_video'] as bool? ?? false;
    incomingCallerName = data['caller_username'] as String?;
    notifyListeners();
  }

  Future<void> startCall({
    required String groupId,
    required String groupName,
    required bool isVideo,
  }) async {
    _myVirtualId = await SecureStorage.getVirtualId();
    _myUsername = await SecureStorage.getUsername();
    if (_myVirtualId == null || _myUsername == null) return;

    _groupId = groupId;
    _groupName = groupName;
    _isVideo = isVideo;
    _inCall = true;
    incomingGroupId = null;

    await _initLocalStream();
    _signaling.sendGroupCallStart(groupId, isVideo, _myVirtualId!, _myUsername!);
    notifyListeners();
  }

  Future<void> joinCall({
    required String groupId,
    required String groupName,
    required bool isVideo,
  }) async {
    _myVirtualId = await SecureStorage.getVirtualId();
    _myUsername = await SecureStorage.getUsername();
    if (_myVirtualId == null || _myUsername == null) return;

    _groupId = groupId;
    _groupName = groupName;
    _isVideo = isVideo;
    _inCall = true;
    incomingGroupId = null;

    await _initLocalStream();
    _signaling.sendGroupCallJoin(groupId, _myVirtualId!, _myUsername!);
    notifyListeners();
  }

  void declineGroupCall() {
    incomingGroupId = null;
    incomingGroupName = null;
    notifyListeners();
  }

  Future<void> _initLocalStream() async {
    if (!_localRendererInit) {
      await localRenderer.initialize();
      _localRendererInit = true;
    }
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true},
      'video': _isVideo ? {'facingMode': 'user', 'width': 640, 'height': 480} : false,
    });
    if (_isVideo) localRenderer.srcObject = _localStream;
  }

  Future<void> _handleGroupCallJoined(Map<String, dynamic> data) async {
    final participants = (data['participants'] as List?)
        ?.map((e) => Map<String, dynamic>.from(e as Map))
        .toList() ?? [];
    // Initiate offers to each existing participant
    for (final p in participants) {
      final vId = p['virtual_id'] as String?;
      final uname = p['username'] as String? ?? vId ?? '';
      if (vId != null && vId != _myVirtualId) {
        await _initiateOfferTo(vId, uname);
      }
    }
    notifyListeners();
  }

  Future<void> _initiateOfferTo(String targetVirtualId, String username) async {
    if (_peers.containsKey(targetVirtualId)) return;
    final connId = '${DateTime.now().millisecondsSinceEpoch}_${_peers.length}';
    final peer = _GroupPeer(virtualId: targetVirtualId, username: username, connId: connId);
    await peer.init();
    _peers[targetVirtualId] = peer;

    peer.pc = await _createPeerConnection(peer);

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await peer.pc!.addTrack(track, _localStream!);
      }
    }

    final constraints = _isVideo
        ? {'offerToReceiveAudio': true, 'offerToReceiveVideo': true}
        : {'offerToReceiveAudio': true};
    final offer = await peer.pc!.createOffer(constraints);
    await peer.pc!.setLocalDescription(offer);

    _signaling.sendGcOffer(
      targetVirtualId: targetVirtualId,
      sdp: {'type': offer.type!, 'sdp': offer.sdp!},
      fromVirtualId: _myVirtualId!,
      fromUsername: _myUsername!,
      groupId: _groupId!,
      connId: connId,
      isVideo: _isVideo,
    );
    notifyListeners();
  }

  Future<void> _handleGcOffer(Map<String, dynamic> data) async {
    if (!_inCall) return;
    final fromVId = data['from_virtual_id'] as String?;
    final fromUsername = data['from_username'] as String?;
    final sdpMap = data['sdp'] as Map?;
    final connId = data['conn_id'] as String?;

    if (fromVId == null || sdpMap == null || connId == null) return;

    _GroupPeer? peer = _peers[fromVId];
    if (peer == null) {
      peer = _GroupPeer(
        virtualId: fromVId,
        username: fromUsername ?? fromVId,
        connId: connId,
      );
      await peer.init();
      _peers[fromVId] = peer;
    }

    peer.pc = await _createPeerConnection(peer);

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await peer.pc!.addTrack(track, _localStream!);
      }
    }

    await peer.pc!.setRemoteDescription(
      RTCSessionDescription(sdpMap['sdp'] as String, sdpMap['type'] as String),
    );
    peer.hasRemoteDescription = true;

    for (final c in peer.pendingCandidates) {
      try {
        await peer.pc!.addCandidate(RTCIceCandidate(
          c['candidate'] as String, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?));
      } catch (_) {}
    }
    peer.pendingCandidates.clear();

    final constraints = _isVideo
        ? {'offerToReceiveAudio': true, 'offerToReceiveVideo': true}
        : {'offerToReceiveAudio': true};
    final answer = await peer.pc!.createAnswer(constraints);
    await peer.pc!.setLocalDescription(answer);

    _signaling.sendGcAnswer(
      targetVirtualId: fromVId,
      sdp: {'type': answer.type!, 'sdp': answer.sdp!},
      connId: connId,
    );
    notifyListeners();
  }

  Future<void> _handleGcAnswer(Map<String, dynamic> data) async {
    final fromVId = data['from_virtual_id'] as String?;
    final sdpMap = data['sdp'] as Map?;
    if (fromVId == null || sdpMap == null) return;

    final peer = _peers[fromVId];
    if (peer?.pc == null) return;

    await peer!.pc!.setRemoteDescription(
      RTCSessionDescription(sdpMap['sdp'] as String, sdpMap['type'] as String),
    );
    peer.hasRemoteDescription = true;

    for (final c in peer.pendingCandidates) {
      try {
        await peer.pc!.addCandidate(RTCIceCandidate(
          c['candidate'] as String, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?));
      } catch (_) {}
    }
    peer.pendingCandidates.clear();
    notifyListeners();
  }

  Future<void> _handleGcIce(Map<String, dynamic> data) async {
    final fromVId = data['from_virtual_id'] as String?;
    final candidate = data['candidate'] as Map?;
    if (fromVId == null || candidate == null) return;

    final peer = _peers[fromVId];
    if (peer == null) return;

    final candidateMap = Map<String, dynamic>.from(candidate);
    if (!peer.hasRemoteDescription || peer.pc == null) {
      peer.pendingCandidates.add(candidateMap);
      return;
    }
    try {
      await peer.pc!.addCandidate(RTCIceCandidate(
        candidateMap['candidate'] as String,
        candidateMap['sdpMid'] as String?,
        candidateMap['sdpMLineIndex'] as int?,
      ));
    } catch (_) {}
  }

  Future<void> _removePeer(String virtualId) async {
    final peer = _peers.remove(virtualId);
    peer?.dispose();
    notifyListeners();
  }

  Future<RTCPeerConnection> _createPeerConnection(_GroupPeer peer) async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': 'all',
    });

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        peer.remoteStream = event.streams.first;
        peer.renderer.srcObject = event.streams.first;
        notifyListeners();
      }
    };

    pc.onIceCandidate = (candidate) {
      _signaling.sendGcIce(
        targetVirtualId: peer.virtualId,
        candidate: candidate.toMap(),
        connId: peer.connId,
      );
    };

    return pc;
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !_isMuted);
    notifyListeners();
  }

  void toggleCamera() {
    if (!_isVideo) return;
    _isCameraOn = !_isCameraOn;
    _localStream?.getVideoTracks().forEach((t) => t.enabled = _isCameraOn);
    notifyListeners();
  }

  Future<void> leaveCall() async {
    if (!_inCall) return;
    if (_groupId != null && _myVirtualId != null) {
      _signaling.sendGroupCallLeave(_groupId!, _myVirtualId!);
      for (final peer in _peers.values) {
        _signaling.sendGcPeerEnd(targetVirtualId: peer.virtualId);
      }
    }
    for (final peer in _peers.values) {
      peer.dispose();
    }
    _peers.clear();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    if (_localRendererInit) localRenderer.srcObject = null;

    _inCall = false;
    _groupId = null;
    _groupName = null;
    _isMuted = false;
    _isCameraOn = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _sigSub?.cancel();
    for (final peer in _peers.values) { peer.dispose(); }
    if (_localRendererInit) localRenderer.dispose();
    _localStream?.getTracks().forEach((t) => t.stop());
    super.dispose();
  }
}
