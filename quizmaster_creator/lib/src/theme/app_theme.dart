import 'package:flutter/material.dart';

abstract final class AppColors {
  static const ink = Color(0xFF17211D);
  static const muted = Color(0xFF607069);
  static const canvas = Color(0xFFF5F7F5);
  static const surface = Color(0xFFFFFFFF);
  static const line = Color(0xFFDCE3DF);
  static const green = Color(0xFF176B4D);
  static const greenSoft = Color(0xFFE4F1EB);
  static const amber = Color(0xFFD88318);
  static const amberSoft = Color(0xFFFFF1D9);
  static const coral = Color(0xFFB94F43);
  static const coralSoft = Color(0xFFFBE7E4);
  static const blue = Color(0xFF356A8A);
  static const blueSoft = Color(0xFFE6F0F5);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.green,
    brightness: Brightness.light,
    surface: AppColors.surface,
    primary: AppColors.green,
    secondary: AppColors.amber,
    error: AppColors.coral,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.canvas,
    fontFamily: 'Roboto',
  );
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineSmall: const TextStyle(
        color: AppColors.ink,
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleLarge: const TextStyle(
        color: AppColors.ink,
        fontSize: 19,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleMedium: const TextStyle(
        color: AppColors.ink,
        fontSize: 15,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      bodyMedium: const TextStyle(
        color: AppColors.ink,
        fontSize: 14,
        height: 1.4,
        letterSpacing: 0,
      ),
      bodySmall: const TextStyle(
        color: AppColors.muted,
        fontSize: 12,
        height: 1.35,
        letterSpacing: 0,
      ),
      labelLarge: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: AppColors.line),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide(color: AppColors.line),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      height: 68,
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.greenSoft,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0),
      ),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
  );
}
