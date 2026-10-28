import 'dart:convert';
import 'package:dont_forget/models/calendar_exceptions.dart';
import 'package:dont_forget/models/departure_plan.dart';
import 'package:dont_forget/models/holiday_calendar.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final calendar = HolidayCalendar.mainland2026;
  test(
    'verified mainland 2026 snapshot contains all published ranges and six makeup days',
    () {
      expect(calendar.holidays.length, 33);
      expect(calendar.workdays, [
        '2026-01-04',
        '2026-02-14',
        '2026-02-28',
        '2026-05-09',
        '2026-09-20',
        '2026-10-10',
      ]);
      expect(
        calendar.holidays,
        containsAll([
          '2026-01-01',
          '2026-02-15',
          '2026-02-23',
          '2026-04-06',
          '2026-05-05',
          '2026-06-21',
          '2026-09-27',
          '2026-10-07',
        ]),
      );
      expect(calendar.covers(DateTime(2027, 1, 1)), false);
      expect(calendar.source, startsWith('https://www.gov.cn/'));
    },
  );
  test('strict snapshot roundtrip retains coverage and source', () {
    expect(
      HolidayCalendar.decode(jsonEncode(calendar.toJson())).toJson(),
      calendar.toJson(),
    );
    expect(HolidayPolicy.fromJson(null).mode, 'none');
    final p = HolidayPolicy(mode: 'workdays', calendar: calendar);
    expect(HolidayPolicy.fromJson(p.toJson()).toJson(), p.toJson());
  });
  final invalid = <String, Map<String, dynamic>>{
    'unknown key': {...calendar.toJson(), 'unknown': 1},
    'invalid date': {
      ...calendar.toJson(),
      'holidays': ['2026-02-30'],
    },
    'outside coverage': {
      ...calendar.toJson(),
      'workdays': ['2027-01-01'],
    },
    'duplicate': {
      ...calendar.toJson(),
      'holidays': ['2026-01-01', '2026-01-01'],
    },
    'conflict': {
      ...calendar.toJson(),
      'workdays': ['2026-01-01'],
    },
    'untrusted scheme': {
      ...calendar.toJson(),
      'source': 'file:///tmp/calendar',
    },
    'inverted coverage': {
      ...calendar.toJson(),
      'from': '2026-12-31',
      'to': '2026-01-01',
    },
    'bad version': {...calendar.toJson(), 'version': 1.0},
    'missing field': {...calendar.toJson()}..remove('region'),
    'oversized text': {...calendar.toJson(), 'region': 'x' * 81},
  };
  for (final entry in invalid.entries) {
    test(
      'import rejects ${entry.key}',
      () => expect(
        () => HolidayCalendar.fromJson(entry.value),
        throwsFormatException,
      ),
    );
  }
  test(
    'duplicate JSON keys, oversize payload and incomplete policies fail closed',
    () {
      expect(
        () => HolidayCalendar.decode('{"version":1,"version":1}'),
        throwsFormatException,
      );
      expect(
        () => HolidayCalendar.decode(' ' * (HolidayCalendar.maxBytes + 1)),
        throwsFormatException,
      );
      for (final raw in [
        {'mode': 'workdays'},
        {'mode': 'none', 'calendar': calendar.toJson()},
        {'mode': 'holiday'},
        {'mode': 'none', 'extra': 1},
      ]) {
        expect(() => HolidayPolicy.fromJson(raw), throwsFormatException);
      }
    },
  );
  test(
    'off, skip and workday modes keep distinct semantics; explicit exceptions win',
    () {
      final off = const HolidayPolicy(),
          skip = HolidayPolicy(mode: 'skip_holidays', calendar: calendar),
          work = HolidayPolicy(mode: 'workdays', calendar: calendar);
      final makeup = DateTime(2026, 10, 10),
          holiday = DateTime(2026, 10, 1),
          unknown = DateTime(2027, 1, 1);
      const exceptions = CalendarExceptions();
      expect(off.permits(holiday, true, exceptions), true);
      expect(skip.permits(holiday, true, exceptions), false);
      expect(skip.permits(makeup, false, exceptions), false);
      expect(work.permits(makeup, false, exceptions), true);
      expect(work.permits(unknown, true, exceptions), false);
      expect(
        work.permits(
          makeup,
          true,
          const CalendarExceptions(skip: ['2026-10-10']),
        ),
        false,
      );
      expect(
        work.permits(
          unknown,
          false,
          const CalendarExceptions(add: ['2027-01-01']),
        ),
        true,
      );
    },
  );
  test(
    'departure holiday matching uses event day even when alarm is previous day',
    () {
      final plan = DeparturePlan(
        id: 'commute',
        title: 'Commute',
        departureMinute: 5,
        leadMinutes: 15,
        weekdays: const [1, 2, 3, 4, 5],
        items: const [ChecklistItem('keys', 'Keys')],
        holidayPolicy: HolidayPolicy(mode: 'workdays', calendar: calendar),
      );
      final dates = plan.schedule(DateTime(2026, 10, 7, 20)).occurrences;
      expect(dates.first.eventTime, DateTime(2026, 10, 8, 0, 5));
      expect(dates.first.triggerTime, DateTime(2026, 10, 7, 23, 50));
      expect(
        dates.any((r) => r.eventTime == DateTime(2026, 10, 10, 0, 5)),
        true,
      );
    },
  );
  test(
    'revoking optional policies removes old persisted fields when merging',
    () {
      final original = DeparturePlan(
        id: 'commute',
        backgroundWeather: true,
        holidayPolicy: HolidayPolicy(mode: 'workdays', calendar: calendar),
      );
      final disabled = original.patch({
        'weather_background': false,
        'holiday_policy': null,
      });
      final merged = disabled.mergeData({
        ...original.toJson(),
        'notification_language': 'en',
      });
      expect(merged.containsKey('weather_background'), false);
      expect(merged.containsKey('holiday_policy'), false);
      expect(merged['notification_language'], 'en');
    },
  );
  test(
    'new semantics use details v4 while unchanged legacy details remain v1',
    () {
      expect(const TaskDetails().toJson()['version'], 1);
      final raw = TaskDetails(
        data: {
          'holiday_policy': HolidayPolicy(
            mode: 'skip_holidays',
            calendar: calendar,
          ).toJson(),
        },
      ).toJson();
      expect(raw['version'], 4);
      expect(
        () => TaskDetails.decode(jsonEncode({...raw, 'version': 1})),
        throwsFormatException,
      );
    },
  );
  test('weather retry state rejects malformed or unbounded imported data', () {
    final valid = {
      'attempt': '2026-10-28T08:00:00',
      'next': '2026-10-28T08:30:00',
      'failures': 0,
      'status': 'pending',
    };
    expect(
      () => TaskDetails(
        kind: 'departure',
        data: {'_weather_refresh': valid},
      ).encode(),
      returnsNormally,
    );
    for (final raw in [
      {...valid, 'failures': 5},
      {...valid, 'status': 'unknown'},
      {...valid, 'next': '2026-10-28T07:00:00'},
      {...valid, 'next': '2026-11-01T08:00:00'},
    ]) {
      expect(
        () => TaskDetails(
          kind: 'departure',
          data: {'_weather_refresh': raw},
        ).encode(),
        throwsFormatException,
      );
    }
  });
}
