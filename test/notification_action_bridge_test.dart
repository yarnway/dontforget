import 'dart:io';

import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/macos_notification_scheduler.dart';
import 'package:dont_forget/services/notification_action_presentation.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/pending_notification_actions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

const _epoch = '10000000-0000-4000-8000-000000000001';
final _now = DateTime.utc(2030, 1, 1, 9);

class _Native implements FlutterLocalNotificationsPlugin {
  final settings = <InitializationSettings>[];
  final schedules =
      <({int id, NotificationDetails details, String? payload})>[];
  final cancelled = <int>[];
  DidReceiveNotificationResponseCallback? response;
  DidReceiveBackgroundNotificationResponseCallback? background;
  NotificationAppLaunchDetails? launch;
  int cancelAllCalls = 0;

  @override
  dynamic noSuchMethod(Invocation call) {
    switch (call.memberName) {
      case #initialize:
        settings.add(call.positionalArguments.single as InitializationSettings);
        response =
            call.namedArguments[#onDidReceiveNotificationResponse]
                as DidReceiveNotificationResponseCallback?;
        background =
            call.namedArguments[#onDidReceiveBackgroundNotificationResponse]
                as DidReceiveBackgroundNotificationResponseCallback?;
        return Future<bool>.value(true);
      case #getNotificationAppLaunchDetails:
        return Future<NotificationAppLaunchDetails?>.value(launch);
      case #zonedSchedule:
        schedules.add((
          id: call.positionalArguments[0] as int,
          details: call.positionalArguments[4] as NotificationDetails,
          payload: call.namedArguments[#payload] as String?,
        ));
        return Future<void>.value();
      case #cancel:
        cancelled.add(call.positionalArguments.first as int);
        return Future<void>.value();
      case #cancelAll:
        cancelAllCalls++;
        return Future<void>.value();
      default:
        throw StateError('Unexpected native access: ${call.memberName}');
    }
  }
}

Reminder _task({bool recurring = false}) => Reminder(
  id: 'synthetic-action-task',
  taskTitle: 'Synthetic notification',
  quadrantLevel: 2,
  noticeRevision: 7,
  triggerTime: _now.add(const Duration(days: 1)),
  isRecurring: recurring,
  recurrenceRule: recurring ? 'daily' : 'none',
);

String _payload() =>
    NotificationPayload.forReminder(_task(), datasetEpoch: _epoch).encode();

NotificationResponse _response({String? actionId, String? payload}) =>
    NotificationResponse(
      notificationResponseType: actionId == null
          ? NotificationResponseType.selectedNotification
          : NotificationResponseType.selectedNotificationAction,
      payload: payload ?? _payload(),
      actionId: actionId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PendingNotificationActions queue;
  late _Native native;
  late NotificationService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('action-bridge-test-');
    queue = PendingNotificationActions.forDirectory(directory);
    native = _Native();
    service = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
      now: () => _now,
      readDatasetEpoch: () async => _epoch,
      pendingActionStore: () async => queue,
    );
  });

  tearDown(() async {
    await service.pauseForMaintenance();
    await directory.delete(recursive: true);
  });

  const expectedIds = ['complete', 'snooze_15', 'snooze_60'];
  const expectedTitles = {
    'en': [
      'Complete this occurrence',
      'In 15 minutes',
      'In 1 hour',
      'Skip this occurrence',
    ],
    'zh': ['完成本次提醒', '15分钟后', '1小时后', '跳过本次'],
    'ja': ['今回の通知を完了', '15分後', '1時間後', '今回をスキップ'],
  };

  for (final language in ['zh', 'en', 'ja']) {
    test(
      '$language Darwin categories and Android actions omit skip for one-off tasks',
      () {
        for (final platform in ['ios', 'macos']) {
          final categories = NotificationActionPresentation.categories(
            platform,
            language,
          );
          expect(categories, hasLength(2));
          final once = categories[0];
          final recurring = categories[1];
          expect(once.identifier, 'dontforget_${platform}_once_$language');
          expect(
            recurring.identifier,
            'dontforget_${platform}_recurring_$language',
          );
          expect(once.actions.map((action) => action.identifier), expectedIds);
          expect(recurring.actions.map((action) => action.identifier), [
            ...expectedIds,
            'skip_occurrence',
          ]);
          expect(
            recurring.actions.map((action) => action.title),
            expectedTitles[language],
          );
        }
        final once = NotificationActionPresentation.android(false, language);
        final recurring = NotificationActionPresentation.android(
          true,
          language,
        );
        expect(once.map((action) => action.id), expectedIds);
        expect(recurring.map((action) => action.id), [
          'complete',
          'snooze_15',
          'skip_occurrence',
        ]);
        expect(recurring.map((action) => action.title), [
          for (final index in [0, 1, 3]) expectedTitles[language]![index],
        ]);
        expect(recurring.any((action) => action.id == 'open'), isFalse);
      },
    );
  }

  test(
    'initialization registers distinct iOS/macOS variants and a background callback',
    () async {
      await service.setNotificationLanguage('zh');
      final settings = native.settings.single;
      expect(
        settings.iOS!.notificationCategories.map(
          (category) => category.identifier,
        ),
        ['dontforget_ios_once_zh', 'dontforget_ios_recurring_zh'],
      );
      expect(
        settings.macOS!.notificationCategories.map(
          (category) => category.identifier,
        ),
        ['dontforget_macos_once_zh', 'dontforget_macos_recurring_zh'],
      );
      expect(native.background, isNotNull);
      expect(settings.iOS!.requestAlertPermission, isFalse);
      expect(settings.macOS!.requestAlertPermission, isFalse);
    },
  );

  for (final recurring in [false, true]) {
    test(
      'scheduled ${recurring ? 'recurring' : 'one-off'} uses versioned payload and matching platform categories',
      () async {
        await service.setNotificationLanguage('ja');
        final task = _task(recurring: recurring);
        await service.scheduleReminderStrict(task);
        final scheduled = native.schedules.single;
        expect(scheduled.details.android!.actions!.map((action) => action.id), [
          'complete',
          'snooze_15',
          if (recurring) 'skip_occurrence' else 'snooze_60',
        ]);
        final variant = recurring ? 'recurring' : 'once';
        expect(
          scheduled.details.iOS!.categoryIdentifier,
          'dontforget_ios_${variant}_ja',
        );
        expect(
          scheduled.details.macOS!.categoryIdentifier,
          'dontforget_macos_${variant}_ja',
        );
        expect(
          NotificationPayload.tryParse(
            scheduled.payload,
          )!.matches(task, currentDatasetEpoch: _epoch),
          isTrue,
        );
        expect(scheduled.id, native.cancelled.single);
      },
    );
  }

  test(
    'language change re-registers labels and reschedules same occurrence and native ID',
    () async {
      await service.setNotificationLanguage('ja');
      await service.scheduleReminderStrict(_task(recurring: true));
      final initial = native.schedules.single;
      await service.setNotificationLanguage('zh');
      expect(native.settings, hasLength(2));
      expect(native.schedules, hasLength(2));
      final updated = native.schedules.last;
      expect(updated.id, initial.id);
      expect(updated.payload, initial.payload);
      expect(
        updated.details.iOS!.categoryIdentifier,
        'dontforget_ios_recurring_zh',
      );
      expect(updated.details.android!.actions!.map((action) => action.title), [
        for (final index in [0, 1, 3]) expectedTitles['zh']![index],
      ]);
      await service.setNotificationLanguage('zh');
      expect(native.settings, hasLength(2));
      expect(native.schedules, hasLength(2));
    },
  );

  test(
    'main-isolate action callbacks persist exact time and signal without navigating',
    () async {
      await service.init();
      final navigation = <String>[];
      final subscription = service.onNotificationPayload.listen(navigation.add);
      try {
        for (final action in [...expectedIds, 'skip_occurrence']) {
          final signalled = service.onNotificationAction.first;
          native.response!(_response(actionId: action));
          await signalled.timeout(const Duration(seconds: 3));
        }
        final pending = await queue.read();
        expect(pending.map((item) => item.actionId), [
          ...expectedIds,
          'skip_occurrence',
        ]);
        expect(pending.every((item) => item.occurredAt == _now), isTrue);
        expect(
          pending.every((item) => item.payload.encode() == _payload()),
          isTrue,
        );
        expect(navigation, isEmpty);
        expect(service.takePendingNotificationPayloads(), isEmpty);
        expect(native.schedules, isEmpty);
      } finally {
        await subscription.cancel();
      }
    },
  );

  test(
    'cold launch action remains in temp queue across service restart',
    () async {
      native.launch = NotificationAppLaunchDetails(
        true,
        notificationResponse: _response(actionId: 'snooze_60'),
      );
      final signalled = service.onNotificationAction.first;
      await service.init();
      await signalled.timeout(const Duration(seconds: 3));
      expect(service.takePendingNotificationPayloads(), isEmpty);
      final reopened = PendingNotificationActions.forDirectory(directory);
      expect((await reopened.read()).single.actionId, 'snooze_60');
      expect((await reopened.read()).single.occurredAt, _now);
    },
  );

  test(
    'repeated native action callback persists once while ordinary click still routes',
    () async {
      await service.init();
      final signalled = service.onNotificationAction.take(2).toList();
      native.response!(_response(actionId: 'complete'));
      native.response!(_response(actionId: 'complete'));
      await signalled.timeout(const Duration(seconds: 3));
      expect(await queue.read(), hasLength(1));
      native.response!(_response());
      expect(service.takePendingNotificationPayloads(), [_payload()]);
    },
  );

  test(
    'malformed payload and unsupported actions never enter queue or route',
    () async {
      await service.init();
      native.response!(_response(actionId: 'complete', payload: '{}'));
      native.response!(_response(actionId: 'delete'));
      native.response!(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(await queue.read(), isEmpty);
      expect(service.takePendingNotificationPayloads(), isEmpty);
    },
  );

  test(
    'custom macOS scheduler forwards the same category and payload',
    () async {
      await service.pauseForMaintenance();
      service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
        now: () => _now,
        readDatasetEpoch: () async => _epoch,
        macScheduler: const MacOSNotificationScheduler(),
        pendingActionStore: () async => queue,
      );
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(MacOSNotificationScheduler.channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      try {
        await service.setNotificationLanguage('zh');
        final task = _task(recurring: true);
        await service.scheduleReminderStrict(task);
        final arguments = calls.single.arguments as Map;
        expect(calls.single.method, 'schedule');
        expect(
          arguments['categoryIdentifier'],
          'dontforget_macos_recurring_zh',
        );
        expect(
          NotificationPayload.tryParse(
            arguments['payload'] as String,
          )!.matches(task, currentDatasetEpoch: _epoch),
          isTrue,
        );
        expect(
          arguments['triggerMilliseconds'],
          task.triggerTime!.millisecondsSinceEpoch,
        );
        expect(native.schedules, isEmpty);
      } finally {
        messenger.setMockMethodCallHandler(
          MacOSNotificationScheduler.channel,
          null,
        );
      }
    },
  );
}
