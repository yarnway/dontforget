import 'reminder.dart';
import '../services/notification_journal.dart';

/// Local bookkeeping, never an operating-system delivery receipt.
class NotificationScheduleStatus {
  const NotificationScheduleStatus({
    this.policyPaused = 0,
    required this.upcoming,
    required this.submitted,
    required this.needsAttention,
    required this.cancellations,
    required this.overdueUnconfirmed,
  });

  final int policyPaused;
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
  }) {
    var policyPaused = 0;
    var upcoming = 0;
    var submitted = 0;
    var needsAttention = 0;
    var cancellations = 0;
    var overdueUnconfirmed = 0;
    final activeIds = <String>{};
    for (final reminder in reminders) {
      if (reminder.isCompleted ||
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
    for (final entry in entries.values) {
      if (!activeIds.contains(entry.reminderId) && entry.needsCancellation) {
        cancellations++;
      }
    }
    return NotificationScheduleStatus(
      policyPaused: policyPaused,
      upcoming: upcoming,
      submitted: submitted,
      needsAttention: needsAttention,
      cancellations: cancellations,
      overdueUnconfirmed: overdueUnconfirmed,
    );
  }
}
