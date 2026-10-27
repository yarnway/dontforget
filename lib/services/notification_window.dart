import 'package:flutter/foundation.dart';
import '../models/reminder.dart';

/// An application budget, not a claim about OS delivery. Keep headroom below
/// documented iOS and common Android vendor limits; macOS uses the same
/// conservative Darwin budget. All other occurrences stay in business storage.
abstract final class NotificationWindow {
  static int? get platformLimit => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => 50,
    TargetPlatform.android => 400,
    _ => null,
  };

  static List<Reminder> select(
    Iterable<Reminder> tasks,
    DateTime now, {
    int? limit,
    bool Function(Reminder)? isSuppressed,
  }) {
    if (limit != null && limit < 1) throw ArgumentError.value(limit, 'limit');
    final sorted =
        tasks
            .where(
              (task) =>
                  task.canNotify &&
                  task.noticeAcknowledgedAt == null &&
                  task.triggerTime!.isAfter(now) &&
                  isSuppressed?.call(task) != true,
            )
            .toList()
          ..sort((a, b) {
            final time = a.triggerTime!.compareTo(b.triggerTime!);
            return time == 0 ? a.id.compareTo(b.id) : time;
          });
    return limit == null ? sorted : sorted.take(limit).toList();
  }
}
