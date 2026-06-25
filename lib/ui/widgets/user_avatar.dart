import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';

/// Displays a circular avatar with a photo if [avatarUrl] is provided,
/// falling back to a coloured initial derived from [username].
class UserAvatar extends StatelessWidget {
  final String username;
  final String? avatarUrl;
  final double radius;
  final Color? backgroundColor;
  final double? fontSize;

  const UserAvatar({
    super.key,
    required this.username,
    this.avatarUrl,
    this.radius = 28,
    this.backgroundColor,
    this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final color = backgroundColor ?? AppTheme.avatarColor(username);
    final initial = username.isNotEmpty ? username[0].toUpperCase() : '?';
    final hasPhoto = avatarUrl != null && avatarUrl!.isNotEmpty;
    final resolvedUrl = hasPhoto
        ? (avatarUrl!.startsWith('http')
            ? avatarUrl!
            : '${AppConstants.serverBaseUrl}$avatarUrl')
        : null;

    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      backgroundImage: resolvedUrl != null ? NetworkImage(resolvedUrl) : null,
      child: hasPhoto
          ? null
          : Text(
              initial,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: fontSize ?? radius * 0.7,
              ),
            ),
    );
  }
}
