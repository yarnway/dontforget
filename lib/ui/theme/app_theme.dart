import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/settings.dart';

/// Reuse immutable themes across settings and reminder rebuilds.
abstract final class AppTheme {
  static final light = _build(Brightness.light);
  static final dark = _build(Brightness.dark);

  static const workspaceMaxWidth = 1040.0;
  static const tabularFigures = <FontFeature>[FontFeature.tabularFigures()];

  static ThemeMode mode(AppAppearance appearance) => switch (appearance) {
    AppAppearance.system => ThemeMode.system,
    AppAppearance.light => ThemeMode.light,
    AppAppearance.dark => ThemeMode.dark,
  };

  /// AA-verified semantic accent for Q1..Q4 across cards, boards, dashboard and
  /// detail views (>= 4.5:1 against both active and recessed card surfaces,
  /// including 12%-tinted Light Q2 badge backgrounds).
  static Color quadrantColor(Brightness brightness, int level) {
    final dark = brightness == Brightness.dark;
    return switch (level) {
      1 => dark ? const Color(0xFFF28B82) : const Color(0xFFC62828),
      2 => dark ? const Color(0xFFF6BF60) : const Color(0xFF9E4706),
      3 => dark ? const Color(0xFF8AB4F8) : const Color(0xFF1D56B8),
      _ => dark ? const Color(0xFF7CD4A8) : const Color(0xFF1F6E58),
    };
  }

  static IconData quadrantIcon(int level) => switch (level) {
    1 => Icons.notifications_active_outlined,
    2 => Icons.star_outline_rounded,
    3 => Icons.checklist_rounded,
    _ => Icons.notes_rounded,
  };

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xFF326E6C),
      brightness: brightness,
      primary: dark ? const Color(0xFF83D3C9) : const Color(0xFF226B67),
      surface: dark ? const Color(0xFF121A1B) : const Color(0xFFF1F5F4),
      surfaceContainerLowest: dark
          ? const Color(0xFF0E1516)
          : const Color(0xFFF6F9F8),
      surfaceContainerLow: dark ? const Color(0xFF182223) : Colors.white,
      surfaceContainer: dark
          ? const Color(0xFF202C2D)
          : const Color(0xFFEAF1EF),
      surfaceContainerHigh: dark
          ? const Color(0xFF283536)
          : const Color(0xFFE2ECE9),
      surfaceContainerHighest: dark
          ? const Color(0xFF314041)
          : const Color(0xFFD9E5E2),
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
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        color: colors.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: colors.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.7)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        elevation: 3,
        color: colors.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.7)),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.75)),
        selectedColor: colors.secondaryContainer,
        backgroundColor: colors.surfaceContainerLow,
        labelStyle: TextStyle(color: colors.onSurface),
        secondaryLabelStyle: TextStyle(
          color: colors.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: colors.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: colors.onInverseSurface, fontSize: 12),
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
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.primary, width: 1.6),
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
