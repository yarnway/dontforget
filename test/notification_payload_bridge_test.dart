import 'dart:async';
import 'dart:convert';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_route_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Native implements FlutterLocalNotificationsPlugin {
  bool initialized = true;
  PlatformException? initializationError;
  InitializationSettings? settings;
  DidReceiveNotificationResponseCallback? callback;
  NotificationAppLaunchDetails? launch;
  NotificationResponse? duringInitialize;
  final List<String> calls = [];
  final List<String?> payloads = [];
  final Map<int, String?> pending = {};

  @override
  dynamic noSuchMethod(Invocation call) {
    calls.add('${call.memberName}');
    switch (call.memberName) {
      case #initialize:
        if (initializationError != null) {
          return Future<bool>.error(initializationError!);
        }
        settings = call.positionalArguments.single as InitializationSettings;
        callback =
            call.namedArguments[#onDidReceiveNotificationResponse]
                as DidReceiveNotificationResponseCallback?;
        if (duringInitialize != null) callback!(duringInitialize!);
        return Future<bool>.value(initialized);
      case #getNotificationAppLaunchDetails:
        return Future<NotificationAppLaunchDetails?>.value(launch);
      case #zonedSchedule:
        final payload = call.namedArguments[#payload] as String?;
        payloads.add(payload);
        pending[call.positionalArguments.first as int] = payload;
        return Future<void>.value();
      case #cancel:
        pending.remove(call.positionalArguments.first);
        return Future<void>.value();
      case #cancelAll:
        pending.clear();
        return Future<void>.value();
      default:
        throw UnsupportedError('${call.memberName}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const firstEpoch = '10000000-0000-4000-8000-000000000001';
  const secondEpoch = '20000000-0000-4000-8000-000000000002';
  late String epoch;
  late _Native native;
  late NotificationService service;
  late Reminder reminder;

  NotificationResponse response(
    String? payload, {
    NotificationResponseType type =
        NotificationResponseType.selectedNotification,
    String? actionId,
  }) => NotificationResponse(
    notificationResponseType: type,
    payload: payload,
    actionId: actionId,
  );

  String payload({String? forEpoch, Reminder? forReminder}) =>
      NotificationPayload.forReminder(
        forReminder ?? reminder,
        datasetEpoch: forEpoch ?? epoch,
      ).encode();

  setUp(() {
    epoch = firstEpoch;
    native = _Native();
    service = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
      readDatasetEpoch: () async => epoch,
    );
    reminder = Reminder(
      id: 'notification-route-test',
      taskTitle: 'Synthetic route test',
      quadrantLevel: 3,
      noticeRevision: 4,
      triggerTime: DateTime.now().add(const Duration(days: 1)),
    );
  });

  tearDown(() async {
    await service.pauseForMaintenance();
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
    test(
      'Darwin $platform false initializes callbacks and cold launch',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        native.initialized = false;
        final encoded = payload();
        native.launch = NotificationAppLaunchDetails(
          true,
          notificationResponse: response(encoded),
        );
        await service.init();
        expect(service.takePendingNotificationPayloads(), [encoded]);
        await service.scheduleReminderStrict(reminder);
        expect(native.payloads, [encoded]);
        expect(
          native.calls.where((call) => call == 'Symbol("initialize")'),
          hasLength(1),
        );
      },
    );

    test(
      'Darwin $platform channel errors still block strict scheduling',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        native.initializationError = PlatformException(
          code: 'initialization_failed',
        );
        await expectLater(
          service.scheduleReminderStrict(reminder),
          throwsStateError,
        );
        expect(native.payloads, isEmpty);
        expect(
          native.calls,
          isNot(contains('Symbol("getNotificationAppLaunchDetails")')),
        );
      },
    );
  }

  test('Android false remains an initialization failure', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    native.initialized = false;
    await expectLater(
      service.scheduleReminderStrict(reminder),
      throwsStateError,
    );
    expect(native.payloads, isEmpty);
    expect(
      native.calls,
      isNot(contains('Symbol("getNotificationAppLaunchDetails")')),
    );
  });

  test(
    'initialization reads launch details without requesting permission',
    () async {
      await service.init();
      expect(service.datasetEpoch, firstEpoch);
      for (final options in [native.settings!.iOS!, native.settings!.macOS!]) {
        expect(options.requestAlertPermission, isFalse);
        expect(options.requestSoundPermission, isFalse);
        expect(options.requestBadgePermission, isFalse);
      }
      expect(native.calls, [
        'Symbol("initialize")',
        'Symbol("getNotificationAppLaunchDetails")',
      ]);
    },
  );

  test('cold launch before a listener is buffered and consumed once', () async {
    final encoded = payload();
    native.launch = NotificationAppLaunchDetails(
      true,
      notificationResponse: response(encoded),
    );
    await service.init();
    expect(service.takePendingNotificationPayloads(), [encoded]);
    expect(service.takePendingNotificationPayloads(), isEmpty);
  });

  test('early native callback during initialization is not lost', () async {
    final encoded = payload();
    native.duringInitialize = response(encoded);
    await service.init();
    expect(service.takePendingNotificationPayloads(), [encoded]);
  });

  test(
    'hot callbacks carry the same versioned format to the listener',
    () async {
      await service.init();
      final delivered = <String>[];
      final subscription = service.onNotificationPayload.listen(delivered.add);
      try {
        native.callback!(response(payload()));
        await Future<void>.delayed(Duration.zero);
        expect(delivered, [payload()]);
        expect(service.takePendingNotificationPayloads(), isEmpty);
        expect(
          NotificationPayload.tryParse(delivered.single)!.noticeRevision,
          4,
        );
      } finally {
        await subscription.cancel();
      }
    },
  );

  test(
    'cold and hot duplicate delivery opens exactly one route when ready',
    () async {
      final encoded = payload();
      native.launch = NotificationAppLaunchDetails(
        true,
        notificationResponse: response(encoded),
      );
      await service.init();
      final opened = <Reminder>[];
      final router = NotificationRouteService(
        readSnapshot: () => NotificationRouteSnapshot(
          datasetEpoch: service.datasetEpoch!,
          reminders: [reminder],
        ),
        openReminder: (target) {
          opened.add(target);
          return true;
        },
      );
      final subscription = service.onNotificationPayload.listen(router.receive);
      try {
        for (final pending in service.takePendingNotificationPayloads()) {
          router.receive(pending);
        }
        native.callback!(response(encoded));
        await Future<void>.delayed(Duration.zero);
        expect(opened, isEmpty);
        expect(router.pendingCount, 1);
        router.setReady(true);
        native.callback!(response(encoded));
        await Future<void>.delayed(Duration.zero);
        expect(opened, [reminder]);
        expect(reminder.noticeAcknowledgedAt, isNull);
        expect(router.pendingCount, 0);
      } finally {
        await subscription.cancel();
        router.dispose();
      }
    },
  );

  test(
    'unsupported actions and malformed payloads never reach routing',
    () async {
      await service.init();
      final delivered = <String>[];
      final subscription = service.onNotificationPayload.listen(delivered.add);
      try {
        native.callback!(
          response(
            payload(),
            type: NotificationResponseType.selectedNotificationAction,
            actionId: 'unsupported-action',
          ),
        );
        native.callback!(response(payload(), actionId: 'unsupported-action'));
        for (final invalid in [
          null,
          '',
          'legacy-task-id',
          '{',
          jsonEncode({...jsonDecode(payload()) as Map, 'kind': 'unknown'}),
          jsonEncode({...jsonDecode(payload()) as Map, 'version': 2}),
        ]) {
          native.callback!(response(invalid));
        }
        await Future<void>.delayed(Duration.zero);
        expect(delivered, isEmpty);
        expect(service.takePendingNotificationPayloads(), isEmpty);
      } finally {
        await subscription.cancel();
      }
    },
  );

  test(
    'launch response is ignored unless the notification launched the app',
    () async {
      native.launch = NotificationAppLaunchDetails(
        false,
        notificationResponse: response(payload()),
      );
      await service.init();
      expect(service.takePendingNotificationPayloads(), isEmpty);
    },
  );

  test('launch without a notification response is harmless', () async {
    native.launch = const NotificationAppLaunchDetails(true);
    await service.init();
    expect(service.takePendingNotificationPayloads(), isEmpty);
    await service.scheduleReminderStrict(reminder);
    expect(native.payloads, [payload()]);
  });

  test(
    'rebuild emits the new epoch and old delivered notifications cannot open',
    () async {
      await service.scheduleReminderStrict(reminder);
      final oldPayload = native.payloads.single!;
      expect(
        NotificationPayload.tryParse(oldPayload)!.datasetEpoch,
        firstEpoch,
      );
      await service.pauseForMaintenance();
      epoch = secondEpoch;
      await service.resumeFromReminders([reminder]);
      final newPayload = native.payloads.last!;
      expect(service.datasetEpoch, secondEpoch);
      expect(
        NotificationPayload.tryParse(newPayload)!.datasetEpoch,
        secondEpoch,
      );
      expect(native.pending.values, [newPayload]);

      final opened = <Reminder>[];
      final router = NotificationRouteService(
        readSnapshot: () => NotificationRouteSnapshot(
          datasetEpoch: service.datasetEpoch!,
          reminders: [reminder],
        ),
        openReminder: (target) {
          opened.add(target);
          return true;
        },
      )..setReady(true);
      final subscription = service.onNotificationPayload.listen(router.receive);
      try {
        native.callback!(response(oldPayload));
        await Future<void>.delayed(Duration.zero);
        expect(opened, isEmpty);
        native.callback!(response(newPayload));
        await Future<void>.delayed(Duration.zero);
        expect(opened, [reminder]);
      } finally {
        await subscription.cancel();
        router.dispose();
      }
    },
  );

  test(
    'normal scheduling refreshes the epoch even after initialization',
    () async {
      await service.init();
      epoch = secondEpoch;
      await service.scheduleReminderStrict(reminder);
      expect(
        NotificationPayload.tryParse(native.payloads.single)!.datasetEpoch,
        secondEpoch,
      );
      expect(service.datasetEpoch, secondEpoch);
    },
  );

  test(
    'cancellation during an epoch read cannot resurrect a native request',
    () async {
      final readStarted = Completer<void>();
      final readFinished = Completer<String>();
      var reads = 0;
      service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
        readDatasetEpoch: () {
          if (++reads == 1) return Future.value(firstEpoch);
          readStarted.complete();
          return readFinished.future;
        },
      );
      final scheduling = service.scheduleReminderStrict(reminder);
      await readStarted.future;
      await service.cancelReminderStrict(reminder.id);
      readFinished.complete(secondEpoch);
      await scheduling;
      expect(native.payloads, isEmpty);
      expect(native.pending, isEmpty);
    },
  );

  test(
    'invalid dataset identity cannot create a routable native request',
    () async {
      epoch = 'invalid';
      await expectLater(
        service.scheduleReminderStrict(reminder),
        throwsArgumentError,
      );
      expect(native.pending, isEmpty);
    },
  );

  test('notification instances are scoped to their database helper', () {
    final first = DatabaseHelper.forTesting('/unused/one', databaseFactoryFfi);
    final second = DatabaseHelper.forTesting('/unused/two', databaseFactoryFfi);
    expect(
      NotificationService.forDatabase(first),
      same(NotificationService.forDatabase(first)),
    );
    expect(
      NotificationService.forDatabase(first),
      isNot(same(NotificationService.forDatabase(second))),
    );
    // This identity check never opens a database or the real app container.
  });
}
