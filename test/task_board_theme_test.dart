import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/ui/widgets/task_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

double contrast(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  return ((first > second ? first : second) + 0.05) /
      ((first < second ? first : second) + 0.05);
}

void main() {
  for (final width in [375.0, 1440.0]) {
    testWidgets(
      'board surfaces and labels track theme changes together at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final mode = ValueNotifier(ThemeMode.light);
        addTearDown(mode.dispose);
        await tester.pumpWidget(
          ProviderScope(
            child: ValueListenableBuilder(
              valueListenable: mode,
              builder: (_, value, _) => MaterialApp(
                localizationsDelegates: const [AppLocalizationsDelegate()],
                themeMode: value,
                themeAnimationDuration: const Duration(milliseconds: 200),
                theme: ThemeData(
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: Colors.teal,
                    brightness: Brightness.light,
                  ),
                ),
                darkTheme: ThemeData(
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: Colors.teal,
                    brightness: Brightness.dark,
                  ),
                ),
                home: Scaffold(
                  body: TaskBoard(reminders: const [], onPlayMedia: (_) {}),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        void checkRenderedPair({required bool settled}) {
          final boardContext = tester.element(find.byType(TaskBoard));
          final colors = Theme.of(boardContext).colorScheme;
          final surface = tester.renderObject<RenderDecoratedBox>(
            find.byKey(const ValueKey('quadrant-surface-1')),
          );
          final background = (surface.decoration as BoxDecoration).color!;
          // Read the actual painted decoration, not only the target widget style.
          expect(background, colors.surfaceContainerLow);
          if (settled) {
            expect(
              contrast(colors.onSurface, background),
              greaterThanOrEqualTo(4.5),
            );
          }
          if (width < 640) {
            for (final index in [1, 2]) {
              final button = find.byKey(ValueKey('category-$index'));
              final foreground = index == 1
                  ? colors.onPrimaryContainer
                  : colors.onSurface;
              final expectedBackground = index == 1
                  ? colors.primaryContainer
                  : colors.surfaceContainerLow;
              final material = tester.widget<Material>(
                find
                    .descendant(of: button, matching: find.byType(Material))
                    .first,
              );
              expect(material.color, expectedBackground);
              final richTexts = tester.widgetList<RichText>(
                find.descendant(of: button, matching: find.byType(RichText)),
              );
              expect(richTexts, isNotEmpty);
              for (final text in richTexts) {
                expect(text.text.style?.color, foreground);
              }
              if (settled) {
                expect(
                  contrast(foreground, expectedBackground),
                  greaterThanOrEqualTo(4.5),
                );
              }
            }
          }
        }

        checkRenderedPair(settled: true);
        for (final value in [ThemeMode.dark, ThemeMode.light]) {
          mode.value = value;
          await tester.pump();
          // These intermediate frames must not introduce an independent lagging
          // background animation on top of MaterialApp's own theme transition.
          for (var frame = 0; frame < 4; frame++) {
            await tester.pump(const Duration(milliseconds: 50));
            checkRenderedPair(settled: frame == 3);
          }
          expect(
            Theme.of(tester.element(find.byType(TaskBoard))).brightness,
            value == ThemeMode.dark ? Brightness.dark : Brightness.light,
          );
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
