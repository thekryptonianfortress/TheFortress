import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Renders text with any URLs highlighted and tappable.
/// Drop-in replacement for [Text] for message content.
class LinkText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextStyle? linkStyle;
  final int? maxLines;
  final TextOverflow? overflow;

  static final _urlRegex = RegExp(
    r'(https?://[^\s]+|www\.[a-zA-Z0-9\-]+\.[^\s]+)',
    caseSensitive: false,
  );

  const LinkText(
    this.text, {
    super.key,
    this.style,
    this.linkStyle,
    this.maxLines,
    this.overflow,
  });

  Future<void> _launch(String raw) async {
    final url = raw.startsWith('http') ? raw : 'https://$raw';
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final matches = _urlRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }

    final baseStyle = style ?? const TextStyle(color: Colors.white, fontSize: 15, height: 1.35);
    final tapStyle = linkStyle ??
        baseStyle.copyWith(
          color: const Color(0xFF7AB8F5),
          decoration: TextDecoration.underline,
          decorationColor: const Color(0xFF7AB8F5),
        );

    final spans = <InlineSpan>[];
    int cursor = 0;

    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, m.start)));
      }
      final url = m.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: tapStyle,
        recognizer: TapGestureRecognizer()..onTap = () => _launch(url),
      ));
      cursor = m.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return RichText(
      text: TextSpan(style: baseStyle, children: spans),
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
    );
  }
}
