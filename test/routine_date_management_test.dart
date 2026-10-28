import 'package:dont_forget/models/ordinary_series.dart';
import 'package:dont_forget/models/routine_date.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final at = DateTime(2030, 1, 7, 6), past = DateTime(2030, 1, 10, 10);
  late OfflineManagementHarness h;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
    await h.notifier.saveOrdinarySeries(
      Reminder(
        id: 'plan',
        taskTitle: 'Fixture',
        quadrantLevel: 2,
        triggerTime: DateTime(2030, 1, 7, 8),
        isRecurring: true,
        recurrenceRule: 'daily',
      ),
      h.database.captureGeneration(),
      now: at,
    );
  });
  tearDown(() async => h.dispose());
  Future<Reminder> parent() => h.row('plan');
  Future<Reminder> day(int n) =>
      h.row('plan:ordinary:2030-01-${n.toString().padLeft(2, '0')}');
  test(
    'completion records actual operation time and original schedule without shifting siblings',
    () async {
      final child = await day(7), next = (await day(8)).toJson();
      await h.notifier.changeRoutineDate(
        child,
        await parent(),
        'complete',
        h.database.captureGeneration(),
        now: past,
      );
      final saved = await day(7);
      expect(saved.isCompleted, true);
      expect(saved.details.completedAt, past);
      expect(saved.details.history.last.scheduled, DateTime(2030, 1, 7, 8));
      expect((await day(8)).toJson(), next);
      expect((await parent()).isCompleted, false);
    },
  );
  test(
    'reopen, individual removal and restore keep the original date identity',
    () async {
      var child = await day(7);
      final id = child.id;
      for (final action in ['skip', 'reopen', 'trash', 'restore']) {
        await h.notifier.changeRoutineDate(
          child,
          await parent(),
          action,
          h.database.captureGeneration(),
          now: past,
        );
        child = await day(7);
        expect(child.id, id);
      }
      expect(child.isCompleted, false);
      expect(child.isVisible, true);
      expect(child.triggerTime, DateTime(2030, 1, 7, 8));
      expect(child.details.history.map((e) => e.action), [
        'skipped',
        'reopened',
        'trash',
        'restore',
      ]);
      final rows = await h.rows();
      expect(rows.length, 62);
      expect((await h.notifier.refreshOrdinarySchedules(now: at)).changed, 0);
    },
  );
  test(
    'stale child or parent is rejected without changing another date',
    () async {
      final child = await day(7), owner = await parent();
      await h.notifier.changeRoutineDate(
        child,
        owner,
        'skip',
        h.database.captureGeneration(),
        now: past,
      );
      await expectLater(
        h.notifier.changeRoutineDate(
          child,
          owner,
          'complete',
          h.database.captureGeneration(),
          now: past,
        ),
        throwsA(isA<StaleReminderOccurrenceException>()),
      );
      final current = await day(8);
      await h.notifier.updateReminderForGeneration(
        owner.copyWith(taskTitle: 'Changed'),
        h.database.captureGeneration(),
        baseline: owner,
      );
      await expectLater(
        h.notifier.changeRoutineDate(
          current,
          owner,
          'complete',
          h.database.captureGeneration(),
          now: past,
        ),
        throwsA(isA<StaleReminderOccurrenceException>()),
      );
      expect((await day(8)).isCompleted, false);
    },
  );
  for (final action in ['pause', 'trash', 'archive']) {
    test(
      '$action parent blocks single-day mutation without implicitly restoring the plan',
      () async {
        if (action == 'archive') {
          final owner = await parent();
          await h.notifier.changeContentArchive(
            owner,
            (await h.rows()).where((e) => e.details.planId == 'plan').toList(),
            true,
            h.database.captureGeneration(),
          );
        } else {
          await h.notifier.changeLifecycle(
            await parent(),
            action,
            h.database.captureGeneration(),
          );
        }
        final owner = await parent(),
            child = await day(7),
            before = child.toJson();
        await expectLater(
          h.notifier.changeRoutineDate(
            child,
            owner,
            action == 'trash' ? 'restore' : 'complete',
            h.database.captureGeneration(),
            now: past,
          ),
          throwsA(isA<StaleReminderOccurrenceException>()),
        );
        expect((await day(7)).toJson(), before);
      },
    );
  }
  test(
    'medication outcomes cannot be changed through generic history actions',
    () async {
      final owner = Reminder(
        id: 'med-parent',
        taskTitle: 'Course',
        quadrantLevel: 2,
        detailsJson: const TaskDetails(kind: 'medicationPlan').encode(),
      );
      final child = Reminder(
        id: 'med-dose',
        taskTitle: 'Dose',
        quadrantLevel: 2,
        eventTime: at,
        triggerTime: at,
        detailsJson: const TaskDetails(
          kind: 'medication',
          planId: 'med-parent',
        ).encode(),
      );
      await h.seed(owner);
      await h.seed(child);
      await expectLater(
        h.notifier.changeRoutineDate(
          child,
          owner,
          'complete',
          h.database.captureGeneration(),
          now: past,
        ),
        throwsA(isA<StaleReminderOccurrenceException>()),
      );
      expect((await h.row(child.id)).details.actualDoseTakenAt, isNull);
    },
  );
  test(
    'native failure preserves the business change and leaves siblings unchanged',
    () async {
      final child = await day(7), next = (await day(8)).toJson();
      h.notifications.fail = true;
      final result = await h.notifier.changeRoutineDate(
        child,
        await parent(),
        'complete',
        h.database.captureGeneration(),
        now: past,
      );
      expect(result.nativeSyncFailed, true);
      expect((await day(7)).isCompleted, true);
      expect((await day(8)).toJson(), next);
    },
  );
  test(
    'old data-generation controllers cannot mutate a date after recovery',
    () async {
      final old = h.database.captureGeneration(),
          child = await day(7),
          owner = await parent();
      final lease = await h.database.beginMaintenance();
      await lease.resume();
      await expectLater(
        h.notifier.changeRoutineDate(child, owner, 'skip', old, now: past),
        throwsException,
      );
      expect((await day(7)).isCompleted, false);
    },
  );
  test(
    'reopening an overdue date cancels old requests instead of replaying them',
    () async {
      await h.notifier.changeRoutineDate(
        await day(7),
        await parent(),
        'complete',
        h.database.captureGeneration(),
        now: past,
      );
      h.notifications.scheduled.clear();
      h.notifications.cancelled.clear();
      await h.notifier.changeRoutineDate(
        await day(7),
        await parent(),
        'reopen',
        h.database.captureGeneration(),
        now: past,
      );
      expect(h.notifications.scheduled, isEmpty);
      expect(h.notifications.cancelled, [(await day(7)).id]);
    },
  );
  test(
    'filters are inclusive, keep unprocessed overdue dates honest and follow the original snoozed date',
    () async {
      await h.notifier.snoozeOccurrence(
        await day(7),
        now: DateTime(2030, 1, 7, 8),
        duration: const Duration(days: 20),
      );
      await h.notifier.changeRoutineDate(
        await day(8),
        await parent(),
        'skip',
        h.database.captureGeneration(),
        now: past,
      );
      await h.notifier.changeRoutineDate(
        await day(9),
        await parent(),
        'trash',
        h.database.captureGeneration(),
        now: past,
      );
      final rows = await h.rows();
      final pastDates = RoutineDate.select(rows, 'plan', past);
      expect(pastDates.map((r) => r.dateKey), [
        '2030-01-10',
        '2030-01-09',
        '2030-01-08',
        '2030-01-07',
      ]);
      expect(
        RoutineDate.select(
          rows,
          'plan',
          past,
          status: 'pending',
        ).map((r) => r.dateKey),
        ['2030-01-10', '2030-01-07'],
      );
      expect(
        RoutineDate.select(rows, 'plan', past, status: 'handled').single.row.id,
        (await day(8)).id,
      );
      expect(
        RoutineDate.select(rows, 'plan', past, status: 'removed').single.row.id,
        (await day(9)).id,
      );
      expect(
        RoutineDate.select(
          rows,
          'plan',
          past,
          from: DateTime(2030, 1, 8),
          to: DateTime(2030, 1, 8),
        ).single.dateKey,
        '2030-01-08',
      );
      expect(
        RoutineDate.select(rows, 'plan', past, query: '01-10').single.dateKey,
        '2030-01-10',
      );
      expect(RoutineDate.select(rows, 'other', past), isEmpty);
      expect(rows.where(OrdinarySeries.isOccurrence).length, 61);
    },
  );
}
