import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/formatters/local_date_time.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/reminder_notice_panel.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:dont_forget/ui/widgets/task_details_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications implements NotificationService {
  @override
  Future<void> cancelReminder(String id) async {}
  @override
  Future<void> scheduleReminder(Reminder reminder) async {}
  @override
  Future<void> cancelReminderStrict(String id) => cancelReminder(id);
  @override
  Future<void> scheduleReminderStrict(Reminder reminder) =>
      scheduleReminder(reminder);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Compare with device wall-clock components, independently of the UI formatter.
String _label(DateTime local) =>
    '${local.year.toString().padLeft(4, '0')}-'
    '${local.month.toString().padLeft(2, '0')}-'
    '${local.day.toString().padLeft(2, '0')} '
    '${local.hour.toString().padLeft(2, '0')}:'
    '${local.minute.toString().padLeft(2, '0')}';

void main() {
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late Reminder task;

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('dontforget-local-time-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    final notifications = _Notifications();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
        remindersProvider.overrideWith(
          (_) => RemindersNotifier(
            database,
            notifications: notifications,
            runLoadEffects: false,
          ),
        ),
      ],
    );
    await container.read(remindersProvider.notifier).ready;
    final now = DateTime.now();
    task = Reminder(
      id: 'utc-restored-task',
      taskTitle: 'Restored UTC reminder',
      quadrantLevel: 3,
      // Asia/Shanghai crosses midnight; America/Los_Angeles keeps the day.
      triggerTime: DateTime.utc(now.year, now.month, 15, 21, 9),
    );
    await container.read(remindersProvider.notifier).addReminder(task);
  });

  tearDown(() async {
    container.dispose();
    await database.close(createBackup: false);
    await directory.delete(recursive: true);
  });

  Future<void> show(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (_, child) => InlineFeedback(child: child!),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test(
    'UTC and explicit-offset input display locally without changing storage',
    () {
      // Dedicated runs verify that the native test process actually adopted TZ.
      final offset = DateTime.utc(2026, 10, 21).toLocal().timeZoneOffset;
      switch (Platform.environment['TZ']) {
        case 'Asia/Shanghai':
          expect(offset, const Duration(hours: 8));
        case 'America/Los_Angeles':
          expect(offset, const Duration(hours: -7));
      }
      for (final encoded in [
        '2026-10-21T08:09:00.000Z',
        '2026-10-21T23:09:00.000Z',
        '2026-10-21T16:09:00.000+08:00',
      ]) {
        final restored = Reminder.fromJson({
          ...task.toJson(),
          'trigger_time': encoded,
        });
        final before = restored.toJson();
        final instant = restored.triggerTime!;
        final local = instant.toLocal();
        expect(formatLocalDateTime(instant), _label(local));
        expect(
          formatLocalDateTime(instant, pattern: 'MM-dd'),
          '${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}',
        );
        expect(restored.toJson(), before);
        expect(restored.triggerTime!.isUtc, isTrue);
        expect(restored.triggerTime!.isAtSameMomentAs(local), isTrue);
      }
    },
  );

  testWidgets('task card displays restored UTC reminder in device timezone', (
    tester,
  ) async {
    await show(tester, TaskCard(task: task, onPlayMedia: () {}));
    expect(find.text(_label(task.triggerTime!.toLocal())), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final fullPage in [true, false]) {
    testWidgets(
      '${fullPage ? 'full detail' : 'dialog'} uses local labels and picker values without resaving UTC',
      (tester) async {
        final original = task.triggerTime!.toIso8601String();
        final local = task.triggerTime!.toLocal();
        await show(
          tester,
          fullPage
              ? TaskDetailScreen(task: task)
              : TaskDetailsDialog(task: task),
        );
        final label = find.text(_label(local));
        expect(label, findsOneWidget);
        if (fullPage) {
          await tester.ensureVisible(label);
          await tester.tap(label);
        } else {
          await tester.tap(find.byTooltip('Reminder Time'));
        }
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DatePickerDialog>(find.byType(DatePickerDialog))
              .initialDate,
          DateUtils.dateOnly(local),
        );
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TimePickerDialog>(find.byType(TimePickerDialog))
              .initialTime,
          TimeOfDay.fromDateTime(local),
        );
        await tester.tap(
          find.descendant(
            of: find.byType(TimePickerDialog),
            matching: find.text('Cancel'),
          ),
        );
        await tester.pumpAndSettle();
        final save = find
            .ancestor(
              of: find.text(fullPage ? 'Save Changes' : 'Save'),
              matching: find.byWidgetPredicate(
                (widget) => widget is FilledButton,
              ),
            )
            .first;
        await tester.ensureVisible(save);
        final action = tester.widget<FilledButton>(save).onPressed;
        expect(action, isA<Future<void> Function()>());
        await tester.runAsync(action! as Future<void> Function());
        await tester.pumpAndSettle();
        final saved = container.read(remindersProvider).single;
        expect(saved.triggerTime!.toIso8601String(), original);
        final rows = await tester.runAsync(
          () => database.read(
            database.captureGeneration(),
            (db) =>
                db.query('Reminders', where: 'id = ?', whereArgs: [task.id]),
          ),
        );
        expect(rows!.single['trigger_time'], original);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'notice categorization compares UTC and local instants correctly',
    (tester) async {
      final due = task.triggerTime!.toLocal();
      for (final now in [due.subtract(const Duration(minutes: 1)), due]) {
        await show(
          tester,
          ReminderNoticePanel(
            reminders: [task],
            now: now,
            onDismiss: (_) {},
            onSnooze: (_) {},
            onComplete: (_) {},
          ),
        );
        expect(
          find.text('${now.isBefore(due) ? 'Due soon' : 'Reminder Due'} · 1'),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
}
