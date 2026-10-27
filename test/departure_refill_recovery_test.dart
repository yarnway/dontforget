import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/departure_plan.dart';
import 'package:dont_forget/models/medication_plan.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications implements NotificationService {
  @override
  Future<void> scheduleReminderStrict(Reminder task) async {}
  @override
  Future<void> cancelReminderStrict(String id) async {}
  @override
  dynamic noSuchMethod(Invocation call) => super.noSuchMethod(call);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final start = DateTime(2032, 1, 1, 6);
  DeparturePlan plan() => DeparturePlan(
    id: 'daily',
    title: 'Fixture departure',
    departureMinute: 480,
    weekdays: const [1, 2, 3, 4, 5, 6, 7],
    items: const [ChecklistItem('keys', 'Keys')],
  );
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  Future<void> open() async {
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    final notifications = _Notifications();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        remindersProvider.overrideWith(
          (_) => RemindersNotifier(
            database,
            notifications: notifications,
            runLoadEffects: false,
          ),
        ),
      ],
    );
    await container.read(remindersProvider.notifier).ready;
  }

  RemindersNotifier notifier() => container.read(remindersProvider.notifier);
  List<Reminder> rows() => container.read(remindersProvider);
  Reminder owner() => rows().singleWhere((r) => r.id == 'daily');
  List<Reminder> dates() =>
      rows().where((r) => r.details.planId == 'daily').toList()
        ..sort((a, b) => a.eventTime!.compareTo(b.eventTime!));
  Future<void> save() async {
    final built = plan().schedule(start);
    await notifier().saveRoutine(
      built.owner,
      built.occurrences,
      database.captureGeneration(),
      now: start,
    );
  }

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp(
      'departure-refill-reopen-',
    );
    await open();
  });
  tearDown(() async {
    container.dispose();
    await database.close(createBackup: false);
    await directory.delete(recursive: true);
  });

  test(
    'reopening preserves handled dates while replenishing missing future dates',
    () async {
      await save();
      final originalCount = dates().length;
      final first = dates().first, second = dates()[1];
      await notifier().completeOccurrence(first, now: first.eventTime);
      await notifier().snoozeOccurrence(
        second,
        now: second.triggerTime,
        duration: const Duration(minutes: 15),
      );
      final preserved = {
        for (final row in dates().take(2)) row.id: row.toJson(),
      };
      container.dispose();
      await database.close(createBackup: false);
      await open();
      final at = DateTime(start.year, start.month, start.day + 30, 6);
      await notifier().refreshDepartureSchedules(now: at);
      expect(dates().length, greaterThan(originalCount));
      for (final entry in preserved.entries) {
        expect(
          dates().singleWhere((r) => r.id == entry.key).toJson(),
          entry.value,
        );
      }
      final repeated = await notifier().refreshDepartureSchedules(now: at);
      expect(repeated.changed, 0);
      expect(rows().map((r) => r.id).toSet().length, rows().length);
    },
  );

  test(
    'a long absence creates a bounded future window without fabricated missed dates',
    () async {
      await save();
      final oldIds = dates().map((r) => r.id).toSet();
      final at = DateTime(2033, 1, 1, 6);
      await notifier().refreshDepartureSchedules(now: at);
      final inserted = dates().where((r) => !oldIds.contains(r.id)).toList();
      expect(inserted.length, DeparturePlan.rollingDays + 1);
      expect(inserted.every((r) => r.triggerTime!.isAfter(at)), isTrue);
      expect(dates().length, 2 * (DeparturePlan.rollingDays + 1));
      expect(oldIds.every((id) => dates().any((r) => r.id == id)), isTrue);
    },
  );

  test(
    'restoring a plan and refilling do not resurrect a separately deleted date',
    () async {
      await save();
      final removed = dates().first;
      await notifier().changeLifecycle(
        removed,
        'trash',
        database.captureGeneration(),
        now: start,
      );
      await notifier().changeLifecycle(
        owner(),
        'trash',
        database.captureGeneration(),
        now: start.add(const Duration(minutes: 1)),
      );
      await notifier().changeLifecycle(
        owner(),
        'restore',
        database.captureGeneration(),
        now: start.add(const Duration(minutes: 2)),
      );
      await notifier().refreshDepartureSchedules(now: start);
      expect(dates().singleWhere((r) => r.id == removed.id).isVisible, isFalse);
      expect(dates().skip(1).every((r) => r.isVisible), isTrue);
      expect(dates().length, DeparturePlan.rollingDays + 1);
    },
  );

  test(
    'skipping an independent departure date leaves tomorrow unchanged',
    () async {
      await save();
      final first = dates().first, next = dates()[1];
      expect(first.isRecurring, isFalse);
      final result = await notifier().skipOccurrence(
        first,
        now: first.triggerTime,
      );
      expect(result.disposition, ReminderActionDisposition.applied);
      final saved = dates().first;
      expect(saved.isCompleted, isTrue);
      expect(saved.details.history.last.action, 'skipped');
      expect(dates()[1].toJson(), next.toJson());
      expect(owner().isCompleted, isFalse);
    },
  );

  test(
    'skipping a medication date records not taken and keeps the next dose',
    () async {
      final medication = MedicationPlan(
        id: 'course',
        title: 'Fixture course',
        person: 'Fixture',
        start: start,
        end: DateTime(2032, 1, 2),
        medicines: [
          Medicine(
            id: 'dose',
            name: 'Fixture',
            strength: 'fixture',
            amount: '1',
            unit: 'fixture',
            meal: 'fixture',
            times: ['08:00'],
            evidence: 'Synthetic',
          ),
        ],
      ).build(now: start);
      await notifier().saveRoutine(
        medication.owner,
        medication.doses,
        database.captureGeneration(),
        now: start,
      );
      final first = rows().singleWhere(
        (r) => r.id == medication.doses.first.id,
      );
      final next = rows().singleWhere((r) => r.id == medication.doses[1].id);
      await notifier().skipOccurrence(first, now: first.triggerTime);
      final saved = rows().singleWhere((r) => r.id == first.id);
      expect(saved.isCompleted, isTrue);
      expect(saved.details.effectiveDoseOutcome, 'not_taken');
      expect(
        rows().singleWhere((r) => r.id == next.id).toJson(),
        next.toJson(),
      );
    },
  );

  test(
    'calendar refill keeps local departure time across daylight saving boundaries',
    () {
      for (final at in [DateTime(2032, 3, 1, 6), DateTime(2032, 10, 25, 6)]) {
        final scheduled = plan().schedule(at).occurrences;
        for (var i = 0; i < scheduled.length; i++) {
          expect(scheduled[i].eventTime!.hour, 8);
          expect(scheduled[i].eventTime!.minute, 0);
          expect(scheduled[i].triggerTime!.hour, 7);
          expect(scheduled[i].triggerTime!.minute, 50);
          if (i > 0) {
            final before = scheduled[i - 1].eventTime!,
                after = scheduled[i].eventTime!;
            expect(
              DateTime.utc(after.year, after.month, after.day)
                  .difference(
                    DateTime.utc(before.year, before.month, before.day),
                  )
                  .inDays,
              1,
            );
          }
        }
      }
    },
  );
}
