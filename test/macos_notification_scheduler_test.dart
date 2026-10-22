import 'dart:async';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/macos_notification_scheduler.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Plugin implements FlutterLocalNotificationsPlugin {
  @override
  dynamic noSuchMethod(Invocation call) => switch (call.memberName) {
    #initialize => Future<bool>.value(true),
    #getNotificationAppLaunchDetails => Future.value(
      const NotificationAppLaunchDetails(false),
    ),
    #cancelAll || #cancel => Future<void>.value(),
    _ => throw StateError('Unexpected fallback to ${call.memberName}'),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'OS completion controls durable status and failure survives reopening',
    () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('mac-schedule-test-');
      var db = DatabaseHelper.forTesting(dir.path, databaseFactoryFfi);
      var service = NotificationService.forTesting(
        _Plugin(),
        usesNativeNotifications: true,
        database: db,
        macScheduler: const MacOSNotificationScheduler(),
      );
      final called = Completer<MethodCall>();
      final completion = Completer<void>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(MacOSNotificationScheduler.channel, (
        call,
      ) async {
        called.complete(call);
        await completion.future;
        return null;
      });
      final reminder = Reminder(
        id: 'os-failure',
        taskTitle: 'Synthetic OS failure',
        quadrantLevel: 1,
        triggerTime: DateTime.now().add(const Duration(days: 1)),
      );
      try {
        final first = service.scheduleReminderStrict(reminder);
        final failed = expectLater(first, throwsA(isA<PlatformException>()));
        final call = await called.future;
        expect(call.method, 'schedule');
        final args = call.arguments as Map;
        expect(args['title'], reminder.taskTitle);
        expect(
          args['triggerMilliseconds'],
          reminder.triggerTime!.toUtc().millisecondsSinceEpoch,
        );
        expect(args['playSound'], isTrue);
        expect(
          NotificationPayload.tryParse(args['payload'] as String),
          isNotNull,
        );
        final pending = (await db.withNotificationJournal(
          (j) => j.read(),
        ))!.entries[reminder.id]!;
        expect(pending.status, 'pending');
        expect(args['id'], pending.nativeId);
        completion.completeError(
          PlatformException(
            code: 'native_schedule_failed',
            details: {'domain': 'UNErrorDomain', 'code': 1},
          ),
        );
        await failed;
        expect(
          (await db.withNotificationJournal(
            (j) => j.read(),
          ))!.entries[reminder.id]!.status,
          'failed',
        );
        await service.pauseForMaintenance();
        await db.close(createBackup: false);
        db = DatabaseHelper.forTesting(dir.path, databaseFactoryFfi);
        expect(
          (await db.withNotificationJournal(
            (j) => j.read(),
          ))!.entries[reminder.id]!.status,
          'failed',
        );
        service = NotificationService.forTesting(
          _Plugin(),
          usesNativeNotifications: true,
          database: db,
          macScheduler: const MacOSNotificationScheduler(),
        );
        messenger.setMockMethodCallHandler(MacOSNotificationScheduler.channel, (
          call,
        ) async {
          expect((call.arguments as Map)['id'], pending.nativeId);
          return null;
        });
        await service.scheduleReminderStrict(reminder);
        final saved = (await db.withNotificationJournal(
          (j) => j.read(),
        ))!.entries[reminder.id]!;
        expect(saved.status, 'submitted');
        expect(saved.nativeId, pending.nativeId);
        expect(saved.attempts, greaterThan(pending.attempts));
      } finally {
        messenger.setMockMethodCallHandler(
          MacOSNotificationScheduler.channel,
          null,
        );
        await service.pauseForMaintenance();
        await db.close(createBackup: false);
        await dir.delete(recursive: true);
      }
    },
  );
}
