import 'package:flutter/services.dart';

/// Await the actual UNUserNotificationCenter completion, which the pinned
/// plugin's macOS zonedSchedule implementation does not observe. Cancellation,
/// permissions and click delivery still use that plugin and the same IDs.
class MacOSNotificationScheduler {
  const MacOSNotificationScheduler();
  static const channel = MethodChannel('dontforget/notification_schedule');

  Future<void> schedule({
    required int nativeId,
    required String title,
    required String body,
    required DateTime trigger,
    required bool playSound,
    required String payload,
    String? categoryIdentifier,
  }) => channel.invokeMethod<void>('schedule', {
    'id': nativeId,
    'title': title,
    'body': body,
    'triggerMilliseconds': trigger.toUtc().millisecondsSinceEpoch,
    'playSound': playSound,
    'payload': payload,
    if (categoryIdentifier != null) 'categoryIdentifier': categoryIdentifier,
  });
}
