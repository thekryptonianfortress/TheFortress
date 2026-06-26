import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MediaType { photos, audio, videos, files }

extension MediaTypeExt on MediaType {
  String get label => switch (this) {
        MediaType.photos => 'Photos',
        MediaType.audio => 'Audio',
        MediaType.videos => 'Videos',
        MediaType.files => 'Files',
      };

  int get bit => switch (this) {
        MediaType.photos => 0x1,
        MediaType.audio => 0x2,
        MediaType.videos => 0x4,
        MediaType.files => 0x8,
      };
}

class AutoDownloadProvider extends ChangeNotifier {
  static const _networkChannel = MethodChannel('pager/network_info');

  static const _keyWifi = 'auto_dl_wifi';
  static const _keyMobile = 'auto_dl_mobile';
  static const _keyRoaming = 'auto_dl_roaming';
  static const _keyDataUsed = 'data_usage_bytes';
  static const _keyDataReset = 'data_usage_reset_date';

  ConnectivityResult _connectivity = ConnectivityResult.none;
  bool _isRoaming = false;

  // Per-connection type sets — defaults match WhatsApp conventions
  Set<MediaType> _wifiTypes = {MediaType.photos, MediaType.audio, MediaType.videos, MediaType.files};
  Set<MediaType> _mobileTypes = {MediaType.photos};
  Set<MediaType> _roamingTypes = {};

  int _bytesUsed = 0;
  DateTime _usageResetDate = DateTime.now();

  StreamSubscription<List<ConnectivityResult>>? _sub;

  ConnectivityResult get connectivity => _connectivity;
  bool get isRoaming => _isRoaming;
  bool get isOnline => _connectivity != ConnectivityResult.none;
  Set<MediaType> get wifiTypes => _wifiTypes;
  Set<MediaType> get mobileTypes => _mobileTypes;
  Set<MediaType> get roamingTypes => _roamingTypes;
  int get bytesUsed => _bytesUsed;
  DateTime get usageResetDate => _usageResetDate;

  AutoDownloadProvider() {
    _init();
  }

  Future<void> _init() async {
    await _loadPrefs();
    final results = await Connectivity().checkConnectivity();
    await _applyResults(results);
    _sub = Connectivity().onConnectivityChanged.listen(_applyResults);
  }

  Future<void> _applyResults(List<ConnectivityResult> results) async {
    _connectivity = results.isNotEmpty ? results.first : ConnectivityResult.none;
    if (_connectivity == ConnectivityResult.mobile) {
      _isRoaming = await _checkRoaming();
    } else {
      _isRoaming = false;
    }
    notifyListeners();
  }

  Future<bool> _checkRoaming() async {
    try {
      return await _networkChannel.invokeMethod<bool>('isRoaming') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the given media type should be auto-downloaded on the current connection.
  bool shouldAutoDownload(MediaType type) {
    if (_connectivity == ConnectivityResult.none) return false;
    if (_connectivity == ConnectivityResult.wifi) return _wifiTypes.contains(type);
    if (_isRoaming) return _roamingTypes.contains(type);
    return _mobileTypes.contains(type);
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _wifiTypes = _fromBits(prefs.getInt(_keyWifi) ?? 0xF);
    _mobileTypes = _fromBits(prefs.getInt(_keyMobile) ?? 0x1);
    _roamingTypes = _fromBits(prefs.getInt(_keyRoaming) ?? 0x0);
    _bytesUsed = prefs.getInt(_keyDataUsed) ?? 0;
    final resetStr = prefs.getString(_keyDataReset);
    _usageResetDate = resetStr != null ? DateTime.tryParse(resetStr) ?? DateTime.now() : DateTime.now();
    notifyListeners();
  }

  Future<void> setTypes(String connection, Set<MediaType> types) async {
    switch (connection) {
      case 'wifi':
        _wifiTypes = types;
      case 'mobile':
        _mobileTypes = types;
      case 'roaming':
        _roamingTypes = types;
    }
    final prefs = await SharedPreferences.getInstance();
    final key = connection == 'wifi' ? _keyWifi : connection == 'mobile' ? _keyMobile : _keyRoaming;
    await prefs.setInt(key, _toBits(types));
    notifyListeners();
  }

  /// Call this whenever media bytes are downloaded so usage stats stay current.
  Future<void> recordBytesDownloaded(int bytes) async {
    _bytesUsed += bytes;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyDataUsed, _bytesUsed);
    notifyListeners();
  }

  Future<void> resetDataUsage() async {
    _bytesUsed = 0;
    _usageResetDate = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyDataUsed, 0);
    await prefs.setString(_keyDataReset, _usageResetDate.toIso8601String());
    notifyListeners();
  }

  Set<MediaType> _fromBits(int bits) => {
        for (final t in MediaType.values)
          if (bits & t.bit != 0) t,
      };

  int _toBits(Set<MediaType> types) =>
      types.fold(0, (acc, t) => acc | t.bit);

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
