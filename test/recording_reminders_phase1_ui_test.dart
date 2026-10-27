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
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/workspace_drafts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late NotificationService notifications;
  const recorder = MethodChannel('com.llfbandit.record/messages');
  setUp(() async {
    sqfliteFfiInit();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorder, (_) async => null);
    directory = await Directory.systemTemp.createTemp('dontforget-phase1-ui-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    notifications = NotificationService.forTesting(
      FlutterLocalNotificationsPlugin(),
      usesNativeNotifications: false,
    );
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
                  child: Consumer(
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
        timeOrigin: ReminderTimeOrigin.aiSuggested,
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
        const ValueKey('review-capture-capture-proposal'),
      );
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(find.text('确认 AI 整理结果'), findsOneWidget);
      expect(container.read(remindersProvider).single.triggerTime, isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        container.read(remindersProvider).single.captureProposalJson,
        isNotNull,
      );
      expect(container.read(remindersProvider).single.triggerTime, isNull);

      await tester.tap(review);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('proposal-title-0')),
        'Reviewed title',
      );
      await tester.tap(find.byKey(const ValueKey('proposal-confirm')));
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
        const ValueKey('review-capture-narrow-proposal'),
      );
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('proposal-confirm')), findsOneWidget);
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
}
