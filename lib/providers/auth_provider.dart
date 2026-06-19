import 'package:flutter/foundation.dart';
import '../data/local/secure_storage.dart';
import '../services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  bool _isAuthenticated = false;
  bool _isLoading = false;
  String? _error;
  String? _userId;
  String? _virtualId;
  String? _username;

  bool get isAuthenticated => _isAuthenticated;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get userId => _userId;
  String? get virtualId => _virtualId;
  String? get username => _username;

  Future<void> checkSession() async {
    final session = await SecureStorage.getSession();
    if (session['token'] != null && session['userId'] != null) {
      _userId = session['userId'];
      _virtualId = session['virtualId'];
      _username = session['username'];
      _isAuthenticated = true;
      notifyListeners();
    }
  }

  Future<bool> register(String username, String password) async {
    _setLoading(true);
    try {
      final data = await AuthService.register(username, password);
      _userId = data['user']['id'] as String;
      _virtualId = data['user']['virtual_id'] as String;
      _username = data['user']['username'] as String;
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

  Future<void> logout() async {
    await AuthService.logout();
    _isAuthenticated = false;
    _userId = null;
    _virtualId = null;
    _username = null;
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
