import 'dart:async';
import 'dart:io';

import 'package:dont_forget/app.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/recovery_coordinator.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/pending_notification_actions.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/workspace_drafts.dart';

class _Notifications extends NotificationService {
  _Notifications(this.queue)
    : super.forTesting(
        FlutterLocalNotificationsPlugin(),
        usesNativeNotifications: false,
      );

  final PendingNotificationActions queue;
  final clicks = StreamController<String>.broadcast(sync: true);
  final actions = StreamController<void>.broadcast(sync: true);
  final cancelled = <String>[];
  final scheduled = <String>[];
  String epoch = '';

  @override
  String get datasetEpoch => epoch;
  @override
  Stream<String> get onNotificationPayload => clicks.stream;
  @override
  Stream<void> get onNotificationAction => actions.stream;
  @override
  Future<PendingNotificationActions> pendingNotificationActions() async =>
      queue;
  @override
  Future<void> init() async {}
  @override
  Future<void> setNotificationLanguage(String language) async {}
  @override
  Future<void> scheduleReminder(Reminder reminder) async {
    scheduled.add(reminder.id);
  }

  @override
  Future<void> cancelReminder(String id) async {
    cancelled.add(id);
  }

  @override
  Future<void> scheduleReminderStrict(Reminder reminder) =>
      scheduleReminder(reminder);
  @override
  Future<void> cancelReminderStrict(String id) => cancelReminder(id);
}

class _Reminders extends RemindersNotifier {
  _Reminders(super.database, {required super.notifications})
    : super(runLoadEffects: false);
  Completer<void>? loading;
  @override
  Future<void> get ready async {
    await super.ready;
    await loading?.future;
  }
}

class _Context extends ContextTriggerService {
  _Context() : super.forTesting();
  @override
  Future<String?> detectCurrentWifiSsid() async => null;
}

class _Recovery extends RecoveryCoordinator {
  _Recovery(super.ref);
  RecoveryFlowState _current = const RecoveryFlowState(RecoveryPhase.idle);
  @override
  RecoveryFlowState get state => _current;
  @override
  int get navigationEpoch => 0;
  void move(RecoveryPhase phase) {
    _current = RecoveryFlowState(phase);
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late PendingNotificationActions queue;
  late _Notifications notifications;
  late _Reminders reminders;
  late _Recovery recovery;
  late Reminder task;
  final channels = <MethodChannel>[];

  String payload() => NotificationPayload.forReminder(
    task,
    datasetEpoch: notifications.epoch,
  ).encode();

  NotificationActionRequest complete() => NotificationActionRequest(
    payload: NotificationPayload.tryParse(payload())!,
    actionId: 'complete',
    occurredAt: DateTime.now(),
  );

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
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final events = MethodChannel('xyz.luan/audioplayers/events/$id');
          channels.add(events);
          messenger.setMockMethodCallHandler(events, (_) async => null);
        }
        return null;
      });
    }
    directory = await Directory.systemTemp.createTemp(
      'notification-action-app-',
    );
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    queue = PendingNotificationActions.forDirectory(directory);
    notifications = _Notifications(queue);
    notifications.epoch = await database.readNotificationEpoch();
    task = Reminder(
      id: 'isolated-action-task',
      taskTitle: 'Synthetic pending action task',
      quadrantLevel: 2,
      triggerTime: DateTime.now().subtract(const Duration(minutes: 1)),
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
          (ref) =>
              reminders = _Reminders(database, notifications: notifications),
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
    if (reminders.loading case final pending?) {
      if (!pending.isCompleted) pending.complete();
    }
    container.dispose();
    await notifications.clicks.close();
    await notifications.actions.close();
    await database.close(createBackup: false);
    await directory.delete(recursive: true);
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    channels.clear();
  });

  Future<void> mount(WidgetTester tester) async {
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MyApp()),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester, {bool Function()? until}) async {
    for (var tick = 0; tick < 80; tick++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
      if (until?.call() ?? tick >= 4) return;
    }
    fail('Notification action did not settle');
  }

  Future<void> enqueue(WidgetTester tester) async {
    var done = false;
    Object? failure;
    unawaited(
      queue
          .enqueue(complete())
          .then((_) => done = true, onError: (Object error) => failure = error),
    );
    await settle(tester, until: () => done || failure != null);
    if (failure != null) throw failure!;
  }

  Future<List<NotificationActionRequest>> readQueue(WidgetTester tester) async {
    List<NotificationActionRequest>? result;
    Object? failure;
    unawaited(
      queue.read().then(
        (value) => result = value,
        onError: (Object error) => failure = error,
      ),
    );
    await settle(tester, until: () => result != null || failure != null);
    if (failure != null) throw failure!;
    return result!;
  }

  Future<void> drained(WidgetTester tester) async {
    for (var round = 0; round < 50; round++) {
      if ((await readQueue(tester)).isEmpty) {
        await tester.pump();
        return;
      }
      await settle(tester);
    }
    fail('Pending notification actions were not drained');
  }

  Future<void> unmount(WidgetTester tester) async {
    await drainWorkspaceDrafts(tester, container);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets(
    'pending action waits for reminders.ready then persists and clears queue',
    (tester) async {
      await enqueue(tester);
      reminders.loading = Completer<void>();
      await mount(tester);
      await settle(tester);
      expect(container.read(remindersProvider).single.isCompleted, isFalse);
      expect(await readQueue(tester), hasLength(1));
      reminders.loading!.complete();
      await settle(
        tester,
        until: () => container.read(remindersProvider).single.isCompleted,
      );
      await settle(tester);
      expect(await readQueue(tester), isEmpty);
      final stored = await tester.runAsync(
        () => database.read(
          database.captureGeneration(),
          (db) => db.query('Reminders'),
        ),
      );
      expect(stored!.single['is_completed'], 1);
      expect(notifications.cancelled, contains(task.id));
      expect(find.byType(TaskDetailScreen, skipOffstage: false), findsNothing);
      await unmount(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hot action reports foreground feedback and default click keeps navigation',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await mount(tester);
      await settle(tester);
      notifications.clicks.add(payload());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byType(TaskDetailScreen, skipOffstage: false),
        findsOneWidget,
      );
      expect(container.read(remindersProvider).single.isCompleted, isFalse);
      await enqueue(tester);
      notifications.actions.add(null);
      await settle(
        tester,
        until: () => container.read(remindersProvider).single.isCompleted,
      );
      await settle(tester);
      await drained(tester);
      expect(find.text('Reminder updated'), findsOneWidget);
      expect(await readQueue(tester), isEmpty);
      await unmount(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recovery defers pending actions and rejects an old dataset on resume',
    (tester) async {
      await mount(tester);
      await settle(tester);
      recovery.move(RecoveryPhase.quiescing);
      await tester.pump();
      await enqueue(tester);
      notifications.actions.add(null);
      await settle(tester);
      expect(container.read(remindersProvider).single.isCompleted, isFalse);
      expect(await readQueue(tester), hasLength(1));
      notifications.epoch = '20000000-0000-4000-8000-000000000002';
      recovery.move(RecoveryPhase.idle);
      await drained(tester);
      expect(await readQueue(tester), isEmpty);
      expect(container.read(remindersProvider).single.isCompleted, isFalse);
      await unmount(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dispose while readiness is delayed retains intent and never reads disposed ref',
    (tester) async {
      await enqueue(tester);
      reminders.loading = Completer<void>();
      await mount(tester);
      await unmount(tester);
      reminders.loading!.complete();
      await settle(tester);
      expect(container.read(remindersProvider).single.isCompleted, isFalse);
      expect(await readQueue(tester), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
}
