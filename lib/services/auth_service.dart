import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import '../core/crypto_utils.dart';
import '../data/local/secure_storage.dart';

class AuthService {
  static final _base = AppConstants.serverBaseUrl;

  /// Register a new account. Phone number becomes the virtual ID.
  static Future<Map<String, dynamic>> register(
      String username, String password, String phoneNumber) async {
    final keypair = await CryptoUtils.generateKeypair();

    final res = await http.post(
      Uri.parse('$_base/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
        'public_key': keypair['publicKey'],
        'phone_number': phoneNumber,
      }),
    ).timeout(const Duration(seconds: 15), onTimeout: () {
      throw Exception('Connection timed out. Check your network.');
    });

    if (res.statusCode != 201) {
      final body = jsonDecode(res.body);
      throw Exception(body['error'] ?? 'Registration failed');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    await SecureStorage.saveSession(
      token: data['token'] as String,
      userId: data['user']['id'] as String,
      virtualId: data['user']['virtual_id'] as String,
      username: data['user']['username'] as String,
      privateKey: keypair['privateKey']!,
      publicKey: keypair['publicKey']!,
      phoneNumber: data['user']['phone_number'] as String?,
    );
    return data;
  }

  /// Link a phone number to an existing account.
  /// Updates virtual_id to the phone number on the server and persists locally.
  static Future<Map<String, dynamic>> linkPhoneNumber(String phoneNumber) async {
    final token = await SecureStorage.getToken();
    if (token == null) throw Exception('Not authenticated');

    final res = await http.post(
      Uri.parse('$_base/users/phone'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'phone_number': phoneNumber}),
    ).timeout(const Duration(seconds: 15), onTimeout: () {
      throw Exception('Connection timed out. Check your network.');
    });

    if (res.statusCode != 200) {
      final body = jsonDecode(res.body);
      throw Exception(body['error'] ?? 'Failed to update phone number');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    await SecureStorage.savePhoneNumber(data['phone_number'] as String?);
    await SecureStorage.saveSession(
      token: token,
      userId: data['id'] as String,
      virtualId: data['virtual_id'] as String,
      username: data['username'] as String,
      privateKey: await SecureStorage.getPrivateKey() ?? '',
      publicKey: await SecureStorage.getPublicKey() ?? '',
      avatarUrl: data['avatar_url'] as String?,
      phoneNumber: data['phone_number'] as String?,
    );
    return data;
  }

  /// Login with virtual ID and password.
  static Future<Map<String, dynamic>> login(String virtualId, String password) async {
    final res = await http.post(
      Uri.parse('$_base/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'virtual_id': virtualId, 'password': password}),
    ).timeout(const Duration(seconds: 15), onTimeout: () {
      throw Exception('Connection timed out. Check your network.');
    });

    if (res.statusCode != 200) {
      final body = jsonDecode(res.body);
      throw Exception(body['error'] ?? 'Login failed');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final token = data['token'] as String;

    // Restore existing keypair, or generate a new one if lost (e.g. fresh install)
    final existing = await SecureStorage.getSession();
    String privateKey = existing['privateKey'] ?? '';
    String publicKey = data['user']['public_key'] as String;

    if (privateKey.isEmpty) {
      // Keys were lost — generate a new pair and update the server
      final keypair = await CryptoUtils.generateKeypair();
      privateKey = keypair['privateKey']!;
      publicKey = keypair['publicKey']!;
      await http.put(
        Uri.parse('$_base/users/public-key'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'public_key': publicKey}),
      );
    }

    await SecureStorage.saveSession(
      token: token,
      userId: data['user']['id'] as String,
      virtualId: data['user']['virtual_id'] as String,
      username: data['user']['username'] as String,
      privateKey: privateKey,
      publicKey: publicKey,
      avatarUrl: data['user']['avatar_url'] as String?,
    );
    return data;
  }

  /// Update FCM token on server so push notifications reach this device.
  static Future<void> updateFcmToken(String fcmToken) async {
    final token = await SecureStorage.getToken();
    if (token == null) return;
    await http.put(
      Uri.parse('$_base/auth/fcm-token'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'fcm_token': fcmToken}),
    );
  }

  static Future<void> logout() async {
    await SecureStorage.clearSession();
  }
}
