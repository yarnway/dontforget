import '../data/database_helper.dart';
import '../models/notification_schedule_status.dart';
import '../models/reminder.dart';

enum ReminderSchedulePhase {
  unknown,
  noReminder,
  inactive,
  elapsed,
  submitted,
  policyPaused,
  needsAttention,
}

/// A local snapshot without starting reminder timers or native reconciliation.
class NotificationScheduleReader {
  NotificationScheduleReader(this.database, {this.isSuppressed});
  final bool Function(Reminder)? isSuppressed;
  final DatabaseHelper database;

  /// Reads one saved occurrence. A missing/stale journal is unknown, and a
  /// submitted plugin call is never treated as an OS delivery receipt.
  Future<ReminderSchedulePhase> readReminder(Reminder expected) async {
    final generation = database.captureGeneration();
    return database.runOperation(generation, () async {
      Future<Reminder?> readSaved() async {
        final rows = await database.read(
          generation,
          (db) => db.query(
            'Reminders',
            columns: const [
              'id',
              'task_title',
              'quadrant_level',
              'trigger_time',
              'is_completed',
              'details_json',
              'notice_revision',
              'notice_acknowledged_at',
            ],
            where: 'id = ?',
            whereArgs: [expected.id],
            limit: 1,
          ),
        );
        return rows.isEmpty ? null : Reminder.fromJson(rows.single);
      }

      bool sameTime(DateTime? a, DateTime? b) =>
          a == null ? b == null : b != null && a.isAtSameMomentAs(b);
      bool sameOccurrence(Reminder? a, Reminder b) =>
          a != null &&
          sameTime(a.triggerTime, b.triggerTime) &&
          a.noticeRevision == b.noticeRevision &&
          a.isCompleted == b.isCompleted &&
          a.detailsJson == b.detailsJson &&
          a.quadrantLevel == b.quadrantLevel &&
          sameTime(a.noticeAcknowledgedAt, b.noticeAcknowledgedAt);

      final saved = await readSaved();
      if (!sameOccurrence(saved, expected)) {
        return ReminderSchedulePhase.unknown;
      }
      final current = saved!;
      if (current.triggerTime == null) return ReminderSchedulePhase.noReminder;
      if (!current.canNotify || current.noticeAcknowledgedAt != null) {
        return ReminderSchedulePhase.inactive;
      }
      if (!current.triggerTime!.isAfter(DateTime.now())) {
        return ReminderSchedulePhase.elapsed;
      }
      final journal = await database.withNotificationJournal((j) => j.read());
      database.checkGeneration(generation);
      if (journal == null) return ReminderSchedulePhase.unknown;
      final epoch = await database.readNotificationEpoch();
      database.checkGeneration(generation);
      if (journal.epoch != epoch) return ReminderSchedulePhase.unknown;
      if (!sameOccurrence(await readSaved(), expected)) {
        return ReminderSchedulePhase.unknown;
      }
      final entry = journal.entries[current.id];
      if (isSuppressed?.call(current) == true) {
        return entry?.action == 'cancel' && entry?.status == 'submitted'
            ? ReminderSchedulePhase.policyPaused
            : ReminderSchedulePhase.needsAttention;
      }
      return entry?.action == 'schedule' &&
              entry?.status == 'submitted' &&
              entry?.noticeRevision == current.noticeRevision &&
              entry?.triggerUtcMicros ==
                  current.triggerTime!.toUtc().microsecondsSinceEpoch
          ? ReminderSchedulePhase.submitted
          : ReminderSchedulePhase.needsAttention;
    });
  }

  Future<NotificationScheduleStatus> read() async {
    final generation = database.captureGeneration();
    return database.runOperation(generation, () async {
      final rows = await database.read(
        generation,
        // Keep the Reminder decoder's required identity fields and the four
        // scheduling fields. Summaries, links and attachment data are unused
        // by this read-only status view, even for large task collections.
        (db) => db.query(
          'Reminders',
          columns: const [
            'id',
            'task_title',
            'quadrant_level',
            'trigger_time',
            'is_completed',
            'notice_revision',
            'notice_acknowledged_at',
          ],
        ),
      );
      final journal = await database.withNotificationJournal((j) => j.read());
      database.checkGeneration(generation);
      final epoch = journal == null
          ? null
          : await database.readNotificationEpoch();
      database.checkGeneration(generation);
      return NotificationScheduleStatus.fromSaved(
        rows.map(Reminder.fromJson),
        journal != null && journal.epoch == epoch ? journal.entries : {},
        DateTime.now(),
        isSuppressed: isSuppressed,
      );
    });
  }
}
