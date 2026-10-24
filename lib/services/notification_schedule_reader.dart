import '../data/database_helper.dart';
import '../models/notification_schedule_status.dart';
import '../models/reminder.dart';

/// A local snapshot without starting reminder timers or native reconciliation.
class NotificationScheduleReader {
  NotificationScheduleReader(this.database);
  final DatabaseHelper database;

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
      );
    });
  }
}
