import '../../data/database_helper.dart';
import '../../models/media_record.dart';
import '../../models/reminder.dart';
import '../../models/settings.dart';
import 'database_recovery.dart';

/// Validates business data before providers can publish defaults or schedule
/// notifications. SELECT 1 alone cannot detect a missing table or bad row.
class StorageBootstrap {
  StorageBootstrap(this.database, {DatabaseRecovery? recovery})
    : recovery = recovery ?? DatabaseRecovery(database);

  final DatabaseHelper database;
  final DatabaseRecovery recovery;

  Future<void> prepare() async {
    await recovery.recoverInterrupted();
    await database.read(database.captureGeneration(), (db) async {
      final requiredColumns = {
        'Settings': AppSettings.defaults().toJson().keys,
        'MediaRecords': MediaRecord(
          id: '',
          type: 'text',
          contentOrPath: '',
          createdAt: DateTime(2000),
        ).toJson().keys,
        'Reminders': Reminder(
          id: '',
          taskTitle: '',
          quadrantLevel: 2,
        ).toJson().keys,
      };
      for (final entry in requiredColumns.entries) {
        final schema = await db.rawQuery('PRAGMA table_info(${entry.key})');
        final columns = schema.map((row) => row['name']).toSet();
        if (!columns.containsAll(entry.value)) {
          throw StateError('Local database schema is incomplete.');
        }
      }
      for (final row in await db.query('Settings')) {
        AppSettings.fromJson(row);
      }
      for (final row in await db.query('MediaRecords')) {
        MediaRecord.fromJson(row);
      }
      for (final row in await db.query('Reminders')) {
        Reminder.fromJson(row);
      }
    });
  }
}
