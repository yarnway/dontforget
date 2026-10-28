import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ThemeData _theme(Brightness brightness) => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF7A8B8B),
    brightness: brightness,
    surface: brightness == Brightness.dark
        ? const Color(0xFF2C2C2C)
        : Colors.white,
  ),
);

double _contrast(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  return first > second
      ? (first + 0.05) / (second + 0.05)
      : (second + 0.05) / (first + 0.05);
}

void main() {
  testWidgets('card foreground and painted background change theme together', (
    tester,
  ) async {
    final brightness = ValueNotifier(Brightness.light);
    addTearDown(brightness.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: ValueListenableBuilder(
          valueListenable: brightness,
          builder: (_, value, __) => MaterialApp(
            theme: _theme(value),
            locale: const Locale('en'),
            supportedLocales: const [Locale('en')],
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: Column(
                children: [
                  TaskCard(
                    task: Reminder(
                      id: 'active-theme',
                      taskTitle: 'Active task',
                      taskSummary: 'Readable supporting text',
                      quadrantLevel: 1,
                    ),
                    onPlayMedia: () {},
                  ),
                  TaskCard(
                    task: Reminder(
                      id: 'done-theme',
                      taskTitle: 'Completed task',
                      quadrantLevel: 1,
                      isCompleted: true,
                    ),
                    onPlayMedia: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final next in [Brightness.dark, Brightness.light, Brightness.dark]) {
      brightness.value = next;
      await tester.pump();
      // Finish the app theme transition without allowing a second card-only
      // interpolation to hide a mismatched intermediate frame.
      await tester.pump(const Duration(milliseconds: 400));
      final colors = Theme.of(
        tester.element(find.byType(TaskCard).first),
      ).colorScheme;
      for (final entry in [
        ('active-theme', 'Active task', colors.surfaceContainerLow),
        ('done-theme', 'Completed task', colors.surfaceContainerLowest),
      ]) {
        final surface = find.byKey(ValueKey('task-surface-${entry.$1}'));
        final painted =
            tester
                    .widget<DecoratedBox>(
                      find
                          .descendant(
                            of: surface,
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration;
        final text = tester.widget<Text>(find.text(entry.$2));
        expect(painted.color, entry.$3);
        expect(
          _contrast(text.style!.color!, painted.color!),
          greaterThanOrEqualTo(4.5),
        );
      }
      final summary = tester.widget<Text>(
        find.text('Readable supporting text'),
      );
      expect(
        _contrast(summary.style!.color!, colors.surface),
        greaterThanOrEqualTo(4.5),
      );
    }
    final menuFinder = find.byKey(const ValueKey('actions-active-theme'));
    final menu = tester.widget<PopupMenuButton<String>>(menuFinder);
    final colors = Theme.of(tester.element(menuFinder)).colorScheme;
    expect(menu.color, colors.surfaceContainer);
    expect(
      _contrast((menu.icon! as Icon).color!, colors.surface),
      greaterThanOrEqualTo(3),
    );
    await tester.tap(menuFinder);
    await tester.pumpAndSettle();
    for (final entry in tester.widgetList<PopupMenuItem<String>>(
      find.byType(PopupMenuItem<String>),
    )) {
      final row = entry.child! as Row;
      final label = (row.children.last as Expanded).child as Text;
      expect(
        _contrast(label.style!.color!, menu.color!),
        greaterThanOrEqualTo(4.5),
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
