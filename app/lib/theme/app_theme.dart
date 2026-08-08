import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Sunshine World Design System
class SunshineColors {
  // Primary palette
  static const skyBlue = Color(0xFF5EC9FF);
  static const skyBlueLight = Color(0xFF74D5FF);
  static const deepBlue = Color(0xFF267EDB);
  static const sunshineYellow = Color(0xFFFFD34D);
  static const warmOrange = Color(0xFFFFB347);
  static const pink = Color(0xFFFF6FAE);
  static const lavender = Color(0xFF8E63E9);
  static const mintGreen = Color(0xFF77D96B);

  // Surfaces
  static const cream = Color(0xFFFFF6E8);
  static const creamLight = Color(0xFFFFFBF2);
  static const white = Color(0xFFFFFFFF);

  // Text
  static const darkText = Color(0xFF3B2A20);
  static const purpleText = Color(0xFF6651B8);
  static const dimPurple = Color(0xFFB9A8D8);

  // Dock
  static const woodBrown = Color(0xFFA9662D);
  static const woodLight = Color(0xFFD8944B);
  static const woodDark = Color(0xFF7A4A1E);

  // Status
  static const success = Color(0xFF4CAF50);
  static const error = Color(0xFFE53935);

  // Gradients
  static const skyGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF74D5FF), Color(0xFF5EC9FF), Color(0xFF8FE0FF)],
  );

  static const pinkGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF8FBF), Color(0xFFFF6FAE)],
  );

  static const blueGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF74D5FF), Color(0xFF267EDB)],
  );

  static const purpleGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFA87CED), Color(0xFF8E63E9)],
  );

  static const woodGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFD8944B), Color(0xFFA9662D), Color(0xFF7A4A1E)],
  );
}

class SunshineTheme {
  static TextTheme get _textTheme {
    return GoogleFonts.nunitoTextTheme().copyWith(
      displayLarge: GoogleFonts.nunito(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        color: SunshineColors.darkText,
      ),
      displayMedium: GoogleFonts.nunito(
        fontSize: 26,
        fontWeight: FontWeight.w800,
        color: SunshineColors.darkText,
      ),
      headlineLarge: GoogleFonts.nunito(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: SunshineColors.darkText,
      ),
      headlineMedium: GoogleFonts.nunito(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: SunshineColors.darkText,
      ),
      titleLarge: GoogleFonts.nunito(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: SunshineColors.darkText,
      ),
      titleMedium: GoogleFonts.nunito(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: SunshineColors.darkText,
      ),
      bodyLarge: GoogleFonts.nunito(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: SunshineColors.darkText,
      ),
      bodyMedium: GoogleFonts.nunito(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: SunshineColors.darkText,
      ),
      bodySmall: GoogleFonts.nunito(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: SunshineColors.darkText.withValues(alpha: 0.7),
      ),
      labelLarge: GoogleFonts.nunito(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: SunshineColors.white,
      ),
    );
  }

  static ThemeData get theme {
    return ThemeData(
      useMaterial3: true,
      textTheme: _textTheme,
      colorScheme: ColorScheme.fromSeed(
        seedColor: SunshineColors.skyBlue,
        primary: SunshineColors.deepBlue,
        secondary: SunshineColors.pink,
        surface: SunshineColors.cream,
        onPrimary: SunshineColors.white,
        onSecondary: SunshineColors.white,
        onSurface: SunshineColors.darkText,
      ),
      scaffoldBackgroundColor: SunshineColors.skyBlue,
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: SunshineColors.deepBlue,
          foregroundColor: SunshineColors.white,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          elevation: 4,
          shadowColor: SunshineColors.deepBlue.withValues(alpha: 0.3),
          textStyle: GoogleFonts.nunito(
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: SunshineColors.deepBlue,
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          side: const BorderSide(color: SunshineColors.deepBlue, width: 1.5),
          textStyle: GoogleFonts.nunito(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: SunshineColors.cream,
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: SunshineColors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: SunshineColors.deepBlue, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        hintStyle: GoogleFonts.nunito(
          color: SunshineColors.darkText.withValues(alpha: 0.4),
          fontSize: 14,
        ),
      ),
    );
  }
}

/// Standard card decoration used across screens
BoxDecoration sunshineCardDecoration({Color? color}) {
  return BoxDecoration(
    color: color ?? SunshineColors.cream,
    borderRadius: BorderRadius.circular(24),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.08),
        blurRadius: 12,
        offset: const Offset(0, 4),
      ),
    ],
  );
}
