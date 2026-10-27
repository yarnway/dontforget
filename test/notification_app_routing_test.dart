import 'dart:async';
import 'dart:io';

import 'package:dont_forget/app.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/providers/recovery_coordinator.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/screens/recovery_outcome_screen.dart';
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

  String payload({String epoch = _firstEpoch}) =>
      NotificationPayload.forReminder(task, datasetEpoch: epoch).encode();

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
    await container.read(mediaRecordsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    await container.read(workspaceDraftsProvider.notifier).ready;
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
  });

  Future<void> mount(WidgetTester tester) async {
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

  testWidgets('cold launch waits for loading and opens without acknowledging', (
    tester,
  ) async {
    notifications.initialization = Completer<void>();
    notifications.pending.add(payload());
    await mount(tester);
    expect(details(), findsNothing);
    expect(notifications.pending, isEmpty);
    await tester.runAsync(
      () => container.read(remindersProvider.notifier).ready,
    );
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
  });

  testWidgets('warm and cold duplicate callbacks open only one detail route', (
    tester,
  ) async {
    notifications.pending.add(payload());
    await mount(tester);
    await ready(tester);
    notifications.clicks.add(payload());
    notifications.clicks.add(payload());
    await tester.pump();
    expect(details(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mutation in [
    'deleted',
    'acknowledged',
    'completed',
    'rescheduled',
  ]) {
    testWidgets('a queued click ignores a $mutation occurrence', (
      tester,
    ) async {
      notifications.initialization = Completer<void>();
      notifications.pending.add(payload());
      await mount(tester);
      await tester.runAsync(() async {
        await container.read(remindersProvider.notifier).ready;
        await database.writeTransaction(database.captureGeneration(), (
          db,
        ) async {
          if (mutation == 'deleted') {
            await db.delete('Reminders');
          } else {
            await db.update('Reminders', switch (mutation) {
              'acknowledged' => {
                'notice_acknowledged_at': DateTime.utc(2026).toIso8601String(),
              },
              'completed' => {'is_completed': 1},
              _ => {'notice_revision': 4},
            });
          }
        });
        await container.read(remindersProvider.notifier).refreshReminders();
      });
      notifications.initialization!.complete();
      await ready(tester);
      expect(details(), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'recovery invalidates late initialization and recreates Navigator',
    (tester) async {
      notifications.initialization = Completer<void>();
      notifications.pending.add(payload());
      await mount(tester);
      await tester.runAsync(
        () => container.read(remindersProvider.notifier).ready,
      );
      final oldNavigator = tester.state<NavigatorState>(find.byType(Navigator));
      recovery.move(RecoveryPhase.quiescing);
      notifications.initialization!.complete();
      notifications.clicks.add(payload());
      await tester.pump();
      expect(details(), findsNothing);
      notifications.epoch = _secondEpoch;
      recovery.move(RecoveryPhase.succeeded, reset: true);
      await tester.pump();
      await tester.pump();
      expect(find.byType(RecoveryOutcomeScreen), findsOneWidget);
      expect(details(), findsNothing);
      recovery.acknowledge();
      await ready(tester);
      expect(
        tester.state<NavigatorState>(find.byType(Navigator)),
        isNot(same(oldNavigator)),
      );
      expect(details(), findsNothing);
      notifications.clicks.add(payload());
      await tester.pump();
      expect(details(), findsNothing);
      notifications.clicks.add(payload(epoch: _secondEpoch));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(details(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native window activation failure does not lose the detail route',
    (tester) async {
      await mount(tester);
      await ready(tester);
      windowActivationFails = true;
      notifications.clicks.add(payload());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(details(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'new recovery clicks wait through provider and navigator rebuild',
    (tester) async {
      await mount(tester);
      await ready(tester);
      recovery.move(RecoveryPhase.quiescing);
      notifications.epoch = _secondEpoch;
      recovery.move(RecoveryPhase.reloading);
      notifications.clicks.add(payload());
      notifications.clicks.add(payload(epoch: _secondEpoch));
      await tester.pump();
      expect(details(), findsNothing);
      recovery.move(RecoveryPhase.succeeded, reset: true);
      await tester.pump();
      await tester.pump();
      expect(details(), findsNothing);
      recovery.acknowledge();
      await ready(tester);
      expect(details(), findsOneWidget);
      expect(tester.widget<TaskDetailScreen>(details()).task.id, task.id);
      // The late old-epoch click never opens a second route, and the current
      // click is navigation only, even when received during data rebuilding.
      expect(
        container.read(remindersProvider).single.noticeAcknowledgedAt,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a changed database generation rejects late startup navigation', (
    tester,
  ) async {
    notifications.initialization = Completer<void>();
    notifications.pending.add(payload());
    await mount(tester);
    await tester.runAsync(() async {
      await container.read(remindersProvider.notifier).ready;
      final lease = await database.beginMaintenance();
      await lease.validateAndOpen();
      await lease.resume();
    });
    notifications.initialization!.complete();
    await ready(tester);
    expect(details(), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'disposing before initialization completes ignores the old click',
    (tester) async {
      notifications.initialization = Completer<void>();
      notifications.pending.add(payload());
      await mount(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      notifications.initialization!.complete();
      await tester.runAsync(
        () => container.read(remindersProvider.notifier).ready,
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(details(), findsNothing);
    },
  );
}
