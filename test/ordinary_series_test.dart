import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/models/calendar_exceptions.dart';
import 'package:dont_forget/models/holiday_calendar.dart';
import 'package:dont_forget/models/ordinary_series.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/offline_management_harness.dart';

Reminder task(
  DateTime due, {
  String rule = 'daily',
  RepeatWindow? repeat,
  HolidayPolicy policy = const HolidayPolicy(),
}) => Reminder(
  id: 'ordinary',
  taskTitle: 'Fixture routine',
  quadrantLevel: 2,
  triggerTime: due,
  eventTime: due.add(const Duration(minutes: 20)),
  isRecurring: true,
  recurrenceRule: rule,
  detailsJson: TaskDetails(
    repeat: repeat,
    tags: const ['fixture'],
    project: 'demo',
    checklist: const [ChecklistItem('keys', 'Keys', done: true)],
    data: {if (policy.mode != 'none') 'holiday_policy': policy.toJson()},
  ).encode(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final at = DateTime(2026, 10, 8, 6);
  final due = DateTime(2026, 10, 8, 8);
  test(
    'independent dates retain stable IDs, metadata, event offset and reset checklists',
    () {
      final schedule = OrdinarySeries.schedule(task(due), at);
      expect(schedule.owner.isWorkspaceItem, false);
      expect(schedule.owner.canNotify, false);
      expect(schedule.occurrences.length, 61);
      expect(schedule.occurrences.first.id, 'ordinary:ordinary:2026-10-08');
      expect(
        schedule.occurrences.every(
          (r) => r.canSkipOccurrence && !r.isRecurring,
        ),
        true,
      );
      expect(schedule.occurrences.first.details.checklist.single.done, false);
      expect(schedule.occurrences.first.details.project, 'demo');
      expect(
        schedule.occurrences.first.eventTime!.difference(due),
        const Duration(minutes: 20),
      );
      expect(OrdinarySeries.template(schedule.owner).triggerTime, due);
      expect(
        TaskDetails.decode(schedule.owner.detailsJson).toJson()['version'],
        4,
      );
      final more = OrdinarySeries.schedule(
        OrdinarySeries.template(schedule.owner),
        DateTime(2026, 10, 9, 6),
      );
      expect(more.occurrences.first.id, schedule.occurrences[1].id);
    },
  );
  for (final rule in ['daily', 'weekly', 'monthly', 'yearly']) {
    test('$rule interval stays anchored across rolling windows', () {
      final anchor = DateTime(2024, 1, 31, 8);
      final row = task(
        anchor,
        rule: rule,
        repeat: const RepeatWindow(interval: 2),
      );
      final first = OrdinarySeries.schedule(row, DateTime(2026, 1, 1));
      final later = OrdinarySeries.schedule(
        OrdinarySeries.template(first.owner),
        DateTime(2026, 1, 15),
      );
      final overlap = first.occurrences
          .where((r) => r.triggerTime!.isAfter(DateTime(2026, 1, 15)))
          .map((r) => r.id)
          .toSet();
      expect(
        later.occurrences.map((r) => r.id).toSet().containsAll(overlap),
        true,
      );
      expect(first.occurrences.length, lessThanOrEqualTo(61));
    });
  }
  test(
    'workday makeup, holiday exclusion and explicit exceptions are ordered',
    () {
      final row = task(
        DateTime(2026, 9, 28, 8),
        rule: 'workday',
        policy: HolidayPolicy(
          mode: 'workdays',
          calendar: HolidayCalendar.mainland2026,
        ),
        repeat: const RepeatWindow(
          exceptions: CalendarExceptions(
            skip: ['2026-10-10'],
            add: ['2026-10-01'],
          ),
        ),
      );
      final days = OrdinarySeries.schedule(
        row,
        DateTime(2026, 9, 30, 10),
      ).occurrences.map((r) => CalendarExceptions.key(r.triggerTime!)).toList();
      expect(days, contains('2026-10-01'));
      expect(days, isNot(contains('2026-10-02')));
      expect(days, isNot(contains('2026-10-10')));
      expect(days, contains('2026-10-08'));
      final makeup = OrdinarySeries.schedule(
        task(
          DateTime(2026, 10, 10, 8),
          rule: 'workday',
          policy: HolidayPolicy(
            mode: 'workdays',
            calendar: HolidayCalendar.mainland2026,
          ),
        ),
        DateTime(2026, 10, 10, 6),
      );
      expect(makeup.occurrences.first.triggerTime!.day, 10);
    },
  );
  test(
    'calendar never bypasses repeat start/end or fabricates missing years',
    () {
      final row = task(
        DateTime(2026, 12, 20, 8),
        rule: 'workday',
        policy: HolidayPolicy(
          mode: 'workdays',
          calendar: HolidayCalendar.mainland2026,
        ),
        repeat: RepeatWindow(
          start: DateTime(2026, 12, 28),
          end: DateTime(2027, 1, 5),
        ),
      );
      final result = OrdinarySeries.schedule(row, DateTime(2026, 12, 20));
      expect(
        result.occurrences.every(
          (r) =>
              !r.triggerTime!.isBefore(DateTime(2026, 12, 28)) &&
              r.triggerTime!.year == 2026,
        ),
        true,
      );
      final missing = OrdinarySeries.schedule(
        OrdinarySeries.template(result.owner),
        DateTime(2027, 1, 1),
      );
      expect(missing.occurrences, isEmpty);
      expect(missing.owner.isCompleted, false);
    },
  );
  test(
    'local wall clock remains fixed across DST and UTC anchors retain fractional seconds',
    () {
      final local = OrdinarySeries.schedule(
        task(DateTime(2026, 10, 30, 8)),
        DateTime(2026, 10, 30),
      );
      expect(local.occurrences.every((r) => r.triggerTime!.hour == 8), true);
      final utc = DateTime.utc(2026, 10, 8, 8, 1, 2, 300, 400);
      final result = OrdinarySeries.schedule(
        task(utc),
        DateTime.utc(2026, 10, 8, 6),
      );
      expect(result.occurrences.first.triggerTime, utc);
      expect(
        result.occurrences.every(
          (r) => r.triggerTime!.isUtc && r.triggerTime!.microsecond == 400,
        ),
        true,
      );
    },
  );
  test(
    'alarm and event retain separate local wall clocks across a DST transition',
    () {
      final row = task(
        DateTime(2026, 10, 31, 1, 50),
      ).copyWith(eventTime: DateTime(2026, 10, 31, 3, 5));
      final result = OrdinarySeries.schedule(row, DateTime(2026, 10, 31));
      expect(
        result.occurrences.every(
          (r) =>
              r.triggerTime!.hour == 1 &&
              r.triggerTime!.minute == 50 &&
              r.eventTime!.hour == 3 &&
              r.eventTime!.minute == 5,
        ),
        true,
      );
    },
  );

  group('durable independent dates', () {
    late OfflineManagementHarness h;
    setUp(() async {
      h = OfflineManagementHarness();
      await h.create();
    });
    tearDown(() async => h.dispose());
    Future<void> save() => h.notifier.saveOrdinarySeries(
      task(due),
      h.database.captureGeneration(),
      now: at,
    );
    Future<List<Reminder>> dates() async =>
        (await h.rows()).where(OrdinarySeries.isOccurrence).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    test(
      'complete, skip and snooze affect only their date; stale replay is rejected',
      () async {
        await save();
        final rows = await dates();
        final untouched = rows[3].toJson();
        await h.notifier.completeOccurrence(rows[0], now: due);
        await h.notifier.skipOccurrence(rows[1], now: rows[1].triggerTime);
        await h.notifier.snoozeOccurrence(rows[2], now: rows[2].triggerTime);
        expect((await h.row(rows[0].id)).isCompleted, true);
        expect(
          (await h.row(rows[1].id)).details.history.last.action,
          'skipped',
        );
        expect((await h.row(rows[2].id)).snoozedAt, isNotNull);
        expect((await h.row(rows[3].id)).toJson(), untouched);
        expect(
          (await h.notifier.completeOccurrence(rows[0], now: due)).disposition,
          ReminderActionDisposition.stale,
        );
        expect((await h.row('ordinary')).isCompleted, false);
      },
    );
    test(
      'restart and long-absence refill retain acted and missed dates without duplicates',
      () async {
        await save();
        final rows = await dates();
        await h.notifier.completeOccurrence(rows.first, now: due);
        final retained = (await h.row(rows.first.id)).toJson();
        await h.close();
        await h.open();
        final later = DateTime(2027, 3, 1, 6);
        await h.notifier.refreshOrdinarySchedules(now: later);
        expect((await h.row(rows.first.id)).toJson(), retained);
        expect((await h.row(rows[1].id)).isCompleted, false);
        expect((await dates()).length, 122);
        expect(
          (await h.notifier.refreshOrdinarySchedules(now: later)).changed,
          0,
        );
      },
    );
    test(
      'preview edit preserves snoozed, completed and overdue dates, replaces only untouched future dates',
      () async {
        await save();
        final rows = await dates();
        await h.notifier.completeOccurrence(rows[0], now: due);
        await h.notifier.snoozeOccurrence(rows[1], now: rows[1].triggerTime);
        final protected = {
          for (final r in await dates())
            if (r.id == rows[0].id || r.id == rows[1].id || r.id == rows[2].id)
              r.id: r.toJson(),
        };
        final owner = await h.row('ordinary');
        final edited = OrdinarySeries.template(owner).copyWith(
          triggerTime: DateTime(2026, 10, 8, 9),
          eventTime: DateTime(2026, 10, 8, 9, 20),
          recurrenceAnchorTime: null,
        );
        await h.notifier.saveOrdinarySeries(
          edited,
          h.database.captureGeneration(),
          baseline: owner,
          now: DateTime(2026, 10, 10, 10),
        );
        for (final e in protected.entries) {
          expect((await h.row(e.key)).toJson(), e.value);
        }
        expect((await h.row(rows[3].id)).triggerTime!.hour, 9);
        await expectLater(
          h.notifier.saveOrdinarySeries(
            edited,
            h.database.captureGeneration(),
            baseline: owner,
            now: at,
          ),
          throwsA(isA<StaleReminderOccurrenceException>()),
        );
      },
    );
    test(
      'stale edits and legacy unresolved conversions do not mutate saved data',
      () async {
        await save();
        final baseline = await h.row('ordinary');
        await h.notifier.changeLifecycle(
          baseline,
          'pause',
          h.database.captureGeneration(),
        );
        await expectLater(
          h.notifier.saveOrdinarySeries(
            OrdinarySeries.template(baseline),
            h.database.captureGeneration(),
            baseline: baseline,
            now: at,
          ),
          throwsA(isA<StaleReminderOccurrenceException>()),
        );
        final legacy = task(due);
        await h.notifier.changeLifecycle(
          await h.row('ordinary'),
          'trash',
          h.database.captureGeneration(),
        );
        expect(
          () => h.notifier.saveOrdinarySeries(
            legacy,
            h.database.captureGeneration(),
            baseline: legacy,
            now: due,
          ),
          throwsFormatException,
        );
      },
    );
    test(
      'independent owners cannot complete and dated children cannot enable serial recurrence',
      () async {
        await save();
        final owner = await h.row('ordinary');
        final child = (await dates()).first;
        expect(
          (await h.notifier.completeOccurrence(owner, now: at)).disposition,
          ReminderActionDisposition.stale,
        );
        await expectLater(
          h.notifier.updateReminderForGeneration(
            child.copyWith(isRecurring: true, recurrenceRule: 'daily'),
            h.database.captureGeneration(),
            baseline: child,
          ),
          throwsStateError,
        );
        expect((await h.row(child.id)).isRecurring, false);
      },
    );
    for (final format in ['json', 'sqlite']) {
      test(
        '$format actual restore preserves independent date identities and v4 calendar policy',
        () async {
          final row = task(
            due,
            rule: 'workday',
            policy: HolidayPolicy(
              mode: 'workdays',
              calendar: HolidayCalendar.mainland2026,
            ),
          );
          await h.notifier.saveOrdinarySeries(
            row,
            h.database.captureGeneration(),
            now: at,
          );
          final first = (await dates()).first;
          await h.notifier.skipOccurrence(first, now: first.triggerTime);
          final before = (await h.rows()).map((r) => r.toJson()).toList();
          await h.database.createMirrorBackup();
          final source = await File(
            '${h.directory.path}/${format == 'json' ? 'ha_snapshot.json' : 'dont_forget_v3.mirror.db'}',
          ).copy('${h.directory.path}/source-$format');
          final inspector = BackupInspector(databaseFactoryFfi);
          final preview = await inspector.inspect(source);
          await h.seed(
            Reminder(id: 'later', taskTitle: 'Later', quadrantLevel: 2),
          );
          await DatabaseRecovery(
            h.database,
            inspector: inspector,
            notifications: NotificationService.forTesting(
              FlutterLocalNotificationsPlugin(),
              usesNativeNotifications: false,
            ),
          ).restore(source, expectedDigest: preview.digest);
          expect((await h.rows()).map((r) => r.toJson()).toList(), before);
          await h.close();
          await h.open();
          expect((await h.rows()).map((r) => r.toJson()).toList(), before);
          expect(
            (await h.row(first.id)).details.history.last.action,
            'skipped',
          );
        },
      );
    }
    test(
      'pause and trash propagate and suppress refill until restored',
      () async {
        await save();
        await h.notifier.changeLifecycle(
          await h.row('ordinary'),
          'pause',
          h.database.captureGeneration(),
        );
        expect((await dates()).every((r) => r.details.paused), true);
        expect(
          (await h.notifier.refreshOrdinarySchedules(
            now: DateTime(2027, 1, 1),
          )).changed,
          0,
        );
        await h.notifier.changeLifecycle(
          await h.row('ordinary'),
          'resume',
          h.database.captureGeneration(),
        );
        expect((await dates()).any((r) => r.details.paused), false);
        await h.notifier.changeLifecycle(
          await h.row('ordinary'),
          'trash',
          h.database.captureGeneration(),
        );
        expect((await dates()).every((r) => !r.isVisible), true);
      },
    );
    test(
      'native failures preserve committed dates and are reported separately',
      () async {
        h.notifications.fail = true;
        final result = await h.notifier.saveOrdinarySeries(
          task(due),
          h.database.captureGeneration(),
          now: at,
        );
        expect(result.nativeSyncFailures, greaterThan(0));
        expect((await dates()).length, 61);
      },
    );
    test(
      'removing an exception restores only system-replaced dates and never user-deleted dates',
      () async {
        await save();
        final rows = await dates();
        await h.notifier.changeLifecycle(
          rows[2],
          'trash',
          h.database.captureGeneration(),
          now: at,
        );
        var owner = await h.row('ordinary');
        var draft = OrdinarySeries.template(owner);
        draft = draft.copyWith(
          detailsJson: draft.details.patch({
            'repeat': const RepeatWindow(
              exceptions: CalendarExceptions(
                skip: ['2026-10-09', '2026-10-10'],
              ),
            ).toJson(),
          }).encode(),
        );
        await h.notifier.saveOrdinarySeries(
          draft,
          h.database.captureGeneration(),
          baseline: owner,
          now: at,
        );
        expect((await h.row(rows[1].id)).isVisible, false);
        owner = await h.row('ordinary');
        draft = OrdinarySeries.template(owner);
        draft = draft.copyWith(
          detailsJson: draft.details.patch({
            'repeat': const RepeatWindow().toJson(),
          }).encode(),
        );
        await h.notifier.saveOrdinarySeries(
          draft,
          h.database.captureGeneration(),
          baseline: owner,
          now: at,
        );
        expect((await h.row(rows[1].id)).isVisible, true);
        expect((await h.row(rows[2].id)).isVisible, false);
      },
    );
    test(
      'a paused plan can change its future time and resumes with that time',
      () async {
        await save();
        await h.notifier.changeLifecycle(
          await h.row('ordinary'),
          'pause',
          h.database.captureGeneration(),
          now: at,
        );
        final owner = await h.row('ordinary');
        final draft = OrdinarySeries.template(owner).copyWith(
          triggerTime: DateTime(2026, 10, 8, 9),
          eventTime: DateTime(2026, 10, 8, 9, 20),
          recurrenceAnchorTime: null,
        );
        await h.notifier.saveOrdinarySeries(
          draft,
          h.database.captureGeneration(),
          baseline: owner,
          now: at,
        );
        expect(
          (await dates())
              .where((r) => r.isVisible)
              .every((r) => r.triggerTime!.hour == 9 && r.details.paused),
          true,
        );
        await h.notifier.changeLifecycle(
          await h.row('ordinary'),
          'resume',
          h.database.captureGeneration(),
          now: at,
        );
        expect(
          (await dates())
              .where((r) => r.isVisible)
              .every((r) => r.triggerTime!.hour == 9 && !r.details.paused),
          true,
        );
      },
    );
    test(
      'a partially checked future date retains the user edits during plan changes',
      () async {
        await save();
        final row = (await dates())[1];
        await h.notifier.setChecklistItem(
          row,
          'keys',
          true,
          h.database.captureGeneration(),
        );
        final protected = (await h.row(row.id)).toJson();
        final owner = await h.row('ordinary');
        await h.notifier.saveOrdinarySeries(
          OrdinarySeries.template(owner).copyWith(taskTitle: 'Changed title'),
          h.database.captureGeneration(),
          baseline: owner,
          now: at,
        );
        expect((await h.row(row.id)).toJson(), protected);
      },
    );
    test(
      'backup preview accepts complete series and rejects orphaned or renamed dates',
      () async {
        await save();
        await h.database.createMirrorBackup();
        final source = h.directory
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .firstWhere(
              (f) =>
                  jsonDecode(f.readAsStringSync()) is Map &&
                  (jsonDecode(f.readAsStringSync()) as Map).containsKey(
                    'reminders',
                  ),
            );
        final inspector = BackupInspector(databaseFactoryFfi);
        expect((await inspector.inspect(source)).counts['reminders'], 62);
        final raw =
            jsonDecode(await source.readAsString()) as Map<String, dynamic>;
        (raw['reminders'] as List).removeWhere((r) => r['id'] == 'ordinary');
        final bad = File('${h.directory.path}/bad-independent.json');
        await bad.writeAsString(jsonEncode(raw));
        await expectLater(
          inspector.inspect(bad),
          throwsA(isA<BackupInspectionException>()),
        );
      },
    );
  });
}
