import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:dont_forget/services/notification_schedule_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2032, 1, 1);
  Reminder task(String id, int minute, {String? planId}) => Reminder(
    id: id,
    taskTitle: id,
    quadrantLevel: 2,
    triggerTime: now.add(Duration(minutes: minute)),
    detailsJson: planId == null
        ? null
        : TaskDetails(kind: 'departure', planId: planId).encode(),
  );
  NotificationJournalEntry submitted(Reminder row) => NotificationJournalEntry(
    reminderId: row.id,
    nativeId: stableNotificationId(row.id),
    action: 'schedule',
    status: 'submitted',
    attempts: 1,
    triggerUtcMicros: row.triggerTime!.toUtc().microsecondsSinceEpoch,
    noticeRevision: row.noticeRevision,
  );

  test('coverage stops before a simultaneous request that is missing', () {
    final early = task('early', 1);
    final first = task('a', 2);
    final missing = task('b', 2);
    final last = task('last', 3);
    final status = NotificationScheduleStatus.fromSaved(
      [early, first, missing, last],
      {
        for (final row in [early, first, last]) row.id: submitted(row),
      },
      now,
      nativePendingLimit: 4,
    );
    expect(status.submitted, 3);
    expect(status.needsAttention, 1);
    expect(status.scheduledThrough, early.triggerTime);
  });

  test(
    'a plan shares the global budget with ordinary and medication tasks',
    () {
      final ordinary = task('ordinary', 1);
      final medication = task('dose', 2).copyWith(
        detailsJson: const TaskDetails(
          kind: 'medication',
          planId: 'course',
        ).encode(),
      );
      final departure = task('departure', 3, planId: 'commute');
      final status = NotificationScheduleStatus.fromSaved(
        [departure, ordinary, medication],
        {
          for (final row in [ordinary, medication]) row.id: submitted(row),
        },
        now,
        nativePendingLimit: 2,
        planId: 'commute',
      );
      expect(status.upcoming, 1);
      expect(status.deferred, 1);
      expect(status.submitted, 0);
      expect(status.needsAttention, 0);
      expect(status.scheduledThrough, isNull);
    },
  );

  test(
    'a capacity boundary cannot claim coverage for a partially admitted time',
    () {
      final earlier = task('early', 1);
      final a = task('a', 2), b = task('b', 2);
      final status = NotificationScheduleStatus.fromSaved(
        [earlier, a, b],
        {earlier.id: submitted(earlier), a.id: submitted(a)},
        now,
        nativePendingLimit: 2,
      );
      expect(status.deferred, 1);
      expect(status.scheduledThrough, earlier.triggerTime);
    },
  );

  group('single saved reminder capacity status', () {
    late Directory directory;
    late DatabaseHelper database;
    late NotificationScheduleReader reader;
    late Reminder early, later;
    late String epoch;
    setUp(() async {
      sqfliteFfiInit();
      directory = await Directory.systemTemp.createTemp('capacity-status-');
      database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
      early = task('early', 1);
      later = task('later', 2, planId: 'commute');
      final db = await database.database;
      for (final row in [early, later]) {
        await db.insert('Reminders', row.toJson());
      }
      epoch = await database.readNotificationEpoch();
      await database.withNotificationJournal((j) => j.reset(epoch));
      reader = NotificationScheduleReader(database, nativePendingLimit: 1);
    });
    tearDown(() async {
      await database.close(createBackup: false);
      await directory.delete(recursive: true);
    });
    Future<void> journal(Reminder row, String action, String status) =>
        database.withNotificationJournal((j) async {
          await j.begin(
            epoch,
            row.id,
            action: action,
            triggerUtcMicros: action == 'schedule'
                ? row.triggerTime!.toUtc().microsecondsSinceEpoch
                : null,
            noticeRevision: action == 'schedule' ? row.noticeRevision : null,
            attemptedAt: now,
          );
          await j.record(
            epoch,
            row.id,
            action: action,
            status: status,
            triggerUtcMicros: action == 'schedule'
                ? row.triggerTime!.toUtc().microsecondsSinceEpoch
                : null,
            noticeRevision: action == 'schedule' ? row.noticeRevision : null,
          );
        });

    test('deferred reminders are separate from failed submissions', () async {
      expect(await reader.readReminder(later), ReminderSchedulePhase.deferred);
      expect(
        await reader.readReminder(early),
        ReminderSchedulePhase.needsAttention,
      );
      await journal(early, 'schedule', 'submitted');
      expect(await reader.readReminder(early), ReminderSchedulePhase.submitted);
      final status = await reader.read();
      expect(status.deferred, 1);
      expect(status.needsAttention, 0);
      expect(status.submitted, 1);
    });
    test(
      'an uncertain cancellation remains attention until cancelled',
      () async {
        await journal(later, 'schedule', 'submitted');
        expect(
          await reader.readReminder(later),
          ReminderSchedulePhase.needsAttention,
        );
        await journal(later, 'cancel', 'failed');
        expect(
          await reader.readReminder(later),
          ReminderSchedulePhase.needsAttention,
        );
        await journal(later, 'cancel', 'submitted');
        expect(
          await reader.readReminder(later),
          ReminderSchedulePhase.deferred,
        );
      },
    );
    test(
      'finishing an earlier task makes the deferred date eligible',
      () async {
        final db = await database.database;
        await db.update(
          'Reminders',
          {'is_completed': 1},
          where: 'id = ?',
          whereArgs: [early.id],
        );
        expect(
          await reader.readReminder(later),
          ReminderSchedulePhase.needsAttention,
        );
        await journal(later, 'schedule', 'submitted');
        expect(
          await reader.readReminder(later),
          ReminderSchedulePhase.submitted,
        );
      },
    );
    test(
      'stale details cannot report a capacity state for a newer occurrence',
      () async {
        final db = await database.database;
        await db.update(
          'Reminders',
          {'notice_revision': 1},
          where: 'id = ?',
          whereArgs: [later.id],
        );
        expect(await reader.readReminder(later), ReminderSchedulePhase.unknown);
      },
    );
    test(
      'suppressed earlier tasks do not consume the shared allocation',
      () async {
        final policyReader = NotificationScheduleReader(
          database,
          nativePendingLimit: 1,
          isSuppressed: (row) => row.id == early.id,
        );
        await journal(later, 'schedule', 'submitted');
        expect(
          await policyReader.readReminder(later),
          ReminderSchedulePhase.submitted,
        );
      },
    );
    test('an unbounded reader keeps the existing status contract', () async {
      final unbounded = NotificationScheduleReader(database);
      expect(
        await unbounded.readReminder(later),
        ReminderSchedulePhase.needsAttention,
      );
      expect((await unbounded.read()).deferred, 0);
    });
  });
}
