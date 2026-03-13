import 'package:flutter/material.dart';

class AppTheme {
  // Child app uses warm, friendly colours — less corporate than parent
  static const Color primary = Color(0xFF6C63FF);   // purple
  static const Color secondary = Color(0xFFFF6584); // pink-red
  static const Color accent = Color(0xFF43D6A0);    // mint green
  static const Color warning = Color(0xFFFFB347);   // orange
  static const Color surface = Color(0xFFF8F7FF);
  static const Color cardBg = Colors.white;

  static ThemeData childTheme() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        secondary: secondary,
        surface: surface,
      ),
      scaffoldBackgroundColor: surface,
      fontFamily: 'Roboto',
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: Color(0xFF2D2D2D)),
        titleTextStyle: TextStyle(
          color: Color(0xFF2D2D2D),
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      cardTheme: CardTheme(
        color: cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}
