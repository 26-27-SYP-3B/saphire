import 'package:flutter/material.dart';

/// The one palette of the app: Spotify's black with marine blue where Spotify has its green.
/// Every colour a widget draws comes from here or from the [ColorScheme] built out of it — no
/// screen mixes in a colour of its own.
const canvas = Color(0xFF000000);
const fieldBackground = Color(0xFF0A1F44);
const elevated = Color(0xFF001F54);
const hover = Color(0xFF163566);
const hairline = Color(0xFF1E335C);
const accent = Color(0xFF1E4FD8);
const accentBright = Color(0xFF5B8DEF);
const bodyText = Color(0xFFF5F7FA);
const mutedText = Color(0xFFA7B4C8);
const errorText = Color(0xFFFF6B6B);

/// The player draws itself darker than the pages, because it sits over content while a song
/// plays. These are the same navy family, one step apart.
const playerCard = Color(0xFF0A1F44);
const playerCardBorder = Color(0xFF163566);
const playerAccent = accentBright;
const playerBarMuted = Color(0xFF2A3E66);

ThemeData buildTheme() {
  final colorScheme =
      ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
      ).copyWith(
        primary: accent,
        onPrimary: Colors.white,
        secondary: accentBright,
        onSecondary: Colors.white,
        surface: canvas,
        onSurface: bodyText,
        onSurfaceVariant: mutedText,
        surfaceContainer: fieldBackground,
        surfaceContainerHigh: elevated,
        outline: hairline,
        error: errorText,
      );

  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(6),
    borderSide: const BorderSide(color: hairline),
  );

  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: canvas,
    // Spotify's own face is proprietary; the system font with the same weights and tight
    // letter spacing is the closest that needs no font asset.
    textTheme: (const TextTheme(
      displayLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
        height: 1.15,
      ),
      displaySmall: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
        height: 1.2,
      ),
      headlineMedium: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        height: 1.2,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5),
      bodySmall: TextStyle(fontSize: 12, height: 1.4),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
    )).apply(bodyColor: bodyText, displayColor: bodyText),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: fieldBackground,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: accentBright),
      ),
      labelStyle: const TextStyle(color: mutedText),
      hintStyle: const TextStyle(color: mutedText),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        // Sizing stays up to the page: a Row has no width to fill, so the theme must not
        // force the whole width. White on navy like Spotify's play button on its accent.
        backgroundColor: accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: bodyText,
        padding: EdgeInsets.zero,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: fieldBackground,
      selectedColor: accent,
      disabledColor: fieldBackground,
      side: const BorderSide(color: hairline),
      labelStyle: const TextStyle(color: bodyText, fontWeight: FontWeight.w600),
      secondaryLabelStyle: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w600,
      ),
      shape: const StadiumBorder(),
    ),
    dividerTheme: const DividerThemeData(color: hairline, thickness: 1),
    iconTheme: const IconThemeData(color: bodyText),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: elevated,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: hairline),
      ),
      textStyle: const TextStyle(color: bodyText, fontSize: 12),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: elevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: hairline),
      ),
    ),
  );
}
