import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('promotion badge appears only for active promoted Q1 tasks', (
    tester,
  ) async {
    final scenarios = [
      (quadrant: 3, completed: true, promoted: true, visible: false),
      (quadrant: 3, completed: false, promoted: true, visible: false),
      (quadrant: 1, completed: true, promoted: true, visible: false),
      (quadrant: 1, completed: false, promoted: false, visible: false),
      (quadrant: 1, completed: false, promoted: true, visible: true),
    ];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (var index = 0; index < scenarios.length; index++)
                    TaskCard(
                      key: ValueKey('promotion-card-$index'),
                      task: Reminder(
                        id: 'promotion-task-$index',
                        taskTitle: 'Promotion visibility QA $index',
                        quadrantLevel: scenarios[index].quadrant,
                        isCompleted: scenarios[index].completed,
                        isDynamicallyPromoted: scenarios[index].promoted,
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
    for (var index = 0; index < scenarios.length; index++) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey('promotion-card-$index')),
          matching: find.text('优先处理'),
        ),
        scenarios[index].visible ? findsOneWidget : findsNothing,
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
