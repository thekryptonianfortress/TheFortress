import 'dart:math';
import 'package:flutter/material.dart';

// ── Theme definitions ────────────────────────────────────────

class GroupTheme {
  final String id;
  final String name;
  final String emoji;
  final List<Color> gradientColors;
  final _PatternType patternType;
  final Color patternColor;

  const GroupTheme({
    required this.id,
    required this.name,
    required this.emoji,
    required this.gradientColors,
    this.patternType = _PatternType.dots,
    required this.patternColor,
  });
}

enum _PatternType { dots, hexagons, diagonal, waves, grid }

const kGroupThemes = [
  GroupTheme(
    id: 'midnight',
    name: 'Midnight',
    emoji: '🌙',
    gradientColors: [Color(0xFF0F1923), Color(0xFF17212B), Color(0xFF1A2535)],
    patternType: _PatternType.dots,
    patternColor: Color(0xFF1E3045),
  ),
  GroupTheme(
    id: 'forest',
    name: 'Forest',
    emoji: '🌿',
    gradientColors: [Color(0xFF091A0C), Color(0xFF0E2214), Color(0xFF132A19)],
    patternType: _PatternType.hexagons,
    patternColor: Color(0xFF1A3820),
  ),
  GroupTheme(
    id: 'aurora',
    name: 'Aurora',
    emoji: '✨',
    gradientColors: [Color(0xFF0C0B1E), Color(0xFF141238), Color(0xFF1C1850)],
    patternType: _PatternType.dots,
    patternColor: Color(0xFF2A1F6E),
  ),
  GroupTheme(
    id: 'volcanic',
    name: 'Volcanic',
    emoji: '🌋',
    gradientColors: [Color(0xFF1A0808), Color(0xFF2C1010), Color(0xFF3A1818)],
    patternType: _PatternType.diagonal,
    patternColor: Color(0xFF5C2020),
  ),
  GroupTheme(
    id: 'ocean',
    name: 'Ocean',
    emoji: '🌊',
    gradientColors: [Color(0xFF060E1A), Color(0xFF081828), Color(0xFF0A2236)],
    patternType: _PatternType.waves,
    patternColor: Color(0xFF0E3050),
  ),
  GroupTheme(
    id: 'carbon',
    name: 'Carbon',
    emoji: '🖤',
    gradientColors: [Color(0xFF080808), Color(0xFF101010), Color(0xFF181818)],
    patternType: _PatternType.grid,
    patternColor: Color(0xFF1C1C1C),
  ),
];

GroupTheme groupThemeById(String? id) {
  if (id == null) return kGroupThemes.first;
  return kGroupThemes.firstWhere((t) => t.id == id,
      orElse: () => kGroupThemes.first);
}

// ── Background widget ─────────────────────────────────────────

class GroupChatBackground extends StatelessWidget {
  final String? themeId;
  const GroupChatBackground({super.key, this.themeId});

  @override
  Widget build(BuildContext context) {
    final theme = groupThemeById(themeId);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: theme.gradientColors,
        ),
      ),
      child: CustomPaint(
        painter: _PatternPainter(
          patternType: theme.patternType,
          color: theme.patternColor,
        ),
        size: Size.infinite,
      ),
    );
  }
}

// ── Pattern painter ───────────────────────────────────────────

class _PatternPainter extends CustomPainter {
  final _PatternType patternType;
  final Color color;
  const _PatternPainter({required this.patternType, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;

    switch (patternType) {
      case _PatternType.dots:
        _drawDots(canvas, size, paint);
      case _PatternType.hexagons:
        _drawHexagons(canvas, size, paint);
      case _PatternType.diagonal:
        _drawDiagonal(canvas, size, paint);
      case _PatternType.waves:
        _drawWaves(canvas, size, paint);
      case _PatternType.grid:
        _drawGrid(canvas, size, paint);
    }
  }

  void _drawDots(Canvas canvas, Size size, Paint paint) {
    const spacing = 52.0;
    const r = 2.5;
    for (double row = 0; row * spacing < size.height + spacing; row++) {
      final yOff = row * spacing;
      final xShift = (row.toInt() % 2 == 0) ? 0.0 : spacing / 2;
      for (double col = -1; col * spacing < size.width + spacing; col++) {
        canvas.drawCircle(Offset(col * spacing + xShift, yOff), r, paint);
      }
    }
  }

  void _drawHexagons(Canvas canvas, Size size, Paint paint) {
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 0.8;
    const r = 18.0;
    final dx = r * 2 * cos(pi / 6);
    final dy = r * 1.5;
    for (double row = -1; row * dy < size.height + dy; row++) {
      final yOff = row * dy;
      final xShift = (row.toInt() % 2 == 0) ? 0.0 : dx / 2;
      for (double col = -1; col * dx < size.width + dx; col++) {
        final cx = col * dx + xShift;
        final path = Path();
        for (int i = 0; i < 6; i++) {
          final angle = pi / 6 + i * pi / 3;
          final x = cx + r * cos(angle);
          final y = yOff + r * sin(angle);
          if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
        }
        path.close();
        canvas.drawPath(path, paint);
      }
    }
  }

  void _drawDiagonal(Canvas canvas, Size size, Paint paint) {
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 0.7;
    const spacing = 28.0;
    final diag = size.width + size.height;
    for (double d = -diag; d < diag; d += spacing) {
      canvas.drawLine(Offset(d, 0), Offset(d + size.height, size.height), paint);
    }
  }

  void _drawWaves(Canvas canvas, Size size, Paint paint) {
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 0.8;
    const waveH = 10.0;
    const spacing = 36.0;
    for (double yBase = 0; yBase < size.height + spacing; yBase += spacing) {
      final path = Path();
      path.moveTo(0, yBase);
      for (double x = 0; x <= size.width; x += 4) {
        final y = yBase + sin(x / 30.0) * waveH;
        path.lineTo(x, y);
      }
      canvas.drawPath(path, paint);
    }
  }

  void _drawGrid(Canvas canvas, Size size, Paint paint) {
    paint.style = PaintingStyle.stroke;
    paint.strokeWidth = 0.5;
    const spacing = 40.0;
    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) =>
      old.patternType != patternType || old.color != color;
}

// ── Theme picker sheet ────────────────────────────────────────

class GroupThemePickerSheet extends StatelessWidget {
  final String? currentThemeId;
  final void Function(String themeId) onSelect;

  const GroupThemePickerSheet({
    super.key,
    this.currentThemeId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF17212B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('Chat Theme',
                  style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            SizedBox(
              height: 160,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: kGroupThemes.length,
                itemBuilder: (_, i) {
                  final t = kGroupThemes[i];
                  final selected = (currentThemeId ?? 'midnight') == t.id;
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      onSelect(t.id);
                    },
                    child: Container(
                      width: 100,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected ? Colors.white : Colors.transparent,
                          width: 2.5,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          children: [
                            // Mini preview of the theme
                            Positioned.fill(
                              child: GroupChatBackground(themeId: t.id),
                            ),
                            // Selected check
                            if (selected)
                              Positioned(
                                top: 8, right: 8,
                                child: Container(
                                  width: 22, height: 22,
                                  decoration: const BoxDecoration(
                                    color: Colors.white, shape: BoxShape.circle),
                                  child: const Icon(Icons.check_rounded,
                                      size: 14, color: Colors.black),
                                ),
                              ),
                            // Label at bottom
                            Positioned(
                              bottom: 0, left: 0, right: 0,
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Text(t.emoji, style: const TextStyle(fontSize: 16)),
                                    Text(t.name,
                                        style: const TextStyle(
                                            color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
