import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/departure_plan.dart';
import 'package:dont_forget/models/medication_plan.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/departure_weather_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/learning_queue_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/task_search_index.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications implements NotificationService {
  final scheduled = <Reminder>[], cancelled = <String>[];
  bool fail = false;
  @override
  bool get isPausedForMaintenance => false;
  @override
  Future<void> init() async {}
  @override
  Future<void> scheduleReminderStrict(Reminder reminder) async {
    if (fail) throw StateError('Synthetic schedule failure');
    scheduled.add(reminder);
  }

  @override
  Future<void> cancelReminderStrict(String id) async {
    if (fail) throw StateError('Synthetic cancel failure');
    cancelled.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Medicine medicine(String id, {List<String> times = const ['07:30', '19:30']}) =>
    Medicine(
      id: id,
      name: 'Fixture $id',
      strength: 'fixture form',
      amount: '1',
      unit: 'fixture unit',
      meal: 'fixture meal instruction',
      times: times,
      evidence: 'Synthetic test data',
    );
MedicationPlan plan(DateTime start, {int days = 14}) => MedicationPlan(
  id: 'synthetic-course',
  title: 'Synthetic course',
  person: 'Fixture',
  start: start,
  end: DateTime(start.year, start.month, start.day + days - 1),
  medicines: [for (var i = 0; i < 4; i++) medicine('$i')],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('bounded data and schedules', () {
    test(
      'invalid details reject unknown fields, overflowing dates and duplicate IDs',
      () {
        final raw = const TaskDetails().toJson();
        expect(
          () => TaskDetails.decode(jsonEncode({...raw, 'new_unknown': true})),
          throwsFormatException,
        );
        expect(
          () => TaskDetails.decode(
            jsonEncode({...raw, 'deleted_at': '2030-02-31T00:00:00'}),
          ),
          throwsFormatException,
        );
        expect(
          () => TaskDetails.decode(jsonEncode({...raw, 'paused': 'true'})),
          throwsFormatException,
        );
        final item = const ChecklistItem('x', 'one').toJson();
        expect(
          () => TaskDetails.decode(
            jsonEncode({
              ...raw,
              'checklist': [item, item],
            }),
          ),
          throwsFormatException,
        );
      },
    );
    test(
      'history is bounded while retaining latest actual and scheduled times',
      () {
        var data = const TaskDetails();
        for (var i = 0; i < 520; i++) {
          data = data.record(
            'completed',
            DateTime(2030, 1, 1).add(Duration(minutes: i)),
            scheduled: DateTime(2030),
          );
        }
        final copy = TaskDetails.decode(data.encode());
        expect(copy.history.length, 512);
        expect(copy.history.first.at, DateTime(2030, 1, 1, 0, 8));
        expect(copy.history.last.scheduled, DateTime(2030));
      },
    );
    test('weekly selected days and two-week cadence use calendar weeks', () {
      final base = DateTime(2030, 1, 7, 8); // Monday
      const repeat = RepeatWindow(interval: 2, weekdays: [1, 3, 5]);
      expect(repeat.next(base, base, 'weekly'), DateTime(2030, 1, 9, 8));
      expect(
        repeat.next(base, DateTime(2030, 1, 11, 8), 'weekly'),
        DateTime(2030, 1, 21, 8),
      );
    });
    test('repeat end is inclusive and short months retain original day', () {
      final base = DateTime(2030, 1, 31, 8);
      final repeat = RepeatWindow(end: DateTime(2030, 3, 31, 8));
      expect(repeat.next(base, base, 'monthly'), DateTime(2030, 2, 28, 8));
      expect(
        repeat.next(base, DateTime(2030, 2, 28, 8), 'monthly'),
        DateTime(2030, 3, 31, 8),
      );
      expect(repeat.next(base, DateTime(2030, 3, 31, 8), 'monthly'), isNull);
      expect(
        const RepeatWindow(interval: 2).next(base, base, 'monthly'),
        DateTime(2030, 3, 31, 8),
      );
    });
    test('partial or ambiguous medication facts never produce reminders', () {
      final draft = MedicationPlan.fromJson({
        'title': 'approximate course',
        'medicines': [
          {
            'name': 'unknown',
            'unresolved': ['dose and duration unknown'],
          },
        ],
        'start': null,
        'end': null,
      });
      expect(draft.issues, isNotEmpty);
      expect(() => draft.build(now: DateTime(2030)), throwsFormatException);
      expect(() => MedicationPlan.day('2030-02-31'), throwsFormatException);
      expect(medicine('x', times: ['07:30', '07:30']).complete, isFalse);
      expect(
        Medicine.fromJson({...medicine('x').toJson(), 'unit': ''}).complete,
        isFalse,
      );
    });
    test(
      'four medicines produce independent bounded doses with stable identities',
      () {
        final built = plan(
          DateTime(2030, 1, 1),
        ).build(now: DateTime(2029, 12, 31));
        expect(built.doses.length, 112);
        expect(built.doses.map((r) => r.id).toSet().length, 112);
        expect(built.doses.first.eventTime, DateTime(2030, 1, 1, 7, 30));
        expect(built.doses.last.eventTime, DateTime(2030, 1, 14, 19, 30));
        expect(
          built.doses.every(
            (r) =>
                !r.isRecurring &&
                r.details.kind == 'medication' &&
                r.details.planId == built.owner.id,
          ),
          isTrue,
        );
        expect(
          plan(
            DateTime(2030, 1, 1),
          ).build(now: DateTime(2029, 12, 31)).doses.map((r) => r.id),
          built.doses.map((r) => r.id),
        );
      },
    );
    test(
      'start after earlier doses excludes them without marking them taken',
      () {
        final doses = plan(
          DateTime(2030, 1, 1),
        ).build(now: DateTime(2030, 1, 1, 8)).doses;
        expect(doses.length, 108);
        expect(doses.first.eventTime, DateTime(2030, 1, 1, 19, 30));
        expect(doses.every((r) => !r.isCompleted), isTrue);
      },
    );
    test('individual medicine dates stay inside the confirmed course', () {
      final original = plan(DateTime(2030, 1, 1));
      final data = original.toJson();
      (data['medicines'] as List).first['end'] = '2030-01-03';
      expect(
        MedicationPlan.fromJson(
          data,
        ).build(now: DateTime(2029, 12, 31)).doses.length,
        90,
      );
      (data['medicines'] as List).first['end'] = '2030-02-01';
      expect(
        () => MedicationPlan.fromJson(data).build(now: DateTime(2029, 12, 31)),
        throwsFormatException,
      );
    });
    test(
      'previous-day departure alarm preserves selected departure weekday',
      () {
        final row = DeparturePlan(
          id: 'night',
          title: 'Night departure',
          departureMinute: 5,
          leadMinutes: 10,
          weekdays: [2],
          items: [const ChecklistItem('x', 'Keys')],
        ).build(DateTime(2030, 1, 7, 12));
        expect(row.triggerTime, DateTime(2030, 1, 7, 23, 55));
        expect(row.eventTime, DateTime(2030, 1, 8, 0, 5));
        expect(row.details.repeat!.weekdays, [1]);
        expect(
          row.getNextOccurrence(after: row.triggerTime),
          DateTime(2030, 1, 14, 23, 55),
        );
      },
    );
    test(
      'habit suggestions require consistent confirmed samples and are opt-in',
      () {
        var p = DeparturePlan(
          id: 'departure',
          title: 'Go',
          place: 'Home',
          learningEnabled: true,
        );
        for (var i = 0; i < 5; i++) {
          p = p.record(DateTime(2030, 1, 7 + i, 8, 10 + i));
        }
        expect(p.suggestion(now: DateTime(2030, 1, 12))?.samples, 5);
        expect(p.suggestion(now: DateTime(2030, 1, 12))?.minute, 492);
        final before = p.records.length;
        p = p.record(DateTime(2030, 1, 7, 8, 30));
        expect(p.records.length, before);
        expect(
          () => p.patch({'learning': false}).record(DateTime(2030, 1, 14)),
          throwsStateError,
        );
        expect(
          p.patch({'records': []}).suggestion(now: DateTime(2030, 1, 12)),
          isNull,
        );
      },
    );
    test(
      'weather coverage and freshness are required for both rain conclusions',
      () {
        final now = DateTime.utc(2030, 1, 1, 6);
        final weather = WeatherForecast(
          now,
          [
            now,
            now.add(const Duration(hours: 1)),
            now.add(const Duration(hours: 2)),
          ],
          [0, 60, 10],
          latitude: 31,
          longitude: 121,
        );
        expect(
          weather.rainDuring(now, now.add(const Duration(hours: 1)), now: now),
          isTrue,
        );
        expect(weather.rainDuring(now, now, now: now), isFalse);
        expect(
          weather.rainDuring(now, now.add(const Duration(hours: 3)), now: now),
          isNull,
        );
        expect(
          weather.rainDuring(now, now, now: now.add(const Duration(hours: 7))),
          isNull,
        );
        expect(WeatherForecast.fromJson(weather.toJson()).hours, weather.hours);
        expect(
          WeatherForecast(
            now,
            [now],
            [null],
            latitude: 31,
            longitude: 121,
          ).rainDuring(now, now, now: now),
          isNull,
        );
      },
    );
    test('tag, project and checklist terms participate in task search', () {
      final task = Reminder(
        id: 'search',
        taskTitle: 'Task',
        quadrantLevel: 2,
        detailsJson: const TaskDetails(
          tags: ['health'],
          project: 'family',
          checklist: [ChecklistItem('x', 'headphones')],
        ).encode(),
      );
      expect(TaskSearchIndex([task]).search('health family headphones'), [
        task,
      ]);
    });
  });

  test('workday intervals count business days across weekends', () {
    final base = DateTime(2030, 1, 11, 8);
    const repeat = RepeatWindow(interval: 3);
    expect(repeat.next(base, base, 'workday'), DateTime(2030, 1, 16, 8));
    expect(
      repeat.next(base, DateTime(2030, 1, 16, 8), 'workday'),
      DateTime(2030, 1, 21, 8),
    );
  });
  test(
    'nested detail data is immutable and out-of-range repeats cannot notify',
    () {
      final details = TaskDetails.decode(
        const TaskDetails(
          data: {
            'nested': {
              'values': [1],
            },
          },
        ).encode(),
      );
      expect(
        () => details.data['nested']['values'].add(2),
        throwsUnsupportedError,
      );
      final task = Reminder(
        id: 'bounded',
        taskTitle: 'Bounded',
        quadrantLevel: 2,
        triggerTime: DateTime(2030, 1, 3, 8),
        isRecurring: true,
        recurrenceRule: 'daily',
        detailsJson: TaskDetails(
          repeat: RepeatWindow(end: DateTime(2030, 1, 2, 23, 59)),
        ).encode(),
      );
      expect(task.canNotify, isFalse);
    },
  );
  test('departure records preserve the confirmed weather context', () {
    final at = DateTime(2030, 1, 7, 8);
    final recorded =
        DeparturePlan(
          id: 'weather-record',
          learningEnabled: true,
          place: 'Home',
        ).record(
          at,
          weather: {
            'source': 'Open-Meteo',
            'fetched': at.toIso8601String(),
            'city': 'Fixture',
            'rain': true,
          },
        );
    expect(
      DeparturePlan.fromJson(recorded.toJson()).records.single.weather!['rain'],
      isTrue,
    );
  });
  group('transactional routines', () {
    late Directory directory;
    late DatabaseHelper database;
    late ProviderContainer container;
    late _Notifications notifications;
    late RemindersNotifier notifier;
    setUp(() async {
      sqfliteFfiInit();
      directory = await Directory.systemTemp.createTemp('dontforget-routines-');
      database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
      notifications = _Notifications();
      container = ProviderContainer(
        overrides: [
          databaseHelperProvider.overrideWithValue(database),
          notificationServiceProvider.overrideWithValue(notifications),
          remindersProvider.overrideWith(
            (_) => RemindersNotifier(
              database,
              notifications: notifications,
              runLoadEffects: false,
            ),
          ),
        ],
      );
      notifier = container.read(remindersProvider.notifier);
      await notifier.ready;
    });
    tearDown(() async {
      container.dispose();
      await database.close(createBackup: false);
      await directory.delete(recursive: true);
    });
    Future<List<Reminder>> saved() async => (await database.read(
      database.captureGeneration(),
      (db) => db.query('Reminders'),
    )).map(Reminder.fromJson).toList();
    ({Reminder owner, List<Reminder> doses}) build() => plan(
      DateTime.now().add(const Duration(days: 2)),
    ).build(now: DateTime.now());
    test(
      'course commit is atomic and repeated confirmation is idempotent',
      () async {
        final rows = build();
        final generation = database.captureGeneration();
        final first = await notifier.saveRoutine(
          rows.owner,
          rows.doses,
          generation,
        );
        expect(first.changed, 113);
        expect((await saved()).length, 113);
        expect(notifications.scheduled.length, 112);
        final retry = await notifier.saveRoutine(
          rows.owner,
          rows.doses,
          generation,
        );
        expect(retry.changed, 0);
        expect((await saved()).length, 113);
      },
    );
    test('invalid duplicate doses cannot partially save the owner', () async {
      final rows = build();
      expect(
        () => notifier.saveRoutine(rows.owner, [
          rows.doses.first,
          rows.doses.first,
        ], database.captureGeneration()),
        throwsFormatException,
      );
      expect(await saved(), isEmpty);
    });
    test(
      'taking one dose does not complete the other medicines or next day',
      () async {
        final rows = build();
        await notifier.saveRoutine(
          rows.owner,
          rows.doses,
          database.captureGeneration(),
        );
        final first = (await saved()).firstWhere(
          (r) => r.details.kind == 'medication',
        );
        await notifier.completeOccurrence(first);
        final all = await saved();
        expect(all.where((r) => r.isCompleted).length, 1);
        expect(
          all.firstWhere((r) => r.id == first.id).details.history.last.action,
          'taken',
        );
        final stale = await notifier.completeOccurrence(first);
        expect(stale.disposition, ReminderActionDisposition.stale);
      },
    );
    test('not-taken is an explicit separate history event', () async {
      final rows = build();
      await notifier.saveRoutine(
        rows.owner,
        rows.doses,
        database.captureGeneration(),
      );
      final first = (await saved()).firstWhere(
        (r) => r.details.kind == 'medication',
      );
      await notifier.markNotTaken(first, database.captureGeneration());
      final item = (await saved()).firstWhere((r) => r.id == first.id);
      expect(item.isCompleted, isTrue);
      expect(item.details.history.last.action, 'not_taken');
      expect(item.details.history.last.scheduled, first.eventTime);
    });
    test(
      'pause stops all remaining doses and resume preserves taken history',
      () async {
        final rows = build();
        final gen = database.captureGeneration();
        await notifier.saveRoutine(rows.owner, rows.doses, gen);
        await notifier.completeOccurrence(
          (await saved()).firstWhere((r) => r.details.kind == 'medication'),
        );
        final owner = (await saved()).firstWhere((r) => r.id == rows.owner.id);
        await notifier.changeLifecycle(owner, 'pause', gen);
        expect((await saved()).where((r) => r.canNotify), isEmpty);
        final paused = (await saved()).firstWhere((r) => r.id == owner.id);
        await notifier.changeLifecycle(paused, 'resume', gen);
        final all = await saved();
        expect(all.where((r) => r.canNotify).length, 111);
        expect(
          all.where((r) => r.isCompleted).single.details.history.last.action,
          'taken',
        );
      },
    );
    test(
      'trash and restore retain data without treating removal as completion',
      () async {
        final task = Reminder(
          id: 'ordinary',
          taskTitle: 'Keep source',
          quadrantLevel: 2,
          triggerTime: DateTime.now().add(const Duration(days: 1)),
        );
        await notifier.addReminder(task);
        final gen = database.captureGeneration();
        await notifier.changeLifecycle(task, 'trash', gen);
        var row = (await saved()).single;
        expect(row.isVisible, isFalse);
        expect(row.isCompleted, isFalse);
        expect(notifications.cancelled, contains(row.id));
        expect((await notifier.completeOccurrence(task)).accepted, isFalse);
        await notifier.changeLifecycle(row, 'restore', gen);
        row = (await saved()).single;
        expect(row.isVisible, isTrue);
        expect(row.isCompleted, isFalse);
      },
    );
    test(
      'checklist resets reusable items but keeps completed one-time items',
      () async {
        final at = DateTime.now().add(const Duration(days: 1));
        final task = Reminder(
          id: 'list',
          taskTitle: 'Leave',
          quadrantLevel: 2,
          triggerTime: at,
          isRecurring: true,
          recurrenceRule: 'daily',
          detailsJson: const TaskDetails(
            checklist: [
              ChecklistItem('keys', 'Keys', done: true),
              ChecklistItem('trash', 'Trash', done: true, once: true),
            ],
          ).encode(),
        );
        await notifier.addReminder(task);
        await notifier.completeOccurrence(task);
        final row = (await saved()).single;
        expect(row.details.checklist.first.done, isFalse);
        expect(row.details.checklist.last.done, isTrue);
        expect(row.isCompleted, isFalse);
        expect(row.details.history.last.scheduled, at);
      },
    );
    test(
      'native failure is separate from a committed course and can be retried',
      () async {
        final rows = build();
        notifications.fail = true;
        final result = await notifier.saveRoutine(
          rows.owner,
          rows.doses,
          database.captureGeneration(),
        );
        expect((await saved()).length, 113);
        expect(result.nativeSyncFailures, 113);
        notifications.fail = false;
        final retry = await notifier.retryNotificationDelivery();
        expect(retry.failed, 0);
        expect(notifications.scheduled.length, 112);
      },
    );
    test(
      'v15 preview validates nested routine data and current frozen schema',
      () async {
        final rows = build();
        await notifier.saveRoutine(
          rows.owner,
          rows.doses,
          database.captureGeneration(),
        );
        await database.createMirrorBackup();
        final snapshot = File('${directory.path}/dontforget_snapshot.json');
        // Use the helper’s actual artifact name rather than a guessed fixture.
        final jsonFiles = directory
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList();
        final source = await snapshot.exists()
            ? snapshot
            : jsonFiles.firstWhere(
                (f) =>
                    jsonDecode(f.readAsStringSync()) is Map &&
                    (jsonDecode(f.readAsStringSync()) as Map).containsKey(
                      'reminders',
                    ),
              );
        final preview = await BackupInspector(
          databaseFactoryFfi,
        ).inspect(source);
        expect(preview.version, 15);
        expect(preview.counts['reminders'], 113);
        final raw =
            jsonDecode(await source.readAsString()) as Map<String, dynamic>;
        final list = raw['reminders'] as List;
        final owner = list.firstWhere(
          (r) =>
              jsonDecode(r['details_json'] as String)['kind'] ==
              'medicationPlan',
        );
        final details = jsonDecode(owner['details_json'] as String);
        details['data']['start'] = '2030-02-31';
        owner['details_json'] = jsonEncode(details);
        final bad = File('${directory.path}/invalid-course.json');
        await bad.writeAsString(jsonEncode(raw));
        expect(
          BackupInspector(databaseFactoryFfi).inspect(bad),
          throwsA(isA<BackupInspectionException>()),
        );
      },
    );
    test(
      'old routine confirmations cannot cross a recovery generation',
      () async {
        final rows = build();
        final old = database.captureGeneration();
        final lease = await database.beginMaintenance();
        await lease.resume();
        await expectLater(
          notifier.saveRoutine(rows.owner, rows.doses, old),
          throwsA(isA<DatabaseAccessException>()),
        );
        expect(await saved(), isEmpty);
      },
    );
    test(
      'word history survives permanent batch deletion and completed cleanup',
      () async {
        final now = DateTime.now();
        final task = Reminder(
          id: 'archive-word',
          taskTitle: 'Words',
          taskSummary: 'alpha — Fixture meaning\nFixture example',
          quadrantLevel: 2,
          spacedRepetitionLevel: 1,
          nextReviewAt: now,
        );
        await notifier.addReminder(task);
        await notifier.gradeWord(task, 'alpha', 2, now: now);
        await notifier.deleteReminder(task.id);
        var remaining = await saved();
        expect(remaining.length, 1);
        expect(remaining.single.details.data['learning_archive'], isTrue);
        expect(remaining.single.isVisible, isFalse);
        expect(LearningQueueService.progress(remaining)['alpha']!.reviews, 1);
        await notifier.clearCompletedReminders();
        remaining = await saved();
        expect(remaining.length, 1);
        expect(LearningQueueService.progress(remaining)['alpha']!.level, 1);
      },
    );
    test('custom known-word intervals keep actual review history', () async {
      final now = DateTime.now();
      final task = Reminder(
        id: 'custom-word',
        taskTitle: 'Words',
        taskSummary: 'alpha — Fixture meaning\nFixture example',
        quadrantLevel: 2,
        spacedRepetitionLevel: 1,
        nextReviewAt: now,
      );
      await notifier.addReminder(task);
      await notifier.gradeWord(
        task,
        'alpha',
        2,
        now: now,
        intervals: [3, 5, 8, 12, 20],
      );
      final row = (await saved()).single,
          progress = LearningQueueService.progress(await saved())['alpha']!;
      expect(
        progress.due,
        DateTime(now.year, now.month, now.day + 3, now.hour, now.minute),
      );
      expect(row.details.history.single.action, 'word_review');
      expect(row.details.history.single.note, 'alpha:2');
    });
    test('ordinary editing cannot make a medication course infinite', () async {
      final rows = build();
      await notifier.saveRoutine(
        rows.owner,
        rows.doses,
        database.captureGeneration(),
      );
      final dose = (await saved()).firstWhere(
        (r) => r.details.kind == 'medication',
      );
      await expectLater(
        notifier.updateReminder(
          dose.copyWith(isRecurring: true, recurrenceRule: 'daily'),
          baseline: dose,
        ),
        throwsStateError,
      );
      expect(
        (await saved())
            .where((r) => r.details.kind == 'medication')
            .every((r) => !r.isRecurring),
        isTrue,
      );
      expect(
        (await notifier.completeOccurrence(
          (await saved()).firstWhere((r) => r.id == rows.owner.id),
        )).accepted,
        isFalse,
      );
    });
    test(
      'v14 upgrade retains original columns and a rollback snapshot',
      () async {
        final legacy = await Directory('${directory.path}/legacy14').create();
        final old = await databaseFactoryFfi.openDatabase(
          '${legacy.path}/dont_forget_v3.db',
          options: OpenDatabaseOptions(
            version: 14,
            onCreate: (db, _) async {
              final schema = await File(
                'test/fixtures/schema_v14.sql',
              ).readAsString();
              for (final statement
                  in schema
                      .split('\n')
                      .where((line) => !line.trimLeft().startsWith('--'))
                      .join('\n')
                      .split(';')) {
                if (statement.trim().isNotEmpty) await db.execute(statement);
              }
            },
          ),
        );
        await old.insert('Settings', AppSettings.defaults().toJson());
        final row = Reminder(
          id: 'legacy',
          taskTitle: 'Keep original',
          quadrantLevel: 2,
          sourceText: 'Original source',
        ).toJson()..remove('details_json');
        await old.insert('Reminders', row);
        await old.close();
        final upgraded = DatabaseHelper.forTesting(
          legacy.path,
          databaseFactoryFfi,
        );
        try {
          final db = await upgraded.database;
          expect(await db.getVersion(), 15);
          final current = (await db.query('Reminders')).single;
          for (final entry in row.entries) {
            expect(current[entry.key], entry.value, reason: entry.key);
          }
          expect(current['details_json'], isNull);
          final rollback = legacy.listSync().whereType<Directory>().singleWhere(
            (d) => d.path.contains('schema-upgrade-v14-to-v15-'),
          );
          expect(
            (await BackupInspector(
              databaseFactoryFfi,
            ).inspect(File('${rollback.path}/snapshot.json'))).version,
            14,
          );
        } finally {
          await upgraded.close(createBackup: false);
        }
      },
    );
    test(
      'selected weekday recurrence keeps an event across the week boundary',
      () async {
        final at = DateTime(2030, 1, 7, 23, 55);
        final task = Reminder(
          id: 'week-boundary',
          taskTitle: 'Fixture',
          quadrantLevel: 2,
          triggerTime: at,
          eventTime: DateTime(2030, 1, 8, 0, 5),
          isRecurring: true,
          recurrenceRule: 'weekly',
          detailsJson: const TaskDetails(
            repeat: RepeatWindow(interval: 2, weekdays: [1, 7]),
          ).encode(),
        );
        await notifier.addReminder(task);
        await notifier.completeOccurrence(task, now: at);
        final next = (await saved()).single;
        expect(next.triggerTime, DateTime(2030, 1, 13, 23, 55));
        expect(next.eventTime, DateTime(2030, 1, 14, 0, 5));
      },
    );
    test(
      'not-taken outcome survives group restore and history rollover',
      () async {
        final rows = build();
        final gen = database.captureGeneration();
        await notifier.saveRoutine(rows.owner, rows.doses, gen);
        final dose = (await saved()).firstWhere(
          (r) => r.details.kind == 'medication',
        );
        await notifier.markNotTaken(dose, gen);
        await notifier.changeLifecycle(
          (await saved()).firstWhere((r) => r.id == rows.owner.id),
          'trash',
          gen,
        );
        await notifier.changeLifecycle(
          (await saved()).firstWhere((r) => r.id == rows.owner.id),
          'restore',
          gen,
        );
        var current = (await saved()).firstWhere((r) => r.id == dose.id);
        expect(current.details.effectiveDoseOutcome, 'not_taken');
        var details = current.details;
        for (var i = 0; i < 520; i++) {
          details = details.record('edited', DateTime.now());
        }
        await notifier.editTaskDetails(current, details, gen);
        current = (await saved()).firstWhere((r) => r.id == dose.id);
        expect(
          current.details.history.every((e) => e.action != 'not_taken'),
          isTrue,
        );
        expect(current.details.effectiveDoseOutcome, 'not_taken');
      },
    );
    test(
      'generic completion records a dose outcome and completion time',
      () async {
        final rows = build();
        await notifier.saveRoutine(
          rows.owner,
          rows.doses,
          database.captureGeneration(),
        );
        final dose = (await saved()).firstWhere(
          (r) => r.details.kind == 'medication',
        );
        await notifier.updateReminder(
          dose.copyWith(isCompleted: true),
          baseline: dose,
        );
        final current = (await saved()).firstWhere((r) => r.id == dose.id);
        expect(current.details.effectiveDoseOutcome, 'taken');
        expect(current.details.completedAt, isNotNull);
        expect(current.details.history.last.action, 'taken');
      },
    );
  });
}
