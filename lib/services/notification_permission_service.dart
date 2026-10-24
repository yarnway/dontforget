import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// The installed plugin cannot distinguish an unasked Darwin permission from a
/// denied one. Both are deliberately reported as [notEnabled].
enum NotificationPermissionStatus {
  granted,
  provisional,
  notEnabled,
  unknown,
  unsupported,
}

class NotificationAuthorization {
  const NotificationAuthorization(
    this.status, {
    this.alertsEnabled,
    this.soundsEnabled,
  });

  final NotificationPermissionStatus status;
  final bool? alertsEnabled;
  final bool? soundsEnabled;
}

class NotificationPermissionSnapshot {
  const NotificationPermissionSnapshot({
    required this.authorization,
    required this.exactAlarms,
    required this.platform,
    this.requestFailed = false,
  });

  final NotificationAuthorization authorization;
  final NotificationPermissionStatus exactAlarms;
  final TargetPlatform? platform;
  final bool requestFailed;

  bool get canRequestNotifications =>
      platform == TargetPlatform.android ||
      platform == TargetPlatform.iOS ||
      platform == TargetPlatform.macOS;
  bool get supportsExactAlarms => platform == TargetPlatform.android;
}

/// The platform boundary is injectable; neither construction nor reads request
/// permission. A null platform represents an unsupported web target.
abstract interface class NotificationPermissionBackend {
  TargetPlatform? get platform;
  Future<NotificationAuthorization> readAuthorization();
  Future<NotificationPermissionStatus> readExactAlarms();
  Future<void> requestNotifications();
  Future<void> requestExactAlarms();
}

class PluginNotificationPermissionBackend
    implements NotificationPermissionBackend {
  PluginNotificationPermissionBackend({
    FlutterLocalNotificationsPlugin? plugin,
    TargetPlatform? platform,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       platform = kIsWeb ? null : platform ?? defaultTargetPlatform;

  final FlutterLocalNotificationsPlugin _plugin;
  @override
  final TargetPlatform? platform;

  NotificationPermissionStatus _enabled(bool? value) => switch (value) {
    true => NotificationPermissionStatus.granted,
    false => NotificationPermissionStatus.notEnabled,
    null => NotificationPermissionStatus.unknown,
  };

  @override
  Future<NotificationAuthorization> readAuthorization() async {
    if (platform == TargetPlatform.android) {
      final enabled = await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.areNotificationsEnabled();
      return NotificationAuthorization(_enabled(enabled));
    }
    final NotificationsEnabledOptions? options;
    if (platform == TargetPlatform.iOS) {
      options = await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.checkPermissions();
    } else if (platform == TargetPlatform.macOS) {
      options = await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.checkPermissions();
    } else {
      return const NotificationAuthorization(
        NotificationPermissionStatus.unsupported,
      );
    }
    if (options == null) {
      return const NotificationAuthorization(
        NotificationPermissionStatus.unknown,
      );
    }
    return NotificationAuthorization(
      options.isProvisionalEnabled
          ? NotificationPermissionStatus.provisional
          : _enabled(options.isEnabled),
      alertsEnabled: options.isAlertEnabled,
      soundsEnabled: options.isSoundEnabled,
    );
  }

  @override
  Future<NotificationPermissionStatus> readExactAlarms() async {
    if (platform != TargetPlatform.android) {
      return NotificationPermissionStatus.unsupported;
    }
    return _enabled(
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.canScheduleExactNotifications(),
    );
  }

  @override
  Future<void> requestNotifications() async {
    switch (platform) {
      case TargetPlatform.android:
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        if (android == null) {
          throw StateError('Notification plugin unavailable');
        }
        await android.requestNotificationsPermission();
      case TargetPlatform.iOS:
        final ios = _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        if (ios == null) throw StateError('Notification plugin unavailable');
        await ios.requestPermissions(alert: true, badge: true, sound: true);
      case TargetPlatform.macOS:
        final mac = _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >();
        if (mac == null) throw StateError('Notification plugin unavailable');
        await mac.requestPermissions(alert: true, badge: true, sound: true);
      default:
        return;
    }
  }

  @override
  Future<void> requestExactAlarms() async {
    if (platform != TargetPlatform.android) return;
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) throw StateError('Notification plugin unavailable');
    await android.requestExactAlarmsPermission();
  }
}

/// Queries are best effort and independent: a failure reading exact alarm
/// access must not hide the observed notification authorization, or vice versa.
class NotificationPermissionService {
  NotificationPermissionService({
    NotificationPermissionBackend? backend,
    this.readTimeout = const Duration(seconds: 3),
  }) : _backend = backend ?? PluginNotificationPermissionBackend();

  final NotificationPermissionBackend _backend;
  final Duration readTimeout;

  Future<T> _read<T>(Future<T> Function() query, T unavailable) async {
    try {
      return await query().timeout(readTimeout);
    } catch (_) {
      return unavailable;
    }
  }

  Future<NotificationPermissionSnapshot> refresh() async {
    // Start independent reads together; a stalled platform query must neither
    // hide the other answer nor leave the settings panel permanently busy.
    final authorization = _read(
      _backend.readAuthorization,
      const NotificationAuthorization(NotificationPermissionStatus.unknown),
    );
    final exactAlarms = _read(
      _backend.readExactAlarms,
      NotificationPermissionStatus.unknown,
    );
    return NotificationPermissionSnapshot(
      authorization: await authorization,
      exactAlarms: await exactAlarms,
      platform: _backend.platform,
    );
  }

  /// Call only from an explicit user action. The native request return value is
  /// not evidence of the current authorization; always query again afterwards.
  Future<NotificationPermissionSnapshot> requestNotifications() =>
      _request(_backend.requestNotifications);

  Future<NotificationPermissionSnapshot> requestExactAlarms() =>
      _request(_backend.requestExactAlarms);

  Future<NotificationPermissionSnapshot> _request(
    Future<void> Function() request,
  ) async {
    var failed = false;
    try {
      // A system permission dialog waits for the person; only the subsequent
      // readback is bounded, never the user's time to answer the prompt.
      await request();
    } catch (_) {
      failed = true;
    }
    final observed = await refresh();
    return NotificationPermissionSnapshot(
      authorization: observed.authorization,
      exactAlarms: observed.exactAlarms,
      platform: observed.platform,
      requestFailed: failed,
    );
  }
}
