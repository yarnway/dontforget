import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'reminder.dart';
import 'task_details.dart';
import 'calendar_exceptions.dart';
import '../services/departure_weather_service.dart';

class DeparturePlan {
  DeparturePlan({
    String? id,
    this.title = '',
    this.place = '',
    this.departureMinute = 480,
    this.leadMinutes = 10,
    this.weekdays = const [1, 2, 3, 4, 5],
    this.items = const [],
    this.learningEnabled = false,
    this.weatherEnabled = false,
    this.latitude,
    this.longitude,
    this.city = '',
    this.rainThreshold = 40,
    this.retentionDays = 30,
    this.returnMinutes = 180,
    this.records = const [],
    this.weather,
    this.exceptions = const CalendarExceptions(),
  }) : id = id ?? const Uuid().v4();
  final String id, title, place, city;
  final int departureMinute,
      leadMinutes,
      rainThreshold,
      retentionDays,
      returnMinutes;
  static const rollingDays = 60;
  final List<int> weekdays;
  final List<ChecklistItem> items;
  final bool learningEnabled, weatherEnabled;
  final double? latitude, longitude;
  final List<DepartureRecord> records;
  final Map<String, dynamic>? weather;
  final CalendarExceptions exceptions;
  factory DeparturePlan.fromJson(Map data) {
    final days = data['weekdays'];
    final minute = data['minute'], lead = data['lead'];
    if (days is! List ||
        days.isEmpty ||
        days.length > 7 ||
        days.any((d) => d is! int || d < 1 || d > 7) ||
        minute is! int ||
        minute < 0 ||
        minute >= 1440 ||
        lead is! int ||
        lead < 0 ||
        lead > 180) {
      throw const FormatException('Invalid departure time');
    }
    final items = data['items'], records = data['records'] ?? [];
    if (items is! List ||
        items.length > 64 ||
        records is! List ||
        records.length > 366) {
      throw const FormatException('Invalid departure data');
    }
    final rain = data['rain_threshold'] ?? 40,
        retention = data['retention_days'] ?? 30,
        returning = data['return_minutes'] ?? 180;
    if (rain is! int ||
        rain < 1 ||
        rain > 100 ||
        retention is! int ||
        retention < 1 ||
        retention > 365 ||
        returning is! int ||
        returning < 1 ||
        returning > 1440 ||
        days.toSet().length != days.length) {
      throw const FormatException('Invalid departure bounds');
    }
    final lat = data['latitude'], lon = data['longitude'];
    if (lat != null &&
            (lat is! num || !lat.isFinite || lat < -90 || lat > 90) ||
        lon != null &&
            (lon is! num || !lon.isFinite || lon < -180 || lon > 180)) {
      throw const FormatException('Invalid city coordinates');
    }
    return DeparturePlan(
      id: TaskDetails.text(data['id'], 64),
      title: TaskDetails.text(data['title'] ?? '', 160),
      place: TaskDetails.text(data['place'] ?? '', 160),
      departureMinute: minute,
      leadMinutes: lead,
      weekdays: List<int>.from(days),
      items: items.map(ChecklistItem.fromJson).toList(),
      learningEnabled: data['learning'] == true,
      weatherEnabled: data['weather_enabled'] == true,
      latitude: (lat as num?)?.toDouble(),
      longitude: (lon as num?)?.toDouble(),
      city: TaskDetails.text(data['city'] ?? '', 160),
      rainThreshold: rain,
      retentionDays: retention,
      returnMinutes: returning,
      records: records.map(DepartureRecord.fromJson).toList(),
      weather: data['weather'] == null
          ? null
          : Map<String, dynamic>.from(data['weather']),
      exceptions: CalendarExceptions.fromJson(data['calendar_exceptions']),
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'place': place,
    'minute': departureMinute,
    'lead': leadMinutes,
    'weekdays': weekdays,
    'items': items.map((e) => e.toJson()).toList(),
    'learning': learningEnabled,
    'weather_enabled': weatherEnabled,
    'latitude': latitude,
    'longitude': longitude,
    'city': city,
    'rain_threshold': rainThreshold,
    'retention_days': retentionDays,
    'return_minutes': returnMinutes,
    'records': records.map((r) => r.toJson()).toList(),
    'weather': weather,
    if (!exceptions.isEmpty) 'calendar_exceptions': exceptions.toJson(),
  };
  DeparturePlan patch(Map<String, dynamic> changes) =>
      DeparturePlan.fromJson({...toJson(), ...changes});
  Reminder build(DateTime now) {
    CalendarExceptions.fromJson(exceptions.toJson());
    if (title.trim().isEmpty ||
        items.isEmpty ||
        rainThreshold < 1 ||
        rainThreshold > 100 ||
        retentionDays < 1 ||
        retentionDays > 365 ||
        returnMinutes < 1 ||
        returnMinutes > 1440) {
      throw const FormatException('Incomplete departure plan');
    }
    var date = DateTime(now.year, now.month, now.day);
    DateTime? due;
    for (
      var i = 0;
      i < 368;
      i++, date = DateTime(date.year, date.month, date.day + 1)
    ) {
      final event = DateTime(
        date.year,
        date.month,
        date.day,
        departureMinute ~/ 60,
        departureMinute % 60,
      );
      final alarm = event.subtract(Duration(minutes: leadMinutes));
      if (exceptions.permits(date, weekdays) && alarm.isAfter(now)) {
        due = alarm;
        break;
      }
    }
    if (due == null) throw const FormatException('Departure time unavailable');
    // Anchor weekdays to the actual departure, including a previous-day alarm.
    final alarmDays = weekdays
        .map((d) => (departureMinute - leadMinutes < 0 ? d + 5 : d - 1) % 7 + 1)
        .toList();
    return Reminder(
      id: id,
      taskTitle: title.trim(),
      taskSummary: [
        place,
        ...items
            .where(
              (item) => item.condition == 'always' && !(item.once && item.done),
            )
            .map((item) => item.label),
      ].where((line) => line.isNotEmpty).join('\n'),
      quadrantLevel: 2,
      triggerTime: due,
      eventTime: due.add(Duration(minutes: leadMinutes)),
      isRecurring: true,
      recurrenceRule: 'weekly',
      detailsJson: TaskDetails(
        kind: 'departure',
        checklist: items,
        repeat: RepeatWindow(
          weekdays: alarmDays,
          exceptions: exceptions.shift(
            departureMinute - leadMinutes < 0 ? -1 : 0,
          ),
        ),
        data: toJson(),
      ).encode(),
    );
  }

  /// A durable owner and independent calendar dates. Completing yesterday is
  /// never a prerequisite for tomorrow, and a stable date ID prevents replay.
  ({Reminder owner, List<Reminder> occurrences}) schedule(
    DateTime now, {
    String language = 'zh',
  }) {
    final first = build(
      now,
    ); // Validate the same confirmed form as the preview.
    final owner = first.copyWith(
      triggerTime: null,
      eventTime: null,
      isRecurring: false,
      recurrenceRule: 'none',
      detailsJson: first.details.patch({
        'repeat': null,
        'data': {
          ...toJson(),
          '_departure_rolling': rollingDays,
          'notification_language': language,
        },
      }).encode(),
    );
    final occurrences = <Reminder>[];
    for (var day = 0; day <= rollingDays; day++) {
      final date = DateTime(now.year, now.month, now.day + day);
      if (!exceptions.permits(date, weekdays)) continue;
      final event = DateTime(
        date.year,
        date.month,
        date.day,
        departureMinute ~/ 60,
        departureMinute % 60,
      );
      final alarm = event.subtract(Duration(minutes: leadMinutes));
      if (!alarm.isAfter(now)) continue;
      final dateKey =
          '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final checklist = items
          .map((item) => item.once ? item : item.copyWith(done: false))
          .toList();
      occurrences.add(
        Reminder(
          id: '$id:departure:$dateKey',
          taskTitle: title.trim(),
          taskSummary: summaryFor(event, checklist, language: language),
          quadrantLevel: 2,
          triggerTime: alarm,
          eventTime: event,
          detailsJson: TaskDetails(
            kind: 'departure',
            planId: id,
            checklist: checklist,
            data: {
              ...toJson(),
              'records': [],
              'weather': null,
              'items': checklist.map((e) => e.toJson()).toList(),
              'departure_occurrence': true,
              'notification_language': language,
            },
          ).encode(),
        ),
      );
    }
    return (owner: owner, occurrences: occurrences);
  }

  bool? rainFor(DateTime event, {DateTime? delivery}) {
    if (!weatherEnabled || weather == null) return null;
    try {
      final forecast = WeatherForecast.fromJson(weather!);
      if (forecast.latitude != latitude || forecast.longitude != longitude) {
        return null;
      }
      return forecast.rainDuring(
        event,
        event.add(Duration(minutes: returnMinutes)),
        // A cached forecast must still be fresh when this dated notice fires.
        now: delivery ?? event.subtract(Duration(minutes: leadMinutes)),
        threshold: rainThreshold,
      );
    } catch (_) {
      return null;
    }
  }

  String summaryFor(
    DateTime event,
    List<ChecklistItem> checklist, {
    String language = 'zh',
    DateTime? delivery,
  }) {
    final rain = rainFor(event, delivery: delivery);
    final words = language == 'ja'
        ? ['天気を確認してください', '雨の可能性', 'この時間帯の降水確率は設定値未満です']
        : language == 'en'
        ? [
            'Weather needs confirmation',
            'Rain is possible',
            'Rain probability is below your threshold for this window',
          ]
        : ['天气待确认', '出行时段可能有雨', '出行时段降水概率低于设定阈值'];
    return [
      if (place.isNotEmpty) place,
      for (final item in checklist)
        if (!item.done &&
            (item.condition != 'rain' || !weatherEnabled || rain != false))
          item.condition == 'rain' && (rain == null || !weatherEnabled)
              ? '${item.label}（${words[0]}）'
              : item.label,
      if (weatherEnabled)
        words[rain == null
            ? 0
            : rain
            ? 1
            : 2],
      if (weatherEnabled && weather != null)
        '${WeatherForecast.source} · $city · ${weather!['fetched']}',
    ].join('\n');
  }

  Map<String, dynamic>? weatherContext(DateTime at) {
    if (!weatherEnabled || weather == null) return null;
    try {
      final forecast = WeatherForecast.fromJson(weather!);
      if (forecast.latitude != latitude || forecast.longitude != longitude) {
        return null;
      }
      return {
        'source': WeatherForecast.source,
        'fetched': forecast.fetchedAt.toIso8601String(),
        'city': city,
        'rain': forecast.rainDuring(
          at,
          at.add(Duration(minutes: returnMinutes)),
          now: at,
          threshold: rainThreshold,
        ),
        'threshold': rainThreshold,
      };
    } catch (_) {
      return null;
    }
  }

  DeparturePlan retained(DateTime now) => patch({
    'records': records
        .where(
          (r) => !r.at.isBefore(now.subtract(Duration(days: retentionDays))),
        )
        .map((r) => r.toJson())
        .toList(),
  });

  DeparturePlan record(
    DateTime at, {
    String? correctedId,
    Map<String, dynamic>? weather,
  }) {
    if (!learningEnabled) throw StateError('Departure recording disabled');
    final cutoff = at.subtract(Duration(days: retentionDays));
    final kept = records
        .where((r) => !r.at.isBefore(cutoff) && r.id != correctedId)
        .toList();
    final day = '${at.year}-${at.month}-${at.day}';
    kept.removeWhere(
      (r) =>
          '${r.at.year}-${r.at.month}-${r.at.day}' == day && r.place == place,
    );
    kept.add(
      DepartureRecord(
        correctedId ?? const Uuid().v4(),
        at,
        place,
        source: 'manual',
        weather: weather,
      ),
    );
    return patch({
      'records': kept
          .skip(kept.length > 366 ? kept.length - 366 : 0)
          .map((r) => r.toJson())
          .toList(),
    });
  }

  /// A transparent local suggestion; no claim that these observations are AI.
  ({int minute, int samples})? suggestion({DateTime? now}) {
    final at = now ?? DateTime.now();
    final minutes =
        records
            .where(
              (r) =>
                  r.place == place &&
                  r.source == 'manual' &&
                  weekdays.contains(r.at.weekday) &&
                  r.at.isBefore(at.add(const Duration(minutes: 1))) &&
                  r.at.isAfter(at.subtract(Duration(days: retentionDays))),
            )
            .map((r) => r.at.hour * 60 + r.at.minute)
            .toList()
          ..sort();
    if (minutes.length < 5 || minutes.last - minutes.first > 90) return null;
    return (minute: minutes[minutes.length ~/ 2], samples: minutes.length);
  }

  String encode() => jsonEncode(toJson());
}

class DepartureRecord {
  const DepartureRecord(
    this.id,
    this.at,
    this.place, {
    this.source = 'manual',
    this.weather,
  });
  final Map<String, dynamic>? weather;
  final String id, place, source;
  final DateTime at;
  factory DepartureRecord.fromJson(dynamic value) {
    if (value is! Map) throw const FormatException('Invalid departure record');
    final source = TaskDetails.text(value['source'] ?? 'manual', 32);
    if (!const {'manual', 'detected'}.contains(source)) {
      throw const FormatException('Invalid observation source');
    }
    return DepartureRecord(
      TaskDetails.text(value['id'], 64),
      TaskDetails.date(value['at'])!,
      TaskDetails.text(value['place'], 160),
      source: source,
      weather: value['weather'] == null
          ? null
          : Map<String, dynamic>.from(value['weather']),
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toIso8601String(),
    'place': place,
    'source': source,
    'weather': weather,
  };
}
