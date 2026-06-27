import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../data/local/secure_storage.dart';

/// LAN peer-to-peer transport for offline messaging and call signaling.
///
/// When the remote server is unreachable, two Pager devices on the same local
/// network can exchange messages and WebRTC call signaling directly via this
/// service — no internet required.
///
/// How it works:
///   1. Each device runs a local WebSocket server on [_port].
///   2. mDNS (via Bonsoir) advertises the device and discovers peers.
///   3. On discovery, a client WebSocket is opened to the peer's server.
///   4. Received events are forwarded via [_inject] callback → wired to
///      SignalingService so CallProvider / MessagesProvider handle them
///      exactly as if they came from the remote Socket.io server.
///
/// Outbound routing (called from SignalingService):
///   - [isReachable] checks if a peer has an active WS connection.
///   - [send] delivers an event packet to a specific peer by virtualId.
///   - [trackCall] / [getPeerForCall] map a callId ↔ peer virtualId so that
///     reply signals (answer, ICE, end) can be routed without knowing the
///     peer's virtualId at every call site.
class LanTransport {
  static final LanTransport instance = LanTransport._();
  LanTransport._();

  static const int _port = 9876;
  static const String _serviceType = '_pager._tcp';
  static const _fgChannel = MethodChannel('com.pager/foreground_service');

  // Keepalive constants
  static const Duration _pingInterval = Duration(seconds: 20);
  static const Duration _pongTimeout = Duration(seconds: 50);
  static const Duration _reconnectDelay = Duration(seconds: 5);

  final _uuid = const Uuid();

  String? _myVirtualId;
  String _myUserId = '';

  /// Called when a LAN event arrives — wired to SignalingService._handleLanEvent.
  void Function(String event, Map<String, dynamic> data)? _inject;

  HttpServer? _server;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  Timer? _heartbeatTimer;

  // virtualId → active WebSocket
  final Map<String, WebSocket> _peers = {};

  // virtualId → last pong received time (for heartbeat timeout detection)
  final Map<String, DateTime> _lastPong = {};

  // virtualId → resolved service (for auto-reconnect)
  final Map<String, ResolvedBonsoirService> _knownServices = {};

  // virtualId → pending reconnect timer
  final Map<String, Timer> _reconnectTimers = {};

  // callId → peer virtualId (for routing reply signals)
  final Map<String, String> _callPeerMap = {};

  // peer userId → peer virtualId (for routing read receipts)
  final Map<String, String> _userToVId = {};

  final _reachableController = StreamController<Set<String>>.broadcast();

  /// Emits the updated set of reachable virtualIds on every peer connect/disconnect.
  Stream<Set<String>> get reachableStream => _reachableController.stream;

  Set<String> get reachablePeers => Set.unmodifiable(_peers.keys);
  String get myUserId => _myUserId;
  String? getVirtualIdForUser(String userId) => _userToVId[userId];

  bool isReachable(String virtualId) {
    final ws = _peers[virtualId];
    if (ws == null) return false;
    if (ws.readyState != WebSocket.open) {
      _peers.remove(virtualId);
      return false;
    }
    return true;
  }

  // ── Startup ───────────────────────────────────────────────────

  /// Set the callback that receives raw LAN events.
  /// Must be called before [start] so no events are dropped.
  void setInjectCallback(
      void Function(String event, Map<String, dynamic> data) fn) {
    _inject = fn;
  }

  Future<void> start(String virtualId) async {
    if (_myVirtualId != null) return; // already running
    _myVirtualId = virtualId;
    _myUserId = await SecureStorage.getUserId() ?? '';
    await _startServer();
    await _startAdvertising();
    await _startDiscovery();
    _startHeartbeat();
    await _startForegroundService();
  }

  // ── Keepalive heartbeat ───────────────────────────────────────

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_pingInterval, (_) {
      final now = DateTime.now();
      for (final entry in _peers.entries.toList()) {
        final vid = entry.key;
        final ws = entry.value;
        if (ws.readyState != WebSocket.open) {
          _dropPeer(vid);
          continue;
        }
        final last = _lastPong[vid];
        if (last != null && now.difference(last) > _pongTimeout) {
          dev.log('[LAN] Peer $vid timed out — dropping');
          ws.close().ignore();
          _dropPeer(vid);
          continue;
        }
        try {
          ws.add(jsonEncode({'type': 'ping'}));
        } catch (_) {
          _dropPeer(vid);
        }
      }
    });
  }

  // ── WebSocket server ──────────────────────────────────────────

  Future<void> _startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      dev.log('[LAN] Server listening on :$_port');
      _server!.transform(WebSocketTransformer()).listen(
        _handleInboundConnection,
        onError: (e) => dev.log('[LAN] Server error: $e'),
      );
    } catch (e) {
      dev.log('[LAN] Server bind failed (port $_port may be in use): $e');
    }
  }

  void _handleInboundConnection(WebSocket ws) {
    String? peerVId;
    ws.listen(
      (raw) {
        if (raw is! String) return;
        try {
          final msg = jsonDecode(raw) as Map<String, dynamic>;
          final type = msg['type'] as String? ?? '';
          if (type == 'hello') {
            peerVId = msg['virtual_id'] as String;
            // Echo our identity back
            ws.add(jsonEncode({'type': 'hello', 'virtual_id': _myVirtualId}));
            _peers[peerVId!] = ws;
            _lastPong[peerVId!] = DateTime.now();
            _notifyReachable();
            dev.log('[LAN] Peer connected (inbound): $peerVId');
          } else if (type == 'ping' && peerVId != null) {
            ws.add(jsonEncode({'type': 'pong'}));
          } else if (type == 'pong' && peerVId != null) {
            _lastPong[peerVId!] = DateTime.now();
          } else if (type == 'event' && peerVId != null) {
            _onLanEvent(
              fromVId: peerVId!,
              event: msg['event'] as String,
              data: Map<String, dynamic>.from(msg['data'] as Map),
            );
          }
        } catch (e) {
          dev.log('[LAN] Inbound parse error: $e');
        }
      },
      onDone: () => _dropPeer(peerVId),
      onError: (_) => _dropPeer(peerVId),
    );
  }

  // ── mDNS advertising ──────────────────────────────────────────

  Future<void> _startAdvertising() async {
    try {
      final svc = BonsoirService(
        name: _myVirtualId!,
        type: _serviceType,
        port: _port,
      );
      _broadcast = BonsoirBroadcast(service: svc);
      await _broadcast!.ready;
      await _broadcast!.start();
      dev.log('[LAN] Advertising as $_myVirtualId');
    } catch (e) {
      dev.log('[LAN] mDNS advertise failed: $e');
    }
  }

  // ── mDNS discovery ────────────────────────────────────────────

  Future<void> _startDiscovery() async {
    try {
      _discovery = BonsoirDiscovery(type: _serviceType);
      await _discovery!.ready;
      _discovery!.eventStream!.listen((event) {
        switch (event.type) {
          case BonsoirDiscoveryEventType.discoveryServiceFound:
            try {
              event.service?.resolve(_discovery!.serviceResolver);
            } catch (_) {}
          case BonsoirDiscoveryEventType.discoveryServiceResolved:
            final svc = event.service as ResolvedBonsoirService?;
            if (svc != null) _connectToPeer(svc);
          case BonsoirDiscoveryEventType.discoveryServiceLost:
            final vid = event.service?.name;
            if (vid != null && vid != _myVirtualId) _dropPeer(vid);
          default:
            break;
        }
      });
      await _discovery!.start();
      dev.log('[LAN] mDNS discovery started');
    } catch (e) {
      dev.log('[LAN] mDNS discovery failed: $e');
    }
  }

  Future<void> _connectToPeer(ResolvedBonsoirService svc) async {
    final peerVId = svc.name;
    if (peerVId == _myVirtualId) return; // skip self
    if (isReachable(peerVId)) return; // already connected

    // Cache address for auto-reconnect
    _knownServices[peerVId] = svc;

    final host = svc.host;
    if (host == null) return;
    dev.log('[LAN] Connecting to $peerVId @ $host:${svc.port}');

    try {
      final ws = await WebSocket.connect('ws://$host:${svc.port}')
          .timeout(const Duration(seconds: 5));

      // Identify ourselves
      ws.add(jsonEncode({'type': 'hello', 'virtual_id': _myVirtualId}));
      _peers[peerVId] = ws;
      _lastPong[peerVId] = DateTime.now();
      _notifyReachable();
      dev.log('[LAN] Connected (outbound) to $peerVId');

      ws.listen(
        (raw) {
          if (raw is! String) return;
          try {
            final msg = jsonDecode(raw) as Map<String, dynamic>;
            final type = msg['type'] as String? ?? '';
            if (type == 'ping') {
              ws.add(jsonEncode({'type': 'pong'}));
            } else if (type == 'pong') {
              _lastPong[peerVId] = DateTime.now();
            } else if (type == 'event') {
              _onLanEvent(
                fromVId: peerVId,
                event: msg['event'] as String,
                data: Map<String, dynamic>.from(msg['data'] as Map),
              );
            }
            // Ignore hello echo from server-side
          } catch (e) {
            dev.log('[LAN] Outbound parse error from $peerVId: $e');
          }
        },
        onDone: () => _dropPeer(peerVId),
        onError: (_) => _dropPeer(peerVId),
      );
    } catch (e) {
      dev.log('[LAN] Connect to $peerVId failed: $e');
    }
  }

  // ── Auto-reconnect ────────────────────────────────────────────

  void _scheduleReconnect(String virtualId) {
    if (_myVirtualId == null) return; // stopped
    if (_reconnectTimers.containsKey(virtualId)) return; // already scheduled
    final svc = _knownServices[virtualId];
    if (svc == null) return; // no known address
    dev.log('[LAN] Scheduling reconnect to $virtualId in ${_reconnectDelay.inSeconds}s');
    _reconnectTimers[virtualId] = Timer(_reconnectDelay, () {
      _reconnectTimers.remove(virtualId);
      if (_myVirtualId == null) return;
      if (isReachable(virtualId)) return; // reconnected via mDNS already
      _connectToPeer(svc);
    });
  }

  // ── Incoming event handling ───────────────────────────────────

  void _onLanEvent({
    required String fromVId,
    required String event,
    required Map<String, dynamic> data,
  }) {
    dev.log('[LAN] ← $event from $fromVId');

    // Track callId → sender virtualId for return-path routing
    final callId = data['call_id'] as String?;
    if (callId != null) _callPeerMap[callId] = fromVId;

    if (event == 'new-message') {
      final msgId = data['message_id'] as String?;
      final senderId = data['sender_id'] as String?;
      final senderVId = data['sender_virtual_id'] as String?;

      // Cache userId → virtualId so read receipts can be routed by userId
      if (senderId != null && senderVId != null) {
        _userToVId[senderId] = senderVId;
      }

      // Acknowledge delivery so the sender's tick updates.
      // recipient_id must be OUR userId (the message recipient) so the sender's
      // MessagesProvider can find the message in _chats[recipientId].
      if (msgId != null && senderId != null) {
        send(fromVId, 'message-ack', {
          'message_id': msgId,
          'recipient_id': _myUserId,
          'status': 'delivered',
        });
      }
    }

    _inject?.call(event, data);
  }

  // ── Outbound ──────────────────────────────────────────────────

  bool send(String virtualId, String event, Map<String, dynamic> data) {
    final ws = _peers[virtualId];
    if (ws == null || ws.readyState != WebSocket.open) {
      _peers.remove(virtualId);
      return false;
    }
    try {
      ws.add(jsonEncode({'type': 'event', 'event': event, 'data': data}));
      dev.log('[LAN] → $event to $virtualId');
      return true;
    } catch (_) {
      _peers.remove(virtualId);
      return false;
    }
  }

  String generateCallId() => _uuid.v4();

  void trackCall(String callId, String peerVId) =>
      _callPeerMap[callId] = peerVId;

  String? getPeerForCall(String callId) => _callPeerMap[callId];

  void clearCall(String callId) => _callPeerMap.remove(callId);

  void _notifyReachable() {
    if (!_reachableController.isClosed) {
      _reachableController.add(Set.unmodifiable(_peers.keys));
    }
  }

  void _dropPeer(String? virtualId) {
    if (virtualId == null) return;
    _peers.remove(virtualId);
    _lastPong.remove(virtualId);
    _notifyReachable();
    dev.log('[LAN] Peer dropped: $virtualId');
    _scheduleReconnect(virtualId);
  }

  // ── Foreground service ────────────────────────────────────────

  Future<void> _startForegroundService() async {
    try {
      await _fgChannel.invokeMethod<void>('start');
    } catch (e) {
      dev.log('[LAN] Foreground service start failed: $e');
    }
  }

  Future<void> _stopForegroundService() async {
    try {
      await _fgChannel.invokeMethod<void>('stop');
    } catch (e) {
      dev.log('[LAN] Foreground service stop failed: $e');
    }
  }

  Future<void> stop() async {
    _myVirtualId = null;
    _myUserId = '';
    _inject = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    for (final t in _reconnectTimers.values) {
      t.cancel();
    }
    _reconnectTimers.clear();
    try { await _broadcast?.stop(); } catch (_) {}
    try { await _discovery?.stop(); } catch (_) {}
    try { await _server?.close(force: true); } catch (_) {}
    for (final ws in _peers.values) {
      try { await ws.close(); } catch (_) {}
    }
    _peers.clear();
    _lastPong.clear();
    _knownServices.clear();
    _callPeerMap.clear();
    _userToVId.clear();
    _broadcast = null;
    _discovery = null;
    _server = null;
    await _stopForegroundService();
  }
}
