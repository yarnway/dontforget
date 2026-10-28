import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/models/weekly_task_review.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/offline_management_harness.dart';

Reminder task(
  String id, {
  String kind = 'task',
  String? parent,
  TaskDetails? details,
  bool completed = false,
}) => Reminder(
  id: id,
  taskTitle: 'Fixture $id',
  quadrantLevel: 2,
  triggerTime: DateTime(2030, 1, 8, 8),
  eventTime: DateTime(2030, 1, 8, 8),
  isCompleted: completed,
  detailsJson: (details ?? TaskDetails(kind: kind, planId: parent)).encode(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
  });
  tearDown(() => h.dispose());
  Future<String> saved() async =>
      jsonEncode((await h.rows()).map((e) => e.toJson()).toList());
  Future<List<Reminder>> seedPair() async {
    for (final id in ['a', 'b', 'untouched']) {
      await h.seed(task(id));
    }
    return [await h.row('a'), await h.row('b')];
  }

  test(
    'bulk pause resume trash restore affects only the selected ordinary tasks',
    () async {
      var selected = await seedPair();
      final gen = h.database.captureGeneration();
      final original = (await h.row('untouched')).toJson();
      for (final action in ['pause', 'resume', 'trash', 'restore']) {
        final result = await h.notifier.changeLifecycleBatch(
          selected,
          action,
          gen,
        );
        expect(result.changed, 2);
        expect(result.nativeSyncFailures, 0);
        selected = [await h.row('a'), await h.row('b')];
        for (final row in selected) {
          expect(row.details.history.last.action, action);
        }
        expect((await h.row('untouched')).toJson(), original);
      }
      expect(selected.every((e) => e.isVisible && !e.details.paused), isTrue);
    },
  );
  test('bulk stale title or checklist rejects the whole transaction', () async {
    final selected = await seedPair();
    final gen = h.database.captureGeneration();
    await h.notifier.updateReminderForGeneration(
      selected[1].copyWith(taskTitle: 'User edit wins'),
      gen,
      baseline: selected[1],
    );
    final before = await saved();
    await expectLater(
      h.notifier.changeLifecycleBatch(selected, 'trash', gen),
      throwsA(isA<StaleReminderOccurrenceException>()),
    );
    expect(await saved(), before);
    expect((await h.row('a')).isVisible, isTrue);
  });
  test(
    'bulk SQLite failure rolls back previous rows and publishes nothing',
    () async {
      final selected = await seedPair();
      final before = await saved();
      final stateBefore = h.container
          .read(remindersProvider)
          .map((e) => e.toJson())
          .toList();
      final db = await h.database.database;
      await db.execute(
        "CREATE TRIGGER fail_second BEFORE UPDATE ON Reminders WHEN NEW.id='b' BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END",
      );
      await expectLater(
        h.notifier.changeLifecycleBatch(
          selected,
          'pause',
          h.database.captureGeneration(),
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(await saved(), before);
      expect(
        h.container.read(remindersProvider).map((e) => e.toJson()).toList(),
        stateBefore,
      );
    },
  );
  test(
    'bulk refuses plans children duplicate IDs empty and oversize selection',
    () async {
      await h.seed(task('owner', kind: 'medicationPlan'));
      await h.seed(task('dose', kind: 'medication', parent: 'owner'));
      final gen = h.database.captureGeneration();
      final before = await saved();
      for (final id in ['owner', 'dose']) {
        await expectLater(
          h.notifier.changeLifecycleBatch([await h.row(id)], 'pause', gen),
          throwsStateError,
        );
      }
      final ordinary = task('ordinary');
      expect(
        () => h.notifier.changeLifecycleBatch([], 'pause', gen),
        throwsFormatException,
      );
      expect(
        () =>
            h.notifier.changeLifecycleBatch([ordinary, ordinary], 'pause', gen),
        throwsFormatException,
      );
      expect(
        () => h.notifier.changeLifecycleBatch(
          [for (var i = 0; i < 51; i++) task('id-$i')],
          'pause',
          gen,
        ),
        throwsFormatException,
      );
      expect(await saved(), before);
    },
  );
  test(
    'mixed archive eligibility and paused hidden tasks cannot partly apply',
    () async {
      final selected = await seedPair();
      final gen = h.database.captureGeneration();
      final before = await saved();
      await expectLater(
        h.notifier.changeLifecycleBatch(selected, 'archive', gen),
        throwsStateError,
      );
      expect(await saved(), before);
      await h.notifier.changeLifecycleBatch([selected.first], 'trash', gen);
      final hidden = await h.row('a');
      final hiddenBefore = await saved();
      await expectLater(
        h.notifier.changeLifecycleBatch(
          [hidden, await h.row('b')],
          'pause',
          gen,
        ),
        throwsStateError,
      );
      expect(await saved(), hiddenBefore);
    },
  );
  test('completed ordinary tasks support bulk archive and unarchive', () async {
    for (final id in ['a', 'b']) {
      await h.seed(task(id, completed: true));
    }
    final gen = h.database.captureGeneration();
    await h.notifier.changeLifecycleBatch(
      [await h.row('a'), await h.row('b')],
      'archive',
      gen,
    );
    expect((await h.rows()).every((e) => e.details.archivedAt != null), isTrue);
    await h.notifier.changeLifecycleBatch(
      [await h.row('a'), await h.row('b')],
      'unarchive',
      gen,
    );
    expect((await h.rows()).every((e) => e.isVisible && e.isCompleted), isTrue);
  });
  test(
    'bulk native failures keep durable results and report each failed sync',
    () async {
      final selected = await seedPair();
      h.notifications.fail = true;
      final result = await h.notifier.changeLifecycleBatch(
        selected,
        'pause',
        h.database.captureGeneration(),
      );
      expect(result.changed, 2);
      expect(result.nativeSyncFailures, 2);
      expect((await h.row('a')).details.paused, isTrue);
      expect((await h.row('b')).details.paused, isTrue);
    },
  );
  test(
    'bulk recovery generation invalidates previously selected tasks',
    () async {
      final selected = await seedPair();
      final gen = h.database.captureGeneration();
      final before = await saved();
      final lease = await h.database.beginMaintenance();
      await lease.resume();
      await expectLater(
        h.notifier.changeLifecycleBatch(selected, 'trash', gen),
        throwsA(isA<DatabaseAccessException>()),
      );
      expect(await saved(), before);
    },
  );
  test(
    'actual dose backfill keeps planned, actual and recorded times distinct and survives reopen',
    () async {
      await h.seed(task('dose', kind: 'medication'));
      final original = await h.row('dose');
      final actual = DateTime(2030, 1, 8, 8, 35),
          recorded = DateTime(2030, 1, 9, 11);
      await h.notifier.recordDoseTakenAt(
        original,
        actual,
        h.database.captureGeneration(),
        now: recorded,
      );
      final next = await h.row('dose');
      expect(next.eventTime, original.eventTime);
      expect(next.triggerTime, original.triggerTime);
      expect(next.details.actualDoseTakenAt, actual);
      expect(next.details.completedAt, recorded);
      expect(next.details.history.last.at, recorded);
      expect(next.details.history.last.scheduled, original.eventTime);
      expect(next.details.history.last.note, actual.toIso8601String());
      expect(next.isCompleted, isTrue);
      expect(h.notifications.cancelled, contains('dose'));
      await h.close();
      await h.open();
      expect((await h.row('dose')).details.actualDoseTakenAt, actual);
    },
  );
  test(
    'correcting a dose time preserves first entry time and counts one dose in the correct week',
    () async {
      await h.seed(task('dose', kind: 'medication'));
      final gen = h.database.captureGeneration();
      await h.notifier.recordDoseTakenAt(
        await h.row('dose'),
        DateTime(2030, 1, 8, 8),
        gen,
        now: DateTime(2030, 1, 9),
      );
      await h.notifier.recordDoseTakenAt(
        await h.row('dose'),
        DateTime(2030, 1, 6, 20),
        gen,
        now: DateTime(2030, 1, 10),
      );
      final dose = await h.row('dose');
      expect(dose.details.history.last.action, 'dose_time_corrected');
      expect(dose.details.completedAt, DateTime(2030, 1, 9));
      final current = WeeklyTaskReview.build(
        [dose],
        weekContaining: DateTime(2030, 1, 10),
        now: DateTime(2030, 1, 11),
      );
      final previous = WeeklyTaskReview.build(
        [dose],
        weekContaining: DateTime(2030, 1, 6),
        now: DateTime(2030, 1, 11),
      );
      expect(current.counts['taken'], 0);
      expect(previous.counts['taken'], 1);
    },
  );
  test(
    'explicit taken correction replaces a not-taken outcome without deleting audit history',
    () async {
      await h.seed(task('dose', kind: 'medication'));
      final gen = h.database.captureGeneration();
      await h.notifier.markNotTaken(await h.row('dose'), gen);
      await h.notifier.recordDoseTakenAt(
        await h.row('dose'),
        DateTime(2026, 1, 1),
        gen,
      );
      final dose = await h.row('dose');
      expect(dose.details.effectiveDoseOutcome, 'taken');
      expect(
        dose.details.history.map((e) => e.action),
        containsAllInOrder(['not_taken', 'taken']),
      );
    },
  );
  test(
    'future actual time stale revision wrong kind and paused dose do not write',
    () async {
      await h.seed(task('dose', kind: 'medication'));
      await h.seed(task('ordinary'));
      final gen = h.database.captureGeneration();
      final dose = await h.row('dose');
      final before = await saved();
      expect(
        () => h.notifier.recordDoseTakenAt(
          dose,
          DateTime(2030),
          gen,
          now: DateTime(2029),
        ),
        throwsFormatException,
      );
      await expectLater(
        h.notifier.recordDoseTakenAt(
          await h.row('ordinary'),
          DateTime(2020),
          gen,
        ),
        throwsA(isA<StaleReminderOccurrenceException>()),
      );
      expect(await saved(), before);
      await h.notifier.changeLifecycle(dose, 'pause', gen);
      final pausedBefore = await saved();
      await expectLater(
        h.notifier.recordDoseTakenAt(dose, DateTime(2020), gen),
        throwsA(isA<StaleReminderOccurrenceException>()),
      );
      await expectLater(
        h.notifier.recordDoseTakenAt(await h.row('dose'), DateTime(2020), gen),
        throwsA(isA<StaleReminderOccurrenceException>()),
      );
      expect(await saved(), pausedBefore);
    },
  );
  test(
    'dose native cancellation failure retains the record with actionable result',
    () async {
      await h.seed(task('dose', kind: 'medication'));
      h.notifications.fail = true;
      final result = await h.notifier.recordDoseTakenAt(
        await h.row('dose'),
        DateTime(2020),
        h.database.captureGeneration(),
      );
      expect(result.nativeSyncFailed, isTrue);
      expect((await h.row('dose')).details.actualDoseTakenAt, DateTime(2020));
    },
  );
  test(
    'dose SQL failure and recovery reject backfill without publishing',
    () async {
      await h.seed(task('dose', kind: 'medication'));
      final dose = await h.row('dose');
      final before = await saved();
      final gen = h.database.captureGeneration();
      final db = await h.database.database;
      await db.execute(
        "CREATE TRIGGER fail_dose BEFORE UPDATE ON Reminders BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END",
      );
      await expectLater(
        h.notifier.recordDoseTakenAt(dose, DateTime(2020), gen),
        throwsA(isA<DatabaseException>()),
      );
      expect(await saved(), before);
      expect(h.container.read(remindersProvider).single.isCompleted, isFalse);
      await db.execute('DROP TRIGGER fail_dose');
      final lease = await h.database.beginMaintenance();
      await lease.resume();
      await expectLater(
        h.notifier.recordDoseTakenAt(dose, DateTime(2020), gen),
        throwsA(isA<DatabaseAccessException>()),
      );
      expect(await saved(), before);
    },
  );
  test(
    'dose actual time accepts backup roundtrip and rejects malformed imported date',
    () async {
      await h.seed(task('dose', kind: 'medication'));
      await h.notifier.recordDoseTakenAt(
        await h.row('dose'),
        DateTime(2020),
        h.database.captureGeneration(),
      );
      await h.database.createMirrorBackup();
      for (final name in ['ha_snapshot.json', 'dont_forget_v3.mirror.db']) {
        await BackupInspector(
          databaseFactoryFfi,
        ).inspect(File('${h.directory.path}/$name'));
      }
      final dose = await h.row('dose');
      expect(
        () => dose.details.patch({
          'data': {
            ...dose.details.data,
            'dose_taken_at': '2030-02-31T08:00:00',
          },
        }),
        throwsFormatException,
      );
    },
  );
}
