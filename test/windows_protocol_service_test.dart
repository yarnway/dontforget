import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/windows_protocol_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProtocolRoute.tryParse', () {
    test('returns null for null, empty or whitespace strings', () {
      expect(ProtocolRoute.tryParse(null), isNull);
      expect(ProtocolRoute.tryParse(''), isNull);
      expect(ProtocolRoute.tryParse('   '), isNull);
    });

    test('returns null for non-dontforget scheme', () {
      expect(ProtocolRoute.tryParse('https://example.com/task/1'), isNull);
      expect(ProtocolRoute.tryParse('mailto:user@example.com'), isNull);
      expect(ProtocolRoute.tryParse('app://open'), isNull);
    });

    test('parses standard view route: dontforget://task/<id>', () {
      final route = ProtocolRoute.tryParse('dontforget://task/rem-12345');
      expect(route, isNotNull);
      expect(route!.action, ProtocolAction.viewTask);
      expect(route.taskId, 'rem-12345');
      expect(route.snoozeMinutes, isNull);
    });

    test('parses complete action route: dontforget://action/complete?id=<id>', () {
      final route = ProtocolRoute.tryParse('dontforget://action/complete?id=task-abc');
      expect(route, isNotNull);
      expect(route!.action, ProtocolAction.completeTask);
      expect(route.taskId, 'task-abc');
      expect(route.snoozeMinutes, isNull);
    });

    test('parses snooze action route with custom minutes', () {
      final route = ProtocolRoute.tryParse('dontforget://action/snooze?id=task-abc&minutes=30');
      expect(route, isNotNull);
      expect(route!.action, ProtocolAction.snoozeTask);
      expect(route.taskId, 'task-abc');
      expect(route.snoozeMinutes, 30);
    });

    test('snooze action route defaults to 15 minutes when missing or invalid', () {
      final route1 = ProtocolRoute.tryParse('dontforget://action/snooze?id=task-1');
      expect(route1, isNotNull);
      expect(route1!.snoozeMinutes, 15);

      final route2 = ProtocolRoute.tryParse('dontforget://action/snooze?id=task-2&minutes=invalid');
      expect(route2, isNotNull);
      expect(route2!.snoozeMinutes, 15);

      final route3 = ProtocolRoute.tryParse('dontforget://action/snooze?id=task-3&minutes=-10');
      expect(route3, isNotNull);
      expect(route3!.snoozeMinutes, 15);
    });

    test('action routes require non-empty id parameter', () {
      expect(ProtocolRoute.tryParse('dontforget://action/complete'), isNull);
      expect(ProtocolRoute.tryParse('dontforget://action/complete?id='), isNull);
      expect(ProtocolRoute.tryParse('dontforget://action/complete?id=   '), isNull);
      expect(ProtocolRoute.tryParse('dontforget://action/snooze'), isNull);
    });

    test('parses fallback direct task id route: dontforget://<id>', () {
      final route = ProtocolRoute.tryParse('dontforget://direct-reminder-id');
      expect(route, isNotNull);
      expect(route!.action, ProtocolAction.viewTask);
      expect(route.taskId, 'direct-reminder-id');
    });

    test('extracts URI from quoted Windows command line arguments', () {
      const cmd = r'"C:\Users\User\AppData\Local\DontForget\dont_forget.exe" "dontforget://task/rem-999"';
      final route = ProtocolRoute.tryParse(cmd);
      expect(route, isNotNull);
      expect(route!.action, ProtocolAction.viewTask);
      expect(route.taskId, 'rem-999');
    });

    test('equality and hashCode match for identical routes', () {
      const r1 = ProtocolRoute(
        action: ProtocolAction.snoozeTask,
        taskId: 't1',
        snoozeMinutes: 15,
      );
      const r2 = ProtocolRoute(
        action: ProtocolAction.snoozeTask,
        taskId: 't1',
        snoozeMinutes: 15,
      );
      const r3 = ProtocolRoute(
        action: ProtocolAction.snoozeTask,
        taskId: 't1',
        snoozeMinutes: 30,
      );

      expect(r1, equals(r2));
      expect(r1.hashCode, equals(r2.hashCode));
      expect(r1, isNot(equals(r3)));
    });
  });

  group('WindowsProtocolService.extractRouteFromArgs', () {
    test('returns null when no arguments contain dontforget://', () {
      expect(WindowsProtocolService.extractRouteFromArgs([]), isNull);
      expect(WindowsProtocolService.extractRouteFromArgs(['--flag', 'path/to/file']), isNull);
    });

    test('extracts route when argument contains dontforget://', () {
      final route = WindowsProtocolService.extractRouteFromArgs([
        '--flag',
        'dontforget://task/rem-777',
      ]);
      expect(route, isNotNull);
      expect(route!.taskId, 'rem-777');
    });
  });

  group('WindowsProtocolService method channel integration', () {
    tearDown(() {
      WindowsProtocolService.dispose();
    });

    test('dispatches onRoute when onProtocolUrl method is invoked', () async {
      ProtocolRoute? received;
      WindowsProtocolService.initialize(
        onRoute: (route) {
          received = route;
        },
      );

      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const codec = StandardMethodCodec();

      final callData = codec.encodeMethodCall(
        const MethodCall('onProtocolUrl', 'dontforget://task/rem-888'),
      );

      await messenger.handlePlatformMessage(
        'com.yarnway.dontforget/protocol',
        callData,
        (_) {},
      );

      expect(received, isNotNull);
      expect(received!.action, ProtocolAction.viewTask);
      expect(received!.taskId, 'rem-888');
    });

    test('ignores onProtocolUrl when input is not a valid route', () async {
      ProtocolRoute? received;
      WindowsProtocolService.initialize(
        onRoute: (route) {
          received = route;
        },
      );

      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const codec = StandardMethodCodec();

      final callData = codec.encodeMethodCall(
        const MethodCall('onProtocolUrl', 'https://other-domain.com'),
      );

      await messenger.handlePlatformMessage(
        'com.yarnway.dontforget/protocol',
        callData,
        (_) {},
      );

      expect(received, isNull);
    });
  });

  group('NotificationService fireReminderNow Windows protocol wiring', () {
    test('passes protocol URIs and action buttons to windowsToastHandler', () async {
      final service = NotificationService();
      String? capturedLaunchUri;
      String? capturedCompleteTitle;
      String? capturedCompleteUri;
      String? capturedSnoozeTitle;
      String? capturedSnoozeUri;

      service.windowsToastHandler = (
        title,
        body, {
        bool playSound = true,
        String? launchUri,
        String? completeActionTitle,
        String? completeActionUri,
        String? snoozeActionTitle,
        String? snoozeActionUri,
      }) async {
        capturedLaunchUri = launchUri;
        capturedCompleteTitle = completeActionTitle;
        capturedCompleteUri = completeActionUri;
        capturedSnoozeTitle = snoozeActionTitle;
        capturedSnoozeUri = snoozeActionUri;
      };

      final reminder = Reminder(
        id: 'toast-task-123',
        taskTitle: '紧急事项',
        taskSummary: '请立即处理',
        quadrantLevel: 1,
        triggerTime: DateTime.now(),
      );

      await service.fireReminderNow(reminder);

      expect(capturedLaunchUri, 'dontforget://task/toast-task-123');
      expect(capturedCompleteTitle, '完成');
      expect(capturedCompleteUri, 'dontforget://action/complete?id=toast-task-123');
      expect(capturedSnoozeTitle, '延后 15 分钟');
      expect(capturedSnoozeUri, 'dontforget://action/snooze?id=toast-task-123&minutes=15');

      final launchRoute = ProtocolRoute.tryParse(capturedLaunchUri);
      expect(launchRoute?.action, ProtocolAction.viewTask);
      expect(launchRoute?.taskId, 'toast-task-123');

      final completeRoute = ProtocolRoute.tryParse(capturedCompleteUri);
      expect(completeRoute?.action, ProtocolAction.completeTask);
      expect(completeRoute?.taskId, 'toast-task-123');

      final snoozeRoute = ProtocolRoute.tryParse(capturedSnoozeUri);
      expect(snoozeRoute?.action, ProtocolAction.snoozeTask);
      expect(snoozeRoute?.taskId, 'toast-task-123');
      expect(snoozeRoute?.snoozeMinutes, 15);
    });
  });
}
