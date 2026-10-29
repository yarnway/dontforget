import 'support/workspace_drafts.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'dart:async';
import 'package:dont_forget/ui/widgets/command_palette_dialog.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/ui/widgets/reminder_notice_panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/app.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/ui/widgets/task_board.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const recorderChannel = MethodChannel('com.llfbandit.record/messages');
  final platformChannels = <MethodChannel>[];
  late Directory testDirectory;
  late DatabaseHelper testDatabase;
  late ProviderContainer container;
  late _ObservedReminders reminders;

  Future<void> applyNoticeAction(WidgetTester tester, String label) async {
    await tester.runAsync(() async {
      final previous = reminders.lastAction;
      await tester.tap(find.widgetWithText(TextButton, label));
      final action = reminders.lastAction;
      expect(action, isNotNull);
      expect(action, isNot(same(previous)));
      await action!.timeout(const Duration(seconds: 5));
    });
    await tester.pump();
  }

  Reminder current(String id) =>
      container.read(remindersProvider).firstWhere((item) => item.id == id);
  setUpAll(() async {
    if (const bool.fromEnvironment('UI_PREVIEW')) {
      const fontPath = String.fromEnvironment('PREVIEW_FONT');
      const iconPath = String.fromEnvironment('PREVIEW_ICONS');
      if (fontPath.isNotEmpty && iconPath.isNotEmpty) {
        for (final family in ['Ahem', 'Roboto']) {
          final loader = FontLoader(family)
            ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
          await loader.load();
        }
        await (FontLoader(
              'MaterialIcons',
            )..addFont(File(iconPath).readAsBytes().then(ByteData.sublistView)))
            .load();
      }
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, (call) async {
          if (call.method == 'create' || call.method == 'dispose') return null;
          throw UnsupportedError(
            'Unexpected recorder operation: ${call.method}',
          );
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          (call) async => switch (call.method) {
            'initialize' => true,
            'getNotificationAppLaunchDetails' => {
              'notificationLaunchedApp': false,
            },
            _ => null,
          },
        );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    platformChannels.addAll(const [
      MethodChannel('xyz.luan/audioplayers.global'),
      MethodChannel('xyz.luan/audioplayers.global/events'),
      MethodChannel('xyz.luan/audioplayers'),
      MethodChannel('tray_manager'),
    ]);
    for (final channel in platformChannels) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final events = MethodChannel('xyz.luan/audioplayers/events/$id');
          platformChannels.add(events);
          messenger.setMockMethodCallHandler(events, (_) async => null);
        }
        return null;
      });
    }
    sqfliteFfiInit();
    testDirectory = await Directory.systemTemp.createTemp('dontforget-widget-');
    testDatabase = DatabaseHelper.forTesting(
      testDirectory.path,
      databaseFactoryFfi,
    );
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(testDatabase),
        remindersProvider.overrideWith(
          (ref) => reminders = _ObservedReminders(testDatabase),
        ),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(workspaceDraftsProvider.notifier).ready;
    await container
        .read(workspaceDraftsProvider.notifier)
        .put('homeView', 'board');
    await container.read(remindersProvider.notifier).ready;
    // Finish identity file I/O before entering a widget fake-async zone.
    await container.read(notificationServiceProvider).init();
    // Complete language category registration before widget fake async.
    await container.read(notificationServiceProvider).setNotificationLanguage(
      container.read(settingsProvider).language,
    );
  });
  tearDownAll(() async {
    await container.read(notificationServiceProvider).pauseForMaintenance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          null,
        );
    container.dispose();
    for (final channel in platformChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    await testDatabase.close();
    for (var i = 0; i < 15; i++) {
      try {
        await testDirectory.delete(recursive: true);
        break;
      } catch (_) {
        if (i == 14) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, null);
  });

  testWidgets('App starts and + button displays media options sheet', (
    WidgetTester tester,
  ) async {
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MyApp()),
    );
    // Advance entrance transitions without waiting for periodic reminder work.
    await tester.pump(const Duration(seconds: 1));

    // Verify '+' button is present
    final addBtn = find.byIcon(Icons.add_circle_outline_rounded);
    expect(addBtn, findsOneWidget);

    // Tap '+' button
    await tester.tap(addBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Verify modal options exist
    expect(find.text('上传素材给大模型'), findsOneWidget);
    if (Platform.isAndroid || Platform.isIOS) {
      expect(find.text('拍摄照片'), findsOneWidget);
    } else {
      expect(find.text('拍摄照片'), findsNothing);
    }
    expect(find.text('相册图片'), findsOneWidget);
    expect(find.text('导入文件'), findsOneWidget);
    expect(find.text('上传视频'), findsOneWidget);

    // Close sheet
    Navigator.pop(tester.element(find.text('上传素材给大模型')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Verify input box exists
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('workspace stays usable at phone, tablet and desktop widths', (
    tester,
  ) async {
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() => tester.view.resetDevicePixelRatio());
    addTearDown(
      tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
    );
    tester.view.devicePixelRatio = 1;
    await tester.runAsync(() async {
      final notifier = container.read(remindersProvider.notifier);
      for (final task in [
        Reminder(
          id: 'ui-review-1',
          taskTitle: '准备周会材料',
          taskSummary: '整理进度、风险与本周计划',
          quadrantLevel: 1,
        ),
        Reminder(
          id: 'ui-review-2',
          taskTitle: '完善产品使用指南',
          taskSummary: '补充首次使用与常见问题',
          quadrantLevel: 2,
        ),
        Reminder(id: 'ui-review-3', taskTitle: '记录阅读笔记', quadrantLevel: 4),
        Reminder(
          id: 'ui-review-done',
          taskTitle: '完成昨日复盘',
          quadrantLevel: 1,
          isCompleted: true,
        ),
      ]) {
        await notifier.addReminder(task);
      }
    });
    for (final width in [375.0, 768.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 900);
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const RepaintBoundary(
            key: ValueKey('workspace-preview'),
            child: MyApp(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('更多功能'), findsOneWidget);
      expect(find.byTooltip('设置'), findsOneWidget);
      // Typing a shortcut letter must not switch focus mode.
      await tester.tap(find.byKey(const ValueKey('composer-input-surface')));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      expect(container.read(immersiveModeProvider), isFalse);
      if (const bool.fromEnvironment('UI_PREVIEW')) {
        InlineFeedback.of(tester.element(find.byType(TaskBoard))).showSnackBar(
          const SnackBar(content: Text('修改已保存')),
          tone: FeedbackTone.success,
        );
        await tester.pump();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('workspace-preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory('dist/ui-preview');
          await directory.create(recursive: true);
          await File(
            '${directory.path}/workspace-feedback-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        tester.binding.platformDispatcher.platformBrightnessTestValue =
            Brightness.dark;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          Theme.of(tester.element(find.byType(TaskBoard))).brightness,
          Brightness.dark,
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'dist/ui-preview/workspace-feedback-dark-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        tester.binding.platformDispatcher.clearPlatformBrightnessTestValue();
        await tester.pump();
      }
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
    }
  });
  testWidgets(
    'upcoming and repeated due events stay inline without stealing input focus',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final upcoming = Reminder(
        id: 'quiet-upcoming',
        taskTitle: '提前准备材料',
        quadrantLevel: 3,
        triggerTime: DateTime.now().add(const Duration(minutes: 2)),
      );
      await tester.runAsync(
        () => container.read(remindersProvider.notifier).addReminder(upcoming),
      );
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const RepaintBoundary(
            key: ValueKey('quiet-preview'),
            child: MyApp(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('即将提醒 · 1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('composer-input-surface')));
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      final due = upcoming.copyWith(
        triggerTime: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      await tester.runAsync(
        () => container.read(remindersProvider.notifier).updateReminder(due),
      );
      final savedDue = current(due.id);
      await tester.runAsync(
        () => container
            .read(notificationServiceProvider)
            .fireReminderNow(savedDue),
      );
      await tester.runAsync(
        () => container
            .read(notificationServiceProvider)
            .fireReminderNow(savedDue),
      );
      await tester.pump();
      expect(find.byType(ReminderNoticePanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reminder-notice-panel')),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(editable.focusNode.hasFocus, isTrue);
      for (final width in [375.0, 768.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(
          find.widgetWithText(TextButton, '稍后 5 分钟提醒').hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('composer-input-surface')).hitTestable(),
          findsOneWidget,
        );
        if (const bool.fromEnvironment('UI_PREVIEW')) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('quiet-preview')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final directory = Directory('dist/ui-preview/quiet');
            await directory.create(recursive: true);
            await File(
              '${directory.path}/workspace-feedback-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      await applyNoticeAction(tester, '我知道了');
      expect(current(due.id).noticeAcknowledgedAt, isNotNull);
      await tester.runAsync(
        () => container
            .read(notificationServiceProvider)
            .fireReminderNow(savedDue),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('reminder-notice-panel')), findsNothing);
      final edited = current(due.id).copyWith(
        triggerTime: DateTime.now().subtract(const Duration(seconds: 3)),
      );
      await tester.runAsync(
        () => container.read(remindersProvider.notifier).updateReminder(edited),
      );
      await tester.runAsync(
        () => container
            .read(notificationServiceProvider)
            .fireReminderNow(current(edited.id)),
      );
      await tester.pump();
      await applyNoticeAction(tester, '稍后 5 分钟提醒');
      final snoozed = container
          .read(remindersProvider)
          .firstWhere((r) => r.id == edited.id);
      expect(
        snoozed.triggerTime!.difference(DateTime.now()).inMinutes,
        inInclusiveRange(4, 5),
      );
      await tester.runAsync(
        () => container
            .read(notificationServiceProvider)
            .cancelReminder(edited.id),
      );
      final dueAgain = snoozed.copyWith(
        triggerTime: DateTime.now().subtract(const Duration(seconds: 5)),
      );
      await tester.runAsync(
        () =>
            container.read(remindersProvider.notifier).updateReminder(dueAgain),
      );
      final savedDueAgain = current(dueAgain.id);
      await tester.runAsync(
        () => container
            .read(notificationServiceProvider)
            .fireReminderNow(savedDueAgain),
      );
      await tester.pump();
      await applyNoticeAction(tester, '标为已完成');
      expect(
        container
            .read(remindersProvider)
            .firstWhere((r) => r.id == edited.id)
            .isCompleted,
        isTrue,
      );
      await tester.runAsync(
        () => container
            .read(notificationServiceProvider)
            .fireReminderNow(savedDueAgain),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('reminder-notice-panel')), findsNothing);
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('due notice recovers a missed broadcast without restarting', (
    tester,
  ) async {
    final task = Reminder(
      id: 'missed-due-event',
      taskTitle: 'First expiry recovery',
      quadrantLevel: 3,
      triggerTime: DateTime.now().add(const Duration(minutes: 2)),
    );
    await tester.runAsync(
      () => container.read(remindersProvider.notifier).addReminder(task),
    );
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MyApp()),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-input-surface')));
    // A restored/edited task can reach the page without a broadcast; the database
    // remains authoritative even if a native timer/foreground callback was missed.
    final due = task.copyWith(
      triggerTime: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    await tester.runAsync(
      () => container.read(remindersProvider.notifier).updateReminder(due),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('reminder-notice-panel')), findsOneWidget);
    expect(find.text('标为已完成'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await applyNoticeAction(tester, '我知道了');
    expect(current(task.id).noticeAcknowledgedAt, isNotNull);
    // Lifecycle callbacks enqueue database/notification work. Run them in the
    // real async zone just like writes, rather than suspending that queue in
    // fake async while the next runAsync command waits for it.
    await tester.runAsync(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await container
          .read(remindersProvider.notifier)
          .scanAndApplyDynamicUrgency();
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('reminder-notice-panel')), findsNothing);
    await tester.runAsync(
      () => container.read(remindersProvider.notifier).deleteReminder(task.id),
    );
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'manual priority scan shows count, native warning and safe failure',
    (tester) async {
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const MyApp()),
      );
      await tester.pump();
      addTearDown(() {
        reminders.scanResult = null;
        reminders.scanError = null;
      });
      for (final locale in ['en', 'zh', 'ja']) {
        final l10n = AppLocalizations(Locale(locale));
        for (final key in [
          'scanDynamicUrgency',
          'scanDynamicUrgencyDesc',
          'dynamicPromotedCount',
          'dynamicScanFailed',
        ]) {
          expect(l10n.get(key), isNot(key));
        }
      }
      for (final nativeFailures in [0, 1]) {
        reminders.scanResult = ReminderBatchResult(
          changed: 3,
          nativeSyncFailures: nativeFailures,
        );
        await tester.tap(find.byTooltip('更多功能'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('检查任务优先级'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('已提升优先级的任务数: 3'), findsOneWidget);
        expect(find.textContaining('Instance of'), findsNothing);
        expect(
          find.textContaining('已保存，但系统提醒未能更新'),
          nativeFailures == 0 ? findsNothing : findsOneWidget,
        );
      }
      reminders.scanError = StateError('SECRET error details');
      await tester.tap(find.byTooltip('更多功能'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('检查任务优先级'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('优先级检查失败，请重试。'), findsOneWidget);
      expect(find.textContaining('SECRET'), findsNothing);
      expect(tester.takeException(), isNull);
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'idle heartbeat preserves the board and search supports keyboard dismissal',
    (tester) async {
      await tester.runAsync(
        () => container
            .read(remindersProvider.notifier)
            .addReminder(
              Reminder(
                id: 'search-shortcuts',
                taskTitle: 'Searchable headline',
                taskSummary: 'search fixture',
                quadrantLevel: 1,
              ),
            ),
      );
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const MyApp()),
      );
      await tester.pump();
      final board = tester.widget<TaskBoard>(find.byType(TaskBoard));
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(tester.widget<TaskBoard>(find.byType(TaskBoard)), same(board));

      await tester.tap(find.byKey(const ValueKey('composer-input-surface')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final search = find.byKey(const ValueKey('task-search-field'));
      expect(search, findsOneWidget);
      await tester.enterText(search, 'search fixture');
      await tester.pump(const Duration(milliseconds: 160));
      expect(find.text('搜索结果 · 1'), findsOneWidget);
      await tester.enterText(search, 'pending debounce');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 200));
      expect(search, findsNothing);
      expect(find.byType(TaskBoard), findsOneWidget);
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'workspace tools command and Meta K open once and do not cover another route',
    (tester) async {
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const MyApp()),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final command = container.read(workspaceToolsCommandProvider);
      expect(command.open!(), true);
      await tester.pumpAndSettle();
      expect(find.byType(CommandPaletteDialog), findsOneWidget);
      expect(command.open!(), false);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('composer-input-surface')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.byType(CommandPaletteDialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Editor stays open')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(command.open!(), false);
      expect(find.text('Editor stays open'), findsOneWidget);
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
      expect(command.open, isNull);
    },
  );
}

// Observe completion of the real database and native work, rather than relying
// on a fixed delay or treating persistent reminder actions as synchronous.
class _ObservedReminders extends RemindersNotifier {
  _ObservedReminders(super.database);

  ReminderBatchResult? scanResult;
  Object? scanError;
  @override
  Future<ReminderBatchResult> scanAndApplyDynamicUrgency() {
    if (scanError != null) return Future.error(scanError!);
    if (scanResult != null) return Future.value(scanResult!);
    return super.scanAndApplyDynamicUrgency();
  }

  Future<ReminderActionResult>? lastAction;

  @override
  Future<ReminderActionResult> acknowledgeOccurrence(
    Reminder expected, {
    required ReminderNoticePhase phase,
    DateTime? now,
  }) => lastAction = super.acknowledgeOccurrence(
    expected,
    phase: phase,
    now: now,
  );

  @override
  Future<ReminderActionResult> snoozeOccurrence(
    Reminder expected, {
    DateTime? now,
    Duration duration = const Duration(minutes: 5),
  }) => lastAction = super.snoozeOccurrence(
    expected,
    now: now,
    duration: duration,
  );

  @override
  Future<ReminderActionResult> completeOccurrence(
    Reminder expected, {
    DateTime? now,
  }) => lastAction = super.completeOccurrence(expected, now: now);
}
