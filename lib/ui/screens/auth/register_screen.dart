import 'package:flutter/material.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:provider/provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/auth_service.dart';
import '../../../services/notification_service.dart';
import '../../../services/signaling_service.dart';
import '../../../core/theme.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String _phoneNumber = '';
  bool _phoneValid = false;
  bool _obscure = true;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!RegExp(r'^\+\d{7,15}$').hasMatch(_phoneNumber)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid phone number')),
      );
      return;
    }
    if (_passwordCtrl.text != _confirmCtrl.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passwords do not match')),
      );
      return;
    }
    final auth = context.read<AuthProvider>();
    final ok = await auth.register(
      _usernameCtrl.text.trim(),
      _passwordCtrl.text,
      _phoneNumber,
    );
    if (!mounted) return;
    if (ok) {
      context.read<SignalingService>().disconnect();
      await context.read<SignalingService>().connect();
      Future(() async {
        try {
          final token = await NotificationService.getFcmToken();
          if (token != null) await AuthService.updateFcmToken(token);
        } catch (_) {}
      });
      if (mounted) Navigator.pushReplacementNamed(context, '/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Auto-detect country from device locale
    final localeCountry =
        WidgetsBinding.instance.platformDispatcher.locale.countryCode ?? 'US';

    final auth = context.watch<AuthProvider>();
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 48),
              const Icon(Icons.wifi_calling_3_rounded,
                  size: 48, color: AppTheme.primary),
              const SizedBox(height: 16),
              const Text('Create account',
                  style: TextStyle(
                      fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Your phone number is your Pager ID',
                  style: TextStyle(color: AppTheme.muted)),
              const SizedBox(height: 40),

              // Phone field
              IntlPhoneField(
                decoration: const InputDecoration(
                  labelText: 'Phone Number',
                  counterText: '',
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                ),
                initialCountryCode: localeCountry,
                onChanged: (phone) {
                  // Strip leading zero from subscriber number (E.164 standard)
                  final digits = phone.number.replaceFirst(RegExp(r'^0+'), '');
                  // phone.countryCode already contains '+' (e.g. "+254")
                  _phoneNumber = '${phone.countryCode}$digits';
                },
                onCountryChanged: (_) {},
                style: const TextStyle(color: AppTheme.onSurface),
                dropdownTextStyle:
                    const TextStyle(color: AppTheme.onSurface),
                flagsButtonPadding:
                    const EdgeInsets.symmetric(horizontal: 8),
              ),
              const SizedBox(height: 8),
              const Text(
                'This becomes your unique ID. Share it with contacts to be reached.',
                style: TextStyle(color: AppTheme.muted, fontSize: 12),
              ),

              const SizedBox(height: 16),
              TextField(
                controller: _usernameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordCtrl,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () =>
                        setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _confirmCtrl,
                obscureText: _obscure,
                decoration: const InputDecoration(
                  labelText: 'Confirm password',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
              if (auth.error != null) ...[
                const SizedBox(height: 12),
                Text(auth.error!,
                    style:
                        const TextStyle(color: AppTheme.danger)),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: auth.isLoading ? null : _register,
                child: auth.isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white))
                    : const Text('Create Account'),
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: () =>
                      Navigator.pushReplacementNamed(context, '/login'),
                  child:
                      const Text('Already have an account? Sign in'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
