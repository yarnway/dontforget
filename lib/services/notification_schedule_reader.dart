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
        (db) => db.query('Reminders'),
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
