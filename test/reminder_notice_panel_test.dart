import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/ui/widgets/reminder_notice_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(find.text('待办提醒到期 · 1'), findsOneWidget);
    expect(find.text('待办提醒到期 · 3'), findsNothing);
    expect(find.text('Due task'), findsOneWidget);
    expect(find.text('稍后 5 分钟提醒'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '我知道了'));
    await tester.pumpAndSettle();
    expect(find.text('即将到期 · 2'), findsOneWidget);
    expect(find.text('Upcoming task 0'), findsOneWidget);
    expect(find.text('5 分钟内到期 · 应用打开时在此提前提示'), findsOneWidget);
    expect(find.text('稍后 5 分钟提醒'), findsNothing);
    expect(remaining.value, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
