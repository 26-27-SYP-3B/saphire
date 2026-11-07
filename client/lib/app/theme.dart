import 'package:flutter/material.dart';

/// Farben der app: Marinblau ist die Hauptfarbe, die Fläche bleibt tiefes
/// Marine-Blau-Schwarz. Akzente sind nur das aktive Feld und die Hauptaktion.
const canvas = Color(0xFF0A1219);
const fieldBackground = Color(0xFF141F2B);
const hairline = Color(0xFF223140);
const accent = Color(0xFF1F5FA8);
const accentFocused = Color(0xFF3F82C8);
const bodyText = Color(0xFFE8EFF6);
const mutedText = Color(0xFF8FA1B3);
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
    // Karten und Felder auf der Startseite.
    surfaceContainer: fieldBackground,
    outline: hairline,
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
      // Die Begrüßung auf der Startseite.
      displayLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        height: 1.2,
      ),
      displaySmall: TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        height: 1.2,
      ),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.3),
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
