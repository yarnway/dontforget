import 'dart:convert';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/macos_notification_scheduler.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/pending_notification_actions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Native implements FlutterLocalNotificationsPlugin {
  DidReceiveNotificationResponseCallback? response;
  NotificationAppLaunchDetails? launch;

  @override
  dynamic noSuchMethod(Invocation call) => switch (call.memberName) {
    #initialize => () {
      response =
          call.namedArguments[#onDidReceiveNotificationResponse]
              as DidReceiveNotificationResponseCallback?;
      return Future<bool>.value(true);
    }(),
    #getNotificationAppLaunchDetails =>
      Future<NotificationAppLaunchDetails?>.value(launch),
    #cancel || #cancelAll || #zonedSchedule => Future<void>.value(),
    _ => throw StateError('Unexpected native operation: ${call.memberName}'),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final observedAt = DateTime.utc(2030, 1, 1, 9);
  final dartAt = observedAt.add(const Duration(minutes: 6));
  late Directory directory;
  late PendingNotificationActions queue;
  late _Native native;
  late NotificationService service;
  late String epoch;
  final requests = <MethodCall>[];
  Object? nativeResult;
  Object? nativeFailure;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Reminder task() => Reminder(
    id: 'synthetic-native-response-time',
    taskTitle: 'Synthetic native response time',
    quadrantLevel: 2,
    triggerTime: observedAt.subtract(const Duration(seconds: 1)),
    eventTime: observedAt.add(const Duration(hours: 1)),
    isRecurring: true,
    recurrenceRule: 'daily',
  );
  String payload() =>
      NotificationPayload.forReminder(task(), datasetEpoch: epoch).encode();
  NotificationResponse response({String? encoded}) => NotificationResponse(
    notificationResponseType:
        NotificationResponseType.selectedNotificationAction,
    actionId: 'snooze_15',
    payload: encoded ?? payload(),
  );

  Future<NotificationActionRequest> receive() async {
    final signal = service.onNotificationAction.first;
    native.response!(response());
    await signal.timeout(const Duration(seconds: 5));
    return (await queue.read()).single;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('native-response-time-');
    queue = PendingNotificationActions.forDirectory(
      Directory('${directory.path}/actions'),
    );
    native = _Native();
    epoch = '10000000-0000-4000-8000-000000000001';
    requests.clear();
    nativeResult = observedAt.microsecondsSinceEpoch;
    nativeFailure = null;
    messenger.setMockMethodCallHandler(MacOSNotificationScheduler.channel, (
      call,
    ) async {
      requests.add(call);
      if (call.method == 'schedule') return null;
      if (nativeFailure != null) throw nativeFailure!;
      return nativeResult;
    });
    service = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
      now: () => dartAt,
      readDatasetEpoch: () async => epoch,
      macScheduler: const MacOSNotificationScheduler(),
      pendingActionStore: () async => queue,
    );
  });

  tearDown(() async {
    await service.pauseForMaintenance();
    messenger.setMockMethodCallHandler(
      MacOSNotificationScheduler.channel,
      null,
    );
    await directory.delete(recursive: true);
  });

  test(
    'channel returns UTC native observation keyed by payload and action',
    () async {
      final value = await const MacOSNotificationScheduler()
          .takeResponseOccurredAt(payload: payload(), actionId: 'snooze_15');
      expect(value, observedAt);
      expect(value!.isUtc, isTrue);
      expect(requests.single.method, 'takeResponseOccurredAt');
      expect(requests.single.arguments, {
        'payload': payload(),
        'actionId': 'snooze_15',
      });
    },
  );

  test(
    'cold action delayed by bootstrap snoozes from native observation',
    () async {
      sqfliteFfiInit();
      final database = DatabaseHelper.forTesting(
        '${directory.path}/database',
        databaseFactoryFfi,
      );
      RemindersNotifier? reminders;
      try {
        epoch = await database.readNotificationEpoch();
        final db = await database.database;
        final original = task();
        await db.insert('Reminders', original.toJson());
        reminders = RemindersNotifier(
          database,
          notifications: service,
          runLoadEffects: false,
        );
        await reminders.ready;
        native.launch = NotificationAppLaunchDetails(
          true,
          notificationResponse: response(),
        );
        final signal = service.onNotificationAction.first;
        await service.init();
        await signal.timeout(const Duration(seconds: 5));
        final request = (await queue.read()).single;
        expect(request.occurredAt, observedAt);
        final result = await reminders.performNotificationAction(
          original,
          payload: request.payload,
          actionId: request.actionId,
          occurredAt: request.occurredAt,
          now: dartAt,
        );
        expect(result.disposition, ReminderActionDisposition.applied);
        expect(
          result.reminder!.triggerTime,
          observedAt.add(const Duration(minutes: 15)),
        );
        expect(result.reminder!.eventTime, original.eventTime);
        expect(result.reminder!.recurrenceAnchorTime, original.triggerTime);
      } finally {
        reminders?.dispose();
        await database.close(createBackup: false);
      }
    },
  );

  test('missing native context falls back to the Dart callback time', () async {
    nativeResult = null;
    await service.init();
    expect((await receive()).occurredAt, dartAt);
  });

  for (final failure in [
    MissingPluginException('old native host'),
    PlatformException(code: 'native_context_unavailable'),
  ]) {
    test(
      'unavailable native channel falls back: ${failure.runtimeType}',
      () async {
        nativeFailure = failure;
        await service.init();
        expect((await receive()).occurredAt, dartAt);
      },
    );
  }

  for (final value in [
    -1,
    8640000000000000001,
    'invalid',
    dartAt.add(const Duration(seconds: 1)).microsecondsSinceEpoch,
  ]) {
    test('invalid or future native time falls back: $value', () async {
      nativeResult = value;
      await service.init();
      expect((await receive()).occurredAt, dartAt);
    });
  }

  test(
    'duplicate action retains first native time when later context is absent',
    () async {
      await service.init();
      expect((await receive()).occurredAt, observedAt);
      nativeResult = null;
      expect((await receive()).occurredAt, observedAt);
      expect(await queue.read(), hasLength(1));
    },
  );

  test(
    'lookup preserves original valid JSON spelling for native correlation',
    () async {
      await service.init();
      final encoded = const JsonEncoder.withIndent(
        ' ',
      ).convert(jsonDecode(payload()));
      final signal = service.onNotificationAction.first;
      native.response!(response(encoded: encoded));
      await signal.timeout(const Duration(seconds: 5));
      expect((requests.single.arguments as Map)['payload'], encoded);
      expect((await queue.read()).single.occurredAt, observedAt);
    },
  );
}
