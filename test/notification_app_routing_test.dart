import 'support/workspace_drafts.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'dart:async';
import 'dart:io';

import 'package:dont_forget/app.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/recovery_coordinator.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/android_protocol_service.dart';
import 'package:dont_forget/services/android_share_service.dart';
import 'package:dont_forget/services/shared_text_inbox.dart';
import 'package:dont_forget/providers/shared_text_provider.dart';
import 'package:dont_forget/ui/screens/shared_text_inbox_screen.dart';
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

class _ProtocolReminders extends RemindersNotifier {
  _ProtocolReminders(super.database, NotificationService notifications)
    : super(notifications: notifications, runLoadEffects: false);

  final actions = <Future<ReminderActionResult>>[];

  @override
  Future<ReminderActionResult> performNotificationAction(
    Reminder expected, {
    required NotificationPayload payload,
    required String actionId,
    required DateTime occurredAt,
    DateTime? now,
  }) {
    final result = super.performNotificationAction(
      expected,
      payload: payload,
      actionId: actionId,
      occurredAt: occurredAt,
      now: now,
    );
    actions.add(result);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _Notifications notifications;
  late _Recovery recovery;
  late Reminder task;
  late _ProtocolReminders protocolReminders;
  String? initialProtocolUrl;
  Completer<String?>? protocolInitialization;
  final channels = <MethodChannel>[];
  var windowActivationFails = false;
  final nativeShares = <Map<String, Object>>[];
  final shareAcks = <String>[];
  String? sharedEpoch;
  SharedText share(int n, {String text = 'Shared 中文 https://example.com'}) =>
      SharedText(
        id: '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
        text: text,
        createdAt: 1762300800000,
      );

  String payload({String epoch = _firstEpoch}) =>
      NotificationPayload.forReminder(task, datasetEpoch: epoch).encode();

  setUp(() async {
    nativeShares.clear();
    shareAcks.clear();
    sharedEpoch = null;
    initialProtocolUrl = null;
    protocolInitialization = null;
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
      AndroidProtocolService.channel,
      AndroidShareService.channel,
    ]);
    for (final channel in List<MethodChannel>.of(channels)) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (channel == AndroidShareService.channel) {
          if (call.method == 'initialize') {
            sharedEpoch = call.arguments as String;
          }
          if (call.method == 'pending') return List.of(nativeShares);
          if (call.method == 'acknowledge') {
            final raw = await container
                .read(workspaceDraftsProvider.notifier)
                .readPersistedKey(SharedTextInbox.key);
            expect(
              SharedTextInboxData.parse(raw).receipts,
              contains(call.arguments),
            );
            shareAcks.add(call.arguments as String);
            nativeShares.removeWhere((item) => item['id'] == call.arguments);
          }
          return null;
        }
        if (channel == AndroidProtocolService.channel &&
            call.method == 'initialize') {
          return protocolInitialization?.future ?? initialProtocolUrl;
        }
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
          (ref) =>
              protocolReminders = _ProtocolReminders(database, notifications),
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
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
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

  Future<void> waitShare(WidgetTester tester, bool Function() done) async {
    final watch = Stopwatch()..start();
    while (!done() && watch.elapsed < const Duration(seconds: 10)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(
      done(),
      true,
      reason:
          'Shared handoff must settle; lifecycle=${tester.binding.lifecycleState}, epoch=$sharedEpoch, acks=${shareAcks.length}',
    );
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets(
    'shared cold text waits for readiness and durable admission before native ack',
    (tester) async {
      final capture = {
        'id': 'original-capture',
        'text': 'Original composer draft',
      };
      await tester.runAsync(
        () => container
            .read(workspaceDraftsProvider.notifier)
            .put('capture', capture),
      );
      nativeShares.add(share(1).toJson());
      notifications.initialization = Completer<void>();
      await mount(tester);
      expect(shareAcks, isEmpty);
      expect(find.byType(SharedTextInboxScreen), findsNothing);
      notifications.initialization!.complete();
      await ready(tester);
      await waitShare(
        tester,
        () => find.byType(SharedTextInboxScreen).evaluate().isNotEmpty,
      );
      expect(sharedEpoch, _firstEpoch);
      expect(shareAcks, [share(1).id]);
      expect(container.read(workspaceDraftsProvider)['capture'], capture);
      expect(container.read(remindersProvider).map((r) => r.id), [task.id]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'shared editor autosaves and explicit local save cannot create duplicate memos on redelivery',
    (tester) async {
      nativeShares.add(share(1).toJson());
      await mount(tester);
      await ready(tester);
      await waitShare(
        tester,
        () => find.byType(SharedTextInboxScreen).evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(ValueKey('shared-item-${share(1).id}')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('shared-text-editor')),
        'Edited 中文 link',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await waitShare(
        tester,
        () =>
            SharedTextInboxData.parse(
              container.read(workspaceDraftsProvider)[SharedTextInbox.key],
            ).items.single.text ==
            'Edited 中文 link',
      );
      await tester.tap(find.byKey(const ValueKey('shared-save-memo')));
      await waitShare(
        tester,
        () =>
            find.byKey(const ValueKey('shared-text-editor')).evaluate().isEmpty,
      );
      final rows = container
          .read(remindersProvider)
          .where((row) => row.id == share(1).id)
          .toList();
      expect(rows, hasLength(1));
      expect(rows.single.sourceText, 'Edited 中文 link');
      expect(rows.single.triggerTime, isNull);
      expect(rows.single.capturePending, false);
      nativeShares.add(share(1).toJson());
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            AndroidShareService.channel.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('onPendingShares'),
            ),
            (_) {},
          );
      await waitShare(tester, () => shareAcks.length == 2);
      expect(
        SharedTextInboxData.parse(
          container.read(workspaceDraftsProvider)[SharedTextInbox.key],
        ).items,
        isEmpty,
      );
      expect(
        container.read(remindersProvider).where((row) => row.id == share(1).id),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a stale shared editor keeps newer stored text and asks before discarding failed edits',
    (tester) async {
      nativeShares.add(share(1).toJson());
      await mount(tester);
      await ready(tester);
      await waitShare(
        tester,
        () => find.byType(SharedTextInboxScreen).evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(ValueKey('shared-item-${share(1).id}')));
      await tester.pumpAndSettle();
      var externalSaved = false;
      unawaited(
        container
            .read(sharedTextInboxProvider)
            .edit(share(1).id, share(1).text, 'External newer edit')
            .then((_) => externalSaved = true),
      );
      await waitShare(tester, () => externalSaved);
      await tester.enterText(
        find.byKey(const ValueKey('shared-text-editor')),
        'Stale local edit',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await waitShare(
        tester,
        () => find.text('Retry saving draft').evaluate().isNotEmpty,
      );
      await tester.tap(find.byIcon(Icons.arrow_back).last);
      await waitShare(
        tester,
        () => find.text('Discard unsaved edits').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Discard unsaved edits'));
      await waitShare(
        tester,
        () =>
            find.byKey(const ValueKey('shared-text-editor')).evaluate().isEmpty,
      );
      expect(
        SharedTextInboxData.parse(
          container.read(workspaceDraftsProvider)[SharedTextInbox.key],
        ).items.single.text,
        'External newer edit',
      );
      expect(container.read(remindersProvider), hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  Finder details() => find.byType(TaskDetailScreen, skipOffstage: false);

  Future<void> sendProtocol(WidgetTester tester, String uri) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          AndroidProtocolService.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('onProtocolUrl', uri),
          ),
          (_) {},
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<String> protocolAction(
    String verb, {
    String? minutes,
    String? epoch,
    Reminder? reminder,
  }) async {
    final target = reminder ?? task;
    return Uri(
      scheme: 'dontforget',
      host: 'action',
      path: '/$verb',
      queryParameters: {
        'id': target.id,
        'payload': NotificationPayload.forReminder(
          target,
          datasetEpoch: epoch ?? await database.readNotificationEpoch(),
        ).encode(),
        if (minutes != null) 'minutes': minutes,
      },
    ).toString();
  }

  Future<void> finishProtocolActions(WidgetTester tester) async {
    var done = false;
    unawaited(Future.wait(protocolReminders.actions).then((_) => done = true));
    for (var tick = 0; tick < 300 && !done; tick++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump();
    }
    expect(done, isTrue, reason: 'Native action and SQLite work must settle');
  }

  testWidgets(
    'Android cold URI waits for loading; duplicate view opens one route and can reopen after closing',
    (tester) async {
      notifications.initialization = Completer<void>();
      initialProtocolUrl = 'dontforget://task/${task.id}';
      await mount(tester);
      expect(details(), findsNothing);
      notifications.initialization!.complete();
      await ready(tester);
      expect(details(), findsOneWidget);
      await sendProtocol(tester, initialProtocolUrl!);
      expect(details(), findsOneWidget);
      expect(
        container.read(remindersProvider).single.noticeAcknowledgedAt,
        isNull,
      );
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      await sendProtocol(tester, initialProtocolUrl!);
      expect(details(), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final entry in ['protocol', 'notification']) {
    testWidgets(
      '$entry detail delegates original media and rejects stale callbacks',
      (tester) async {
        await tester.runAsync(() async {
          await database.writeTransaction(
            database.captureGeneration(),
            (db) => db.insert('MediaRecords', {
              'id': 'route-media',
              'type': 'audio',
              'content_or_path': '${directory.path}/route-audio.m4a',
              'created_at': DateTime.utc(2026).toIso8601String(),
            }),
          );
          await protocolReminders.updateReminder(
            task.copyWith(recordId: 'route-media'),
          );
        });
        task = container.read(remindersProvider).single;
        if (entry == 'protocol') {
          initialProtocolUrl = 'dontforget://task/${task.id}';
        } else {
          notifications.pending.add(payload());
        }
        await mount(tester);
        await ready(tester);
        final command = container.read(workspaceToolsCommandProvider);
        expect(command.playMedia, isNotNull);
        final played = <String>[];
        command.playMedia = played.add;
        final callback = tester.widget<TaskDetailScreen>(details()).onPlayMedia;
        expect(callback, isNotNull);
        final button = find.text('Play / preview attachment');
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pump();
        expect(played, ['route-media']);
        recovery.move(RecoveryPhase.quiescing);
        await tester.pump();
        callback!();
        expect(played, ['route-media']);
        recovery.move(RecoveryPhase.succeeded, reset: true);
        await tester.pump();
        recovery.acknowledge();
        await ready(tester);
        container.read(workspaceToolsCommandProvider).playMedia = played.add;
        callback();
        expect(played, ['route-media']);
        await tester.pumpWidget(const SizedBox());
        callback();
        expect(played, ['route-media']);
      },
    );
  }

  testWidgets('workspace releases its media delegate when disposed', (
    tester,
  ) async {
    await mount(tester);
    await ready(tester);
    final command = container.read(workspaceToolsCommandProvider);
    expect(command.playMedia, isNotNull);
    await tester.pumpWidget(const SizedBox());
    expect(command.playMedia, isNull);
  });

  testWidgets('workspace quiesce removes its media delegate', (tester) async {
    await mount(tester);
    await ready(tester);
    final command = container.read(workspaceToolsCommandProvider);
    expect(command.playMedia, isNotNull);
    var paused = false;
    unawaited(
      container
          .read(runtimeRecoveryGateProvider)
          .pause()
          .then((_) => paused = true),
    );
    for (var tick = 0; tick < 300 && !paused; tick++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(paused, isTrue);
    expect(command.playMedia, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Android ignores missing and trashed tasks', (tester) async {
    await mount(tester);
    await ready(tester);
    await sendProtocol(tester, 'dontforget://task/missing');
    expect(details(), findsNothing);
    await tester.runAsync(
      () => container.read(remindersProvider.notifier).deleteReminder(task.id),
    );
    await sendProtocol(tester, 'dontforget://task/${task.id}');
    expect(details(), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Android duplicate completion changes a recurring occurrence only once',
    (tester) async {
      await tester.runAsync(
        () => protocolReminders.updateReminder(
          task.copyWith(isRecurring: true, recurrenceRule: 'daily'),
        ),
      );
      task = container.read(remindersProvider).single;
      final uri = await tester.runAsync(() => protocolAction('complete'));
      await mount(tester);
      await ready(tester);
      await sendProtocol(tester, uri!);
      await finishProtocolActions(tester);
      final after = container.read(remindersProvider).single;
      expect(after.noticeRevision, task.noticeRevision + 1);
      expect(after.triggerTime, isNot(task.triggerTime));
      await sendProtocol(tester, uri);
      await finishProtocolActions(tester);
      expect(container.read(remindersProvider).single.toJson(), after.toJson());
      expect(protocolReminders.actions, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final minutes in ['15', '60']) {
    testWidgets(
      'Android snooze $minutes validates and consumes one occurrence',
      (tester) async {
        await tester.runAsync(
          () => protocolReminders.updateReminder(
            task.copyWith(
              triggerTime: DateTime.now().subtract(const Duration(hours: 1)),
            ),
          ),
        );
        task = container.read(remindersProvider).single;
        final uri = await tester.runAsync(
          () => protocolAction('snooze', minutes: minutes),
        );
        await mount(tester);
        await ready(tester);
        final before = DateTime.now();
        await sendProtocol(tester, uri!);
        await finishProtocolActions(tester);
        final after = container.read(remindersProvider).single;
        expect(after.noticeRevision, task.noticeRevision + 1);
        expect(
          after.triggerTime!.isBefore(
            before.add(Duration(minutes: int.parse(minutes))),
          ),
          isFalse,
        );
        expect(
          after.triggerTime!.isAfter(
            DateTime.now().add(
              Duration(minutes: int.parse(minutes), seconds: 5),
            ),
          ),
          isFalse,
        );
        await sendProtocol(tester, uri);
        await finishProtocolActions(tester);
        expect(
          container.read(remindersProvider).single.toJson(),
          after.toJson(),
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'Android rejects bare actions and stale data-set or revision tokens',
    (tester) async {
      final oldEpoch = await tester.runAsync(
        () => protocolAction('complete', epoch: _secondEpoch),
      );
      final oldRevision = await tester.runAsync(
        () => protocolAction(
          'complete',
          reminder: task.copyWith(noticeRevision: 1),
        ),
      );
      await mount(tester);
      await ready(tester);
      final before = container.read(remindersProvider).single.toJson();
      for (final uri in [
        'dontforget://action/complete?id=${task.id}',
        oldEpoch!,
        oldRevision!,
      ]) {
        await sendProtocol(tester, uri);
        await finishProtocolActions(tester);
        expect(container.read(remindersProvider).single.toJson(), before);
      }
      expect(protocolReminders.actions, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Android drops links queued before or during recovery', (
    tester,
  ) async {
    notifications.initialization = Completer<void>();
    initialProtocolUrl = 'dontforget://task/${task.id}';
    await mount(tester);
    recovery.move(RecoveryPhase.quiescing);
    await sendProtocol(tester, initialProtocolUrl!);
    recovery.move(RecoveryPhase.succeeded, reset: true);
    await tester.pump();
    notifications.initialization!.complete();
    recovery.acknowledge();
    await ready(tester);
    expect(details(), findsNothing);
    await sendProtocol(tester, initialProtocolUrl!);
    expect(details(), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

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
    addTearDown(() => drainWorkspaceDrafts(tester, container));
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
    addTearDown(() => drainWorkspaceDrafts(tester, container));
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
      addTearDown(() => drainWorkspaceDrafts(tester, container));
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
      addTearDown(() => drainWorkspaceDrafts(tester, container));
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
      addTearDown(() => drainWorkspaceDrafts(tester, container));
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
      addTearDown(() => drainWorkspaceDrafts(tester, container));
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
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'disposing before initialization completes ignores the old click',
    (tester) async {
      notifications.initialization = Completer<void>();
      notifications.pending.add(payload());
      await mount(tester);
      addTearDown(() => drainWorkspaceDrafts(tester, container));
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
