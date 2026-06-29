import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme.dart';

class _OgData {
  final String title;
  final String? description;
  final String domain;
  const _OgData({required this.title, this.description, required this.domain});
}

/// Shows an inline link preview card for the first URL in a message.
/// Fetches OG title + description; uses Google's favicon service for the icon.
class LinkPreviewCard extends StatefulWidget {
  final String rawUrl;
  const LinkPreviewCard(this.rawUrl, {super.key});

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  static final _cache = <String, _OgData?>{};

  _OgData? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _normalizedUrl {
    final u = widget.rawUrl;
    return u.startsWith('http') ? u : 'https://$u';
  }

  Future<void> _load() async {
    final key = widget.rawUrl;
    if (_cache.containsKey(key)) {
      if (mounted) setState(() { _data = _cache[key]; _loading = false; });
      return;
    }
    try {
      final data = await _fetchOg(_normalizedUrl);
      _cache[key] = data;
      if (mounted) setState(() { _data = data; _loading = false; });
    } catch (_) {
      _cache[key] = null;
      if (mounted) setState(() { _loading = false; });
    }
  }

  Future<void> _open() async {
    final uri = Uri.tryParse(_normalizedUrl);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 48,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: AppTheme.muted),
          ),
        ),
      );
    }
    if (_data == null) return const SizedBox.shrink();

    final faviconUrl =
        'https://www.google.com/s2/favicons?domain=${_data!.domain}&sz=32';

    return GestureDetector(
      onTap: _open,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
          border: Border(
            left: BorderSide(
              color: AppTheme.primary.withValues(alpha: 0.6),
              width: 2.5,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Favicon
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                faviconUrl,
                width: 20,
                height: 20,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.language_rounded,
                  size: 18,
                  color: AppTheme.muted,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _data!.domain,
                    style: TextStyle(
                      color: AppTheme.primary.withValues(alpha: 0.85),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    _data!.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_data!.description != null &&
                      _data!.description!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      _data!.description!,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 11,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── OG fetch helpers ──────────────────────────────────────────────────────────

Future<_OgData?> _fetchOg(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;

  final response = await http.get(
    uri,
    headers: {
      'User-Agent':
          'Mozilla/5.0 (compatible; TelegramBot/1.0; +https://core.telegram.org/bots/webhooks)',
      'Accept': 'text/html',
    },
  ).timeout(const Duration(seconds: 8));

  if (response.statusCode != 200) return null;

  String html;
  try {
    html = utf8.decode(response.bodyBytes, allowMalformed: true);
  } catch (_) {
    html = response.body;
  }

  final title = _ogProp(html, 'og:title') ??
      _metaName(html, 'twitter:title') ??
      _htmlTitle(html) ??
      uri.host;

  final description = _ogProp(html, 'og:description') ??
      _metaName(html, 'description') ??
      _metaName(html, 'twitter:description');

  final domain = uri.host.replaceAll('www.', '');

  return _OgData(
    title: title.trim(),
    description: description?.trim(),
    domain: domain,
  );
}

// Matches <meta property="og:..." content="VALUE"> (both attribute orders)
String? _ogProp(String html, String prop) {
  // Use non-capturing for quotes, capture only value
  final a = RegExp(
    'property=["\']${RegExp.escape(prop)}["\'][^>]+content=["\']([^"\'<>]+)["\']',
    caseSensitive: false,
  ).firstMatch(html);
  if (a != null) return _decodeHtml(a.group(1)!);

  final b = RegExp(
    'content=["\']([^"\'<>]+)["\'][^>]+property=["\']${RegExp.escape(prop)}["\']',
    caseSensitive: false,
  ).firstMatch(html);
  if (b != null) return _decodeHtml(b.group(1)!);

  return null;
}

// Matches <meta name="..." content="VALUE">
String? _metaName(String html, String name) {
  final a = RegExp(
    'name=["\']${RegExp.escape(name)}["\'][^>]+content=["\']([^"\'<>]+)["\']',
    caseSensitive: false,
  ).firstMatch(html);
  if (a != null) return _decodeHtml(a.group(1)!);

  final b = RegExp(
    'content=["\']([^"\'<>]+)["\'][^>]+name=["\']${RegExp.escape(name)}["\']',
    caseSensitive: false,
  ).firstMatch(html);
  if (b != null) return _decodeHtml(b.group(1)!);

  return null;
}

String? _htmlTitle(String html) {
  final m = RegExp(
    r'<title[^>]*>([^<]+)</title>',
    caseSensitive: false,
  ).firstMatch(html);
  return m != null ? _decodeHtml(m.group(1)!) : null;
}

String _decodeHtml(String text) {
  return text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ');
}
