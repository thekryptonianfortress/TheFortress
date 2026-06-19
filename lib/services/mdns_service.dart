import 'dart:async';
import 'package:multicast_dns/multicast_dns.dart';
import '../core/constants.dart';

/// Discovers peers on the same LAN for offline (no-internet) calls.
/// Uses mDNS (multicast DNS) to advertise presence and find other Pager users.
class MdnsService {
  MDnsClient? _client;
  final _peers = <String, Map<String, dynamic>>{};
  final _peersController = StreamController<Map<String, Map<String, dynamic>>>.broadcast();

  Stream<Map<String, Map<String, dynamic>>> get peersStream => _peersController.stream;
  Map<String, Map<String, dynamic>> get peers => Map.unmodifiable(_peers);

  /// Start advertising this device and scanning for peers.
  Future<void> start(String virtualId, String username) async {
    _client = MDnsClient();
    await _client!.start();
    _scan();
  }

  void _scan() async {
    if (_client == null) return;
    try {
      await for (final PtrResourceRecord ptr in _client!.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(AppConstants.mdnsServiceType),
      )) {
        await for (final SrvResourceRecord srv in _client!.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
        )) {
          await for (final IPAddressResourceRecord ip in _client!.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
          )) {
            final virtualId = ptr.domainName.split('.').first;
            _peers[virtualId] = {
              'virtual_id': virtualId,
              'host': ip.address.address,
              'port': srv.port,
            };
            _peersController.add(Map.unmodifiable(_peers));
          }
        }
      }
    } catch (_) {
      // mDNS not available — ignore
    }
  }

  bool isPeerReachable(String virtualId) => _peers.containsKey(virtualId);

  Map<String, dynamic>? getPeerInfo(String virtualId) => _peers[virtualId];

  void stop() {
    _client?.stop();
    _client = null;
    _peers.clear();
  }

  void dispose() {
    stop();
    _peersController.close();
  }
}
