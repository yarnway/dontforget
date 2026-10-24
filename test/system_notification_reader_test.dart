import 'dart:async';

import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/system_notification_reader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

class _Plugin implements FlutterLocalNotificationsPlugin {
  final calls = <Symbol>[];
  Future<List<PendingNotificationRequest>> pending = Future.value([]);
  Future<List<ActiveNotification>> retained = Future.value([]);

  @override
  dynamic noSuchMethod(Invocation call) {
    calls.add(call.memberName);
    return switch (call.memberName) {
      #pendingNotificationRequests => pending,
      #getActiveNotifications => retained,
      _ => throw StateError(
        'Readback must not mutate or initialize notifications',
      ),
    };
  }
}

void main() {
  test(
    'service reads actual OS lists without init, journal or permission work',
    () async {
      final plugin = _Plugin()
        ..pending = Future.value([
          const PendingNotificationRequest(10, 'Future', 'body', 'payload'),
        ])
        ..retained = Future.value([
          const ActiveNotification(
            id: 11,
            title: 'Delivered',
            body: 'body',
            payload: 'payload',
          ),
        ]);
      final service = NotificationService.forTesting(
        plugin,
        usesNativeNotifications: true,
        readDatasetEpoch: () =>
            throw StateError('Readback must not access the database'),
      );
      final snapshot = await service.readSystemNotifications();
      expect(plugin.calls, [
        #pendingNotificationRequests,
        #getActiveNotifications,
      ]);
      expect(snapshot.pending!.single.id, 10);
      expect(snapshot.retained!.single.title, 'Delivered');
      expect(() => snapshot.retained!.clear(), throwsUnsupportedError);
    },
  );

  test(
    'one failed OS query does not hide the other successful observation',
    () async {
      final plugin = _Plugin()
        ..pending = Future.error(PlatformException(code: 'unavailable'))
        ..retained = Future.value([
          const ActiveNotification(id: 11, title: 'Delivered'),
        ]);
      final snapshot = await SystemNotificationReader(
        plugin,
        supported: true,
      ).read();
      expect(snapshot.pending, isNull);
      expect(snapshot.retained, hasLength(1));
    },
  );

  test('bounded query timeout remains unknown rather than zero', () async {
    final pending = Completer<List<PendingNotificationRequest>>();
    final plugin = _Plugin()..pending = pending.future;
    final snapshot = await SystemNotificationReader(
      plugin,
      supported: true,
      timeout: const Duration(milliseconds: 10),
    ).read();
    expect(snapshot.pending, isNull);
    expect(snapshot.retained, isEmpty);
    pending.complete([
      const PendingNotificationRequest(10, 'Late', null, null),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(snapshot.pending, isNull);
  });

  test('unsupported platforms never invoke the native plugin', () async {
    final plugin = _Plugin();
    final snapshot = await SystemNotificationReader(
      plugin,
      supported: false,
    ).read();
    expect(snapshot.supported, isFalse);
    expect(snapshot.pending, isNull);
    expect(snapshot.retained, isNull);
    expect(plugin.calls, isEmpty);
  });
}
