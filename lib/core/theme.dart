import 'package:flutter/material.dart';

class AppTheme {
  // ── Telegram-inspired palette ──────────────────────────────
  static const Color background     = Color(0xFF17212B); // main scaffold bg
  static const Color surface        = Color(0xFF232E3C); // elevated surfaces
  static const Color inputBg        = Color(0xFF1C2733); // input / app bar
  static const Color outgoingBubble = Color(0xFF2B5278); // sent messages
  static const Color incomingBubble = Color(0xFF182533); // received messages
  static const Color primary        = Color(0xFF5288C1); // accent / links
  static const Color accent         = Color(0xFF4DD5A6); // green (read, online)
  static const Color danger         = Color(0xFFEC3942); // delete / errors
  static const Color onSurface      = Color(0xFFF5F5F5); // primary text
  static const Color muted          = Color(0xFF708899); // secondary text
  static const Color divider        = Color(0xFF0D1722); // dividers

  // Legacy aliases (keep old references compiling)
  static const Color surfaceVariant = surface;
  static const Color primaryDark    = Color(0xFF1A4E8A);

  // ── Avatar colours (cycle by name hash) ───────────────────
  static const List<Color> _avatarPalette = [
    Color(0xFF6FB9F0), Color(0xFF77D655), Color(0xFFF57D42),
    Color(0xFF9371E8), Color(0xFFEB5545), Color(0xFF3BA6B9),
    Color(0xFFE1B05C), Color(0xFF6196CA),
  ];

  static Color avatarColor(String name) {
    final hash = name.codeUnits.fold(0, (a, b) => a + b);
    return _avatarPalette[hash % _avatarPalette.length];
  }

  // ── ThemeData ──────────────────────────────────────────────
  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: primary,
          secondary: accent,
          surface: background,
          error: danger,
        ),
        scaffoldBackgroundColor: background,
        appBarTheme: const AppBarTheme(
          backgroundColor: inputBg,
          foregroundColor: onSurface,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: onSurface,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: inputBg,
          selectedItemColor: primary,
          unselectedItemColor: muted,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: inputBg,
          indicatorColor: primary.withValues(alpha: 0.2),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              color: selected ? primary : muted,
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            );
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return IconThemeData(color: selected ? primary : muted, size: 22);
          }),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: primary, width: 1.5),
          ),
          labelStyle: const TextStyle(color: muted),
          hintStyle: const TextStyle(color: muted),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
          ),
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(color: onSurface, fontWeight: FontWeight.bold),
          bodyMedium: TextStyle(color: onSurface),
          bodySmall: TextStyle(color: muted),
        ),
        dividerColor: divider,
        dialogTheme: const DialogThemeData(
          backgroundColor: surface,
          surfaceTintColor: Colors.transparent,
        ),
        useMaterial3: true,
      );
}
