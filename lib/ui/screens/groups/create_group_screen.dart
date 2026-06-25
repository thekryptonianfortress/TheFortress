import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme.dart';
import '../../../data/local/secure_storage.dart';
import '../../../providers/groups_provider.dart';
import '../../../services/media_service.dart';
import 'group_chat_screen.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  bool _loading = false;
  File? _avatarFile;
  String? _avatarUrl;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final file = await MediaService.pickFromGallery();
    if (file == null || !mounted) return;
    setState(() { _avatarFile = file; _avatarUrl = null; });
    try {
      final token = await SecureStorage.getToken() ?? '';
      final meta = await MediaService.upload(file, token);
      if (mounted) setState(() => _avatarUrl = meta.url);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Photo upload failed: $e')));
    }
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() => _loading = true);
    try {
      final group = await context.read<GroupsProvider>().createGroup(
            name: name,
            description: _descCtrl.text.trim().isNotEmpty ? _descCtrl.text.trim() : null,
            avatarUrl: _avatarUrl,
          );
      if (!mounted) return;
      Navigator.pop(context);
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => GroupChatScreen(group: group)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create group: $e')),
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
        title: const Text('Create Group', style: TextStyle(color: AppTheme.onSurface, fontWeight: FontWeight.w700)),
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
            // Group avatar picker
            Center(
              child: GestureDetector(
                onTap: _pickAvatar,
                child: Stack(
                  children: [
                    Container(
                      width: 90, height: 90,
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.4), width: 2),
                        image: _avatarFile != null
                            ? DecorationImage(image: FileImage(_avatarFile!), fit: BoxFit.cover)
                            : null,
                      ),
                      child: _avatarFile == null
                          ? const Icon(Icons.group_rounded, size: 42, color: AppTheme.muted)
                          : null,
                    ),
                    Positioned(
                      right: 0, bottom: 0,
                      child: Container(
                        width: 28, height: 28,
                        decoration: const BoxDecoration(color: AppTheme.primary, shape: BoxShape.circle),
                        child: const Icon(Icons.camera_alt_rounded, size: 15, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Center(
              child: Text('Tap to add photo', style: TextStyle(color: AppTheme.muted, fontSize: 12)),
            ),
            const SizedBox(height: 28),
            Text('Group Name', style: TextStyle(color: AppTheme.muted.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              maxLength: 50,
              style: const TextStyle(color: AppTheme.onSurface, fontSize: 16),
              decoration: InputDecoration(
                counterStyle: TextStyle(color: AppTheme.muted.withValues(alpha: 0.6)),
                hintText: 'Enter group name',
                hintStyle: const TextStyle(color: AppTheme.muted),
                filled: true,
                fillColor: AppTheme.inputBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('Description (optional)', style: TextStyle(color: AppTheme.muted.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _descCtrl,
              maxLines: 3,
              maxLength: 200,
              style: const TextStyle(color: AppTheme.onSurface, fontSize: 15),
              decoration: InputDecoration(
                counterStyle: TextStyle(color: AppTheme.muted.withValues(alpha: 0.6)),
                hintText: 'What is this group about?',
                hintStyle: const TextStyle(color: AppTheme.muted),
                filled: true,
                fillColor: AppTheme.inputBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _create,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _loading
                    ? const SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Create Group', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
