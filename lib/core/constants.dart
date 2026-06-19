class AppConstants {
  static const String appName = 'Pager';
  static const String virtualIdPrefix = 'PGR';

  // Backend URLs — override with --dart-define=SERVER_URL=http://10.0.2.2:3000 for emulator
  static const String serverBaseUrl =
      String.fromEnvironment('SERVER_URL', defaultValue: 'http://10.152.224.130:3000');
  static const String wsUrl =
      String.fromEnvironment('SERVER_URL', defaultValue: 'http://10.152.224.130:3000');

  // STUN/TURN
  static const List<Map<String, dynamic>> defaultIceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];

  // TURN credentials are fetched from server and cached locally
  static const String iceServersCacheKey = 'cached_ice_servers';
  static const String iceServersCacheExpiryKey = 'cached_ice_servers_expiry';

  // mDNS service type for LAN discovery
  static const String mdnsServiceType = '_pager._tcp';
  static const int mdnsPort = 5353;
  static const int lanSignalingPort = 9876;

  // Local DB
  static const String dbName = 'pager.db';
  static const int dbVersion = 1;

  // Secure storage keys
  static const String keyPrivateKey = 'private_key';
  static const String keyPublicKey = 'public_key';
  static const String keyAuthToken = 'auth_token';
  static const String keyVirtualId = 'virtual_id';
  static const String keyUserId = 'user_id';
  static const String keyUsername = 'username';
}
