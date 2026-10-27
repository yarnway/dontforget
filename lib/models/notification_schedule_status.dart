import 'reminder.dart';
import '../services/notification_journal.dart';
import '../services/notification_window.dart';

/// Local bookkeeping, never an operating-system delivery receipt.
class NotificationScheduleStatus {
  const NotificationScheduleStatus({
    this.policyPaused = 0,
    this.deferred = 0,
    this.scheduledThrough,
    this.capacity,
    required this.upcoming,
    required this.submitted,
    required this.needsAttention,
    required this.cancellations,
    required this.overdueUnconfirmed,
  });

  final int policyPaused, deferred;
  final DateTime? scheduledThrough;
  final int? capacity;
  final int upcoming;
  final int submitted;
  final int needsAttention;
  final int cancellations;
  final int overdueUnconfirmed;

  factory NotificationScheduleStatus.fromSaved(
    Iterable<Reminder> reminders,
    Map<String, NotificationJournalEntry> entries,
    DateTime now, {
    bool Function(Reminder)? isSuppressed,
    int? nativePendingLimit,
    String? planId,
  }) {
    final all = reminders.toList();
    final selected = NotificationWindow.select(
      all,
      now,
      limit: nativePendingLimit,
      isSuppressed: isSuppressed,
    );
    final selectedIds = selected.map((r) => r.id).toSet();
    final relevant = all
        .where(
          (r) => planId == null || r.id == planId || r.details.planId == planId,
        )
        .toList();
    DateTime? through;
    final eligible = NotificationWindow.select(
      all,
      now,
      isSuppressed: isSuppressed,
    );
    for (var i = 0; i < eligible.length;) {
      final time = eligible[i].triggerTime!;
      var complete = true, relevantTime = false;
      while (i < eligible.length &&
          eligible[i].triggerTime!.isAtSameMomentAs(time)) {
        final row = eligible[i++];
        final entry = entries[row.id];
        complete =
            complete &&
            selectedIds.contains(row.id) &&
            entry?.action == 'schedule' &&
            entry?.status == 'submitted' &&
            entry?.noticeRevision == row.noticeRevision &&
            entry?.triggerUtcMicros ==
                row.triggerTime!.toUtc().microsecondsSinceEpoch;
        relevantTime =
            relevantTime ||
            planId == null ||
            row.id == planId ||
            row.details.planId == planId;
      }
      if (!complete) break;
      if (relevantTime) through = time;
    }
    var deferred = 0;
    var policyPaused = 0;
    var upcoming = 0;
    var submitted = 0;
    var needsAttention = 0;
    var cancellations = 0;
    var overdueUnconfirmed = 0;
    final activeIds = <String>{};
    for (final reminder in relevant) {
      if (!reminder.canNotify ||
          reminder.noticeAcknowledgedAt != null ||
          reminder.triggerTime == null) {
        continue;
      }
      activeIds.add(reminder.id);
      final entry = entries[reminder.id];
      if (!reminder.triggerTime!.isAfter(now)) {
        final staleSchedule =
            entry?.action == 'schedule' &&
            (entry?.noticeRevision != reminder.noticeRevision ||
                entry?.triggerUtcMicros !=
                    reminder.triggerTime!.toUtc().microsecondsSinceEpoch);
        if (staleSchedule ||
            (entry?.action == 'cancel' && (entry?.unfinished ?? false))) {
          cancellations++;
        } else if (entry?.unfinished ?? false) {
          overdueUnconfirmed++;
        }
        continue;
      }
      upcoming++;
      if (isSuppressed?.call(reminder) == true) {
        if (entry?.action == 'cancel' && entry?.status == 'submitted') {
          policyPaused++;
        } else {
          needsAttention++;
        }
      } else if (!selectedIds.contains(reminder.id)) {
        deferred++;
        if (entry?.needsCancellation == true) cancellations++;
      } else if (entry?.action == 'schedule' &&
          entry?.status == 'submitted' &&
          entry?.noticeRevision == reminder.noticeRevision &&
          entry?.triggerUtcMicros ==
              reminder.triggerTime!.toUtc().microsecondsSinceEpoch) {
        submitted++;
      } else {
        needsAttention++;
      }
    }
    final relevantIds = relevant.map((r) => r.id).toSet();
    for (final entry in entries.values.where(
      (e) => planId == null || relevantIds.contains(e.reminderId),
    )) {
      if (!activeIds.contains(entry.reminderId) && entry.needsCancellation) {
        cancellations++;
      }
    }
    return NotificationScheduleStatus(
      policyPaused: policyPaused,
      deferred: deferred,
      scheduledThrough: through,
      capacity: nativePendingLimit,
      upcoming: upcoming,
      submitted: submitted,
      needsAttention: needsAttention,
      cancellations: cancellations,
      overdueUnconfirmed: overdueUnconfirmed,
    );
  }
}
