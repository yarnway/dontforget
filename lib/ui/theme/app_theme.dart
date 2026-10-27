import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/settings.dart';

/// Reuse immutable themes across settings and reminder rebuilds.
abstract final class AppTheme {
  static final light = _build(Brightness.light);
  static final dark = _build(Brightness.dark);

  static ThemeMode mode(AppAppearance appearance) => switch (appearance) {
    AppAppearance.system => ThemeMode.system,
    AppAppearance.light => ThemeMode.light,
    AppAppearance.dark => ThemeMode.dark,
  };

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xFF326E6C),
      brightness: brightness,
      primary: dark ? const Color(0xFF83D3C9) : const Color(0xFF226B67),
      surface: dark ? const Color(0xFF121A1B) : const Color(0xFFF5F8F7),
      surfaceContainerLowest: dark ? const Color(0xFF0E1516) : Colors.white,
      surfaceContainerLow: dark ? const Color(0xFF182223) : Colors.white,
      surfaceContainer: dark
          ? const Color(0xFF202C2D)
          : const Color(0xFFEDF3F1),
      surfaceContainerHigh: dark
          ? const Color(0xFF283536)
          : const Color(0xFFE5EEEB),
      surfaceContainerHighest: dark
          ? const Color(0xFF314041)
          : const Color(0xFFDEE8E5),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: true,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        // A transparent app bar otherwise infers a dark background and leaves
        // white iOS status icons against the app's independent light theme.
        systemOverlayStyle: dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      dividerTheme: DividerThemeData(color: colors.outlineVariant),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerLow,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
      ),
    );
  }
}
