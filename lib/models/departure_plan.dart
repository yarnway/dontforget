import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'reminder.dart';
import 'task_details.dart';

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
    this.records = const [],
    this.weather,
  }) : id = id ?? const Uuid().v4();
  final String id, title, place, city;
  final int departureMinute, leadMinutes, rainThreshold, retentionDays;
  final List<int> weekdays;
  final List<ChecklistItem> items;
  final bool learningEnabled, weatherEnabled;
  final double? latitude, longitude;
  final List<DepartureRecord> records;
  final Map<String, dynamic>? weather;
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
      rainThreshold: data['rain_threshold'] as int? ?? 40,
      retentionDays: data['retention_days'] as int? ?? 30,
      records: records.map(DepartureRecord.fromJson).toList(),
      weather: data['weather'] == null
          ? null
          : Map<String, dynamic>.from(data['weather']),
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
    'records': records.map((r) => r.toJson()).toList(),
    'weather': weather,
  };
  DeparturePlan patch(Map<String, dynamic> changes) =>
      DeparturePlan.fromJson({...toJson(), ...changes});
  Reminder build(DateTime now) {
    if (title.trim().isEmpty ||
        items.isEmpty ||
        rainThreshold < 1 ||
        rainThreshold > 100 ||
        retentionDays < 1 ||
        retentionDays > 365) {
      throw const FormatException('Incomplete departure plan');
    }
    var date = DateTime(now.year, now.month, now.day);
    DateTime? due;
    for (
      var i = 0;
      i < 9;
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
      if (weekdays.contains(date.weekday) && alarm.isAfter(now)) {
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
        repeat: RepeatWindow(weekdays: alarmDays),
        data: toJson(),
      ).encode(),
    );
  }

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
