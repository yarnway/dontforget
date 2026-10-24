import 'dart:async';

import 'package:dont_forget/services/notification_permission_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

class _Plugin implements FlutterLocalNotificationsPlugin {
  _Plugin(this.implementation);
  final Object? implementation;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #resolvePlatformSpecificImplementation) {
      return implementation;
    }
    throw UnsupportedError('${invocation.memberName}');
  }
}

class _Darwin extends MacOSFlutterLocalNotificationsPlugin {
  NotificationsEnabledOptions? options;
  Object? readError;
  Object? requestError;
  int requests = 0;
  List<bool>? requestArguments;
  Future<void> Function()? onRequest;

  @override
  Future<NotificationsEnabledOptions?> checkPermissions() async {
    if (readError != null) throw readError!;
    return options;
  }

  @override
  Future<bool?> requestPermissions({
    bool sound = false,
    bool alert = false,
    bool badge = false,
    bool provisional = false,
    bool critical = false,
  }) async {
    requests++;
    requestArguments = [sound, alert, badge, provisional, critical];
    if (requestError != null) throw requestError!;
    await onRequest?.call();
    // The service must query current state, not trust this optimistic result.
    return true;
  }
}

class _Android extends AndroidFlutterLocalNotificationsPlugin {
  bool? notifications;
  bool? exact;
  bool failExact = false;
  bool failNotification = false;
  int notificationRequests = 0;
  int exactRequests = 0;
  int notificationReads = 0;
  int exactReads = 0;
  Completer<bool?>? notificationGate;
  Completer<bool?>? exactGate;

  @override
  Future<bool?> areNotificationsEnabled() async {
    notificationReads++;
    if (failNotification) throw StateError('query unavailable');
    if (notificationGate != null) return notificationGate!.future;
    return notifications;
  }

  @override
  Future<bool?> canScheduleExactNotifications() async {
    exactReads++;
    if (failExact) throw StateError('query unavailable');
    if (exactGate != null) return exactGate!.future;
    return exact;
  }

  @override
  Future<bool?> requestNotificationsPermission() async {
    notificationRequests++;
    notifications = true;
    return true;
  }

  @override
  Future<bool?> requestExactAlarmsPermission() async {
    exactRequests++;
    exact = true;
    return true;
  }
}

NotificationsEnabledOptions _options({
  bool enabled = false,
  bool provisional = false,
  bool alerts = false,
  bool sounds = false,
}) => NotificationsEnabledOptions(
  isEnabled: enabled,
  isSoundEnabled: sounds,
  isAlertEnabled: alerts,
  isBadgeEnabled: false,
  isProvisionalEnabled: provisional,
  isCriticalEnabled: false,
);

NotificationPermissionService _service(TargetPlatform target, Object? native) =>
    NotificationPermissionService(
      backend: PluginNotificationPermissionBackend(
        platform: target,
        plugin: _Plugin(native),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('stalled reads start together and time out independently', (
    tester,
  ) async {
    final notification = Completer<bool?>();
    final exact = Completer<bool?>();
    final native = _Android()
      ..notificationGate = notification
      ..exactGate = exact;
    final service = _service(TargetPlatform.android, native);
    final pending = service.refresh();
    await tester.pump();
    expect(native.notificationReads, 1);
    expect(native.exactReads, 1);
    exact.complete(true);
    await tester.pump(const Duration(seconds: 3));
    final first = await pending;
    expect(first.authorization.status, NotificationPermissionStatus.unknown);
    expect(first.exactAlarms, NotificationPermissionStatus.granted);
    notification.complete(false);
    native
      ..notificationGate = null
      ..exactGate = null
      ..notifications = true
      ..exact = false;
    final recovered = await service.refresh();
    expect(
      recovered.authorization.status,
      NotificationPermissionStatus.granted,
    );
    expect(recovered.exactAlarms, NotificationPermissionStatus.notEnabled);
    expect(native.notificationRequests, 0);
    expect(native.exactRequests, 0);
  });

  testWidgets('both unavailable queries finish within one read timeout', (
    tester,
  ) async {
    final native = _Android()
      ..notificationGate = Completer<bool?>()
      ..exactGate = Completer<bool?>();
    final pending = _service(TargetPlatform.android, native).refresh();
    await tester.pump(const Duration(seconds: 3));
    final state = await pending;
    expect(state.authorization.status, NotificationPermissionStatus.unknown);
    expect(state.exactAlarms, NotificationPermissionStatus.unknown);
    native.notificationGate!.complete(true);
    native.exactGate!.complete(true);
  });

  testWidgets('a permission dialog does not inherit the read timeout', (
    tester,
  ) async {
    final answer = Completer<void>();
    final native = _Darwin()
      ..onRequest = (() => answer.future)
      ..options = _options(enabled: true);
    var completed = false;
    final pending = _service(TargetPlatform.macOS, native)
        .requestNotifications()
        .then((value) {
          completed = true;
          return value;
        });
    await tester.pump(const Duration(seconds: 10));
    expect(completed, isFalse);
    expect(native.requests, 1);
    answer.complete();
    await tester.pump();
    expect(
      (await pending).authorization.status,
      NotificationPermissionStatus.granted,
    );
  });

  test(
    'Darwin unasked or denied is notEnabled, never inferred denied',
    () async {
      final native = _Darwin()..options = _options();
      final state = await _service(TargetPlatform.macOS, native).refresh();
      expect(
        state.authorization.status,
        NotificationPermissionStatus.notEnabled,
      );
      expect(state.authorization.alertsEnabled, isFalse);
      expect(state.exactAlarms, NotificationPermissionStatus.unsupported);
      expect(native.requests, 0);
    },
  );

  test(
    'Darwin provisional remains provisional even when enabled is false',
    () async {
      final native = _Darwin()..options = _options(provisional: true);
      final state = await _service(TargetPlatform.macOS, native).refresh();
      expect(
        state.authorization.status,
        NotificationPermissionStatus.provisional,
      );
      expect(native.requests, 0);
    },
  );

  test(
    'Darwin granted preserves independently disabled presentation options',
    () async {
      final native = _Darwin()..options = _options(enabled: true, sounds: true);
      final state = await _service(TargetPlatform.macOS, native).refresh();
      expect(state.authorization.status, NotificationPermissionStatus.granted);
      expect(state.authorization.alertsEnabled, isFalse);
      expect(state.authorization.soundsEnabled, isTrue);
    },
  );

  test('missing platform implementation and null query are unknown', () async {
    for (final native in [null, _Darwin()]) {
      final state = await _service(TargetPlatform.macOS, native).refresh();
      expect(state.authorization.status, NotificationPermissionStatus.unknown);
    }
  });

  test('query errors are unknown and a fresh read can recover', () async {
    final native = _Darwin()..readError = StateError('unavailable');
    final service = _service(TargetPlatform.macOS, native);
    expect(
      (await service.refresh()).authorization.status,
      NotificationPermissionStatus.unknown,
    );
    native
      ..readError = null
      ..options = _options(enabled: true);
    expect(
      (await service.refresh()).authorization.status,
      NotificationPermissionStatus.granted,
    );
    expect(native.requests, 0);
  });

  test(
    'explicit request reads actual state rather than its returned bool',
    () async {
      final native = _Darwin()..options = _options();
      final state = await _service(
        TargetPlatform.macOS,
        native,
      ).requestNotifications();
      expect(native.requests, 1);
      expect(native.requestArguments, [true, true, true, false, false]);
      expect(
        state.authorization.status,
        NotificationPermissionStatus.notEnabled,
      );
      expect(state.requestFailed, isFalse);
    },
  );

  test(
    'request errors remain visible beside separately observed state',
    () async {
      final native = _Darwin()
        ..options = _options(enabled: true)
        ..requestError = StateError('request failed');
      final state = await _service(
        TargetPlatform.macOS,
        native,
      ).requestNotifications();
      expect(state.requestFailed, isTrue);
      expect(state.authorization.status, NotificationPermissionStatus.granted);
    },
  );

  test(
    'notification and exact alarm access are independent on Android',
    () async {
      final native = _Android()
        ..notifications = false
        ..exact = true;
      final state = await _service(TargetPlatform.android, native).refresh();
      expect(
        state.authorization.status,
        NotificationPermissionStatus.notEnabled,
      );
      expect(state.exactAlarms, NotificationPermissionStatus.granted);
      expect(native.notificationRequests, 0);
      expect(native.exactRequests, 0);
    },
  );

  test(
    'failed exact alarm query does not erase observed notification access',
    () async {
      final native = _Android()
        ..notifications = true
        ..failExact = true;
      final state = await _service(TargetPlatform.android, native).refresh();
      expect(state.authorization.status, NotificationPermissionStatus.granted);
      expect(state.exactAlarms, NotificationPermissionStatus.unknown);
    },
  );

  test(
    'failed notification query does not erase observed exact alarm access',
    () async {
      final native = _Android()
        ..failNotification = true
        ..exact = true;
      final state = await _service(TargetPlatform.android, native).refresh();
      expect(state.authorization.status, NotificationPermissionStatus.unknown);
      expect(state.exactAlarms, NotificationPermissionStatus.granted);
    },
  );

  test(
    'Android requests do not grant or request the other capability',
    () async {
      final native = _Android()
        ..notifications = false
        ..exact = false;
      final service = _service(TargetPlatform.android, native);
      final notification = await service.requestNotifications();
      expect(
        notification.authorization.status,
        NotificationPermissionStatus.granted,
      );
      expect(notification.exactAlarms, NotificationPermissionStatus.notEnabled);
      expect(native.exactRequests, 0);
      final exact = await service.requestExactAlarms();
      expect(exact.exactAlarms, NotificationPermissionStatus.granted);
      expect(native.notificationRequests, 1);
      expect(native.exactRequests, 1);
    },
  );

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    test('$platform never reports native notification authorization', () async {
      final state = await _service(platform, null).refresh();
      expect(
        state.authorization.status,
        NotificationPermissionStatus.unsupported,
      );
      expect(state.exactAlarms, NotificationPermissionStatus.unsupported);
      expect(state.canRequestNotifications, isFalse);
    });
  }
}
