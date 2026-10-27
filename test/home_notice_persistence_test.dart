import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/screens/home_screen.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/reminder_notice_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ObservedReminders extends RemindersNotifier {
  _ObservedReminders(super.database, NotificationService notifications)
    : super(notifications: notifications, runLoadEffects: false);

  Future<void>? lastAction;

  @override
  Future<ReminderActionResult> acknowledgeOccurrence(
    Reminder expected, {
    required ReminderNoticePhase phase,
    DateTime? now,
  }) {
    final operation = super.acknowledgeOccurrence(
      expected,
      phase: phase,
      now: now,
    );
    // The UI receives the original result/error. Tests await its actual queued
    // database/native work without a wall-clock sleep or an unhandled error.
    lastAction = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }
}

class _Context extends ContextTriggerService {
  _Context() : super.forTesting();
  @override
  Future<String?> detectCurrentWifiSsid() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late NotificationService notifications;
  late _ObservedReminders reminders;
  final channels = <MethodChannel>[];

  Future<void> load() async {
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    notifications = NotificationService.forTesting(
      FlutterLocalNotificationsPlugin(),
      usesNativeNotifications: false,
    );
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
        contextTriggerServiceProvider.overrideWithValue(_Context()),
        remindersProvider.overrideWith(
          (ref) => reminders = _ObservedReminders(database, notifications),
        ),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(mediaRecordsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
  }

  Future<void> unload() async {
    container.dispose();
    await notifications.pauseForMaintenance();
    await database.close(createBackup: false);
  }

  setUp(() async {
    sqfliteFfiInit();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    channels.addAll(const [
      MethodChannel('xyz.luan/audioplayers.global'),
      MethodChannel('xyz.luan/audioplayers.global/events'),
      MethodChannel('xyz.luan/audioplayers'),
      MethodChannel('com.llfbandit.record/messages'),
      MethodChannel('tray_manager'),
    ]);
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final events = MethodChannel('xyz.luan/audioplayers/events/$id');
          channels.add(events);
          messenger.setMockMethodCallHandler(events, (_) async => null);
        }
        return null;
      });
    }
    directory = await Directory.systemTemp.createTemp('home-notice-');
    await load();
    await container
        .read(remindersProvider.notifier)
        .addReminder(
          Reminder(
            id: 'due',
            taskTitle: 'Persisted due task',
            quadrantLevel: 3,
            triggerTime: DateTime.now().subtract(const Duration(minutes: 1)),
          ),
        );
  });

  tearDown(() async {
    await unload();
    await directory.delete(recursive: true);
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    channels.clear();
  });

  Future<void> showHome(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
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
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> dismissNotice(WidgetTester tester) async {
    await tester.runAsync(() async {
      final previous = reminders.lastAction;
      await tester.tap(find.widgetWithText(TextButton, '我知道了'));
      final action = reminders.lastAction;
      expect(action, isNotNull);
      expect(action, isNot(same(previous)));
      await action;
    });
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('acknowledgement survives a new database and home session', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await showHome(tester);
    expect(find.byType(ReminderNoticePanel), findsOneWidget);
    await dismissNotice(tester);
    expect(
      container.read(remindersProvider).single.noticeAcknowledgedAt,
      isNotNull,
    );
    expect(find.text('提醒时间已到 · 1'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await unload();
      await load();
    });
    await showHome(tester);
    expect(find.text('提醒时间已到 · 1'), findsNothing);
    expect(find.text('Persisted due task'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed acknowledgement remains visible and can be retried', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      final db = await database.database;
      await db.execute(
        "CREATE TRIGGER reject_ack BEFORE UPDATE ON Reminders BEGIN SELECT RAISE(ABORT, 'isolated failure'); END",
      );
    });
    await showHome(tester);
    await dismissNotice(tester);
    expect(find.text('提醒时间已到 · 1'), findsOneWidget);
    expect(
      container.read(remindersProvider).single.noticeAcknowledgedAt,
      isNull,
    );
    expect(find.text('提醒更新失败，请重试。'), findsOneWidget);
    await tester.runAsync(() async {
      final db = await database.database;
      await db.execute('DROP TRIGGER reject_ack');
    });
    await dismissNotice(tester);
    expect(find.text('提醒时间已到 · 1'), findsNothing);
    expect(
      container.read(remindersProvider).single.noticeAcknowledgedAt,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
