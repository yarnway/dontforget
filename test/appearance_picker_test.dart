import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/appearance_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/interaction_preview.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
}

void main() {
  setUpAll(loadInteractionPreviewFonts);
  for (final theme in [AppTheme.light, AppTheme.dark]) {
    test('${theme.brightness} text and controls remain readable', () {
      final c = theme.colorScheme;
      for (final bg in [
        c.surface,
        c.surfaceContainerLow,
        c.surfaceContainerHigh,
      ]) {
        expect(contrast(c.onSurface, bg), greaterThanOrEqualTo(4.5));
        expect(contrast(c.onSurfaceVariant, bg), greaterThanOrEqualTo(4.5));
      }
      expect(contrast(c.onPrimary, c.primary), greaterThanOrEqualTo(4.5));
      expect(
        contrast(c.onSurface, c.primaryContainer),
        greaterThanOrEqualTo(4.5),
      );
    });
    for (final locale in ['zh', 'en', 'ja']) {
      for (final width in [320.0, 430.0, 840.0]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets(
            '${theme.brightness} $locale $width scale $scale appearance controls fit and select',
            (tester) async {
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 900);
              addTearDown(tester.view.resetDevicePixelRatio);
              addTearDown(tester.view.resetPhysicalSize);
              var selected = AppAppearance.system;
              await tester.pumpWidget(
                MaterialApp(
                  theme: theme,
                  locale: Locale(locale),
                  supportedLocales: [Locale(locale)],
                  localizationsDelegates: const [
                    AppLocalizationsDelegate(),
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  home: StatefulBuilder(
                    builder: (context, setState) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: Scaffold(
                        body: RepaintBoundary(
                          key: interactionPreviewKey,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: AppearancePicker(
                              value: selected,
                              onChanged: (v) => setState(() => selected = v),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              for (final mode in [
                AppAppearance.light,
                AppAppearance.dark,
                AppAppearance.system,
              ]) {
                final button = find.byKey(ValueKey('appearance-${mode.name}'));
                await tester.ensureVisible(button);
                expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
                await tester.tap(button);
                await tester.pumpAndSettle();
                expect(selected, mode);
                expect(tester.takeException(), isNull);
              }
              if (locale == 'zh' && scale == 1 && width != 320) {
                await captureInteractionPreview(
                  tester,
                  'appearance-${theme.brightness.name}-$width',
                );
              }
            },
          );
        }
      }
    }
  }
  testWidgets(
    'appearance options support Tab and activation without text input',
    (tester) async {
      var selected = AppAppearance.system;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [AppLocalizationsDelegate()],
          home: Scaffold(
            body: AppearancePicker(
              value: selected,
              onChanged: (v) => selected = v,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(selected, AppAppearance.light);
      expect(AppTheme.mode(AppAppearance.dark), ThemeMode.dark);
    },
  );
}
