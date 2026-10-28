import 'package:flutter/services.dart';

/// Await the actual UNUserNotificationCenter completion, which the pinned
/// plugin's macOS zonedSchedule implementation does not observe. Cancellation,
/// permissions and click delivery still use that plugin and the same IDs.
class MacOSNotificationScheduler {
  const MacOSNotificationScheduler();
  static const channel = MethodChannel('dontforget/notification_schedule');

  /// The first native delegate observation, before Dart response processing.
  /// This is not an OS-provided physical click timestamp. The native cache is
  /// bounded and process-local, so old hosts or evicted responses return null.
  Future<DateTime?> takeResponseOccurredAt({
    required String payload,
    required String actionId,
  }) async {
    final micros = await channel.invokeMethod<int>('takeResponseOccurredAt', {
      'payload': payload,
      'actionId': actionId,
    });
    return micros == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
  }

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
