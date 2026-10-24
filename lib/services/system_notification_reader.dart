import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class SystemNotificationEntry {
  const SystemNotificationEntry({required this.id, this.title});
  final int? id;
  final String? title;
}

/// OS observations are independent of the application's submission journal.
/// Null means unavailable, while an empty list is a successful zero readback.
class SystemNotificationSnapshot {
  SystemNotificationSnapshot({
    required this.supported,
    List<SystemNotificationEntry>? pending,
    List<SystemNotificationEntry>? retained,
  }) : pending = pending == null ? null : List.unmodifiable(pending),
       retained = retained == null ? null : List.unmodifiable(retained);

  final bool supported;
  final List<SystemNotificationEntry>? pending;
  final List<SystemNotificationEntry>? retained;
}

class SystemNotificationReader {
  const SystemNotificationReader(
    this.plugin, {
    required this.supported,
    this.timeout = const Duration(seconds: 3),
  });

  final FlutterLocalNotificationsPlugin plugin;
  final bool supported;
  final Duration timeout;

  Future<List<SystemNotificationEntry>?> _query(
    Future<List<SystemNotificationEntry>> Function() operation,
  ) async {
    try {
      return await operation().timeout(timeout);
    } catch (_) {
      // Never turn an unavailable platform response into a misleading zero.
      return null;
    }
  }

  Future<SystemNotificationSnapshot> read() async {
    if (!supported) return SystemNotificationSnapshot(supported: false);
    final values = await Future.wait([
      _query(
        () async => [
          for (final entry in await plugin.pendingNotificationRequests())
            SystemNotificationEntry(id: entry.id, title: entry.title),
        ],
      ),
      _query(
        () async => [
          for (final entry in await plugin.getActiveNotifications())
            SystemNotificationEntry(id: entry.id, title: entry.title),
        ],
      ),
    ]);
    return SystemNotificationSnapshot(
      supported: true,
      pending: values[0],
      retained: values[1],
    );
  }
}
