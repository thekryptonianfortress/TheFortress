import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../providers/groups_provider.dart';

class JoinGroupScreen extends StatefulWidget {
  const JoinGroupScreen({super.key});

  @override
  State<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends State<JoinGroupScreen> {
  final _codeCtrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid join code')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final result = await context.read<GroupsProvider>().joinGroup(code);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Request sent', style: TextStyle(color: AppTheme.onSurface, fontWeight: FontWeight.w700)),
          content: Text(
            'Your request to join "${result['group_name']}" has been sent.\nThe admin will review your request.',
            style: const TextStyle(color: AppTheme.muted),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              child: const Text('OK', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.inputBg,
        elevation: 0,
        title: const Text('Join Group', style: TextStyle(color: AppTheme.onSurface, fontWeight: FontWeight.w700)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.onSurface),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 88, height: 88,
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppTheme.accent.withValues(alpha: 0.4), width: 2),
                ),
                child: const Icon(Icons.link_rounded, size: 44, color: AppTheme.accent),
              ),
            ),
            const SizedBox(height: 32),
            const Text('You need an 8-character invite code from a group admin.',
                style: TextStyle(color: AppTheme.muted, fontSize: 14), textAlign: TextAlign.center),
            const SizedBox(height: 32),
            Text('Group Code', style: TextStyle(color: AppTheme.muted.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _codeCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              maxLength: 8,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                _UpperCaseFormatter(),
              ],
              style: const TextStyle(
                  color: AppTheme.onSurface, fontSize: 22, letterSpacing: 6, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                counterText: '',
                hintText: 'XXXXXXXX',
                hintStyle: TextStyle(color: AppTheme.muted.withValues(alpha: 0.4), letterSpacing: 6, fontSize: 22),
                filled: true,
                fillColor: AppTheme.inputBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _join(),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _join,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _loading
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Send Join Request', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue next) =>
      next.copyWith(text: next.text.toUpperCase());
}
