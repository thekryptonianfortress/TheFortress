import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import '../data/local/secure_storage.dart';
import '../services/auth_service.dart';

String? _normalizeAvatarUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  if (url.startsWith('http')) return url;
  return '${AppConstants.serverBaseUrl}$url';
}

class AuthProvider extends ChangeNotifier {
  bool _isAuthenticated = false;
  bool _isLoading = false;
  String? _error;
  String? _userId;
  String? _virtualId;
  String? _username;
  String? _avatarUrl;

  bool get isAuthenticated => _isAuthenticated;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get userId => _userId;
  String? get virtualId => _virtualId;
  String? get username => _username;
  String? get avatarUrl => _avatarUrl;

  Future<void> checkSession() async {
    final session = await SecureStorage.getSession();
    if (session['token'] != null && session['userId'] != null) {
      _userId = session['userId'];
      _virtualId = session['virtualId'];
      _username = session['username'];
      _avatarUrl = session['avatarUrl'];
      _isAuthenticated = true;
      notifyListeners();
      // Refresh profile in background to pick up any server-side changes
      _fetchMeInBackground();
    }
  }

  Future<void> _fetchMeInBackground() async {
    try {
      final token = await SecureStorage.getToken();
      if (token == null) return;
      final res = await http.get(
        Uri.parse('${AppConstants.serverBaseUrl}/users/me'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _username = data['username'] as String?;
        _avatarUrl = _normalizeAvatarUrl(data['avatar_url'] as String?);
        await SecureStorage.saveUsername(_username ?? '');
        await SecureStorage.saveAvatarUrl(_avatarUrl);
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<bool> register(String username, String password) async {
    _setLoading(true);
    try {
      final data = await AuthService.register(username, password);
      _userId = data['user']['id'] as String;
      _virtualId = data['user']['virtual_id'] as String;
      _username = data['user']['username'] as String;
      _avatarUrl = null;
      _isAuthenticated = true;
      _error = null;
      return true;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  Future<bool> login(String virtualId, String password) async {
    _setLoading(true);
    try {
      final data = await AuthService.login(virtualId, password);
      _userId = data['user']['id'] as String;
      _virtualId = data['user']['virtual_id'] as String;
      _username = data['user']['username'] as String;
      _avatarUrl = _normalizeAvatarUrl(data['user']['avatar_url'] as String?);
      _isAuthenticated = true;
      _error = null;
      return true;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Update username and/or avatar. Returns null on success, error string on failure.
  Future<String?> updateProfile({String? username, String? avatarUrl}) async {
    final token = await SecureStorage.getToken();
    if (token == null) return 'Not authenticated';
    try {
      final body = <String, dynamic>{};
      if (username != null) body['username'] = username;
      if (avatarUrl != null) body['avatar_url'] = avatarUrl;

      final res = await http.post(
        Uri.parse('${AppConstants.serverBaseUrl}/auth/update-profile'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _username = data['username'] as String?;
        final returnedUrl = data['avatar_url'] as String?;
        // Only update _avatarUrl if the caller explicitly set one, or explicitly
        // cleared it (empty string). If server returns null and we didn't touch
        // the avatar in this call, preserve the existing value.
        if (avatarUrl != null) {
          _avatarUrl = _normalizeAvatarUrl(returnedUrl);
        } else {
          // Username-only update: trust the server value but normalize it;
          // only overwrite if server returned something non-null.
          if (returnedUrl != null) {
            _avatarUrl = _normalizeAvatarUrl(returnedUrl);
          }
        }
        await SecureStorage.saveUsername(_username ?? '');
        await SecureStorage.saveAvatarUrl(_avatarUrl);
        notifyListeners();
        return null;
      }
      final err = jsonDecode(res.body)['error'] as String? ?? 'Update failed';
      return err;
    } catch (e) {
      return e.toString();
    }
  }

  /// Change password. Returns null on success, error string on failure.
  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final token = await SecureStorage.getToken();
    if (token == null) return 'Not authenticated';
    try {
      final res = await http.post(
        Uri.parse('${AppConstants.serverBaseUrl}/auth/change-password'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'current_password': currentPassword,
          'new_password': newPassword,
        }),
      );
      if (res.statusCode == 200) return null;
      return jsonDecode(res.body)['error'] as String? ?? 'Failed to change password';
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> logout() async {
    await AuthService.logout();
    _isAuthenticated = false;
    _userId = null;
    _virtualId = null;
    _username = null;
    _avatarUrl = null;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void _setLoading(bool v) {
    _isLoading = v;
    notifyListeners();
  }
}
