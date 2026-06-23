import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants.dart';

class SecureStorage {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<void> saveSession({
    required String token,
    required String userId,
    required String virtualId,
    required String username,
    required String privateKey,
    required String publicKey,
    String? avatarUrl,
  }) async {
    await Future.wait([
      _storage.write(key: AppConstants.keyAuthToken, value: token),
      _storage.write(key: AppConstants.keyUserId, value: userId),
      _storage.write(key: AppConstants.keyVirtualId, value: virtualId),
      _storage.write(key: AppConstants.keyUsername, value: username),
      _storage.write(key: AppConstants.keyPrivateKey, value: privateKey),
      _storage.write(key: AppConstants.keyPublicKey, value: publicKey),
      _storage.write(key: 'avatar_url', value: avatarUrl),
    ]);
    // Mirror token + server URL to regular SharedPreferences so native Android
    // code (QuickReplyReceiver) and background Dart isolates can read them.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pager_auth_token', token);
    await prefs.setString('pager_server_url', AppConstants.serverBaseUrl);
  }

  static Future<Map<String, String?>> getSession() async {
    final results = await Future.wait([
      _storage.read(key: AppConstants.keyAuthToken),
      _storage.read(key: AppConstants.keyUserId),
      _storage.read(key: AppConstants.keyVirtualId),
      _storage.read(key: AppConstants.keyUsername),
      _storage.read(key: AppConstants.keyPrivateKey),
      _storage.read(key: AppConstants.keyPublicKey),
      _storage.read(key: 'avatar_url'),
    ]);
    return {
      'token': results[0],
      'userId': results[1],
      'virtualId': results[2],
      'username': results[3],
      'privateKey': results[4],
      'publicKey': results[5],
      'avatarUrl': results[6],
    };
  }

  static Future<String?> getToken() => _storage.read(key: AppConstants.keyAuthToken);
  static Future<String?> getPrivateKey() => _storage.read(key: AppConstants.keyPrivateKey);
  static Future<String?> getPublicKey() => _storage.read(key: AppConstants.keyPublicKey);
  static Future<String?> getUserId() => _storage.read(key: AppConstants.keyUserId);
  static Future<String?> getVirtualId() => _storage.read(key: AppConstants.keyVirtualId);
  static Future<String?> getUsername() => _storage.read(key: AppConstants.keyUsername);
  static Future<String?> getAvatarUrl() => _storage.read(key: 'avatar_url');

  static Future<void> saveAvatarUrl(String? url) =>
      _storage.write(key: 'avatar_url', value: url);
  static Future<void> saveUsername(String username) =>
      _storage.write(key: AppConstants.keyUsername, value: username);

  static Future<void> clearSession() => _storage.deleteAll();
}
