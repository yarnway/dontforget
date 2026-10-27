import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/departure_plan.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/departure_weather_service.dart';
import 'package:dont_forget/services/notification_schedule_reader.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications implements NotificationService {
  final scheduled = <Reminder>[], cancelled = <String>[];
  @override
  bool get isPausedForMaintenance => false;
  @override
  bool isSuppressed(Reminder task) => false;
  @override
  Future<void> init() async {}
  @override
  Future<void> scheduleReminderStrict(Reminder task) async {
    scheduled.add(task);
  }

  @override
  Future<void> cancelReminderStrict(String id) async {
    cancelled.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation call) => super.noSuchMethod(call);
}

class _Weather implements DepartureWeatherService {
  _Weather(this.forecast);
  final WeatherForecast forecast;
  int requests = 0;
  Completer<void>? barrier;
  bool fail = false;
  @override
  Future<WeatherForecast> fetch(
    double latitude,
    double longitude, {
    required DateTime now,
    CancelToken? cancelToken,
  }) async {
    requests++;
    await barrier?.future;
    if (fail) throw StateError('Synthetic offline forecast');
    return forecast;
  }

  @override
  dynamic noSuchMethod(Invocation call) => super.noSuchMethod(call);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final start = DateTime(2030, 1, 7, 6); // Monday
  DeparturePlan plan({bool weather = false, bool learning = false}) =>
      DeparturePlan(
        id: 'commute',
        title: 'Leave home',
        place: 'Home',
        departureMinute: 480,
        weekdays: [1, 2, 3, 4, 5],
        leadMinutes: 10,
        learningEnabled: learning,
        weatherEnabled: weather,
        latitude: weather ? 31 : null,
        longitude: weather ? 121 : null,
        items: const [
          ChecklistItem('keys', 'Keys'),
          ChecklistItem('trash', 'Rubbish', once: true),
          ChecklistItem('umbrella', 'Umbrella', condition: 'rain'),
        ],
      );
  WeatherForecast forecast(DateTime at, {int probability = 80}) =>
      WeatherForecast(
        at,
        [
          for (var i = 0; i < 24; i++)
            DateTime(at.year, at.month, at.day).add(Duration(hours: i)).toUtc(),
        ],
        List.filled(24, probability),
        latitude: 31,
        longitude: 121,
      );

  test('rolling dates are independent, stable and calendar bounded', () {
    final result = plan().schedule(start);
    expect(result.owner.triggerTime, isNull);
    expect(result.owner.isWorkspaceItem, isFalse);
    expect(result.occurrences.length, greaterThan(40));
    expect(
      result.occurrences.every(
        (r) => !r.isRecurring && !r.isCompleted && r.isWorkspaceItem,
      ),
      isTrue,
    );
    expect(result.occurrences.first.eventTime, DateTime(2030, 1, 7, 8));
    expect(
      result.occurrences.last.eventTime!.difference(start).inDays,
      lessThanOrEqualTo(60),
    );
    final next = plan().schedule(start.add(const Duration(days: 1)));
    expect(result.occurrences[1].id, next.occurrences.first.id);
  });
  test('a previous-day alarm is tied to the following departure date', () {
    final result = plan()
        .patch({
          'minute': 5,
          'lead': 10,
          'weekdays': [2],
        })
        .schedule(start);
    final first = result.occurrences.first;
    expect(first.triggerTime, DateTime(2030, 1, 7, 23, 55));
    expect(first.eventTime, DateTime(2030, 1, 8, 0, 5));
    expect(first.id, endsWith('2030-01-08'));
  });
  test(
    'weather must be fresh at delivery, future dates fall back to base items',
    () {
      final p = plan(
        weather: true,
      ).patch({'weather': forecast(start).toJson()});
      final dates = p.schedule(start).occurrences;
      expect(dates.first.taskSummary, contains('出行时段可能有雨'));
      expect(dates[1].taskSummary, contains('天气待确认'));
      expect(dates[1].taskSummary, contains('Umbrella'));
      expect(
        p.summaryFor(
          DateTime(2030, 1, 7, 8),
          p.items,
          delivery: start.add(const Duration(hours: 7)),
        ),
        contains('天气待确认'),
      );
    },
  );
  test(
    'dry forecast omits conditional items only with full return-window coverage',
    () {
      final p = plan(
        weather: true,
      ).patch({'weather': forecast(start, probability: 0).toJson()});
      expect(
        p.schedule(start).occurrences.first.taskSummary,
        isNot(contains('Umbrella')),
      );
      final short = WeatherForecast(
        start,
        [DateTime(2030, 1, 7, 8).toUtc()],
        [0],
        latitude: 31,
        longitude: 121,
      );
      expect(
        p
            .patch({'weather': short.toJson()})
            .schedule(start)
            .occurrences
            .first
            .taskSummary,
        contains('Umbrella'),
      );
      expect(
        p.patch({
          'return_minutes': 60,
          'weather': forecast(start).toJson(),
        }).returnMinutes,
        60,
      );
      expect(
        () => p.patch({'return_minutes': 1441}).schedule(start),
        throwsFormatException,
      );
    },
  );

  group('durable independent dates', () {
    late Directory directory;
    late DatabaseHelper database;
    late ProviderContainer container;
    late _Notifications notifications;
    late RemindersNotifier notifier;
    setUp(() async {
      sqfliteFfiInit();
      directory = await Directory.systemTemp.createTemp(
        'dontforget-departure-rolling-',
      );
      database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
      notifications = _Notifications();
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
      notifier = container.read(remindersProvider.notifier);
      await notifier.ready;
    });
    tearDown(() async {
      container.dispose();
      await database.close(createBackup: false);
      await directory.delete(recursive: true);
    });
    List<Reminder> getRows() => container.read(remindersProvider);
    Reminder owner() => getRows().singleWhere((r) => r.id == 'commute');
    List<Reminder> dates() =>
        getRows()
            .where((r) => r.details.planId == 'commute' && r.isVisible)
            .toList()
          ..sort((a, b) => a.eventTime!.compareTo(b.eventTime!));
    Future<void> save({DeparturePlan? value}) async {
      final rows = (value ?? plan()).schedule(start);
      await notifier.saveRoutine(
        rows.owner,
        rows.occurrences,
        database.captureGeneration(),
        now: start,
      );
    }

    test(
      'missing yesterday does not block today and refill is idempotent',
      () async {
        await save();
        final original = dates();
        await notifier.refreshDepartureSchedules(
          now: start.add(const Duration(days: 10)),
        );
        final refilled = dates();
        expect(refilled.length, greaterThan(original.length));
        expect(
          refilled.singleWhere((r) => r.id == original.first.id).isCompleted,
          isFalse,
        );
        final again = await notifier.refreshDepartureSchedules(
          now: start.add(const Duration(days: 10)),
        );
        expect(again.changed, 0);
      },
    );
    test(
      'completing one date leaves the next date and checkboxes independent',
      () async {
        await save();
        final first = dates().first, second = dates()[1];
        await notifier.setChecklistItem(
          first,
          'keys',
          true,
          database.captureGeneration(),
        );
        final current = dates().first;
        await notifier.completeOccurrence(
          current,
          now: start.add(const Duration(hours: 2)),
        );
        expect(dates().first.isCompleted, isTrue);
        expect(dates()[1].toJson(), second.toJson());
        expect(dates()[1].details.checklist.first.done, isFalse);
      },
    );
    test(
      'one-time item completion updates owner and all future dates',
      () async {
        await save();
        await notifier.setChecklistItem(
          dates().first,
          'trash',
          true,
          database.captureGeneration(),
        );
        expect(
          owner().details.checklist.singleWhere((e) => e.id == 'trash').done,
          isTrue,
        );
        expect(
          dates().every(
            (r) => r.details.checklist.singleWhere((e) => e.id == 'trash').done,
          ),
          isTrue,
        );
        expect(
          dates().every((r) => !r.taskSummary!.contains('Rubbish')),
          isTrue,
        );
        await notifier.refreshDepartureSchedules(
          now: start.add(const Duration(days: 10)),
        );
        expect(
          dates().every(
            (r) => r.details.checklist.singleWhere((e) => e.id == 'trash').done,
          ),
          isTrue,
        );
      },
    );
    test(
      'paused and trashed owners do not create new dates or active alarms',
      () async {
        await save();
        await notifier.changeLifecycle(
          owner(),
          'pause',
          database.captureGeneration(),
        );
        final count = getRows().length;
        await notifier.refreshDepartureSchedules(
          now: start.add(const Duration(days: 90)),
        );
        expect(getRows().length, count);
        expect(dates().every((r) => !r.canNotify), isTrue);
        await notifier.changeLifecycle(
          owner(),
          'trash',
          database.captureGeneration(),
        );
        await notifier.refreshDepartureSchedules(
          now: start.add(const Duration(days: 100)),
        );
        expect(getRows().length, count);
        expect(getRows().every((r) => !r.isVisible), isTrue);
      },
    );
    test('old confirmed records expire even while a plan is paused', () async {
      var p = plan(
        learning: true,
      ).record(start.subtract(const Duration(days: 29)));
      await save(value: p);
      await notifier.changeLifecycle(
        owner(),
        'pause',
        database.captureGeneration(),
      );
      await notifier.refreshDepartureSchedules(
        now: start.add(const Duration(days: 2)),
      );
      expect(DeparturePlan.fromJson(owner().details.data).records, isEmpty);
    });
    test(
      'recording a departure completes only the matching calendar date',
      () async {
        await save(value: plan(learning: true));
        final recordTime = start.add(const Duration(hours: 2));
        final updated = DeparturePlan.fromJson(
          owner().details.data,
        ).record(recordTime);
        await notifier.updateDepartureRecords(
          owner(),
          updated,
          database.captureGeneration(),
          departedAt: recordTime,
        );
        expect(dates().first.isCompleted, isTrue);
        expect(dates()[1].isCompleted, isFalse);
        expect(owner().isCompleted, isFalse);
        expect(
          DeparturePlan.fromJson(owner().details.data).records.single.at,
          recordTime,
        );
      },
    );
    test(
      'legacy current occurrence is preserved when the owner becomes rolling',
      () async {
        final legacy = plan().build(start);
        await notifier.addReminderForGeneration(
          legacy,
          database.captureGeneration(),
        );
        await notifier.refreshDepartureSchedules(now: start);
        expect(owner().triggerTime, isNull);
        expect(owner().isWorkspaceItem, isFalse);
        expect(dates().first.triggerTime, legacy.triggerTime);
        expect(dates().first.isCompleted, isFalse);
        await notifier.refreshDepartureSchedules(now: start);
        expect(dates().map((r) => r.id).toSet().length, dates().length);
      },
    );
    test(
      'foreground prefetch updates a dated native body with a per-plan cooldown',
      () async {
        await save(value: plan(weather: true));
        final weather = _Weather(forecast(start));
        await notifier.refreshDepartureWeather(
          weather,
          isActive: () => true,
          now: start,
        );
        expect(weather.requests, 1);
        expect(dates().first.taskSummary, contains('出行时段可能有雨'));
        expect(dates()[1].taskSummary, contains('天气待确认'));
        await notifier.refreshDepartureWeather(
          weather,
          isActive: () => true,
          now: start.add(const Duration(minutes: 1)),
        );
        expect(weather.requests, 1);
      },
    );
    test(
      'opt-out while weather is in flight discards the late response',
      () async {
        await save(value: plan(weather: true));
        final weather = _Weather(forecast(start))..barrier = Completer<void>();
        final work = notifier.refreshDepartureWeather(
          weather,
          isActive: () => true,
          now: start,
        );
        await Future<void>.delayed(Duration.zero);
        final current = owner();
        await notifier.editTaskDetails(
          current,
          current.details.patch({
            'data': {
              ...current.details.data,
              'weather_enabled': false,
              'weather': null,
            },
          }),
          database.captureGeneration(),
        );
        weather.barrier!.complete();
        await work;
        expect(owner().details.data['weather_enabled'], isFalse);
        expect(owner().details.data['weather'], isNull);
        expect(dates().first.taskSummary, contains('天气待确认'));
      },
    );
    test(
      'offline and inactive refresh keep base items without making a rain claim',
      () async {
        await save(value: plan(weather: true));
        final weather = _Weather(forecast(start))..fail = true;
        await notifier.refreshDepartureWeather(
          weather,
          isActive: () => false,
          now: start,
        );
        expect(weather.requests, 0);
        await notifier.refreshDepartureWeather(
          weather,
          isActive: () => true,
          now: start,
        );
        expect(weather.requests, 1);
        expect(dates().first.taskSummary, contains('Umbrella'));
        expect(dates().first.taskSummary, contains('天气待确认'));
      },
    );
    test(
      'read-only schedule status respects plan pause and counts dates outside capacity separately',
      () async {
        await save();
        final reader = NotificationScheduleReader(
          database,
          nativePendingLimit: 3,
        );
        final status = await reader.read(planId: 'commute');
        expect(status.upcoming, dates().length);
        expect(status.deferred, dates().length - 3);
        expect(status.needsAttention, 3);
        await notifier.changeLifecycle(
          owner(),
          'pause',
          database.captureGeneration(),
        );
        expect((await reader.read()).upcoming, 0);
      },
    );
  });
}
