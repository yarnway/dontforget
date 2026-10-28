import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'calendar_exceptions.dart';
import 'stored_json.dart';

/// A dated, sourced snapshot. No inference of unannounced years or regions.
class HolidayCalendar {
  HolidayCalendar({
    required this.id,
    required this.region,
    required this.from,
    required this.to,
    required this.source,
    required this.holidays,
    required this.workdays,
  }) : _parts = null;
  HolidayCalendar._bundle(List<HolidayCalendar> parts)
    : _parts = List.unmodifiable(parts),
      id =
          'bundle:${sha256.convert(utf8.encode(jsonEncode(parts.map((e) => e.toJson()).toList())))}',
      region = parts.first.region,
      from = parts.first.from,
      to = parts.last.to,
      source = parts.last.source,
      holidays = List.unmodifiable(parts.expand((e) => e.holidays)),
      workdays = List.unmodifiable(parts.expand((e) => e.workdays));
  final List<HolidayCalendar>? _parts;
  List<HolidayCalendar> get snapshots => _parts ?? [this];
  static const maxSnapshots = 4;
  final String id, region, from, to, source;
  final List<String> holidays, workdays;
  static const maxBytes = 49152;
  factory HolidayCalendar.fromJson(dynamic raw) {
    if (raw is Map && raw['version'] == 2) {
      if (raw['version'] is! int ||
          raw.length != 2 ||
          raw['snapshots'] is! List ||
          (raw['snapshots'] as List).length < 2 ||
          (raw['snapshots'] as List).length > maxSnapshots ||
          utf8.encode(jsonEncode(raw)).length > maxBytes) {
        throw const FormatException('Invalid calendar bundle');
      }
      final parts = (raw['snapshots'] as List).map((e) {
        if (e is! Map || e['version'] != 1) {
          throw const FormatException('Nested calendar bundle');
        }
        return HolidayCalendar.fromJson(e);
      }).toList()..sort((a, b) => a.from.compareTo(b.from));
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].region != parts.first.region ||
            parts.take(i).any((p) => p.id == parts[i].id) ||
            (i > 0 && parts[i].from.compareTo(parts[i - 1].to) <= 0)) {
          throw const FormatException('Conflicting calendar coverage');
        }
      }
      return HolidayCalendar._bundle(parts);
    }
    if (raw is! Map ||
        raw.length != 8 ||
        raw['version'] is! int ||
        raw['version'] != 1 ||
        utf8.encode(jsonEncode(raw)).length > maxBytes) {
      throw const FormatException('Invalid calendar');
    }
    String text(String k, int max) {
      final v = raw[k];
      if (v is! String ||
          v.isEmpty ||
          v.length > max ||
          v.trim() != v ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(v)) {
        throw const FormatException('Invalid calendar text');
      }
      return v;
    }

    final id = text('id', 128),
        region = text('region', 80),
        from = text('from', 10),
        to = text('to', 10),
        source = text('source', 1024);
    final start = CalendarExceptions.day(from),
        end = CalendarExceptions.day(to);
    if (end.isBefore(start) ||
        end.difference(start).inDays > 1095 ||
        Uri.tryParse(source)?.scheme != 'https' ||
        Uri.parse(source).host.isEmpty) {
      throw const FormatException('Invalid calendar coverage');
    }
    List<String> dates(String k) {
      final rows = raw[k];
      if (rows is! List || rows.length > 366) {
        throw const FormatException('Invalid calendar dates');
      }
      final values = rows.map((e) {
        if (e is! String) throw const FormatException('Invalid date');
        CalendarExceptions.day(e);
        if (e.compareTo(from) < 0 || e.compareTo(to) > 0) {
          throw const FormatException('Date outside coverage');
        }
        return e;
      }).toList();
      if (values.toSet().length != values.length) {
        throw const FormatException('Duplicate calendar date');
      }
      return List.unmodifiable(values..sort());
    }

    final off = dates('holidays'), on = dates('workdays');
    if (off.toSet().intersection(on.toSet()).isNotEmpty) {
      throw const FormatException('Conflicting calendar dates');
    }
    return HolidayCalendar(
      id: id,
      region: region,
      from: from,
      to: to,
      source: source,
      holidays: off,
      workdays: on,
    );
  }
  static HolidayCalendar decode(String raw) {
    if (utf8.encode(raw).length > maxBytes) {
      throw const FormatException('Calendar too large');
    }
    return HolidayCalendar.fromJson(decodeStoredJson(raw));
  }

  Map<String, dynamic> toJson() => _parts != null
      ? {'version': 2, 'snapshots': _parts.map((e) => e.toJson()).toList()}
      : {
          'version': 1,
          'id': id,
          'region': region,
          'from': from,
          'to': to,
          'source': source,
          'holidays': holidays,
          'workdays': workdays,
        };
  bool covers(DateTime day) {
    if (_parts != null) return _parts.any((e) => e.covers(day));
    final k = CalendarExceptions.key(day);
    return k.compareTo(from) >= 0 && k.compareTo(to) <= 0;
  }

  HolidayCalendar merge(
    HolidayCalendar update, {
    bool replaceOverlaps = false,
  }) {
    if (region != update.region) {
      throw const FormatException('Calendar regions differ');
    }
    final parts = [...snapshots];
    for (final next in update.snapshots) {
      if (parts.any(
        (p) => jsonEncode(p.toJson()) == jsonEncode(next.toJson()),
      )) {
        continue;
      }
      final overlaps = parts
          .where(
            (p) =>
                p.from.compareTo(next.to) <= 0 &&
                p.to.compareTo(next.from) >= 0,
          )
          .toList();
      if (overlaps.isNotEmpty && !replaceOverlaps) {
        throw const CalendarUpdateConflict();
      }
      if (overlaps.any(
        (p) => next.from.compareTo(p.from) > 0 || next.to.compareTo(p.to) < 0,
      )) {
        throw const FormatException(
          'Update must include entire overlapping coverage',
        );
      }
      parts.removeWhere(overlaps.contains);
      if (parts.any((p) => p.id == next.id)) {
        throw const FormatException('Calendar ID reused');
      }
      parts.add(next);
    }
    parts.sort((a, b) => a.from.compareTo(b.from));
    return HolidayCalendar.fromJson(
      parts.length == 1
          ? parts.single.toJson()
          : {'version': 2, 'snapshots': parts.map((p) => p.toJson()).toList()},
    );
  }

  List<int> missingYears(DateTime start, {int days = 60}) => {
    for (var i = 0; i <= days; i++)
      if (!covers(DateTime(start.year, start.month, start.day + i)))
        DateTime(start.year, start.month, start.day + i).year,
  }.toList()..sort();

  static HolidayCalendar get mainland2026 {
    final off = <String>[];
    for (final range in [
      [1, 1, 3],
      [2, 15, 23],
      [4, 4, 6],
      [5, 1, 5],
      [6, 19, 21],
      [9, 25, 27],
      [10, 1, 7],
    ]) {
      for (var day = range[1]; day <= range[2]; day++) {
        off.add(CalendarExceptions.key(DateTime(2026, range[0], day)));
      }
    }
    return HolidayCalendar.fromJson({
      'version': 1,
      'id': 'CN-2026-20251104',
      'region': 'CN',
      'from': '2026-01-01',
      'to': '2026-12-31',
      'source': 'https://www.gov.cn/zhengce/content/202511/content_7047090.htm',
      'holidays': off,
      'workdays': [
        '2026-01-04',
        '2026-02-14',
        '2026-02-28',
        '2026-05-09',
        '2026-09-20',
        '2026-10-10',
      ],
    });
  }
}

class CalendarUpdateConflict implements Exception {
  const CalendarUpdateConflict();
}

class HolidayPolicy {
  const HolidayPolicy({this.mode = 'none', this.calendar});
  final String mode;
  final HolidayCalendar? calendar;
  factory HolidayPolicy.fromJson(dynamic raw) {
    if (raw == null) return const HolidayPolicy();
    if (raw is! Map ||
        raw.keys.any((k) => k != 'mode' && k != 'calendar') ||
        !const ['none', 'skip_holidays', 'workdays'].contains(raw['mode'])) {
      throw const FormatException('Invalid holiday policy');
    }
    final calendar = raw['calendar'] == null
        ? null
        : HolidayCalendar.fromJson(raw['calendar']);
    if ((raw['mode'] == 'none') != (calendar == null)) {
      throw const FormatException('Calendar required');
    }
    return HolidayPolicy(mode: raw['mode'], calendar: calendar);
  }
  Map<String, dynamic> toJson() => {
    'mode': mode,
    if (calendar != null) 'calendar': calendar!.toJson(),
  };
  bool permits(DateTime date, bool baseline, CalendarExceptions exceptions) {
    if (exceptions.excludes(date)) return false;
    if (exceptions.includes(date)) return true;
    if (mode == 'none') return baseline;
    if (!calendar!.covers(date)) return false;
    final key = CalendarExceptions.key(date);
    if (calendar!.holidays.contains(key)) return false;
    if (mode == 'workdays') {
      return calendar!.workdays.contains(key) || date.weekday <= 5;
    }
    return baseline;
  }
}
