import 'dart:async';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/notification_permission_service.dart';
import 'package:dont_forget/services/notification_schedule_reader.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/formatters/local_date_time.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/input_bottom_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Recorder implements AudioRecorder {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TwoTasks extends LLMService {
  @override
  Future<List<Reminder>> extractTasks(
    String text,
    AppSettings settings,
  ) async => [
    Reminder(id: 'saved-first', taskTitle: 'first', quadrantLevel: 2),
    Reminder(id: 'fails-second', taskTitle: 'second', quadrantLevel: 2),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _TwoTasks model;

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('dontforget-p0-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    model = _TwoTasks();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(
          NotificationService.forTesting(
            FlutterLocalNotificationsPlugin(),
            usesNativeNotifications: false,
          ),
        ),
        llmServiceProvider.overrideWithValue(model),
        homeControllerProvider.overrideWith(
          (ref) => HomeController(ref, audioRecorder: _Recorder()),
        ),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    container.read(homeControllerProvider);
  });

  tearDown(() async {
    container.dispose();
    model.dispose();
    await database.close(createBackup: false);
    await directory.delete(recursive: true);
  });

  Future<void> submitAndWaitForFailure(String text) async {
    final completed = Completer<void>();
    final subscription = container.listen(homeControllerProvider, (_, state) {
      if (state.failedTextDrafts.isNotEmpty &&
          state.pendingTasksCount == 0 &&
          !completed.isCompleted) {
        completed.complete();
      }
    });
    try {
      await container.read(homeControllerProvider.notifier).processText(text);
      await completed.future.timeout(const Duration(seconds: 5));
    } finally {
      subscription.close();
    }
  }

  test('failed local insertion retains the exact submitted text', () async {
    final db = await database.database;
    await db.execute(
      "CREATE TRIGGER reject_capture BEFORE INSERT ON Reminders "
      "BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
    );
    const input = '  first line\nsecond line  ';
    await submitAndWaitForFailure(input);
    expect(
      container.read(homeControllerProvider).failedTextDrafts.single.text,
      input,
    );
    expect(await db.query('Reminders'), isEmpty);
  });

  test('concurrent failures retain each input independently', () async {
    final db = await database.database;
    await db.execute(
      "CREATE TRIGGER reject_capture BEFORE INSERT ON Reminders "
      "BEGIN SELECT RAISE(ABORT, 'synthetic'); END",
    );
    final completed = Completer<void>();
    final subscription = container.listen(homeControllerProvider, (_, state) {
      if (state.failedTextDrafts.length == 2 &&
          state.pendingTasksCount == 0 &&
          !completed.isCompleted) {
        completed.complete();
      }
    });
    try {
      final home = container.read(homeControllerProvider.notifier);
      await home.processText('first');
      await home.processText('second');
      await completed.future.timeout(const Duration(seconds: 5));
      expect(
        container
            .read(homeControllerProvider)
            .failedTextDrafts
            .map((d) => d.text)
            .toSet(),
        {'first', 'second'},
      );
      expect(await db.query('Reminders'), isEmpty);
    } finally {
      subscription.close();
    }
  });

  test(
    'partial AI save retains input without retrying already saved tasks',
    () async {
      await container
          .read(settingsProvider.notifier)
          .updateSettings(
            container.read(settingsProvider).copyWith(apiKey: 'synthetic-only'),
          );
      final db = await database.database;
      await db.execute(
        "CREATE TRIGGER reject_second BEFORE INSERT ON Reminders "
        "WHEN NEW.id = 'fails-second' BEGIN SELECT RAISE(ABORT, 'synthetic'); END",
      );
      await submitAndWaitForFailure('synthetic request');
      expect((await db.query('Reminders')).map((row) => row['id']), [
        'saved-first',
      ]);
      expect(
        container.read(homeControllerProvider).failedTextDrafts.single.text,
        'synthetic request',
      );
    },
  );

  testWidgets('restoring a failed submission preserves newer input', (
    tester,
  ) async {
    final db = await tester.runAsync(() async {
      final db = await database.database;
      await db.execute(
        "CREATE TRIGGER reject_capture BEFORE INSERT ON Reminders "
        "BEGIN SELECT RAISE(ABORT, 'synthetic'); END",
      );
      await submitAndWaitForFailure('failed original');
      return db;
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: InlineFeedback(child: Scaffold(body: InputBottomBar())),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'newer draft');
    await tester.ensureVisible(
      find.byKey(const ValueKey('restore-failed-input')),
    );
    await tester.tap(find.byKey(const ValueKey('restore-failed-input')));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'newer draft\nfailed original',
    );
    expect(container.read(homeControllerProvider).failedTextDrafts, isEmpty);
    expect(await tester.runAsync(() => db!.query('Reminders')), isEmpty);
  });

  testWidgets('restoring waits until input method composition is complete', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final db = await database.database;
      await db.execute(
        "CREATE TRIGGER reject_capture BEFORE INSERT ON Reminders "
        "BEGIN SELECT RAISE(ABORT, 'synthetic'); END",
      );
      await submitAndWaitForFailure('failed original');
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('zh'),
          supportedLocales: [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: InlineFeedback(child: Scaffold(body: InputBottomBar())),
        ),
      ),
    );
    await tester.pump();
    final editor = tester.widget<TextField>(find.byType(TextField)).controller!;
    editor.value = const TextEditingValue(
      text: '选词',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    // Invoke the action without changing focus, which would commit composition.
    tester
        .widget<TextButton>(find.byKey(const ValueKey('restore-failed-input')))
        .onPressed!();
    await tester.pump();
    expect(editor.text, '选词');
    expect(editor.value.composing, const TextRange(start: 0, end: 2));
    expect(
      container.read(homeControllerProvider).failedTextDrafts,
      hasLength(1),
    );
    expect(find.text('请先完成输入法选词，再恢复内容。'), findsOneWidget);

    editor.value = editor.value.copyWith(composing: TextRange.empty);
    tester
        .widget<TextButton>(find.byKey(const ValueKey('restore-failed-input')))
        .onPressed!();
    await tester.pump();
    expect(editor.text, '选词\nfailed original');
    expect(container.read(homeControllerProvider).failedTextDrafts, isEmpty);
  });

  testWidgets('failed input stays reachable in a narrow, large-text window', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 667);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(() async {
      final db = await database.database;
      await db.execute(
        "CREATE TRIGGER reject_capture BEFORE INSERT ON Reminders "
        "BEGIN SELECT RAISE(ABORT, 'synthetic'); END",
      );
      await submitAndWaitForFailure('待恢复的记录');
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: InlineFeedback(child: child!),
          ),
          home: const Scaffold(body: InputBottomBar()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('restore-failed-input')),
    );
    await tester.tap(find.byKey(const ValueKey('restore-failed-input')));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '待恢复的记录',
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'single reminder status uses the matching saved occurrence and journal',
    () async {
      final db = await database.database;
      final task = Reminder(
        id: 'schedule',
        taskTitle: 'synthetic',
        quadrantLevel: 2,
        triggerTime: DateTime.now().add(const Duration(hours: 1)),
      );
      await db.insert('Reminders', task.toJson());
      final reader = NotificationScheduleReader(database);
      expect(await reader.readReminder(task), ReminderSchedulePhase.unknown);
      final epoch = await database.readNotificationEpoch();
      await database.withNotificationJournal((journal) async {
        await journal.reset(epoch);
        await journal.begin(
          epoch,
          task.id,
          action: 'schedule',
          triggerUtcMicros: task.triggerTime!.toUtc().microsecondsSinceEpoch,
          noticeRevision: task.noticeRevision,
          attemptedAt: DateTime.now(),
        );
        await journal.record(
          epoch,
          task.id,
          action: 'schedule',
          status: 'submitted',
          triggerUtcMicros: task.triggerTime!.toUtc().microsecondsSinceEpoch,
          noticeRevision: task.noticeRevision,
        );
      });
      expect(await reader.readReminder(task), ReminderSchedulePhase.submitted);
      await database.withNotificationJournal((journal) async {
        await journal.begin(
          epoch,
          task.id,
          action: 'cancel',
          attemptedAt: DateTime.now(),
        );
        await journal.record(
          epoch,
          task.id,
          action: 'cancel',
          status: 'submitted',
        );
      });
      expect(
        await NotificationScheduleReader(
          database,
          isSuppressed: (_) => true,
        ).readReminder(task),
        ReminderSchedulePhase.policyPaused,
      );
      await db.update(
        'Reminders',
        {'notice_revision': 1},
        where: 'id = ?',
        whereArgs: [task.id],
      );
      expect(await reader.readReminder(task), ReminderSchedulePhase.unknown);
      expect(
        await reader.readReminder(task.copyWith(noticeRevision: 1)),
        ReminderSchedulePhase.needsAttention,
      );
    },
  );

  testWidgets(
    'detail reports permission and submitted status without claiming delivery',
    (tester) async {
      final task = Reminder(
        id: 'ui',
        taskTitle: 'Synthetic',
        quadrantLevel: 2,
        triggerTime: DateTime.now().add(const Duration(hours: 2)),
        timeOrigin: ReminderTimeOrigin.aiSuggested,
      );
      final uiContainer = ProviderContainer(
        parent: container,
        overrides: [
          reminderScheduleReaderProvider.overrideWithValue(
            (_) async => ReminderSchedulePhase.submitted,
          ),
          notificationPermissionReaderProvider.overrideWithValue(
            () async => const NotificationPermissionSnapshot(
              authorization: NotificationAuthorization(
                NotificationPermissionStatus.notEnabled,
              ),
              exactAlarms: NotificationPermissionStatus.unsupported,
              platform: TargetPlatform.iOS,
            ),
          ),
        ],
      );
      addTearDown(uiContainer.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: uiContainer,
          child: MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (_, child) => InlineFeedback(child: child!),
            home: TaskDetailScreen(task: task),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('刷新状态'));
      await tester.tap(find.text('刷新状态'));
      await tester.pumpAndSettle();
      expect(find.text('已提交系统安排，不代表已经送达。'), findsOneWidget);
      expect(find.textContaining('未开启'), findsOneWidget);
      expect(find.text('AI 建议时间 · 可修改'), findsOneWidget);

      // Changing the category may change focus-policy suppression, so the
      // snapshot of the saved category must no longer be shown as current.
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '常规待办'))
          .onSelected!(true);
      await tester.pump();
      expect(find.text('提醒设置已修改，保存后更新提醒。'), findsOneWidget);
      expect(find.text('已提交系统安排，不代表已经送达。'), findsNothing);
    },
  );

  test('next 20:00 uses local calendar days at the boundary', () {
    expect(
      nextReminderClockTime(DateTime(2026, 10, 27, 19, 59), 20),
      DateTime(2026, 10, 27, 20),
    );
    expect(
      nextReminderClockTime(DateTime(2026, 10, 27, 20), 20),
      DateTime(2026, 10, 28, 20),
    );
    expect(
      nextReminderClockTime(DateTime(2026, 3, 7, 21), 20),
      DateTime(2026, 3, 8, 20),
    );
    expect(
      nextReminderClockTime(DateTime(2026, 10, 31, 21), 20),
      DateTime(2026, 11, 1, 20),
    );
    expect(
      nextReminderClockTime(DateTime(2026, 11, 1, 12), 9, tomorrow: true),
      DateTime(2026, 11, 2, 9),
    );
  });
}
