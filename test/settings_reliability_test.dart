import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/services/notification_diagnostics_service.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/ui/screens/settings_screen.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/lan_sync_service.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'support/interaction_preview.dart';

class _LanReviewService extends LanSyncService {
  _LanReviewService() : super.forTesting();

  List<LanSyncConflict> conflicts = const [];
  LanSyncServerInfo? listening;
  LanSyncPeerAddress? lastPeer;

  @override
  Future<LanSyncServerInfo> startServer({
    int? port,
    required DatabaseHelper dbHelper,
    VoidCallback? onDataChanged,
  }) async => listening!;

  @override
  Future<bool> syncWithPeer({
    required String peerIp,
    int port = LanSyncService.defaultPort,
    required String pin,
    required DatabaseHelper dbHelper,
    VoidCallback? onDataChanged,
    ValueChanged<List<LanSyncConflict>>? onConflicts,
  }) async {
    lastPeer = (host: peerIp, port: port);
    onConflicts?.call(conflicts);
    return true;
  }
}

void main() {
  setUpAll(loadInteractionPreviewFonts);
  TestWidgetsFlutterBinding.ensureInitialized();
  const notificationChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  late Directory directory;
  late DatabaseHelper helper;
  late ProviderContainer container;
  late _LanReviewService lan;
  setUp(() async {
    // Persistence/layout tests have no native permission channel. The focused
    // permission tests exercise supported platforms and stalled native reads.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationChannel, (call) async {
          return switch (call.method) {
            'areNotificationsEnabled' ||
            'canScheduleExactNotifications' => true,
            _ => null,
          };
        });
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('dontforget-settings-');
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    lan = _LanReviewService();
    container = ProviderContainer(
      overrides: [
        lanSyncServiceProvider.overrideWithValue(lan),
        notificationFailureHistoryReaderProvider.overrideWithValue(
          () async => const NotificationFailureHistory(available: false),
        ),
        // These tests exercise persistence, not a real OS channel. Dedicated
        // reader tests cover native results, partial failure and timeouts.
        notificationServiceProvider.overrideWithValue(
          NotificationService.forTesting(
            FlutterLocalNotificationsPlugin(),
            usesNativeNotifications: false,
          ),
        ),
        notificationScheduleStatusReaderProvider.overrideWithValue(
          () async => const NotificationScheduleStatus(
            upcoming: 0,
            submitted: 0,
            needsAttention: 0,
            cancellations: 0,
            overdueUnconfirmed: 0,
          ),
        ),
        databaseHelperProvider.overrideWithValue(helper),
      ],
    );
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ready;
    await notifier.updateSettings(
      notifier.state.copyWith(apiKey: 'user-test-key'),
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationChannel, null);
    container.dispose();
    await helper.close();
    await directory.delete(recursive: true);
  });

  Future<void> showSettings(
    WidgetTester tester, {
    bool routed = false,
    SettingsArea? area,
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
          builder: (context, child) => InlineFeedback(
            child: RepaintBoundary(key: interactionPreviewKey, child: child!),
          ),
          home: routed
              ? Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                )
              : SettingsScreen(area: area),
        ),
      ),
    );
    await tester.pump();
    if (routed) {
      await tester.tap(find.text('open'));
      await tester.pump();
    }
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets('sync settings advertise and connect using the selected port', (
    tester,
  ) async {
    lan.listening = LanSyncServerInfo(
      isRunning: true,
      ip: '192.168.1.50',
      port: 45123,
      pin: '123456',
    );
    await tester.runAsync(
      () => container.read(remindersProvider.notifier).ready,
    );
    await showSettings(tester, area: SettingsArea.sync);
    final toggle = find.byKey(const ValueKey('lan-sync-server'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.textContaining('192.168.1.50:45123'), findsOneWidget);
    expect(find.textContaining('默认端口不可用'), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '192。168。1。50：45123');
    await tester.enterText(fields.at(1), '123456');
    final sync = find.byKey(const ValueKey('lan-sync-now'));
    await tester.ensureVisible(sync);
    await tester.tap(sync);
    await tester.pumpAndSettle();
    expect(lan.lastPeer, (host: '192.168.1.50', port: 45123));
  });

  testWidgets('sync differences show both versions and open the local reader', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final task = Reminder(id: 'local', taskTitle: '营业时间', quadrantLevel: 3);
    await tester.runAsync(() async {
      final reminders = container.read(remindersProvider.notifier);
      await reminders.ready;
      await reminders.addReminder(task);
    });
    lan.conflicts = [
      LanSyncConflict(
        taskId: task.id,
        local: (title: task.taskTitle, note: '', inTrash: false),
        peer: (title: '门店时间', note: '周末延长', inTrash: true),
      ),
    ];
    await showSettings(tester, area: SettingsArea.sync);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '127.0.0.1');
    await tester.enterText(fields.at(1), '123456');
    final sync = find.byKey(const ValueKey('lan-sync-now'));
    await tester.ensureVisible(sync);
    await tester.tap(sync);
    await tester.pumpAndSettle();
    final review = find.byKey(const ValueKey('lan-sync-conflicts'));
    await tester.ensureVisible(review);
    expect(find.text('查看差异（1）'), findsOneWidget);
    await tester.tap(review);
    await tester.pumpAndSettle();
    await tester.tap(find.text('营业时间'));
    await tester.pumpAndSettle();
    expect(find.text('门店时间'), findsOneWidget);
    expect(find.text('周末延长'), findsOneWidget);
    final dialog = find.byKey(const ValueKey('lan-sync-conflicts-dialog'));
    final scrollable = find
        .descendant(of: dialog, matching: find.byType(Scrollable))
        .first;
    final open = find.text('打开本机事项');
    await tester.dragUntilVisible(
      open.hitTestable(),
      scrollable,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(find.text('在回收站'), findsOneWidget);
    await tester.tap(open.hitTestable());
    await tester.pumpAndSettle();
    final reader = find.byKey(const ValueKey('task-detail-reader-list'));
    expect(reader, findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    Navigator.of(tester.element(reader)).pop();
    await tester.pumpAndSettle();

    Future<void> choosePeerText() async {
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      final heading = find.descendant(of: dialog, matching: find.text('营业时间'));
      if (find.text('门店时间').evaluate().isEmpty) {
        await tester.tap(heading);
        await tester.pumpAndSettle();
      }
      final adopt = find.text('采用对方的标题和备注');
      await tester.dragUntilVisible(
        adopt.hitTestable(),
        scrollable,
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      await tester.tap(adopt.hitTestable());
      await tester.pumpAndSettle();
    }

    await choosePeerText();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(container.read(remindersProvider).single.taskTitle, '营业时间');

    await choosePeerText();
    await tester.runAsync(
      () => tester.tap(find.widgetWithText(FilledButton, '保存')),
    );
    for (var i = 0; i < 50; i++) {
      await tester.pump();
      if (container.read(remindersProvider).single.taskTitle == '门店时间') break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pumpAndSettle();
    final saved = container.read(remindersProvider).single;
    expect(saved.taskTitle, '门店时间');
    expect(saved.taskSummary, '周末延长');
    expect(saved.details.deletedAt, isNull);
    await tester.ensureVisible(review);
    await tester.tap(review);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: dialog, matching: find.text('门店时间')));
    await tester.pumpAndSettle();
    expect(find.text('在回收站'), findsOneWidget);
    expect(find.text('采用对方的标题和备注'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    lan.conflicts = const [];
    await tester.ensureVisible(sync);
    await tester.tap(sync);
    await tester.pumpAndSettle();
    expect(review, findsNothing);
  });

  test(
    'adopting peer text checks the stored row and preserves other fields',
    () async {
      final notifier = container.read(remindersProvider.notifier);
      await notifier.ready;
      final task = Reminder(
        id: 'local',
        taskTitle: 'Local',
        taskSummary: 'Local notes',
        quadrantLevel: 3,
      );
      await notifier.addReminder(task);
      final generation = helper.captureGeneration();
      final conflict = LanSyncConflict(
        taskId: task.id,
        local: LanSyncConflict.contentOf(task),
        peer: (title: 'Peer', note: '', inTrash: true),
      );
      Future<void> patch(Map<String, Object?> fields) =>
          helper.writeTransaction(generation, (tx) async {
            await tx.update(
              'Reminders',
              fields,
              where: 'id = ?',
              whereArgs: [task.id],
            );
          });
      Future<Reminder> read() => helper.read(
        generation,
        (db) async => Reminder.fromJson((await db.query('Reminders')).single),
      );

      // Simulate a newer write that the notifier has not refreshed yet.
      await patch({'task_summary': 'Newer'});
      expect(
        (await notifier.adoptLanSyncText(conflict, generation)).accepted,
        isFalse,
      );
      expect((await read()).taskSummary, 'Newer');

      await patch({'task_summary': 'Local notes', 'is_pinned': 1});
      expect(
        (await notifier.adoptLanSyncText(conflict, generation)).accepted,
        isTrue,
      );
      final saved = await read();
      expect(saved.taskTitle, 'Peer');
      expect(saved.taskSummary, isEmpty);
      expect(saved.isPinned, isTrue);
      expect(saved.details.deletedAt, isNull);
      expect(saved.details.history.last.action, 'edited');
    },
  );

  testWidgets(
    'trash differences require confirmation before changing local status',
    (tester) async {
      final task = Reminder(
        id: 'trash-qa',
        taskTitle: '本机事项',
        quadrantLevel: 3,
      );
      await tester.runAsync(() async {
        final notifier = container.read(remindersProvider.notifier);
        await notifier.ready;
        await notifier.addReminder(task);
      });
      lan.conflicts = [
        LanSyncConflict(
          taskId: task.id,
          local: (title: task.taskTitle, note: '', inTrash: false),
          peer: (title: task.taskTitle, note: '', inTrash: true),
        ),
      ];
      await showSettings(tester, area: SettingsArea.sync);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '127.0.0.1');
      await tester.enterText(fields.at(1), '123456');
      final sync = find.byKey(const ValueKey('lan-sync-now'));
      await tester.ensureVisible(sync);
      await tester.tap(sync);
      await tester.pumpAndSettle();
      final review = find.byKey(const ValueKey('lan-sync-conflicts'));
      Future<void> openConfirmation() async {
        await tester.ensureVisible(review);
        await tester.tap(review);
        await tester.pumpAndSettle();
        final move = find.widgetWithText(TextButton, '移入本机回收站');
        if (move.evaluate().isEmpty) {
          await tester.tap(find.text('本机事项'));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(move);
        await tester.tap(move.hitTestable());
        await tester.pumpAndSettle();
      }

      await openConfirmation();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(container.read(remindersProvider).single.isVisible, isTrue);

      await openConfirmation();
      final confirm = find.widgetWithText(FilledButton, '移入本机回收站');
      await tester.runAsync(() => tester.tap(confirm));
      for (var i = 0; i < 50; i++) {
        await tester.pump();
        if (!container.read(remindersProvider).single.isVisible &&
            review.evaluate().isEmpty) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pumpAndSettle();
      final moved = container.read(remindersProvider).single;
      expect(moved.details.deletedAt, isNotNull);
      expect(moved.details.history.last.action, 'trash');
      expect(review, findsNothing);
    },
  );

  testWidgets('appearance remains a draft until save and survives reopening', (
    tester,
  ) async {
    await showSettings(tester);
    await tester.tap(find.byKey(const ValueKey('appearance-dark')));
    await tester.pump();
    expect(container.read(settingsProvider).appearance, AppAppearance.system);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      for (
        var i = 0;
        i < 100 &&
            container.read(settingsProvider).appearance != AppAppearance.dark;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).appearance, AppAppearance.dark);
    late SettingsNotifier reloaded;
    await tester.runAsync(() async {
      reloaded = SettingsNotifier(helper);
      await reloaded.ready;
    });
    expect(reloaded.state.appearance, AppAppearance.dark);
    expect(reloaded.state.apiKey, 'user-test-key');
    reloaded.dispose();
    await tester.pumpWidget(const SizedBox());
    await showSettings(tester);
    expect(
      tester
          .widget<Semantics>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('appearance-dark')),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .properties
          .selected,
      isTrue,
    );
  });

  testWidgets('send mode is saved explicitly and survives settings reload', (
    tester,
  ) async {
    await showSettings(tester);
    final picker = find.byKey(const ValueKey('input-send-mode'));
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅发送按钮').last);
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).inputSendMode, InputSendMode.enter);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      for (
        var i = 0;
        i < 100 &&
            container.read(settingsProvider).inputSendMode !=
                InputSendMode.button;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(
      container.read(settingsProvider).inputSendMode,
      InputSendMode.button,
    );
    await tester.runAsync(() async {
      final reloaded = SettingsNotifier(helper);
      await reloaded.ready;
      expect(reloaded.state.inputSendMode, InputSendMode.button);
      expect(reloaded.state.apiKey, 'user-test-key');
      reloaded.dispose();
    });
  });

  testWidgets('send mode participates in discard confirmation', (tester) async {
    await showSettings(tester, routed: true);
    final picker = find.byKey(const ValueKey('input-send-mode'));
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅发送按钮').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('有未保存的修改'), findsOneWidget);
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).inputSendMode, InputSendMode.enter);
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets('discarding an appearance change keeps the saved mode', (
    tester,
  ) async {
    await showSettings(tester, routed: true);
    await tester.tap(find.byKey(const ValueKey('appearance-light')));
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('有未保存的修改'), findsOneWidget);
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).appearance, AppAppearance.system);
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets(
    'settings draft back confirmation keeps or explicitly discards without writing',
    (tester) async {
      await showSettings(tester, routed: true);
      final field = find.byKey(const ValueKey('settings-api-key'));
      await tester.scrollUntilVisible(
        field,
        180,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 50,
      );
      await tester.pumpAndSettle();
      await tester.enterText(field, 'uncommitted-key');
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('有未保存的修改'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'uncommitted-key',
      );
      expect(container.read(settingsProvider).apiKey, 'user-test-key');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      await showSettings(tester, routed: true);
      await tester.scrollUntilVisible(
        field,
        180,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 50,
      );
      expect(tester.widget<TextField>(field).controller!.text, 'user-test-key');
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [const Size(375, 667), const Size(667, 375)]) {
    testWidgets(
      'settings controls and active field remain usable above keyboard at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.view.viewInsets = FakeViewPadding(
          bottom: size.height > 400 ? 300 : 150,
        );
        addTearDown(tester.view.reset);
        await showSettings(tester);
        final field = find.byKey(const ValueKey('settings-api-key'));
        await tester.scrollUntilVisible(
          field,
          180,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 50,
        );
        await tester.pumpAndSettle();
        expect(field.hitTestable(), findsOneWidget);
        await tester.enterText(field, '中文日本語keyboard');
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field).controller!.text,
          '中文日本語keyboard',
        );
        for (final label in ['备份已保存的数据', '保存']) {
          expect(find.text(label).hitTestable(), findsOneWidget);
          expect(
            tester.getRect(find.text(label)).bottom,
            lessThan(size.height - tester.view.viewInsets.bottom),
          );
        }
        expect(tester.takeException(), isNull);
        await captureInteractionPreview(
          tester,
          'settings-keyboard-${size.width.toInt()}',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'Switching providers clears the previous key without supplying a bundled key',
    (tester) async {
      await showSettings(tester);
      final keyField = find.byWidgetPredicate(
        (w) => w is TextField && w.obscureText,
      );
      await tester.scrollUntilVisible(
        keyField,
        350,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.widget<TextField>(keyField).controller!.text,
        'user-test-key',
      );
      await tester.ensureVisible(find.text('一键选用 DeepSeek'));
      await tester.pumpAndSettle();
      expect(find.text('一键选用 DeepSeek').hitTestable(), findsOneWidget);
      await tester.tap(find.text('一键选用 DeepSeek'));
      await tester.pump();
      expect(
        tester.widget<TextField>(keyField).controller!.text,
        'user-test-key',
      );
      await tester.ensureVisible(find.text('一键选用 Gemini'));
      await tester.pumpAndSettle();
      expect(find.text('一键选用 Gemini').hitTestable(), findsOneWidget);
      await tester.tap(find.text('一键选用 Gemini'));
      await tester.pump();
      expect(tester.widget<TextField>(keyField).controller!.text, isEmpty);
      expect(container.read(settingsProvider).apiKey, 'user-test-key');
    },
  );

  testWidgets('Manual backup reports success only after files exist', (
    tester,
  ) async {
    await showSettings(tester);
    final button = find.text('备份已保存的数据');
    await tester.scrollUntilVisible(
      button,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.runAsync(() => tester.tap(button));
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find
          .text(AppLocalizations(const Locale('zh')).get('backupSuccess'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    expect(
      find.text(AppLocalizations(const Locale('zh')).get('backupSuccess')),
      findsOneWidget,
    );
    expect(
      File('${directory.path}/dont_forget_v3.mirror.db').existsSync(),
      isTrue,
    );
    expect(File('${directory.path}/ha_snapshot.json').existsSync(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('backup and save remain reachable without scrolling on a phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 667);
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() => tester.view.resetDevicePixelRatio());
    await showSettings(tester);
    for (final label in ['备份已保存的数据', '保存']) {
      final button = find.text(label);
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getRect(button).bottom, lessThan(667));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Save failure keeps the settings screen open and shows an error',
    (tester) async {
      final db = await tester.runAsync(() => helper.database);
      await tester.runAsync(
        () => db!.execute(
          'CREATE TRIGGER reject_settings BEFORE INSERT ON Settings '
          "BEGIN SELECT RAISE(ABORT, 'test write failure'); END",
        ),
      );
      await showSettings(tester);
      await tester.scrollUntilVisible(
        find.text('保存'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.runAsync(() => tester.tap(find.text('保存')));
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find
            .text(
              AppLocalizations(const Locale('zh')).get('settingsSaveFailed'),
            )
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(
        find.text(
          AppLocalizations(const Locale('zh')).get('settingsSaveFailed'),
        ),
        findsOneWidget,
      );
      expect(container.read(settingsProvider).apiKey, 'user-test-key');
      await tester.runAsync(() => db!.execute('DROP TRIGGER reject_settings'));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
