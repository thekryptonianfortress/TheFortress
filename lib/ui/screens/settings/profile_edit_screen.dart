import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../../core/constants.dart';
import '../../../core/theme.dart';
import '../../../data/local/secure_storage.dart';
import '../../../providers/auth_provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class ProfileEditScreen extends StatefulWidget {
  final bool showPasswordSection;
  const ProfileEditScreen({super.key, this.showPasswordSection = false});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final _usernameFocus = FocusNode();
  late final TextEditingController _usernameCtrl;
  File? _pickedImage;
  bool _savingProfile = false;

  // Password section
  final _currentPassCtrl = TextEditingController();
  final _newPassCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();
  bool _savingPassword = false;
  bool _showCurrent = false;
  bool _showNew = false;
  bool _showConfirm = false;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthProvider>();
    _usernameCtrl = TextEditingController(text: auth.username ?? '');
    if (widget.showPasswordSection) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Scrollable.ensureVisible(_usernameFocus.context ?? context,
            alignment: 1.0,
            duration: const Duration(milliseconds: 300));
      });
    }
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _currentPassCtrl.dispose();
    _newPassCtrl.dispose();
    _confirmPassCtrl.dispose();
    _usernameFocus.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.muted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded,
                  color: AppTheme.primary),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded,
                  color: AppTheme.primary),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            if (context.read<AuthProvider>().avatarUrl != null)
              ListTile(
                leading: Icon(Icons.delete_rounded, color: AppTheme.danger),
                title:
                    Text('Remove Photo', style: TextStyle(color: AppTheme.danger)),
                onTap: () => Navigator.pop(ctx, null),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    // null = remove photo (bottom sheet was closed differently than tapping remove)
    // We only act if source was explicitly returned
    if (!mounted) return;

    // User tapped "Remove Photo"
    if (source == null && context.read<AuthProvider>().avatarUrl != null) {
      // Check if sheet was dismissed by swipe (source == null but we do nothing)
      // We handle remove by detecting the ListTile explicitly — but showModalBottomSheet
      // returns null both for swipe-dismiss and for "Remove Photo" tapping Navigator.pop(ctx, null).
      // We'll use a separate approach below.
    }

    if (source == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: source,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked != null && mounted) {
      setState(() => _pickedImage = File(picked.path));
    }
  }

  Future<void> _removePhoto() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Photo'),
        content: const Text('Remove your profile photo?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove', style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _savingProfile = true);
    final err =
        await context.read<AuthProvider>().updateProfile(avatarUrl: '');
    if (!mounted) return;
    setState(() {
      _savingProfile = false;
      _pickedImage = null;
    });
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo removed')),
      );
    }
  }

  Future<String?> _uploadAvatar(File file) async {
    final token = await SecureStorage.getToken();
    if (token == null) return null;
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${AppConstants.serverBaseUrl}/media/upload'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.files.add(await http.MultipartFile.fromPath('file', file.path));
    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode == 200) {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final url = data['url'] as String?;
      if (url == null) return null;
      return url.startsWith('http') ? url : '${AppConstants.serverBaseUrl}$url';
    }
    return null;
  }

  Future<void> _saveProfile() async {
    final auth = context.read<AuthProvider>();
    final newUsername = _usernameCtrl.text.trim();
    String? newAvatarUrl;

    if (_pickedImage != null) {
      setState(() => _savingProfile = true);
      newAvatarUrl = await _uploadAvatar(_pickedImage!);
      if (!mounted) return;
      if (newAvatarUrl == null) {
        setState(() => _savingProfile = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to upload photo')),
        );
        return;
      }
    }

    setState(() => _savingProfile = true);
    final err = await auth.updateProfile(
      username: newUsername != auth.username ? newUsername : null,
      avatarUrl: newAvatarUrl,
    );
    if (!mounted) return;
    setState(() => _savingProfile = false);

    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    } else {
      setState(() => _pickedImage = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated')),
      );
    }
  }

  Future<void> _savePassword() async {
    final current = _currentPassCtrl.text.trim();
    final next = _newPassCtrl.text.trim();
    final confirm = _confirmPassCtrl.text.trim();

    if (current.isEmpty || next.isEmpty || confirm.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all password fields')),
      );
      return;
    }
    if (next.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('New password must be at least 8 characters')),
      );
      return;
    }
    if (next != confirm) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passwords do not match')),
      );
      return;
    }

    setState(() => _savingPassword = true);
    final err = await context.read<AuthProvider>().changePassword(
          currentPassword: current,
          newPassword: next,
        );
    if (!mounted) return;
    setState(() => _savingPassword = false);

    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    } else {
      _currentPassCtrl.clear();
      _newPassCtrl.clear();
      _confirmPassCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password changed successfully')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final avatarUrl = auth.avatarUrl;
    final username = auth.username ?? '';
    final initial =
        username.isNotEmpty ? username[0].toUpperCase() : 'P';
    final avatarColor =
        AppTheme.avatarColor(username.isNotEmpty ? username : 'P');

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Edit Profile'),
        actions: [
          if (_savingProfile)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppTheme.primary),
                ),
              ),
            )
          else
            TextButton(
              onPressed: _saveProfile,
              child: const Text('Save',
                  style: TextStyle(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w700)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(0),
        children: [
          // ── Avatar section ──────────────────────────────────
          Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Column(
              children: [
                // Avatar
                Stack(
                  children: [
                    GestureDetector(
                      onTap: _pickPhoto,
                      child: Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          color: avatarColor,
                          shape: BoxShape.circle,
                        ),
                        child: _pickedImage != null
                            ? ClipOval(
                                child: Image.file(_pickedImage!,
                                    fit: BoxFit.cover))
                            : (avatarUrl != null && avatarUrl.isNotEmpty)
                                ? ClipOval(
                                    child: CachedNetworkImage(
                                        imageUrl: avatarUrl,
                                        fit: BoxFit.cover,
                                        placeholder: (_, __) => Center(
                                              child: Text(initial,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 38,
                                                    fontWeight:
                                                        FontWeight.w700,
                                                  )),
                                            ),
                                        errorWidget: (_, __, ___) => Center(
                                              child: Text(initial,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 38,
                                                    fontWeight:
                                                        FontWeight.w700,
                                                  )),
                                            )),
                                  )
                                : Center(
                                    child: Text(initial,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 38,
                                          fontWeight: FontWeight.w700,
                                        )),
                                  ),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: GestureDetector(
                        onTap: _pickPhoto,
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: AppTheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: AppTheme.surface, width: 2),
                          ),
                          child: const Icon(Icons.camera_alt_rounded,
                              size: 15, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: _pickPhoto,
                  child: const Text(
                    'Change Photo',
                    style: TextStyle(
                        color: AppTheme.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500),
                  ),
                ),
                if (avatarUrl != null && avatarUrl.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  GestureDetector(
                    onTap: _removePhoto,
                    child: Text(
                      'Remove Photo',
                      style: TextStyle(
                          color: AppTheme.danger,
                          fontSize: 13),
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 8),

          // ── Username ────────────────────────────────────────
          _sectionLabel('NAME'),
          Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: TextField(
              controller: _usernameCtrl,
              focusNode: _usernameFocus,
              style: const TextStyle(color: AppTheme.onSurface, fontSize: 16),
              decoration: const InputDecoration(
                hintText: 'Your name',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.symmetric(vertical: 12),
              ),
              textCapitalization: TextCapitalization.words,
              maxLength: 32,
              buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              'This is the name shown to your contacts.',
              style: const TextStyle(color: AppTheme.muted, fontSize: 12),
            ),
          ),

          const SizedBox(height: 24),

          // ── Change Password ─────────────────────────────────
          _sectionLabel('CHANGE PASSWORD'),
          Container(
            color: AppTheme.surface,
            child: Column(
              children: [
                _PasswordField(
                  controller: _currentPassCtrl,
                  label: 'Current Password',
                  show: _showCurrent,
                  onToggle: () =>
                      setState(() => _showCurrent = !_showCurrent),
                  showDivider: true,
                ),
                _PasswordField(
                  controller: _newPassCtrl,
                  label: 'New Password',
                  show: _showNew,
                  onToggle: () => setState(() => _showNew = !_showNew),
                  showDivider: true,
                ),
                _PasswordField(
                  controller: _confirmPassCtrl,
                  label: 'Confirm New Password',
                  show: _showConfirm,
                  onToggle: () =>
                      setState(() => _showConfirm = !_showConfirm),
                  showDivider: false,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _savingPassword ? null : _savePassword,
                child: _savingPassword
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Change Password'),
              ),
            ),
          ),

          const SizedBox(height: 48),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        text,
        style: const TextStyle(
          color: AppTheme.primary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _PasswordField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool show;
  final VoidCallback onToggle;
  final bool showDivider;

  const _PasswordField({
    required this.controller,
    required this.label,
    required this.show,
    required this.onToggle,
    required this.showDivider,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: TextField(
            controller: controller,
            obscureText: !show,
            style: const TextStyle(color: AppTheme.onSurface, fontSize: 15),
            decoration: InputDecoration(
              labelText: label,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              suffixIcon: IconButton(
                icon: Icon(
                    show ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                    size: 20,
                    color: AppTheme.muted),
                onPressed: onToggle,
              ),
            ),
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            thickness: 1,
            color: AppTheme.divider,
            indent: 16,
          ),
      ],
    );
  }
}
