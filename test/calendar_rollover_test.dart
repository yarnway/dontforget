import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/models/holiday_calendar.dart';
import 'package:dont_forget/models/calendar_exceptions.dart';
import 'package:dont_forget/models/departure_plan.dart';
import 'package:dont_forget/services/backup_file_exporter.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/holiday_calendar_file_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/offline_management_harness.dart';

HolidayCalendar fixtureYear(
  int year, {
  List<String> off = const [],
  String? id,
}) => HolidayCalendar.fromJson({
  'version': 1,
  'id': id ?? 'synthetic-$year',
  'region': 'CN',
  'from': '$year-01-01',
  'to': '$year-12-31',
  'source': 'https://example.test/synthetic-calendar/$year',
  'holidays': off,
  'workdays': <String>[],
});
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'new year preserves both sources, canonical roundtrip and repeat imports',
    () {
      final old = HolidayCalendar.mainland2026,
          next = fixtureYear(2027, off: ['2027-01-01']);
      final book = old.merge(next);
      expect(book.snapshots.map((e) => e.id), [old.id, next.id]);
      expect(book.snapshots.first.source, old.source);
      expect(book.snapshots.last.source, next.source);
      expect(book.toJson()['version'], 2);
      expect(
        HolidayCalendar.decode(jsonEncode(book.toJson())).toJson(),
        book.toJson(),
      );
      expect(book.merge(next).toJson(), book.toJson());
      expect(book.merge(old).toJson(), book.toJson());
    },
  );
  test('gaps and uncovered years never become implicitly covered', () {
    final book = fixtureYear(2026).merge(fixtureYear(2028));
    expect(book.covers(DateTime(2027, 1, 1)), false);
    expect(book.missingYears(DateTime(2026, 12, 30)), [2027]);
    final policy = HolidayPolicy(mode: 'workdays', calendar: book);
    expect(
      policy.permits(DateTime(2027, 1, 4), true, const CalendarExceptions()),
      false,
    );
  });
  test(
    'overlap requires explicit replacement and leaves other years intact',
    () {
      final book = fixtureYear(2026).merge(fixtureYear(2027));
      final update = fixtureYear(2027, id: 'revised-2027', off: ['2027-01-01']);
      expect(() => book.merge(update), throwsA(isA<CalendarUpdateConflict>()));
      final changed = book.merge(update, replaceOverlaps: true);
      expect(changed.snapshots.map((e) => e.id), [
        'synthetic-2026',
        'revised-2027',
      ]);
      expect(book.snapshots.last.holidays, isEmpty);
    },
  );
  test(
    'partial overlap, region mismatch, ID reuse, nested and excessive bundles reject',
    () {
      final book = fixtureYear(2026).merge(fixtureYear(2027));
      final partial = HolidayCalendar.fromJson({
        ...fixtureYear(2027).toJson(),
        'from': '2027-06-01',
      });
      expect(
        () => book.merge(partial, replaceOverlaps: true),
        throwsFormatException,
      );
      expect(
        () => book.merge(
          HolidayCalendar.fromJson({
            ...fixtureYear(2028).toJson(),
            'region': 'JP',
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => fixtureYear(2026).merge(fixtureYear(2027, id: 'synthetic-2026')),
        throwsFormatException,
      );
      expect(
        () => HolidayCalendar.fromJson({
          'version': 2,
          'snapshots': [book.toJson(), fixtureYear(2028).toJson()],
        }),
        throwsFormatException,
      );
      expect(
        () => HolidayCalendar.fromJson({
          'version': 2,
          'snapshots': [
            for (var y = 2026; y < 2031; y++) fixtureYear(y).toJson(),
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => HolidayCalendar.fromJson({
          'version': 2.0,
          'snapshots': book.snapshots.map((e) => e.toJson()).toList(),
        }),
        throwsFormatException,
      );
    },
  );
  test('bundle fences v4 readers while a single snapshot retains v4', () {
    final single = TaskDetails(
      data: {
        'holiday_policy': HolidayPolicy(
          mode: 'skip_holidays',
          calendar: fixtureYear(2026),
        ).toJson(),
      },
    );
    expect(single.toJson()['version'], 4);
    final advanced = single.patch({
      'data': {
        'holiday_policy': HolidayPolicy(
          mode: 'skip_holidays',
          calendar: fixtureYear(2026).merge(fixtureYear(2027)),
        ).toJson(),
      },
    });
    expect(advanced.toJson()['version'], 5);
    expect(
      () =>
          TaskDetails.decode(jsonEncode({...advanced.toJson(), 'version': 4})),
      throwsFormatException,
    );
  });
  group('database rollover', () {
    late OfflineManagementHarness h;
    final at = DateTime(2026, 12, 30, 6);
    setUp(() async {
      h = OfflineManagementHarness();
      await h.create();
    });
    tearDown(() async => h.dispose());
    Reminder template(HolidayCalendar calendar) => Reminder(
      id: 'year',
      taskTitle: 'Synthetic daily',
      quadrantLevel: 2,
      triggerTime: DateTime(2026, 12, 28, 8),
      isRecurring: true,
      recurrenceRule: 'daily',
      detailsJson: TaskDetails(
        data: {
          'holiday_policy': HolidayPolicy(
            mode: 'skip_holidays',
            calendar: calendar,
          ).toJson(),
        },
      ).encode(),
    );
    test(
      'confirmed update fills January and preserves acted December dates',
      () async {
        await h.notifier.saveOrdinarySeries(
          template(fixtureYear(2026)),
          h.database.captureGeneration(),
          now: at,
        );
        final first = await h.row('year:ordinary:2026-12-30');
        await h.notifier.completeOccurrence(first, now: at);
        final protected = (await h.row(first.id)).toJson(),
            parent = await h.row('year');
        final combined = fixtureYear(
          2026,
        ).merge(fixtureYear(2027, off: ['2027-01-01']));
        await h.notifier.saveOrdinarySeries(
          template(combined),
          h.database.captureGeneration(),
          baseline: parent,
          now: at,
        );
        final rows = await h.rows();
        expect((await h.row(first.id)).toJson(), protected);
        expect(rows.any((r) => r.id == 'year:ordinary:2027-01-01'), false);
        expect(rows.any((r) => r.id == 'year:ordinary:2027-01-02'), true);
        expect((await h.notifier.refreshOrdinarySchedules(now: at)).changed, 0);
        expect(rows.map((r) => r.id).toSet().length, rows.length);
      },
    );
    for (final format in ['json', 'sqlite']) {
      test(
        '$format actual recovery and reopen retain v5 sources and individual history',
        () async {
          await h.notifier.saveOrdinarySeries(
            template(fixtureYear(2026).merge(fixtureYear(2027))),
            h.database.captureGeneration(),
            now: at,
          );
          final owner = await h.row('year'),
              child = await h.row('year:ordinary:2026-12-30');
          await h.notifier.changeRoutineDate(
            child,
            owner,
            'skip',
            h.database.captureGeneration(),
            now: at,
          );
          final before = (await h.rows()).map((r) => r.toJson()).toList();
          await h.database.createMirrorBackup();
          final source = await File(
            '${h.directory.path}/${format == 'json' ? 'ha_snapshot.json' : 'dont_forget_v3.mirror.db'}',
          ).copy('${h.directory.path}/input-$format');
          final inspector = BackupInspector(databaseFactoryFfi),
              preview = await BackupInspector(
                databaseFactoryFfi,
              ).inspect(source);
          await h.seed(
            Reminder(id: 'extra', taskTitle: 'Extra', quadrantLevel: 2),
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
        },
      );
    }
    test(
      'departure calendar edits preserve snoozed and user-removed dates and keep a paused plan paused',
      () async {
        final initial = DeparturePlan(
          id: 'commute',
          title: 'Synthetic commute',
          weekdays: const [1, 2, 3, 4, 5, 6, 7],
          items: const [ChecklistItem('keys', 'Keys')],
          holidayPolicy: HolidayPolicy(
            mode: 'skip_holidays',
            calendar: fixtureYear(2026),
          ),
        );
        final schedule = initial.schedule(at);
        await h.notifier.saveRoutine(
          schedule.owner,
          schedule.occurrences,
          h.database.captureGeneration(),
          now: at,
        );
        final first = await h.row('commute:departure:2026-12-30');
        await h.notifier.snoozeOccurrence(first, now: first.triggerTime);
        final removed = await h.row('commute:departure:2026-12-31');
        await h.notifier.changeRoutineDate(
          removed,
          await h.row('commute'),
          'trash',
          h.database.captureGeneration(),
          now: at,
        );
        final preserved = {
          for (final id in [first.id, removed.id])
            id: (await h.row(id)).toJson(),
        };
        final updated = initial
            .patch({
              'minute': 540,
              'holiday_policy': HolidayPolicy(
                mode: 'skip_holidays',
                calendar: fixtureYear(2026).merge(fixtureYear(2027)),
              ).toJson(),
            })
            .schedule(at);
        await h.notifier.saveRoutine(
          updated.owner,
          updated.occurrences,
          h.database.captureGeneration(),
          baseline: await h.row('commute'),
          now: at,
        );
        for (final e in preserved.entries) {
          expect((await h.row(e.key)).toJson(), e.value);
        }
        await h.notifier.changeLifecycle(
          await h.row('commute'),
          'pause',
          h.database.captureGeneration(),
          now: at,
        );
        final paused = await h.row('commute');
        final next = initial
            .patch({
              'minute': 600,
              'holiday_policy': HolidayPolicy(
                mode: 'skip_holidays',
                calendar: fixtureYear(2026).merge(fixtureYear(2027)),
              ).toJson(),
            })
            .schedule(at);
        await h.notifier.saveRoutine(
          next.owner,
          next.occurrences,
          h.database.captureGeneration(),
          baseline: paused,
          now: at,
        );
        expect((await h.row('commute')).details.paused, true);
        expect(
          (await h.row('commute:departure:2027-01-02')).details.paused,
          true,
        );
        expect(
          (await h.row('commute:departure:2027-01-02')).eventTime!.hour,
          10,
        );
      },
    );
  });
  test(
    'calendar files are bounded, strict, cancellable and do not follow file links',
    () async {
      final dir = await Directory.systemTemp.createTemp('calendar-files-');
      try {
        final file = await File('${dir.path}/book.json').writeAsString(
          jsonEncode(fixtureYear(2026).merge(fixtureYear(2027)).toJson()),
        );
        expect(
          (await HolidayCalendarFileService(
            pickPath: () async => file.path,
          ).pick())!.snapshots.length,
          2,
        );
        expect(
          await HolidayCalendarFileService(pickPath: () async => null).pick(),
          isNull,
        );
        final link = await Link('${dir.path}/alias.json').create(file.path);
        await expectLater(
          HolidayCalendarFileService(pickPath: () async => link.path).pick(),
          throwsFormatException,
        );
        await file.writeAsString(' ' * (HolidayCalendar.maxBytes + 1));
        await expectLater(
          HolidayCalendarFileService(pickPath: () async => file.path).pick(),
          throwsFormatException,
        );
        await file.writeAsBytes([255]);
        await expectLater(
          HolidayCalendarFileService(pickPath: () async => file.path).pick(),
          throwsFormatException,
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'export roundtrip keeps every source and removes only its temporary staging directory',
    () async {
      final dir = await Directory.systemTemp.createTemp('calendar-export-'),
          target = await Directory.systemTemp.createTemp(
            'calendar-destination-',
          );
      try {
        final book = fixtureYear(2026).merge(fixtureYear(2027));
        final files = HolidayCalendarFileService(
          temporaryDirectory: () async => dir,
          exporter: BackupFileExporter(
            useDirectoryPicker: true,
            pickDirectory: () async => target.path,
          ),
        );
        expect(await files.save(book), true);
        expect(dir.listSync(), isEmpty);
        final saved = target.listSync().whereType<File>().single;
        expect(
          (await HolidayCalendarFileService(
            pickPath: () async => saved.path,
          ).pick())!.toJson(),
          book.toJson(),
        );
        final cancel = HolidayCalendarFileService(
          temporaryDirectory: () async => dir,
          exporter: BackupFileExporter(
            useDirectoryPicker: true,
            pickDirectory: () async => null,
          ),
        );
        expect(await cancel.save(book), false);
        expect(dir.listSync(), isEmpty);
        expect(target.listSync(), hasLength(1));
      } finally {
        await dir.delete(recursive: true);
        await target.delete(recursive: true);
      }
    },
  );
}
