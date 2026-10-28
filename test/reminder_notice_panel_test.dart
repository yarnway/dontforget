import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/ui/widgets/reminder_notice_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'notice actions share height and centered labels across responsive layouts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final now = DateTime.now();
      final reminder = Reminder(
        id: 'notice-layout',
        taskTitle: 'A reminder to review',
        quadrantLevel: 1,
        triggerTime: now,
      );
      for (final width in [320.0, 375.0, 768.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 900);
        for (final scale in [1.0, 2.0]) {
          for (final language in ['zh', 'en', 'ja']) {
            final loc = AppLocalizations(Locale(language));
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(language),
                supportedLocales: const [
                  Locale('zh'),
                  Locale('en'),
                  Locale('ja'),
                ],
                localizationsDelegates: const [
                  AppLocalizationsDelegate(),
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: ReminderNoticePanel(
                      reminders: [reminder],
                      now: now,
                      onDismiss: (_) {},
                      onSnooze: (_) {},
                      onComplete: (_) {},
                      onSnoozeUntil: (_, _) {},
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final rectangles = <Rect>[];
            for (final entry in {
              'notice-snooze-five': 'snooze5Min',
              'snooze-options': 'snoozeMore',
              'notice-complete': 'markDone',
              'notice-dismiss': 'iKnow',
            }.entries) {
              final button = find.byKey(ValueKey(entry.key));
              final rectangle = tester.getRect(button);
              rectangles.add(rectangle);
              expect(rectangle.height, greaterThanOrEqualTo(44));
              expect(
                (tester.getCenter(find.text(loc.get(entry.value))).dy -
                        rectangle.center.dy)
                    .abs(),
                lessThan(1),
                reason: '$width/$scale/$language/${entry.key}',
              );
            }
            expect(
              rectangles.every(
                (r) => (r.height - rectangles.first.height).abs() < 1,
              ),
              isTrue,
            );
            if (width == 1440 && scale == 1) {
              expect(
                rectangles.every(
                  (r) => (r.center.dy - rectangles.first.center.dy).abs() < 1,
                ),
                isTrue,
              );
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          }
        }
      }
    },
  );

  testWidgets('aligned snooze menu preserves callback and busy behavior', (
    tester,
  ) async {
    var complete = 0, snooze = 0, dismiss = 0;
    DateTime? postponed;
    final now = DateTime.now();
    final task = Reminder(
      id: 'notice-actions',
      taskTitle: 'Synthetic notice',
      quadrantLevel: 1,
      triggerTime: now,
    );
    Future<void> show({bool busy = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: ReminderNoticePanel(
              reminders: [task],
              now: now,
              busyIds: busy ? {task.id} : {},
              onDismiss: (_) => dismiss++,
              onSnooze: (_) => snooze++,
              onComplete: (_) => complete++,
              onSnoozeUntil: (_, time) => postponed = time,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show();
    await tester.tap(find.byKey(const ValueKey('snooze-options')));
    await tester.pumpAndSettle();
    final label = AppLocalizations(const Locale('en')).get('snooze15');
    await tester.tap(find.widgetWithText(MenuItemButton, label));
    await tester.pumpAndSettle();
    expect(postponed?.isAfter(now.add(const Duration(minutes: 14))), isTrue);
    expect([complete, snooze, dismiss], [0, 0, 0]);
    await tester.tap(find.byKey(const ValueKey('notice-snooze-five')));
    await tester.tap(find.byKey(const ValueKey('notice-complete')));
    await tester.tap(find.byKey(const ValueKey('notice-dismiss')));
    expect([complete, snooze, dismiss], [1, 1, 1]);
    await show(busy: true);
    for (final key in [
      'snooze-options',
      'notice-snooze-five',
      'notice-complete',
      'notice-dismiss',
    ]) {
      expect(
        tester.widget<TextButton>(find.byKey(ValueKey(key))).onPressed,
        isNull,
      );
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('learning notice opens its card without completing or snoozing', (
    tester,
  ) async {
    final now = DateTime(2026, 10, 27, 14);
    final learning = Reminder(
      id: 'learning',
      taskTitle: 'Learning batch',
      quadrantLevel: 2,
      triggerTime: now,
      nextReviewAt: now,
      spacedRepetitionLevel: 2,
      reviewNotificationsEnabled: true,
    );
    Reminder? opened;
    var mutations = 0;
    Future<void> show(Reminder task, {bool busy = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: ReminderNoticePanel(
              reminders: [task],
              now: now,
              busyIds: busy ? {task.id} : {},
              onDismiss: (_) => mutations++,
              onComplete: (_) => mutations++,
              onSnooze: (_) => mutations++,
              onReview: (task) => opened = task,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show(learning);
    await tester.tap(find.byKey(const ValueKey('notice-start-review')));
    expect(opened, same(learning));
    expect(mutations, 0);
    await show(learning, busy: true);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('notice-start-review')),
          )
          .onPressed,
      isNull,
    );
    await show(
      learning.copyWith(triggerTime: now.add(const Duration(minutes: 2))),
    );
    expect(find.byKey(const ValueKey('notice-start-review')), findsNothing);
    await show(learning.copyWith(reviewNotificationsEnabled: false));
    expect(find.byKey(const ValueKey('notice-start-review')), findsNothing);
  });

  testWidgets('mixed notices count only the category shown in the title', (
    tester,
  ) async {
    final now = DateTime(2026, 10, 21, 12, 30);
    final remaining = ValueNotifier([
      Reminder(
        id: 'due',
        taskTitle: 'Due task',
        quadrantLevel: 3,
        triggerTime: now,
      ),
      for (var index = 0; index < 2; index++)
        Reminder(
          id: 'upcoming-$index',
          taskTitle: 'Upcoming task $index',
          quadrantLevel: 3,
          triggerTime: now.add(const Duration(minutes: 5)),
        ),
    ]);
    addTearDown(remaining.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh')],
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: remaining,
            builder: (_, reminders, __) => ReminderNoticePanel(
              reminders: reminders,
              now: now,
              onDismiss: (dismissed) => remaining.value = reminders
                  .where((item) => item.id != dismissed.id)
                  .toList(),
              onSnooze: (_) {},
              onComplete: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('提醒时间已到 · 1'), findsOneWidget);
    expect(find.text('提醒时间已到 · 3'), findsNothing);
    expect(find.text('Due task'), findsOneWidget);
    expect(find.text('稍后 5 分钟提醒'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '我知道了'));
    await tester.pumpAndSettle();
    expect(find.text('即将提醒 · 2'), findsOneWidget);
    expect(find.text('Upcoming task 0'), findsOneWidget);
    expect(find.text('5 分钟内到提醒时间 · 应用打开时在此提前提示'), findsNothing);
    expect(find.text('稍后 5 分钟提醒'), findsNothing);
    expect(remaining.value, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
