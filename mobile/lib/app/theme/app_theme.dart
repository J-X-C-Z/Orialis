import 'package:flutter/material.dart';

class AppColors {
  static const ink = Color(0xFF14201F);
  static const paper = Color(0xFFF7F7F3);
  static const surface = Colors.white;
  static const accent = Color(0xFF287A70);
  static const accentSoft = Color(0xFFDDEEE8);
  static const muted = Color(0xFF687572);
  static const danger = Color(0xFFB34D48);
}

class AppSpacing {
  static const page = 20.0;
  static const section = 24.0;
  static const item = 12.0;
}

class AppRadius {
  static const card = 18.0;
  static const control = 12.0;
}

ThemeData buildOrialisTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.light,
    surface: AppColors.surface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme.copyWith(primary: AppColors.accent),
    scaffoldBackgroundColor: AppColors.paper,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.paper,
      foregroundColor: AppColors.ink,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: const BorderSide(color: Color(0xFFE0E7E2)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
    ),
  );
}
