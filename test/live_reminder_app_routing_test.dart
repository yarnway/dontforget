import 'support/workspace_drafts.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dont_forget/services/live_reminder_service.dart';

import 'package:dont_forget/app.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/recovery_coordinator.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _firstEpoch = '9c2361cc-ea7b-46bd-ab59-5e2873508ff1';
const _secondEpoch = '1d43159f-2c14-4283-a921-8ea5d67ff1c9';

class _Notifications extends NotificationService {
  _Notifications()
    : super.forTesting(
        FlutterLocalNotificationsPlugin(),
        usesNativeNotifications: false,
      );

  final clicks = StreamController<String>.broadcast(sync: true);
  final pending = <String>[];
  Completer<void>? initialization;
  String epoch = _firstEpoch;

  @override
  String get datasetEpoch => epoch;
  @override
  Stream<String> get onNotificationPayload => clicks.stream;
  @override
  List<String> takePendingNotificationPayloads() {
    final result = List<String>.of(pending);
    pending.clear();
    return result;
  }

  @override
  Future<void> init() async => initialization?.future;
  @override
  Future<void> scheduleReminder(Reminder reminder) async {}
  @override
  Future<void> cancelReminder(String id) async {}
  @override
  Future<void> scheduleReminderStrict(Reminder reminder) =>
      scheduleReminder(reminder);
  @override
  Future<void> cancelReminderStrict(String id) => cancelReminder(id);
}

class _Context extends ContextTriggerService {
  _Context() : super.forTesting();
  @override
  Future<String?> detectCurrentWifiSsid() async => null;
}

class _Recovery extends RecoveryCoordinator {
  _Recovery(super.ref);
  RecoveryFlowState _current = const RecoveryFlowState(RecoveryPhase.idle);
  int _epoch = 0;

  @override
  RecoveryFlowState get state => _current;
  @override
  int get navigationEpoch => _epoch;

  void move(RecoveryPhase phase, {bool reset = false}) {
    _current = RecoveryFlowState(phase);
    if (reset) _epoch++;
    notifyListeners();
  }

  @override
  void acknowledge() => move(RecoveryPhase.idle, reset: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _Notifications notifications;
  late _Recovery recovery;
  late Reminder task;
  final channels = <MethodChannel>[];
  var windowActivationFails = false;
  String? coldPayload;
  int nativeEnds = 0;
  const liveChannel = ChannelLiveReminderBackend.channel;

  String payload({String epoch = _firstEpoch}) =>
      NotificationPayload.forReminder(task, datasetEpoch: epoch).encode();

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    coldPayload = null;
    nativeEnds = 0;
    sqfliteFfiInit();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    channels.addAll(const [
      MethodChannel('xyz.luan/audioplayers.global'),
      MethodChannel('xyz.luan/audioplayers.global/events'),
      MethodChannel('xyz.luan/audioplayers'),
      MethodChannel('com.llfbandit.record/messages'),
      MethodChannel('tray_manager'),
      MethodChannel('window_manager'),
    ]);
    for (final channel in List<MethodChannel>.of(channels)) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (channel.name == 'window_manager' && windowActivationFails) {
          throw PlatformException(code: 'window_unavailable');
        }
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final events = MethodChannel('xyz.luan/audioplayers/events/$id');
          channels.add(events);
          messenger.setMockMethodCallHandler(events, (_) async => null);
        }
        return null;
      });
    }
    channels.add(liveChannel);
    messenger.setMockMethodCallHandler(liveChannel, (call) async {
      if (call.method == 'initialize') return coldPayload;
      if (call.method == 'status') return {'availability': 'available'};
      if (call.method == 'end') nativeEnds++;
      return null;
    });
    windowActivationFails = false;
    directory = await Directory.systemTemp.createTemp('notification-routing-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    notifications = _Notifications();
    task = Reminder(
      id: 'isolated-notification-task',
      taskTitle: 'Open this isolated task',
      quadrantLevel: 2,
      triggerTime: DateTime.utc(2030, 1, 2, 3, 4),
      noticeRevision: 3,
    );
    await database.writeTransaction(database.captureGeneration(), (db) async {
      await db.update('Settings', {'language': 'en'});
      await db.insert('Reminders', task.toJson());
    });
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
        contextTriggerServiceProvider.overrideWithValue(_Context()),
        remindersProvider.overrideWith(
          (ref) => RemindersNotifier(
            database,
            notifications: notifications,
            runLoadEffects: false,
          ),
        ),
        recoveryCoordinatorProvider.overrideWith(
          (ref) => recovery = _Recovery(ref),
        ),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(workspaceDraftsProvider.notifier).ready;
    await container.read(mediaRecordsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
  });

  tearDown(() async {
    if (notifications.initialization case final pending?) {
      if (!pending.isCompleted) pending.complete();
    }
    container.dispose();
    await notifications.clicks.close();
    await database.close(createBackup: false);
    await directory.delete(recursive: true);
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    channels.clear();
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> mount(WidgetTester tester) async {
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MyApp()),
    );
    await tester.pump();
  }

  Future<void> ready(WidgetTester tester) async {
    await tester.runAsync(() async {
      await container.read(remindersProvider.notifier).ready;
      await notifications.init();
    });
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Finder details() => find.byType(TaskDetailScreen, skipOffstage: false);

  Future<void> nativeTap(String value) async {
    final done = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          liveChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('openReminder', value),
          ),
          (_) => done.complete(),
        );
    await done.future;
  }

  testWidgets(
    'cold Live Activity tap waits for data, opens detail, does not acknowledge',
    (tester) async {
      notifications.initialization = Completer<void>();
      coldPayload = payload();
      await mount(tester);
      expect(details(), findsNothing);
      notifications.initialization!.complete();
      await ready(tester);
      expect(details(), findsOneWidget);
      expect(tester.widget<TaskDetailScreen>(details()).task.id, task.id);
      final rows = await tester.runAsync(
        () => database.read(
          database.captureGeneration(),
          (db) => db.query('Reminders'),
        ),
      );
      expect(rows!.single['notice_acknowledged_at'], isNull);
      expect(rows.single['notice_revision'], 3);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('duplicate warm tap opens once, can reopen after returning', (
    tester,
  ) async {
    await mount(tester);
    await ready(tester);
    await nativeTap(payload());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await nativeTap(payload());
    await tester.pump();
    expect(details(), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(details(), findsNothing);
    await nativeTap(payload());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(details(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  for (final mutation in [
    'deleted',
    'acknowledged',
    'completed',
    'rescheduled',
    'restored',
  ]) {
    testWidgets('queued Live Activity tap ignores $mutation occurrence', (
      tester,
    ) async {
      notifications.initialization = Completer<void>();
      coldPayload = payload();
      await mount(tester);
      await tester.runAsync(() async {
        await database.writeTransaction(database.captureGeneration(), (
          db,
        ) async {
          if (mutation == 'deleted') {
            await db.delete('Reminders');
          } else if (mutation != 'restored') {
            await db.update('Reminders', switch (mutation) {
              'acknowledged' => {
                'notice_acknowledged_at': DateTime.utc(2026).toIso8601String(),
              },
              'completed' => {'is_completed': 1},
              _ => {'notice_revision': 4},
            });
          }
        });
        if (mutation == 'restored') notifications.epoch = _secondEpoch;
        await container.read(remindersProvider.notifier).refreshReminders();
      });
      notifications.initialization!.complete();
      await ready(tester);
      expect(details(), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('recovery closes activity and drops pending old tap', (
    tester,
  ) async {
    notifications.initialization = Completer<void>();
    coldPayload = payload();
    await mount(tester);
    recovery.move(RecoveryPhase.quiescing);
    await tester.pump();
    expect(nativeEnds, 1);
    notifications.initialization!.complete();
    recovery.move(RecoveryPhase.idle);
    await ready(tester);
    expect(details(), findsNothing);
    await nativeTap('not a payload');
    await tester.pump();
    expect(details(), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
}
