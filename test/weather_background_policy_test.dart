import 'dart:async';
import 'package:dio/dio.dart';
import 'package:dont_forget/models/departure_plan.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/departure_weather_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';

class _Weather implements DepartureWeatherService {
  int requests = 0;
  bool fail = false;
  Completer<void>? barrier;
  final coordinates = <(double, double)>[];
  @override
  Future<WeatherForecast> fetch(
    double latitude,
    double longitude, {
    required DateTime now,
    CancelToken? cancelToken,
  }) async {
    requests++;
    coordinates.add((latitude, longitude));
    await barrier?.future;
    if (fail) throw StateError('Synthetic offline forecast');
    return WeatherForecast(
      now,
      [
        for (var i = 0; i < 24; i++)
          DateTime(now.year, now.month, now.day, i).toUtc(),
      ],
      List.filled(24, 80),
      latitude: latitude,
      longitude: longitude,
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final at = DateTime(2030, 1, 7, 6);
  late OfflineManagementHarness h;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
  });
  tearDown(() async => h.dispose());
  DeparturePlan plan({String id = 'commute', bool background = false}) =>
      DeparturePlan(
        id: id,
        title: 'Fixture departure',
        weekdays: const [1, 2, 3, 4, 5, 6, 7],
        weatherEnabled: true,
        backgroundWeather: background,
        latitude: 31.23,
        longitude: 121.99,
        items: const [
          ChecklistItem('keys', 'Keys'),
          ChecklistItem('rain', 'Umbrella', condition: 'rain'),
        ],
      );
  Future<void> save(DeparturePlan p) async {
    final s = p.schedule(at);
    await h.notifier.saveRoutine(
      s.owner,
      s.occurrences,
      h.database.captureGeneration(),
      now: at,
    );
  }

  Future<Reminder> owner() => h.row('commute');
  test('foreground default never fetches from a background pump', () async {
    await save(plan());
    final w = _Weather();
    await h.notifier.refreshDepartureWeather(
      w,
      isActive: () => true,
      background: true,
      now: at,
    );
    expect(w.requests, 0);
    expect((await owner()).details.data['_weather_refresh'], isNull);
    await h.notifier.refreshDepartureWeather(w, isActive: () => true, now: at);
    expect(w.coordinates, [(31.23, 121.99)]);
  });
  test(
    'explicit background consent uses only the saved confirmed place',
    () async {
      await save(plan(background: true));
      final w = _Weather();
      await h.notifier.refreshDepartureWeather(
        w,
        isActive: () => true,
        background: true,
        now: at,
      );
      expect(w.requests, 1);
      expect(w.coordinates, [(31.23, 121.99)]);
      expect((await owner()).details.data['_weather_refresh']['status'], 'ok');
    },
  );
  test(
    'foreground request crossing into background without consent discards late result',
    () async {
      await save(plan());
      var background = false;
      final w = _Weather()..barrier = Completer<void>();
      final pending = h.notifier.refreshDepartureWeather(
        w,
        isActive: () => true,
        isBackground: () => background,
        now: at,
      );
      while (w.requests == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      background = true;
      w.barrier!.complete();
      await pending;
      expect((await owner()).details.data['weather'], isNull);
    },
  );
  test(
    'revoking background consent during fetch discards the response and allows foreground repair',
    () async {
      await save(plan(background: true));
      final w = _Weather()..barrier = Completer<void>();
      final pending = h.notifier.refreshDepartureWeather(
        w,
        isActive: () => true,
        background: true,
        now: at,
      );
      while (w.requests == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final baseline = await owner();
      await h.notifier.editTaskDetails(
        baseline,
        baseline.details.patch({
          'data': {...baseline.details.data, 'weather_background': false},
        }),
        h.database.captureGeneration(),
      );
      w.barrier!.complete();
      await pending;
      expect((await owner()).details.data['weather'], isNull);
      await h.notifier.refreshDepartureWeather(
        w,
        isActive: () => true,
        background: true,
        now: at.add(const Duration(minutes: 31)),
      );
      expect(w.requests, 1);
      await h.notifier.refreshDepartureWeather(
        w,
        isActive: () => true,
        now: at.add(const Duration(minutes: 31)),
      );
      expect(w.requests, 2);
    },
  );
  test(
    'pending refresh does not invalidate an already-open consent withdrawal',
    () async {
      await save(plan());
      final baseline = await owner();
      final w = _Weather()..barrier = Completer<void>();
      final pending = h.notifier.refreshDepartureWeather(
        w,
        isActive: () => true,
        now: at,
      );
      while (w.requests == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await h.notifier.editTaskDetails(
        baseline,
        baseline.details.patch({
          'data': {
            ...baseline.details.data,
            'weather_enabled': false,
            'weather': null,
          },
        }),
        h.database.captureGeneration(),
      );
      w.barrier!.complete();
      await pending;
      expect((await owner()).details.data['weather_enabled'], false);
      expect((await owner()).details.data['_weather_refresh'], isNull);
      expect((await owner()).details.data['weather'], isNull);
    },
  );
  test('successful cooldown survives process reconstruction', () async {
    await save(plan());
    final w = _Weather();
    await h.notifier.refreshDepartureWeather(w, isActive: () => true, now: at);
    await h.close();
    await h.open();
    await h.notifier.refreshDepartureWeather(
      w,
      isActive: () => true,
      now: at.add(const Duration(minutes: 10)),
    );
    expect(w.requests, 1);
    await h.notifier.refreshDepartureWeather(
      w,
      isActive: () => true,
      now: at.add(const Duration(minutes: 31)),
    );
    expect(w.requests, 2);
  });
  test(
    'failure backoff is durable and base checklist remains truthful',
    () async {
      await save(plan());
      final w = _Weather()..fail = true;
      await h.notifier.refreshDepartureWeather(
        w,
        isActive: () => true,
        now: at,
      );
      final first = (await owner()).details.data['_weather_refresh'];
      expect(first['status'], 'failed');
      expect(first['failures'], 1);
      expect(
        TaskDetails.date(first['next']),
        at.add(const Duration(minutes: 60)),
      );
      await h.close();
      await h.open();
      await h.notifier.refreshDepartureWeather(
        w,
        isActive: () => true,
        now: at.add(const Duration(minutes: 31)),
      );
      expect(w.requests, 1);
      await h.notifier.refreshDepartureWeather(
        w,
        isActive: () => true,
        now: at.add(const Duration(minutes: 61)),
      );
      expect(w.requests, 2);
      expect((await owner()).details.data['_weather_refresh']['failures'], 2);
      final dates = (await h.rows()).where(
        (r) => r.details.planId == 'commute',
      );
      expect(dates.first.taskSummary, contains('天气待确认'));
      expect(dates.first.taskSummary, contains('Keys'));
    },
  );
  test(
    'pause and closed runtime gates prevent requests and late writes',
    () async {
      await save(plan(background: true));
      final w = _Weather();
      await h.notifier.refreshDepartureWeather(
        w,
        isActive: () => false,
        background: true,
        now: at,
      );
      expect(w.requests, 0);
      await h.notifier.changeLifecycle(
        await owner(),
        'pause',
        h.database.captureGeneration(),
      );
      await h.notifier.refreshDepartureWeather(
        w,
        isActive: () => true,
        background: true,
        now: at,
      );
      expect(w.requests, 0);
    },
  );
  test('one pump caps network attempts at three eligible plans', () async {
    for (var i = 0; i < 4; i++) {
      await save(plan(id: 'commute$i', background: true));
    }
    final w = _Weather();
    await h.notifier.refreshDepartureWeather(
      w,
      isActive: () => true,
      background: true,
      now: at,
    );
    expect(w.requests, 3);
  });
}
