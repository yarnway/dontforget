import 'dart:async';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/context_digest_sheet.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:dont_forget/ui/widgets/task_details_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications implements NotificationService {
  final canceled = <String>[];
  final scheduled = <String>[];
  Completer<void>? cancelStarted;
  Completer<void>? allowCancel;

  @override
  Future<void> cancelReminder(String id) async {
    canceled.add(id);
    cancelStarted?.complete();
    await allowCancel?.future;
  }

  @override
  Future<void> scheduleReminder(Reminder task) async => scheduled.add(task.id);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedLlm extends LLMService {
  final started = Completer<void>();
  final result = Completer<List<String>>();

  @override
  Future<List<String>> decomposeTaskToMicroHabits(
    Reminder task,
    AppSettings settings, {
    String language = 'zh',
  }) {
    started.complete();
    return result.future;
  }
}

void main() {
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _Notifications notifications;
  late _DelayedLlm llm;
  late Reminder task;

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('dontforget-ui-epoch-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    notifications = _Notifications();
    llm = _DelayedLlm();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
        llmServiceProvider.overrideWithValue(llm),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    task = Reminder(
      id: 'qa-task',
      taskTitle: 'Original task',
      quadrantLevel: 2,
    );
    await container.read(remindersProvider.notifier).addReminder(task);
  });

  tearDown(() async {
    if (notifications.allowCancel case final pending?
        when !pending.isCompleted) {
      pending.complete();
    }
    container.dispose();
    await database.close();
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
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(body: child),
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

  Future<void> Function() command(WidgetTester tester, String label) {
    final button = find
        .ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate(
            (widget) => widget is ButtonStyleButton,
          ),
        )
        .first;
    final callback = tester.widget<ButtonStyleButton>(button).onPressed!;
    return callback as Future<void> Function();
  }

  Future<void> advanceGeneration() async {
    final lease = await database.beginMaintenance();
    await lease.resume();
    await container.read(remindersProvider.notifier).refreshReminders();
  }

  testWidgets(
    'dialog waits for notification reconciliation and maintenance drains it',
    (tester) async {
      await show(tester, TaskDetailsDialog(task: task));
      await tester.enterText(find.byType(TextField), 'Saved task');
      final save = command(tester, 'Save');
      late Future<void> pending;
      await tester.runAsync(() async {
        notifications.cancelStarted = Completer<void>();
        notifications.allowCancel = Completer<void>();
        pending = save();
        await notifications.cancelStarted!.future.timeout(
          const Duration(seconds: 5),
        );
      });
      await tester.pump();
      expect(find.byType(TaskDetailsDialog), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      var drained = false;
      await tester.runAsync(() async {
        final maintenance = database.beginMaintenance().then((lease) {
          drained = true;
          return lease;
        });
        await Future<void>.delayed(Duration.zero);
        expect(drained, isFalse);
        notifications.allowCancel!.complete();
        await pending;
        await (await maintenance).resume();
      });
      await tester.pumpAndSettle();
      expect(drained, isTrue);
      expect(container.read(remindersProvider).single.taskTitle, 'Saved task');
      // Maintenance invalidated this route before it could report success.
      expect(find.byType(TaskDetailsDialog), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final detail in [false, true]) {
    testWidgets(
      '${detail ? 'full editor' : 'dialog'} cannot save a draft from a previous generation',
      (tester) async {
        await show(
          tester,
          detail ? TaskDetailScreen(task: task) : TaskDetailsDialog(task: task),
        );
        await tester.enterText(find.byType(TextField).first, 'Stale draft');
        await tester.runAsync(() async {
          await advanceGeneration();
          await container
              .read(remindersProvider.notifier)
              .updateReminder(task.copyWith(taskTitle: 'Restored task'));
        });
        await tester.runAsync(
          command(tester, detail ? 'Save Changes' : 'Save'),
        );
        await tester.pumpAndSettle();
        expect(
          container.read(remindersProvider).single.taskTitle,
          'Restored task',
        );
        expect(find.text('Stale draft'), findsOneWidget);
        expect(
          find.text('Could not update this reminder. Please try again.'),
          findsOneWidget,
        );
        expect(notifications.canceled, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'dialog save and delete failures preserve the editor and never announce deletion',
    (tester) async {
      await tester.runAsync(() async {
        final generation = database.captureGeneration();
        await database.writeTransaction(generation, (db) async {
          for (final operation in ['UPDATE', 'DELETE']) {
            await db.execute(
              "CREATE TRIGGER reject_$operation BEFORE $operation ON Reminders BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
            );
          }
        });
      });
      await show(tester, TaskDetailsDialog(task: task));
      await tester.enterText(find.byType(TextField), 'Keep draft');
      await tester.runAsync(command(tester, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Keep draft'), findsOneWidget);
      await tester.runAsync(command(tester, 'Delete Task'));
      await tester.pumpAndSettle();
      expect(find.byType(TaskDetailsDialog), findsOneWidget);
      expect(
        find.text('Could not delete this task. Please try again.'),
        findsOneWidget,
      );
      expect(find.text('Undo'), findsNothing);
      expect(
        container.read(remindersProvider).single.taskTitle,
        'Original task',
      );
      expect(notifications.canceled, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Undo cannot restore a deleted task after maintenance advances the generation',
    (tester) async {
      await show(tester, TaskDetailsDialog(task: task));
      await tester.runAsync(command(tester, 'Delete Task'));
      await tester.pumpAndSettle();
      expect(container.read(remindersProvider), isEmpty);
      expect(find.text('Undo'), findsOneWidget);
      await tester.runAsync(advanceGeneration);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(container.read(remindersProvider), isEmpty);
      expect(
        find.text('Could not update this reminder. Please try again.'),
        findsOneWidget,
      );
      expect(notifications.scheduled, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'micro-habit response from before maintenance cannot change restored task',
    (tester) async {
      await show(tester, TaskCard(task: task, onPlayMedia: () {}));
      late Future<void> pending;
      await tester.runAsync(() async {
        pending = command(tester, '5-Min Micro Habits')();
        await llm.started.future;
        // This must finish while the network response remains pending.
        await advanceGeneration().timeout(const Duration(seconds: 5));
        await container
            .read(remindersProvider.notifier)
            .updateReminder(task.copyWith(subTasks: '["Restored step"]'));
        llm.result.complete(['Old response step']);
        await pending;
      });
      await tester.pumpAndSettle();
      expect(
        container.read(remindersProvider).single.subTasks,
        '["Restored step"]',
      );
      expect(notifications.scheduled, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'an old context digest cannot complete a restored task with the same id',
    (tester) async {
      await show(tester, ContextDigestSheet(digestReminders: [task]));
      await tester.runAsync(advanceGeneration);
      final button = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Mark as Done',
        ),
      );
      await tester.runAsync(button.onPressed as Future<void> Function());
      await tester.pumpAndSettle();
      expect(container.read(remindersProvider).single.isCompleted, isFalse);
      expect(
        find.text('Could not update this reminder. Please try again.'),
        findsOneWidget,
      );
      expect(notifications.canceled, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
