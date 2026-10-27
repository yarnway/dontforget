import 'package:dont_forget/models/settings.dart';
import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/input_bottom_bar.dart';
import 'package:dont_forget/ui/widgets/task_workspace_overview.dart';
import 'package:dont_forget/ui/widgets/learning_queue_panel.dart';
import 'package:dont_forget/ui/widgets/capture_preview_dialog.dart';
import 'package:dont_forget/ui/screens/notification_repair_screen.dart';
import 'package:dont_forget/ui/widgets/notification_permission_panel.dart';
import 'package:dont_forget/services/learning_queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/workspace_drafts.dart';

class _FailableNotifications extends NotificationService {
  _FailableNotifications()
    : super.forTesting(
        FlutterLocalNotificationsPlugin(),
        usesNativeNotifications: false,
      );
  bool failCancel = false;
  @override
  Future<void> cancelReminderStrict(String id) async {
    if (failCancel) throw StateError('Synthetic cancellation failure');
    await super.cancelReminderStrict(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _FailableNotifications notifications;
  const recorder = MethodChannel('com.llfbandit.record/messages');
  setUp(() async {
    sqfliteFfiInit();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorder, (_) async => null);
    directory = await Directory.systemTemp.createTemp('dontforget-phase1-ui-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    notifications = _FailableNotifications();
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
    await container.read(settingsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    await container.read(workspaceDraftsProvider.notifier).ready;
  });
  tearDown(() async {
    container.dispose();
    await notifications.pauseForMaintenance();
    await database.close(createBackup: false);
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorder, null);
  });

  Future<void> show(
    WidgetTester tester, {
    double width = 768,
    double height = 900,
    double scale = 1,
    String language = 'zh',
    Brightness brightness = Brightness.light,
    Widget? tool,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, height));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: brightness,
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: InlineFeedback(child: child!),
          ),
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child:
                      tool ??
                      Consumer(
                        builder: (context, ref, _) => TaskWorkspaceOverview(
                          reminders: ref.watch(remindersProvider),
                          onPlayMedia: (_) {},
                        ),
                      ),
                ),
                const InputBottomBar(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('today combines overdue, planned, pinned and app-only reviews', (
    tester,
  ) async {
    final now = DateTime.now();
    final notifier = container.read(remindersProvider.notifier);
    await tester.runAsync(() async {
      for (final task in [
        Reminder(
          id: 'pin',
          taskTitle: 'Pinned unscheduled',
          quadrantLevel: 2,
          isPinned: true,
        ),
        Reminder(
          id: 'late',
          taskTitle: 'Late task',
          quadrantLevel: 2,
          eventTime: now.subtract(const Duration(days: 1)),
        ),
        Reminder(
          id: 'today',
          taskTitle: 'Today event',
          quadrantLevel: 2,
          eventTime: DateTime(now.year, now.month, now.day, 23, 59),
        ),
        Reminder(
          id: 'review',
          taskTitle: 'App-only review',
          quadrantLevel: 2,
          spacedRepetitionLevel: 1,
          nextReviewAt: now.subtract(const Duration(days: 1)),
        ),
        Reminder(
          id: 'later',
          taskTitle: 'Future task',
          quadrantLevel: 2,
          eventTime: now.add(const Duration(days: 3)),
        ),
      ]) {
        await notifier.addReminder(task);
      }
    });
    await show(tester);
    for (final title in [
      'Pinned unscheduled',
      'Late task',
      'Today event',
      'App-only review',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('Future task'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('workspace-view-future')));
    await tester.pumpAndSettle();
    expect(find.text('Future task'), findsOneWidget);
    expect(find.text('Late task'), findsNothing);
    await drainWorkspaceDrafts(tester, container);
    expect(container.read(workspaceDraftsProvider)['homeView'], 'future');
  });

  testWidgets('restored unsent text can opt out of alarms and AI', (
    tester,
  ) async {
    await tester.runAsync(
      () => container.read(workspaceDraftsProvider.notifier).put('capture', {
        'text': '明天9点仅作记录',
        'id': 'draft-ui',
      }),
    );
    expect(
      container.read(workspaceDraftsProvider)['capture']['text'],
      '明天9点仅作记录',
    );
    await tester.runAsync(
      () => container
          .read(settingsProvider.notifier)
          .updateSettings(
            container
                .read(settingsProvider)
                .copyWith(inputSendMode: InputSendMode.button),
          ),
    );
    await show(tester, width: 375);
    expect(find.text('草稿暂未保存，请保留内容并重试。'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '明天9点仅作记录',
    );
    await tester.tap(find.byKey(const ValueKey('capture-time-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅备忘'));
    await tester.pumpAndSettle();
    expect(find.text('仅本地保存，不调用 AI、不设置提醒。'), findsOneWidget);
    await tester.tap(find.byTooltip('发送'));
    for (var i = 0; i < 100 && container.read(remindersProvider).isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump();
    }
    await drainWorkspaceDrafts(tester, container);
    expect(container.read(remindersProvider).single.triggerTime, isNull);
    // Changing the saved draft's options creates a fresh idempotency key.
    expect(container.read(remindersProvider).single.id, isNot('draft-ui'));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(container.read(workspaceDraftsProvider)['capture'], isNull);
  });

  testWidgets(
    'AI proposal stays unscheduled until it is reviewed and confirmed',
    (tester) async {
      final suggestedTime = DateTime.now().add(const Duration(hours: 3));
      final proposal = Reminder(
        id: 'model-proposal',
        taskTitle: 'AI title',
        quadrantLevel: 2,
        triggerTime: suggestedTime,
        eventTime: suggestedTime.add(const Duration(hours: 1)),
      );
      final original = Reminder(
        id: 'capture-proposal',
        taskTitle: 'Original title',
        sourceText: 'Original input',
        quadrantLevel: 2,
        captureProposalJson: jsonEncode([proposal.toJson()]),
      );
      await tester.runAsync(() async {
        await container
            .read(workspaceDraftsProvider.notifier)
            .put('homeView', 'all');
        await container.read(remindersProvider.notifier).addReminder(original);
      });
      await show(tester, width: 375);
      final review = find.byKey(
        const ValueKey('preview-capture-capture-proposal'),
      );
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(CapturePreviewDialog),
          matching: find.text('确认 AI 解析结果'),
        ),
        findsOneWidget,
      );
      expect(container.read(remindersProvider).single.triggerTime, isNull);
      await tester.ensureVisible(find.text('暂时保留原文'));
      await tester.tap(find.text('暂时保留原文'));
      await tester.pumpAndSettle();
      expect(
        container.read(remindersProvider).single.captureProposalJson,
        isNotNull,
      );
      expect(container.read(remindersProvider).single.triggerTime, isNull);

      await tester.tap(review);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('proposal-title-0')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('proposal-title-0')),
        'Reviewed title',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm-capture-proposal')),
      );
      await tester.tap(find.byKey(const ValueKey('confirm-capture-proposal')));
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await tester.pump();
        if (container.read(remindersProvider).single.captureProposalJson ==
            null) {
          break;
        }
      }
      final accepted = container.read(remindersProvider).single;
      expect(accepted.taskTitle, 'Reviewed title');
      expect(accepted.triggerTime, suggestedTime);
      expect(accepted.timeOrigin, ReminderTimeOrigin.aiSuggested);
      expect(accepted.sourceText, 'Original input');
      expect(accepted.captureProposalJson, isNull);
      expect(tester.takeException(), isNull);
      await tester.runAsync(notifications.pauseForMaintenance);
    },
  );

  testWidgets(
    'AI review preserves explicit time and accepts far future date editing',
    (tester) async {
      final manual = DateTime.now().add(const Duration(hours: 2));
      final proposal = Reminder(
        id: 'model',
        taskTitle: 'Suggested',
        quadrantLevel: 2,
        triggerTime: manual.add(const Duration(hours: 2)),
        eventTime: DateTime(2205, 5, 1),
      );
      final original = Reminder(
        id: 'manual-proposal',
        taskTitle: 'Original',
        quadrantLevel: 2,
        triggerTime: manual,
        timeOrigin: ReminderTimeOrigin.manual,
        captureProposalJson: jsonEncode([proposal.toJson()]),
      );
      await tester.runAsync(() async {
        await container.read(remindersProvider.notifier).addReminder(original);
        await container
            .read(workspaceDraftsProvider.notifier)
            .put('homeView', 'all');
      });
      await show(tester);
      await tester.tap(
        find.byKey(const ValueKey('preview-capture-manual-proposal')),
      );
      await tester.pumpAndSettle();
      final eventEditor = find.byKey(const ValueKey('proposal-event-0'));
      await tester.ensureVisible(eventEditor);
      await tester.tap(eventEditor);
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      final confirm = find.byKey(const ValueKey('confirm-capture-proposal'));
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      for (
        var i = 0;
        i < 100 &&
            container.read(remindersProvider).single.captureProposalJson !=
                null;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await tester.pump();
      }
      final saved = container.read(remindersProvider).single;
      expect(saved.triggerTime, manual);
      expect(saved.timeOrigin, ReminderTimeOrigin.manual);
      expect(saved.eventTime, proposal.eventTime);
      expect(saved.captureProposalJson, isNull);
    },
  );

  testWidgets(
    'pending input dialog cannot change restored drafts after maintenance',
    (tester) async {
      await tester.runAsync(
        () => container.read(workspaceDraftsProvider.notifier).put(
          'pendingCaptures',
          {
            'old': {'id': 'old', 'text': 'Old input'},
          },
        ),
      );
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('pending-captures')));
      await tester.pumpAndSettle();
      await drainWorkspaceDrafts(tester, container);
      final gate = container.read(runtimeRecoveryGateProvider);
      final pausing = gate.pause();
      await tester.pumpAndSettle();
      final paused = await pausing;
      await tester.runAsync(() async {
        final lease = await database.beginMaintenance();
        await lease.validateAndOpen();
        await lease.resume();
        container.invalidate(workspaceDraftsProvider);
        final restored = container.read(workspaceDraftsProvider.notifier);
        await restored.ready;
        await restored.put('capture', {
          'id': 'restored',
          'text': 'Restored input',
        });
        await restored.put('pendingCaptures', null);
        gate.resume(paused);
      });
      await tester.pump();
      await tester.tap(
        find.text(
          AppLocalizations(const Locale('zh')).get('failedInputRestore'),
        ),
      );
      await tester.pumpAndSettle();
      await drainWorkspaceDrafts(tester, container);
      expect(container.read(workspaceDraftsProvider)['capture'], {
        'id': 'restored',
        'text': 'Restored input',
      });
      expect(
        container.read(workspaceDraftsProvider)['pendingCaptures'],
        isNull,
      );
      expect(container.read(remindersProvider), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed capture survives reopening and retains exact input', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await container
          .read(settingsProvider.notifier)
          .updateSettings(
            container
                .read(settingsProvider)
                .copyWith(inputSendMode: InputSendMode.button),
          );
      final db = await database.database;
      await db.execute(
        "CREATE TRIGGER reject_capture BEFORE INSERT ON Reminders "
        "BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
      );
    });
    await show(tester, width: 375);
    const input = '  保留原文\n包含换行  ';
    await tester.enterText(find.byType(TextField), input);
    await drainWorkspaceDrafts(tester, container);
    await tester.tap(find.byTooltip('发送'));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump();
      if (container.read(homeControllerProvider).error != null) break;
    }
    await drainWorkspaceDrafts(tester, container);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      input,
    );
    expect(container.read(remindersProvider), isEmpty);
    await tester.pumpWidget(const SizedBox());
    container.invalidate(workspaceDraftsProvider);
    await tester.runAsync(
      () => container.read(workspaceDraftsProvider.notifier).ready,
    );
    await show(tester, width: 375);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      input,
    );

    await tester.runAsync(
      () async =>
          (await database.database).execute('DROP TRIGGER reject_capture'),
    );
    await tester.tap(find.byTooltip('发送'));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump();
      if (container.read(remindersProvider).isNotEmpty) break;
    }
    await drainWorkspaceDrafts(tester, container);
    expect(container.read(remindersProvider).single.sourceText, input);
    expect(container.read(workspaceDraftsProvider)['pendingCaptures'], isNull);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  for (final language in ['zh', 'en', 'ja']) {
    testWidgets('AI review fits a narrow window with large text in $language', (
      tester,
    ) async {
      final proposal = Reminder(
        id: 'model',
        taskTitle: 'Review this synthetic task',
        taskSummary: 'A longer explanation that can wrap over multiple lines.',
        quadrantLevel: 2,
        triggerTime: DateTime.now().add(const Duration(hours: 2)),
      );
      await tester.runAsync(() async {
        await container
            .read(workspaceDraftsProvider.notifier)
            .put('homeView', 'all');
        await container
            .read(remindersProvider.notifier)
            .addReminder(
              Reminder(
                id: 'narrow-proposal',
                taskTitle: 'Original',
                sourceText: 'Original input',
                quadrantLevel: 2,
                captureProposalJson: jsonEncode([proposal.toJson()]),
              ),
            );
      });
      await show(tester, width: 375, height: 667, scale: 2, language: language);
      final review = find.byKey(
        const ValueKey('preview-capture-narrow-proposal'),
      );
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('confirm-capture-proposal')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [375.0, 768.0, 1440.0]) {
    for (final language in ['zh', 'en', 'ja']) {
      testWidgets(
        'quick capture and today fit $width $language with large text',
        (tester) async {
          await show(
            tester,
            width: width,
            scale: 1.8,
            language: language,
            brightness: Brightness.dark,
          );
          await tester.enterText(find.byType(TextField), '明天下午三点开会');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await drainWorkspaceDrafts(tester, container);
          expect(
            container.read(workspaceDraftsProvider)['capture']['text'],
            '明天下午三点开会',
          );
        },
      );
    }
  }
  testWidgets(
    'AI preview keeps raw text until edited confirmation and prevents reapply',
    (tester) async {
      final candidate = Reminder(
        id: 'model',
        taskTitle: 'Proposed title',
        quadrantLevel: 2,
      );
      final raw = Reminder(
        id: 'raw',
        taskTitle: 'Original',
        sourceText: 'Original source',
        quadrantLevel: 2,
        captureProposalJson: jsonEncode([candidate.toJson()]),
      );
      await tester.runAsync(() async {
        await container.read(remindersProvider.notifier).addReminder(raw);
        await container
            .read(workspaceDraftsProvider.notifier)
            .put('homeView', 'all');
      });
      await show(tester, width: 375);
      expect(container.read(remindersProvider).single.taskTitle, 'Original');
      await tester.tap(find.byKey(const ValueKey('preview-capture-raw')));
      await tester.pumpAndSettle();
      expect(find.byType(CapturePreviewDialog), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('proposal-title-0')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('proposal-title-0')),
        'Edited title',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm-capture-proposal')),
      );
      await tester.tap(find.byKey(const ValueKey('confirm-capture-proposal')));
      for (
        var i = 0;
        i < 100 &&
            container.read(remindersProvider).single.captureProposalJson !=
                null;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(
        container.read(remindersProvider).single.taskTitle,
        'Edited title',
      );
      expect(
        container.read(remindersProvider).single.sourceText,
        'Original source',
      );
      expect(
        container.read(remindersProvider).single.captureProposalJson,
        isNull,
      );
      expect(find.byType(CapturePreviewDialog), findsNothing);
    },
  );

  testWidgets('word feedback advances only the current word and shows workload', (
    tester,
  ) async {
    final task = Reminder(
      id: 'learning',
      taskTitle: 'Words',
      quadrantLevel: 2,
      spacedRepetitionLevel: 1,
      nextReviewAt: DateTime.now().subtract(const Duration(days: 1)),
      taskSummary:
          'alpha — First word\nExample alpha.\n\nbeta — Second word\nExample beta.',
    );
    await tester.runAsync(
      () => container.read(remindersProvider.notifier).addReminder(task),
    );
    await show(tester, width: 375, tool: const LearningQueuePanel());
    expect(find.text('alpha'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('word-grade-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('word-grade-2')));
    for (
      var i = 0;
      i < 100 &&
          container.read(remindersProvider).single.wordProgressJson == null;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(
      LearningQueueService.decode(
        container.read(remindersProvider).single.wordProgressJson,
      ).keys,
      ['alpha'],
    );
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('今日已学: 1 / 20'), findsOneWidget);
    expect(container.read(remindersProvider).single.isCompleted, isFalse);
  });

  testWidgets(
    'repair action opens notification permission and retry controls',
    (tester) async {
      await show(
        tester,
        tool: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => InlineFeedback.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Saved; notification failed'),
                  action: notificationRepairAction(context),
                ),
              ),
              child: const Text('Show failure'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show failure'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修复提醒'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await tester.pump();
      }
      expect(find.byType(NotificationRepairScreen), findsOneWidget);
      expect(find.byType(NotificationPermissionPanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('notification-reminders-retry')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [375.0, 768.0, 1440.0]) {
    for (final language in ['zh', 'en', 'ja']) {
      testWidgets('learning queue fits $width $language with large text', (
        tester,
      ) async {
        await show(
          tester,
          width: width,
          scale: 1.8,
          language: language,
          tool: const LearningQueuePanel(),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'native failure remains actionable after today removes the completed card',
    (tester) async {
      await tester.runAsync(
        () => container
            .read(remindersProvider.notifier)
            .addReminder(
              Reminder(
                id: 'finish',
                taskTitle: 'Finish this task',
                quadrantLevel: 1,
                triggerTime: DateTime.now().add(const Duration(hours: 1)),
              ),
            ),
      );
      await show(tester, width: 768);
      notifications.failCancel = true;
      await tester.tap(find.byType(Checkbox).first);
      for (var i = 0; i < 100 && find.text('修复提醒').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await tester.pump();
      }
      expect(container.read(remindersProvider).single.isCompleted, isTrue);
      expect(find.text('Finish this task'), findsNothing);
      expect(find.text('修复提醒'), findsOneWidget);
      await tester.tap(find.text('修复提醒'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await tester.pump();
      }
      expect(find.byType(NotificationRepairScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
