import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 22);
  Reminder task(String id) => Reminder(
    id: id,
    taskTitle: 'Synthetic',
    quadrantLevel: 3,
    triggerTime: now.add(const Duration(hours: 1)),
  );
  NotificationJournalEntry entry(
    Reminder r, {
    String action = 'schedule',
    String status = 'submitted',
  }) => NotificationJournalEntry(
    reminderId: r.id,
    nativeId: stableNotificationId(r.id),
    action: action,
    status: status,
    attempts: 1,
    triggerUtcMicros: r.triggerTime?.toUtc().microsecondsSinceEpoch,
    noticeRevision: r.noticeRevision,
  );

  test('only a matching future occurrence counts as submitted to plugin', () {
    final saved = [
      task('ok'),
      task('failed'),
      task('missing'),
      task('stale'),
      task('cancel'),
      task('pending'),
    ];
    final entries = {
      'ok': entry(saved[0]),
      'failed': entry(saved[1], status: 'failed'),
      'stale': entry(saved[3].copyWith(noticeRevision: 1)),
      'cancel': entry(saved[4], action: 'cancel'),
      'pending': entry(saved[5], status: 'pending'),
    };
    final summary = NotificationScheduleStatus.fromSaved(saved, entries, now);
    expect(summary.upcoming, 6);
    expect(summary.submitted, 1);
    expect(summary.needsAttention, 5);
    expect(summary.cancellations, 0);
    expect(summary.overdueUnconfirmed, 0);
  });

  test('cancel work and expired unknown schedules have distinct counts', () {
    final expired = task('expired').copyWith(triggerTime: now);
    final stale = task('stale').copyWith(triggerTime: now);
    final cancel = task('cancel').copyWith(triggerTime: now);
    final completed = task('done').copyWith(isCompleted: true);
    final acknowledged = task('ack').copyWith(noticeAcknowledgedAt: now);
    final delivered = task('delivered').copyWith(triggerTime: now);
    final entries = {
      'expired': entry(expired, status: 'failed'),
      'stale': entry(task('stale')),
      'cancel': entry(cancel, action: 'cancel', status: 'failed'),
      'done': entry(completed),
      'ack': entry(acknowledged, action: 'cancel'),
      'orphan': entry(task('orphan')),
      'delivered': entry(delivered),
    };
    final summary = NotificationScheduleStatus.fromSaved(
      [expired, stale, cancel, completed, acknowledged, delivered],
      entries,
      now,
    );
    expect(summary.upcoming, 0);
    expect(summary.submitted, 0);
    expect(summary.cancellations, 4);
    expect(summary.overdueUnconfirmed, 1);
  });
}
