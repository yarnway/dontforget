import 'package:flutter/services.dart';
import 'dart:async';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/editor_keyboard_actions.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:dont_forget/ui/widgets/task_details_dialog.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/services/notification_service.dart';

// Observe the real queued SQLite operation instead of assuming it finishes in 50 ms.
class _ObservedRemindersNotifier extends RemindersNotifier {
  _ObservedRemindersNotifier(super.database, NotificationService notifications)
    : super(notifications: notifications);
  Future<void>? lastWrite;

  Future<T> _observe<T>(Future<T> operation) {
    lastWrite = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  @override
  Future<ReminderActionResult> addReminder(Reminder task) =>
      _observe(super.addReminder(task));
  @override
  Future<ReminderActionResult> restoreDeletedReminder(
    Reminder task,
    DataGeneration generation,
  ) => _observe(super.restoreDeletedReminder(task, generation));
  @override
  Future<ReminderActionResult> updateReminder(
    Reminder task, {
    Reminder? baseline,
  }) => _observe(super.updateReminder(task, baseline: baseline));
  @override
  Future<ReminderActionResult> deleteReminder(String id) =>
      _observe(super.deleteReminder(id));
}

class _DetailNotifications implements NotificationService {
  final canceled = <String>[];
  final scheduled = <Reminder>[];
  final reconciled = <Reminder>[];
  bool failNative = false;
  Completer<void>? nativeEntered;
  Future<void>? nativePause;
  @override
  Future<void> cancelReminder(String id) async => canceled.add(id);
  @override
  Future<void> scheduleReminder(Reminder task) async => scheduled.add(task);
  @override
  Future<void> cancelReminderStrict(String id) async {
    await cancelReminder(id);
    if (failNative) throw StateError('isolated native cancellation failure');
  }

  @override
  Future<void> scheduleReminderStrict(Reminder task) async {
    nativeEntered?.complete();
    await nativePause;
    reconciled.add(task);
    await cancelReminder(task.id);
    if (failNative) throw StateError('isolated native update failure');
    if (!task.isCompleted &&
        task.noticeAcknowledgedAt == null &&
        (task.triggerTime?.isAfter(DateTime.now()) ?? false)) {
      await scheduleReminder(task);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory testDirectory;
  late DatabaseHelper testDatabase;
  late ProviderContainer container;
  late _ObservedRemindersNotifier notifier;
  late _DetailNotifications notifications;
  setUpAll(() async {
    sqfliteFfiInit();
    testDirectory = await Directory.systemTemp.createTemp('dontforget-widget-');
    testDatabase = DatabaseHelper.forTesting(
      testDirectory.path,
      databaseFactoryFfi,
    );
    notifications = _DetailNotifications();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(testDatabase),
        remindersProvider.overrideWith(
          (ref) => notifier = _ObservedRemindersNotifier(
            testDatabase,
            notifications,
          ),
        ),
        notificationServiceProvider.overrideWithValue(notifications),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
  });
  tearDownAll(() async {
    container.dispose();
    await testDatabase.close();
    await testDirectory.delete(recursive: true);
  });

  Future<void> performWrite(WidgetTester tester, Finder button) async {
    expect(button.hitTestable(), findsOneWidget);
    final target = tester.widget(
      find
          .ancestor(
            of: button,
            matching: find.byWidgetPredicate(
              (widget) => widget is IconButton || widget is ButtonStyleButton,
            ),
          )
          .first,
    );
    final callback = target is IconButton
        ? target.onPressed
        : (target as ButtonStyleButton).onPressed;
    expect(callback, isNotNull);
    if (callback is Future<void> Function()) {
      // Keep the whole UI command in the real async zone, including notification
      // reconciliation and route completion after the queued database write.
      await tester.runAsync(callback);
    } else {
      // Inline Undo dispatches a void callback; observe its actual queued write.
      await tester.runAsync(() async {
        final previous = notifier.lastWrite;
        await tester.tap(button);
        final operation = notifier.lastWrite;
        expect(operation, isNotNull);
        expect(operation, isNot(same(previous)));
        await operation;
      });
    }
    await tester.pumpAndSettle();
  }

  Future<void> openDetail(
    WidgetTester tester,
    Reminder task, {
    bool dialog = false,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (_, child) => InlineFeedback(child: child!),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => dialog
                        ? Scaffold(body: TaskDetailsDialog(task: task))
                        : TaskDetailScreen(task: task),
                  ),
                ),
                child: const Text('Open QA'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open QA'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'TaskDetailScreen renders task title, summary, reminder time, and professional categories',
    (WidgetTester tester) async {
      final task = Reminder(
        id: 'test-123',
        taskTitle: '参加周三技术评审会',
        taskSummary: '需要准备PPT架构图与云原生评估报告',
        quadrantLevel: 1,
        triggerTime: DateTime.now().add(const Duration(hours: 2)),
      );

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
            builder: (context, child) => InlineFeedback(child: child!),
            home: TaskDetailScreen(task: task),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify Title and Summary fields
      expect(find.text('事项详情'), findsOneWidget);
      expect(find.text('参加周三技术评审会'), findsOneWidget);
      expect(find.text('需要准备PPT架构图与云原生评估报告'), findsOneWidget);

      // Verify Professional Categories exist
      expect(find.text('紧急提醒'), findsWidgets);
      expect(find.text('重点跟进'), findsWidgets);
      expect(find.text('常规待办'), findsWidgets);
      expect(find.text('备忘便签'), findsWidgets);

      // Verify Quick Presets exist
      expect(find.text('+15分钟'), findsOneWidget);
      expect(find.text('+1小时'), findsOneWidget);
      expect(find.text('今晚 20:00'), findsOneWidget);
      expect(find.text('明天 09:00'), findsOneWidget);

      // Verify Save button
      expect(find.text('保存修改'), findsOneWidget);
    },
  );
  testWidgets('promotion alert appears only for active promoted Q1 tasks', (
    tester,
  ) async {
    for (final scenario in [
      (quadrant: 3, completed: true, promoted: true, visible: false),
      (quadrant: 3, completed: false, promoted: true, visible: false),
      (quadrant: 1, completed: true, promoted: true, visible: false),
      (quadrant: 1, completed: false, promoted: false, visible: false),
      (quadrant: 1, completed: false, promoted: true, visible: true),
    ]) {
      await openDetail(
        tester,
        Reminder(
          id: 'detail-promotion-visibility',
          taskTitle: 'Promotion visibility QA',
          quadrantLevel: scenario.quadrant,
          isCompleted: scenario.completed,
          isDynamicallyPromoted: scenario.promoted,
          triggerTime: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      );
      final expected = scenario.visible ? findsOneWidget : findsNothing;
      expect(find.text('已根据临近提醒时间自动跃迁至 Q1'), expected);
      expect(find.text('任务距离触发已不足 24 小时，底层自动跃迁为紧急且重要，触发系统强提醒。'), expected);
      expect(find.text('撤回至 Q2'), expected);
      expect(
        find.text('距离提醒: 已到期'),
        scenario.completed ? findsNothing : findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
  testWidgets('deleting a detail route retains Undo and restores the task', (
    tester,
  ) async {
    final task = Reminder(
      id: 'delete-route-qa',
      taskTitle: 'Delete route QA',
      quadrantLevel: 1,
    );
    await tester.runAsync(
      () => container.read(remindersProvider.notifier).addReminder(task),
    );
    await openDetail(tester, task);
    await performWrite(tester, find.byIcon(Icons.delete_outline_rounded));
    expect(tester.takeException(), isNull);
    expect(
      container.read(remindersProvider).any((r) => r.id == task.id),
      isFalse,
    );
    await tester.pump(const Duration(seconds: 20));
    expect(find.text('撤销'), findsOneWidget);
    await performWrite(tester, find.text('撤销'));
    expect(
      container.read(remindersProvider).any((r) => r.id == task.id),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('failed deletion keeps the detail route and its saved task', (
    tester,
  ) async {
    final task = Reminder(
      id: 'failed-detail-delete',
      taskTitle: 'Keep saved task',
      quadrantLevel: 1,
    );
    await tester.runAsync(() => notifier.addReminder(task));
    notifications.canceled.clear();
    final db = await tester.runAsync(() => testDatabase.database);
    await tester.runAsync(
      () => db!.execute(
        "CREATE TRIGGER reject_detail_delete BEFORE DELETE ON Reminders WHEN OLD.id = 'failed-detail-delete' BEGIN SELECT RAISE(ABORT, 'test failure'); END",
      ),
    );
    try {
      await openDetail(tester, task);
      await performWrite(tester, find.byIcon(Icons.delete_outline_rounded));
      expect(find.byType(TaskDetailScreen), findsOneWidget);
      expect(
        container.read(remindersProvider).any((r) => r.id == task.id),
        isTrue,
      );
      expect(find.text('删除失败，请重试。'), findsOneWidget);
      expect(notifications.canceled, isNot(contains(task.id)));
      expect(find.text('撤销'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    } finally {
      await tester.runAsync(
        () => db!.execute('DROP TRIGGER reject_detail_delete'),
      );
    }
  });

  testWidgets('failed save retains the draft and does not change notifications', (
    tester,
  ) async {
    final task = Reminder(
      id: 'failed-detail-save',
      taskTitle: 'Original title',
      quadrantLevel: 1,
    );
    await tester.runAsync(() => notifier.addReminder(task));
    notifications.canceled.clear();
    final db = await tester.runAsync(() => testDatabase.database);
    await tester.runAsync(
      () => db!.execute(
        "CREATE TRIGGER reject_detail_save BEFORE UPDATE ON Reminders WHEN OLD.id = 'failed-detail-save' BEGIN SELECT RAISE(ABORT, 'test failure'); END",
      ),
    );
    try {
      await openDetail(tester, task);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.controller?.text == task.taskTitle,
        ),
        'Unsaved draft',
      );
      await tester.ensureVisible(find.text('保存修改'));
      await performWrite(tester, find.text('保存修改'));
      expect(find.byType(TaskDetailScreen), findsOneWidget);
      expect(find.text('Unsaved draft'), findsOneWidget);
      expect(
        container
            .read(remindersProvider)
            .firstWhere((r) => r.id == task.id)
            .taskTitle,
        task.taskTitle,
      );
      expect(find.text('提醒更新失败，请重试。'), findsOneWidget);
      expect(notifications.canceled, isNot(contains(task.id)));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    } finally {
      await tester.runAsync(
        () => db!.execute('DROP TRIGGER reject_detail_save'),
      );
    }
  });

  for (final dialog in [false, true]) {
    testWidgets(
      '${dialog ? 'dialog' : 'full detail'} native failure keeps saved changes open for retry',
      (tester) async {
        final task = Reminder(
          id: 'native-save-retry-$dialog',
          taskTitle: 'Before native failure',
          quadrantLevel: 3,
          triggerTime: DateTime.now().add(const Duration(hours: 1)),
        );
        await tester.runAsync(() => notifier.addReminder(task));
        await openDetail(tester, task, dialog: dialog);
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.controller?.text == task.taskTitle,
          ),
          'Saved despite native failure',
        );
        if (!dialog) {
          // This also changes occurrence metadata on persistence. Native must
          // receive that committed revision, never the pre-save UI candidate.
          await tester.ensureVisible(find.text('+15分钟'));
          await tester.tap(find.text('+15分钟'));
        } else {
          // A background schedule change while the dialog is open must also
          // be retained and supplied to native reconciliation.
          await tester.runAsync(
            () => notifier.updateReminder(
              task.copyWith(
                triggerTime: DateTime.now().add(const Duration(minutes: 30)),
              ),
            ),
          );
        }
        final save = find.text(dialog ? '保存' : '保存修改');
        notifications.failNative = true;
        try {
          await tester.ensureVisible(save);
          await performWrite(tester, save);
          expect(
            find.byType(dialog ? TaskDetailsDialog : TaskDetailScreen),
            findsOneWidget,
          );
          const warning = '已保存，但系统提醒未能更新。请检查通知权限并重新保存任务。';
          expect(find.text(warning), findsOneWidget);
          expect(find.text('提醒更新失败，请重试。'), findsNothing);
          final saved = container
              .read(remindersProvider)
              .firstWhere((item) => item.id == task.id);
          expect(saved.taskTitle, 'Saved despite native failure');
          expect(saved.noticeRevision, task.noticeRevision + 1);
          final rows = await tester.runAsync(
            () => testDatabase.read(
              testDatabase.captureGeneration(),
              (db) =>
                  db.query('Reminders', where: 'id = ?', whereArgs: [task.id]),
            ),
          );
          expect(rows!.single, saved.toJson());
          expect(notifications.reconciled.last.toJson(), saved.toJson());

          notifications.failNative = false;
          await tester.ensureVisible(save);
          await performWrite(tester, save);
          expect(
            find.byType(dialog ? TaskDetailsDialog : TaskDetailScreen),
            findsNothing,
          );
          expect(find.text(warning), findsNothing);
          expect(notifications.scheduled.last.toJson(), saved.toJson());
          expect(
            container
                .read(remindersProvider)
                .firstWhere((item) => item.id == task.id)
                .noticeRevision,
            saved.noticeRevision,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          notifications.failNative = false;
        }
      },
    );
  }

  testWidgets('save closes the editor after the queued change is persisted', (
    tester,
  ) async {
    final task = Reminder(
      id: 'saved-detail',
      taskTitle: 'Before editing',
      quadrantLevel: 1,
    );
    await tester.runAsync(() => notifier.addReminder(task));
    await openDetail(tester, task);
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == task.taskTitle,
      ),
      'Saved title',
    );
    await tester.ensureVisible(find.text('保存修改'));
    await performWrite(tester, find.text('保存修改'));
    expect(find.byType(TaskDetailScreen), findsNothing);
    expect(
      container
          .read(remindersProvider)
          .firstWhere((r) => r.id == task.id)
          .taskTitle,
      'Saved title',
    );
    final db = await tester.runAsync(() => testDatabase.database);
    final rows = await tester.runAsync(
      () => db!.query('Reminders', where: 'id = ?', whereArgs: [task.id]),
    );
    expect(rows!.single['task_title'], 'Saved title');
    expect(notifications.canceled, contains(task.id));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('saving a long-open editor preserves newer background fields', (
    tester,
  ) async {
    final task = Reminder(
      id: 'detail-background-merge',
      taskTitle: 'Editor baseline',
      taskSummary: 'Original summary',
      quadrantLevel: 2,
      triggerTime: DateTime.now().add(const Duration(days: 3)),
      linkedTaskIds: ['initial-link'],
    );
    await tester.runAsync(() => notifier.addReminder(task));
    await openDetail(tester, task);
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == task.taskTitle,
      ),
      'My edited title',
    );
    final background = task.copyWith(
      quadrantLevel: 1,
      isDynamicallyPromoted: true,
      taskSummary: 'New synchronized summary',
      subTasks: '["AI-created subtask"]',
      triggerTime: task.triggerTime!.add(const Duration(hours: 2)),
      isRecurring: true,
      recurrenceRule: 'daily',
      recurrenceDescription: 'Daily',
      contextTrigger: '{"type":"profile","value":"office"}',
      linkedTaskIds: ['initial-link', 'background-link'],
    );
    await tester.runAsync(() => notifier.updateReminder(background));
    await tester.pump();
    await tester.ensureVisible(find.text('保存修改'));
    await performWrite(tester, find.text('保存修改'));
    final saved = container
        .read(remindersProvider)
        .firstWhere((r) => r.id == task.id);
    expect(saved.taskTitle, 'My edited title');
    expect(saved.taskSummary, background.taskSummary);
    expect(saved.quadrantLevel, 1);
    expect(saved.isDynamicallyPromoted, isTrue);
    expect(saved.subTasks, background.subTasks);
    expect(saved.triggerTime, background.triggerTime);
    expect(saved.isRecurring, isTrue);
    expect(saved.recurrenceRule, 'daily');
    expect(saved.contextTrigger, background.contextTrigger);
    expect(saved.linkedTaskIds, contains('background-link'));
    expect(notifications.scheduled.last.toJson(), saved.toJson());
    expect(find.byType(TaskDetailScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'explicitly clearing time survives a concurrent background edit',
    (tester) async {
      final task = Reminder(
        id: 'detail-clear-time',
        taskTitle: 'Clear scheduled time',
        quadrantLevel: 1,
        triggerTime: DateTime.now().add(const Duration(days: 3)),
      );
      await tester.runAsync(() => notifier.addReminder(task));
      await openDetail(tester, task);
      await tester.ensureVisible(find.byIcon(Icons.clear));
      await tester.tap(find.byIcon(Icons.clear));
      await tester.runAsync(
        () => notifier.updateReminder(
          task.copyWith(
            taskSummary: 'Preserve this background summary',
            triggerTime: task.triggerTime!.add(const Duration(days: 1)),
          ),
        ),
      );
      await tester.pump();
      notifications.scheduled.clear();
      await tester.ensureVisible(find.text('保存修改'));
      await performWrite(tester, find.text('保存修改'));
      final saved = container
          .read(remindersProvider)
          .firstWhere((r) => r.id == task.id);
      expect(saved.triggerTime, isNull);
      expect(saved.taskSummary, 'Preserve this background summary');
      expect(notifications.scheduled.where((r) => r.id == task.id), isEmpty);
      expect(notifications.canceled, contains(task.id));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'saving an externally deleted task does not recreate or schedule it',
    (tester) async {
      final task = Reminder(
        id: 'detail-already-deleted',
        taskTitle: 'Remove while open',
        quadrantLevel: 1,
      );
      await tester.runAsync(() => notifier.addReminder(task));
      await openDetail(tester, task);
      await tester.runAsync(() => notifier.deleteReminder(task.id));
      notifications.canceled.clear();
      await tester.pump();
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.controller?.text == task.taskTitle,
        ),
        'Must not revive',
      );
      await tester.ensureVisible(find.text('保存修改'));
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(find.byType(TaskDetailScreen), findsOneWidget);
      expect(find.text('提醒更新失败，请重试。'), findsOneWidget);
      expect(
        container.read(remindersProvider).where((r) => r.id == task.id),
        isEmpty,
      );
      expect(notifications.scheduled.where((r) => r.id == task.id), isEmpty);
      expect(notifications.canceled, isNot(contains(task.id)));
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final dialog in [false, true]) {
    testWidgets(
      '${dialog ? 'dialog' : 'detail'} deletion reports native failure and keeps Undo',
      (tester) async {
        final task = Reminder(
          id: 'cancel-failure-$dialog',
          taskTitle: 'Undo after cancel failure',
          quadrantLevel: 3,
          triggerTime: DateTime.now().add(const Duration(hours: 2)),
        );
        await tester.runAsync(() => notifier.addReminder(task));
        final saved = container
            .read(remindersProvider)
            .singleWhere((r) => r.id == task.id);
        await openDetail(tester, task, dialog: dialog);
        notifications.failNative = true;
        try {
          final button = dialog
              ? find.byIcon(Icons.delete_outline)
              : find.byIcon(Icons.delete_outline_rounded);
          await tester.ensureVisible(button);
          await performWrite(tester, button);
          expect(
            container.read(remindersProvider).where((r) => r.id == task.id),
            isEmpty,
          );
          expect(
            find.text('任务已删除，但系统提醒未能移除。请在设置中点击“重新安排提醒”重试。'),
            findsOneWidget,
          );
          expect(find.text('删除失败，请重试。'), findsNothing);
          expect(find.text('撤销'), findsOneWidget);
          notifications.failNative = false;
          await performWrite(tester, find.text('撤销'));
          final restored = container
              .read(remindersProvider)
              .singleWhere((r) => r.id == task.id);
          expect(restored.toJson(), saved.toJson());
          expect(notifications.scheduled.last.toJson(), saved.toJson());
          await tester.pumpWidget(const SizedBox());
        } finally {
          notifications.failNative = false;
        }
      },
    );
  }
  testWidgets(
    'native menu save resolves current editor and rejects modal or composing focus',
    (tester) async {
      final task = Reminder(
        id: 'native-menu-save',
        taskTitle: 'Original menu title',
        quadrantLevel: 2,
      );
      await tester.runAsync(() => notifier.addReminder(task));
      await openDetail(tester, task);
      final title = find.byKey(const ValueKey('detail-title'));
      await tester.enterText(title, 'Native menu saved');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(EditorKeyboardActions.saveFocusedEditor(), false);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      await tester.tap(title);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '组合',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      expect(EditorKeyboardActions.saveFocusedEditor(), false);
      await tester.enterText(title, 'Native menu saved');
      await tester.runAsync(() async {
        expect(EditorKeyboardActions.saveFocusedEditor(), true);
        await notifier.lastWrite;
      });
      await tester.pumpAndSettle();
      expect(find.byType(TaskDetailScreen), findsNothing);
      expect(
        container
            .read(remindersProvider)
            .singleWhere((r) => r.id == task.id)
            .taskTitle,
        'Native menu saved',
      );
      expect(EditorKeyboardActions.saveFocusedEditor(), false);
    },
  );

  testWidgets(
    'detail Escape guards draft, modal owns Escape, command-S saves',
    (tester) async {
      final task = Reminder(
        id: 'keyboard-detail',
        taskTitle: 'Original',
        quadrantLevel: 2,
      );
      await tester.runAsync(() => notifier.addReminder(task));
      await openDetail(tester, task);
      final title = find.byKey(const ValueKey('detail-title'));
      await tester.enterText(title, 'Keyboard saved');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('继续编辑'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(TaskDetailScreen), findsOneWidget);
      await tester.tap(title);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '组合',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.enterText(title, 'Keyboard saved');
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await notifier.lastWrite;
      });
      await tester.pumpAndSettle();
      expect(find.byType(TaskDetailScreen), findsNothing);
      expect(
        container
            .read(remindersProvider)
            .singleWhere((r) => r.id == task.id)
            .taskTitle,
        'Keyboard saved',
      );
    },
  );

  testWidgets(
    'dirty back keeps edits, discard preserves database, reverted draft exits',
    (tester) async {
      final task = Reminder(
        id: 'unsaved-discard',
        taskTitle: 'Original title',
        quadrantLevel: 2,
      );
      await tester.runAsync(() => notifier.addReminder(task));
      await openDetail(tester, task);
      await tester.enterText(
        find.byKey(const ValueKey('detail-title')),
        'Unsaved title',
      );
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pumpAndSettle();
      expect(find.text('继续编辑'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved title'), findsOneWidget);
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      await navigator.maybePop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(TaskDetailScreen), findsNothing);
      expect(
        container
            .read(remindersProvider)
            .singleWhere((r) => r.id == task.id)
            .taskTitle,
        'Original title',
      );
      await tester.tap(find.text('Open QA'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('detail-title')),
        'Temporary',
      );
      await tester.enterText(
        find.byKey(const ValueKey('detail-title')),
        'Original title',
      );
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Open QA'), findsOneWidget);
    },
  );

  testWidgets(
    'save and leave persists; invalid title keeps the draft visible',
    (tester) async {
      final task = Reminder(
        id: 'unsaved-save',
        taskTitle: 'Before save',
        quadrantLevel: 2,
      );
      await tester.runAsync(() => notifier.addReminder(task));
      await openDetail(tester, task);
      await tester.enterText(find.byKey(const ValueKey('detail-title')), '');
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并返回'));
      await tester.pumpAndSettle();
      expect(find.byType(TaskDetailScreen), findsOneWidget);
      expect(
        container
            .read(remindersProvider)
            .singleWhere((r) => r.id == task.id)
            .taskTitle,
        'Before save',
      );
      await tester.enterText(
        find.byKey(const ValueKey('detail-title')),
        'Saved by exit',
      );
      await tester.runAsync(() async {
        final back = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.arrow_back_ios_new_rounded),
        );
        final exit = (back.onPressed! as Future<void> Function())();
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存并返回'));
        await exit;
      });
      await tester.pumpAndSettle();
      expect(
        container
            .read(remindersProvider)
            .singleWhere((r) => r.id == task.id)
            .taskTitle,
        'Saved by exit',
      );
      expect(find.byType(TaskDetailScreen), findsNothing);
    },
  );

  testWidgets('native sync failure after save leaves a clean draft', (
    tester,
  ) async {
    final task = Reminder(
      id: 'unsaved-native',
      taskTitle: 'Before native failure',
      quadrantLevel: 2,
    );
    await tester.runAsync(() => notifier.addReminder(task));
    await openDetail(tester, task);
    await tester.enterText(
      find.byKey(const ValueKey('detail-title')),
      'Persisted despite native failure',
    );
    notifications.failNative = true;
    try {
      await tester.ensureVisible(find.text('保存修改'));
      await performWrite(tester, find.text('保存修改'));
      expect(find.byType(TaskDetailScreen), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(TaskDetailScreen), findsNothing);
      expect(
        container
            .read(remindersProvider)
            .singleWhere((r) => r.id == task.id)
            .taskTitle,
        'Persisted despite native failure',
      );
    } finally {
      notifications.failNative = false;
    }
  });
  testWidgets('typing while native save settles preserves the newer draft', (
    tester,
  ) async {
    final task = Reminder(
      id: 'unsaved-during-write',
      triggerTime: DateTime.now().add(const Duration(hours: 2)),
      taskTitle: 'Before write',
      quadrantLevel: 2,
    );
    await tester.runAsync(() => notifier.addReminder(task));
    await openDetail(tester, task);
    await tester.enterText(
      find.byKey(const ValueKey('detail-title')),
      'Submitted',
    );
    Completer<void>? finish;
    try {
      final save = tester.widget<FilledButton>(
        find.widgetWithIcon(FilledButton, Icons.save_outlined),
      );
      await tester.runAsync(() async {
        notifications.nativeEntered = Completer<void>();
        finish = Completer<void>();
        notifications.nativePause = finish!.future;
        final write = (save.onPressed! as Future<void> Function())();
        await notifications.nativeEntered!.future;
        await tester.enterText(
          find.byKey(const ValueKey('detail-title')),
          'Newer draft',
        );
        finish!.complete();
        await write;
      });
      await tester.pumpAndSettle();
      expect(find.byType(TaskDetailScreen), findsOneWidget);
      expect(find.text('Newer draft'), findsOneWidget);
      expect(
        container
            .read(remindersProvider)
            .singleWhere((r) => r.id == task.id)
            .taskTitle,
        'Submitted',
      );
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pumpAndSettle();
      expect(find.text('继续编辑'), findsOneWidget);
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
    } finally {
      if (finish != null && !finish!.isCompleted) finish!.complete();
      notifications.nativeEntered = null;
      notifications.nativePause = null;
    }
  });
}
