import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../../core/constants.dart';
import '../../core/crypto_utils.dart';
import '../../data/local/secure_storage.dart';
import '../../providers/auth_provider.dart';
import '../../services/auth_service.dart';
import '../../services/notification_service.dart';
import '../../services/signaling_service.dart';
import '../../core/theme.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  /// Ensures the stored private key is valid (32 bytes). If not, regenerates
  /// the keypair and pushes the new public key to the server so E2E crypto works.
  Future<void> _ensureValidKeypair() async {
    try {
      final token = await SecureStorage.getToken();
      if (token == null) return;
      final privateKey = await SecureStorage.getPrivateKey() ?? '';
      // X25519 private key must be exactly 32 bytes when base64-decoded
      final isValid = privateKey.isNotEmpty && base64Decode(privateKey).length == 32;
      if (isValid) return;

      final keypair = await CryptoUtils.generateKeypair();
      await http.put(
        Uri.parse('${AppConstants.serverBaseUrl}/users/public-key'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'public_key': keypair['publicKey']}),
      );
      final session = await SecureStorage.getSession();
      await SecureStorage.saveSession(
        token: token,
        userId: session['userId'] ?? '',
        virtualId: session['virtualId'] ?? '',
        username: session['username'] ?? '',
        privateKey: keypair['privateKey']!,
        publicKey: keypair['publicKey']!,
      );
    } catch (_) {}
  }

  Future<void> _checkAuth() async {
    await context.read<AuthProvider>().checkSession();
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    if (auth.isAuthenticated) {
      // Silently fix broken keypairs without requiring logout
      await _ensureValidKeypair();
      await context.read<SignalingService>().connect();
      // Fire-and-forget — don't block navigation on FCM
      Future(() async {
        try {
          final token = await NotificationService.getFcmToken();
          if (token != null) await AuthService.updateFcmToken(token);
        } catch (_) {}
      });
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/home');
    } else {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_calling_3_rounded, size: 72, color: AppTheme.primary),
            SizedBox(height: 16),
            Text('Pager', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppTheme.onSurface)),
            SizedBox(height: 24),
            CircularProgressIndicator(color: AppTheme.primary),
          ],
        ),
      ),
    );
  }
}
