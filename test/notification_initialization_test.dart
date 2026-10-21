import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_service.dart';

class _NativeNotifications implements FlutterLocalNotificationsPlugin {
  final List<String> calls = [];
  Future<void> Function()? onInitialize;
  Future<void> Function()? onCancel;

  Future<bool> _initialize() async {
    calls.add('initialize');
    await onInitialize?.call();
    calls.add('ready');
    return true;
  }

  Future<void> _cancel() async {
    calls.add('cancel');
    await onCancel?.call();
    calls.add('cancelled');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #initialize:
        return _initialize();
      case #cancel:
        return _cancel();
      case #getNotificationAppLaunchDetails:
        return Future<NotificationAppLaunchDetails?>.value();
      case #zonedSchedule:
        calls.add('schedule');
        return Future<void>.value();
      default:
        throw UnsupportedError('${invocation.memberName}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeNotifications native;
  late NotificationService service;
  final reminders = <Reminder>[];

  Reminder reminder(String id, {bool completed = false}) {
    final task = Reminder(
      id: id,
      taskTitle: 'Notification protocol test',
      quadrantLevel: 2,
      triggerTime: DateTime.now().add(const Duration(days: 1)),
      isCompleted: completed,
    );
    reminders.add(task);
    return task;
  }

  setUp(() {
    reminders.clear();
    native = _NativeNotifications();
    service = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
    );
  });

  tearDown(() async {
    native.onCancel = null;
    for (final task in reminders) {
      await service.cancelReminder(task.id);
    }
  });

  test('first schedules await one shared native initialization', () async {
    final initialized = Completer<void>();
    native.onInitialize = () => initialized.future;
    final first = service.scheduleReminder(reminder('first'));
    final second = service.scheduleReminder(reminder('second'));
    await Future<void>.delayed(Duration.zero);
    expect(native.calls.where((call) => call == 'initialize'), hasLength(1));
    expect(native.calls, isNot(contains('schedule')));
    initialized.complete();
    await Future.wait([first, second]);
    expect(native.calls.where((call) => call == 'schedule'), hasLength(2));
    expect(
      native.calls.indexOf('ready'),
      lessThan(native.calls.indexOf('schedule')),
    );
  });

  test('replacement waits until native cancellation has completed', () async {
    final cancelled = Completer<void>();
    native.onCancel = () => cancelled.future;
    final scheduled = service.scheduleReminder(reminder('replacement'));
    await Future<void>.delayed(Duration.zero);
    expect(native.calls, ['cancel']);
    cancelled.complete();
    await scheduled;
    expect(native.calls, [
      'cancel',
      'cancelled',
      'initialize',
      'ready',
      'schedule',
    ]);
  });

  test(
    'completed reminders are cancelled without requesting permission',
    () async {
      await service.scheduleReminder(reminder('completed', completed: true));
      expect(native.calls, ['cancel', 'cancelled']);
    },
  );
}
