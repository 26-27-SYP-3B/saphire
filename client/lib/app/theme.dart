import 'package:flutter/material.dart';

/// Farben der Anmelde- und Registrierungsseiten.
/// Marinblau ist der einzige Akzent, alles andere bleibt neutral dunkel.
const canvas = Color(0xFF10151A);
const fieldBackground = Color(0xFF171E24);
const hairline = Color(0xFF29333B);
const accent = Color(0xFF1F5F8C);
const accentFocused = Color(0xFF3C88BC);
const bodyText = Color(0xFFEDF1F4);
const mutedText = Color(0xFF8A99A6);
const errorText = Color(0xFFE2685F);

ThemeData buildTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: accent,
    onPrimary: Colors.white,
    surface: canvas,
    onSurface: bodyText,
    onSurfaceVariant: mutedText,
    error: errorText,
  );

  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: const BorderSide(color: hairline),
  );

  return ThemeData(
    colorScheme: colorScheme,
    // shortcut: keine eigene Schrift, es ist die Systemschrift. Upgrade: ein
    // Font-Asset, wenn die app eine eigene Marke bekommen soll.
    textTheme: (const TextTheme(
      displaySmall: TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        height: 1.2,
      ),
      labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5),
    )).apply(
      bodyColor: bodyText,
      displayColor: bodyText,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: fieldBackground,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: accentFocused),
      ),
      labelStyle: const TextStyle(color: mutedText),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accentFocused,
        padding: EdgeInsets.zero,
      ),
    ),
  );
}
