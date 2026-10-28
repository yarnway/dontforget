import 'dart:convert';
import 'stored_datetime.dart';
import 'stored_json.dart';
import 'calendar_exceptions.dart';

/// Versioned, bounded extension data. Historical tasks retain null storage.
class TaskDetails {
  const TaskDetails({
    this.repeat,
    this.checklist = const [],
    this.tags = const [],
    this.project = '',
    this.history = const [],
    this.paused = false,
    this.deletedAt,
    this.archivedAt,
    this.completedAt,
    this.doseOutcome,
    this.kind = 'task',
    this.planId,
    this.data = const {},
  });
  final RepeatWindow? repeat;
  final List<ChecklistItem> checklist;
  final List<String> tags;
  final String project;
  final List<TaskEvent> history;
  final bool paused;
  final DateTime? deletedAt, archivedAt, completedAt;
  final String kind;
  final String? doseOutcome;
  DateTime? get actualDoseTakenAt =>
      kind == 'medication' && effectiveDoseOutcome == 'taken'
      ? date(data['dose_taken_at'])
      : null;
  String? get effectiveDoseOutcome =>
      doseOutcome ??
      history
          .where((e) => e.action == 'taken' || e.action == 'not_taken')
          .lastOrNull
          ?.action;
  final String? planId;
  final Map<String, dynamic> data;
  bool get hidden => deletedAt != null || archivedAt != null;

  static TaskDetails decode(String? raw) {
    if (raw == null) return const TaskDetails();
    if (raw.length > 262144) {
      throw const FormatException('Task details too large');
    }
    final json = decodeStoredJson(raw);
    if (json is! Map<String, dynamic> ||
        json['version'] is! int ||
        !const [1, 2].contains(json['version']) ||
        json['version'] != _formatVersion(json)) {
      throw const FormatException('Invalid task details');
    }
    const keys = {
      'version',
      'repeat',
      'checklist',
      'tags',
      'project',
      'history',
      'paused',
      'deleted_at',
      'archived_at',
      'completed_at',
      'dose_outcome',
      'kind',
      'plan_id',
      'data',
    };
    if (json.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('Unknown task detail');
    }
    List<T> list<T>(String key, int limit, T Function(dynamic) parse) {
      final values = json[key] ?? [];
      if (values is! List || values.length > limit) {
        throw const FormatException('Invalid list');
      }
      return List.unmodifiable(values.map(parse));
    }

    final paused = json['paused'] ?? false;
    if (paused is! bool) throw const FormatException('Invalid pause');
    final kind = text(json['kind'] ?? 'task', 32);
    if (!const {
      'task',
      'medication',
      'medicationPlan',
      'departure',
      'study',
    }.contains(kind)) {
      throw const FormatException('Invalid task kind');
    }
    final outcome = json['dose_outcome'];
    if (outcome != null && !const {'taken', 'not_taken'}.contains(outcome)) {
      throw const FormatException('Invalid dose outcome');
    }
    final data = json['data'] ?? <String, dynamic>{};
    if (data is! Map<String, dynamic> || jsonEncode(data).length > 65536) {
      throw const FormatException('Invalid task data');
    }
    if (kind == 'medication' && data['dose_taken_at'] != null) {
      date(data['dose_taken_at']);
    }
    final items = list('checklist', 64, ChecklistItem.fromJson);
    if (items.map((e) => e.id).toSet().length != items.length) {
      throw const FormatException('Duplicate checklist ID');
    }
    return TaskDetails(
      repeat: json['repeat'] == null
          ? null
          : RepeatWindow.fromJson(json['repeat']),
      checklist: items,
      tags: list('tags', 16, (v) => text(v, 64)),
      project: text(json['project'] ?? '', 128),
      history: list('history', 512, TaskEvent.fromJson),
      paused: paused,
      deletedAt: date(json['deleted_at']),
      archivedAt: date(json['archived_at']),
      completedAt: date(json['completed_at']),
      doseOutcome: outcome as String?,
      kind: kind,
      planId: json['plan_id'] == null ? null : text(json['plan_id'], 160),
      data: Map<String, dynamic>.unmodifiable(
        data.map((key, value) => MapEntry(key, _freeze(value))),
      ),
    );
  }

  static String text(dynamic value, int limit) {
    if (value is! String || value.length > limit) {
      throw const FormatException('Invalid text');
    }
    return value;
  }

  static DateTime? date(dynamic value) {
    if (value == null) return null;
    if (value is! String) throw const FormatException('Invalid date');
    final parsed = tryParseStoredDateTime(value);
    if (parsed == null || parsed.year < 1900 || parsed.year > 2200) {
      throw const FormatException('Invalid date');
    }
    return parsed;
  }

  String encode() {
    final raw = jsonEncode(toJson());
    decode(raw); // Apply the same limits to local writes and imported data.
    return raw;
  }

  Map<String, dynamic> toJson() => {
    'version': _formatVersion({
      'kind': kind,
      'repeat': repeat?.toJson(),
      'data': data,
    }),
    'repeat': repeat?.toJson(),
    'checklist': checklist.map((e) => e.toJson()).toList(),
    'tags': tags,
    'project': project,
    'history': history.map((e) => e.toJson()).toList(),
    'paused': paused,
    'deleted_at': deletedAt?.toIso8601String(),
    'archived_at': archivedAt?.toIso8601String(),
    'completed_at': completedAt?.toIso8601String(),
    'dose_outcome': doseOutcome,
    'kind': kind,
    'plan_id': planId,
    'data': data,
  };
  static int _formatVersion(Map<String, dynamic> data) {
    final repeat = data['repeat'];
    if (repeat is Map) {
      if (repeat['anchor'] != null) return 2;
      final e = repeat['exceptions'];
      if (e is Map &&
          ((e['skip'] is List && (e['skip'] as List).isNotEmpty) ||
              (e['add'] is List && (e['add'] as List).isNotEmpty))) {
        return 2;
      }
    }
    final body = data['data'];
    if (body is Map) {
      if (data['kind'] == 'departure' && body['calendar_exceptions'] is Map) {
        final e = body['calendar_exceptions'] as Map;
        if ((e['skip'] is List && (e['skip'] as List).isNotEmpty) ||
            (e['add'] is List && (e['add'] as List).isNotEmpty)) {
          return 2;
        }
      }
      bool medicationExtension(Map value) =>
          value['review_sources'] == true ||
          (value['resolved_fields'] is Map &&
              (value['resolved_fields'] as Map).isNotEmpty) ||
          const [
            'sources',
            'meals',
            'meal_links',
            'meal_context',
            'provenance',
          ].any((key) => value[key] is List && (value[key] as List).isNotEmpty);
      if (const ['medication', 'medicationPlan'].contains(data['kind']) &&
          (medicationExtension(body) ||
              (body['medicines'] is List &&
                  (body['medicines'] as List).whereType<Map>().any(
                    medicationExtension,
                  )))) {
        return 2;
      }
    }
    return 1;
  }

  TaskDetails patch(Map<String, dynamic> changes) {
    final next = {...toJson(), ...changes};
    next['version'] = _formatVersion(next);
    return decode(jsonEncode(next));
  }

  TaskDetails record(
    String action,
    DateTime at, {
    DateTime? scheduled,
    String? note,
  }) => patch({
    'history': [
      ...history
          .skip(history.length >= 512 ? history.length - 511 : 0)
          .map((e) => e.toJson()),
      TaskEvent(action, at, scheduled: scheduled, note: note).toJson(),
    ],
  });
}

class ChecklistItem {
  const ChecklistItem(
    this.id,
    this.label, {
    this.done = false,
    this.once = false,
    this.condition = 'always',
  });
  final String id, label, condition;
  final bool done, once;
  factory ChecklistItem.fromJson(dynamic value) {
    if (value is! Map ||
        value['done'] is! bool ||
        value['once'] is! bool ||
        !const {'always', 'rain'}.contains(value['condition'])) {
      throw const FormatException('Invalid checklist item');
    }
    final id = TaskDetails.text(value['id'], 160);
    final label = TaskDetails.text(value['label'], 512);
    if (id.isEmpty || label.trim().isEmpty) {
      throw const FormatException('Empty checklist item');
    }
    return ChecklistItem(
      id,
      label,
      done: value['done'],
      once: value['once'],
      condition: value['condition'],
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'done': done,
    'once': once,
    'condition': condition,
  };
  ChecklistItem copyWith({String? label, bool? done}) => ChecklistItem(
    id,
    label ?? this.label,
    done: done ?? this.done,
    once: once,
    condition: condition,
  );
}

class TaskEvent {
  const TaskEvent(this.action, this.at, {this.scheduled, this.note});
  final String action;
  final DateTime at;
  final DateTime? scheduled;
  final String? note;
  factory TaskEvent.fromJson(dynamic value) {
    if (value is! Map) throw const FormatException('Invalid task event');
    final at = TaskDetails.date(value['at']);
    if (at == null) throw const FormatException('Missing task event date');
    return TaskEvent(
      TaskDetails.text(value['action'], 40),
      at,
      scheduled: TaskDetails.date(value['scheduled']),
      note: value['note'] == null
          ? null
          : TaskDetails.text(value['note'], 1024),
    );
  }
  Map<String, dynamic> toJson() => {
    'action': action,
    'at': at.toIso8601String(),
    'scheduled': scheduled?.toIso8601String(),
    'note': note,
  };
}

class RepeatWindow {
  const RepeatWindow({
    this.interval = 1,
    this.weekdays = const [],
    this.start,
    this.end,
    this.anchor,
    this.exceptions = const CalendarExceptions(),
  });
  final int interval;
  final List<int> weekdays;
  final DateTime? start, end, anchor;
  final CalendarExceptions exceptions;
  factory RepeatWindow.fromJson(dynamic value) {
    if (value is! Map ||
        value['interval'] is! int ||
        value['interval'] < 1 ||
        value['interval'] > 365) {
      throw const FormatException('Invalid repeat interval');
    }
    final days = value['weekdays'];
    if (days is! List ||
        days.length > 7 ||
        days.any((d) => d is! int || d < 1 || d > 7) ||
        days.toSet().length != days.length) {
      throw const FormatException('Invalid weekdays');
    }
    final start = TaskDetails.date(value['start']);
    final end = TaskDetails.date(value['end']);
    if (start != null && end != null && end.isBefore(start)) {
      throw const FormatException('Invalid repeat range');
    }
    final exceptions = CalendarExceptions.fromJson(value['exceptions']);
    if (exceptions.add.any(
      (date) =>
          (start != null &&
              date.compareTo(CalendarExceptions.key(start)) < 0) ||
          (end != null && date.compareTo(CalendarExceptions.key(end)) > 0),
    )) {
      throw const FormatException('Extra date outside repeat range');
    }
    return RepeatWindow(
      interval: value['interval'],
      weekdays: List<int>.unmodifiable(days),
      start: start,
      end: end,
      anchor: TaskDetails.date(value['anchor']),
      exceptions: exceptions,
    );
  }
  Map<String, dynamic> toJson() => {
    'interval': interval,
    'weekdays': weekdays,
    'start': start?.toIso8601String(),
    'end': end?.toIso8601String(),
    if (anchor != null) 'anchor': anchor!.toIso8601String(),
    if (!exceptions.isEmpty) 'exceptions': exceptions.toJson(),
  };

  /// Calendar arithmetic, never 24-hour additions across DST boundaries.
  DateTime? next(DateTime base, DateTime after, String rule) {
    RepeatWindow.fromJson(toJson());
    base = anchor ?? base;
    final ordinary = _nextRegular(base, after, rule);
    DateTime? extra;
    for (final key in exceptions.add) {
      final day = CalendarExceptions.day(key);
      final at = base.isUtc
          ? DateTime.utc(
              day.year,
              day.month,
              day.day,
              base.hour,
              base.minute,
              base.second,
              base.millisecond,
              base.microsecond,
            )
          : DateTime(
              day.year,
              day.month,
              day.day,
              base.hour,
              base.minute,
              base.second,
              base.millisecond,
              base.microsecond,
            );
      if (!at.isBefore(base) &&
          at.isAfter(after) &&
          (start == null || !at.isBefore(start!)) &&
          (end == null || !at.isAfter(end!)) &&
          (extra == null || at.isBefore(extra))) {
        extra = at;
      }
    }
    return ordinary == null
        ? extra
        : extra == null || ordinary.isBefore(extra)
        ? ordinary
        : extra;
  }

  DateTime? _nextRegular(DateTime base, DateTime after, String rule) {
    DateTime calendar(int year, int month, int day) => base.isUtc
        ? DateTime.utc(year, month, day, base.hour, base.minute, base.second)
        : DateTime(year, month, day, base.hour, base.minute, base.second);
    final cutoff = base.isUtc ? after.toUtc() : after.toLocal();
    final beginning = start;
    DateTime? accept(DateTime candidate) {
      if (end != null && candidate.isAfter(end!)) return null;
      return candidate;
    }

    if (rule == 'monthly' || rule == 'yearly') {
      final months = rule == 'monthly';
      final units = months
          ? (cutoff.year - base.year) * 12 + cutoff.month - base.month
          : cutoff.year - base.year;
      var step = units < 0 ? 1 : (units ~/ interval + 1) * interval;
      // The current calendar bucket may still contain a later clamped date.
      if (units > 0 && units % interval == 0) step = units;
      for (var attempts = 0; attempts < 2400; attempts++, step += interval) {
        final target = DateTime.utc(
          base.year + (months ? 0 : step),
          base.month + (months ? step : 0),
          1,
        );
        final last = DateTime.utc(target.year, target.month + 1, 0).day;
        final candidate = calendar(
          target.year,
          target.month,
          base.day > last ? last : base.day,
        );
        if (candidate.isAfter(cutoff) &&
            (beginning == null || !candidate.isBefore(beginning)) &&
            !exceptions.excludes(candidate)) {
          return accept(candidate);
        }
      }
      return null;
    }
    final origin = DateTime.utc(base.year, base.month, base.day);
    final from = DateTime.utc(
      cutoff.year,
      cutoff.month,
      cutoff.day,
    ).difference(origin).inDays;
    var offset = from < 1 ? 1 : from;
    if (beginning != null) {
      final delta = DateTime.utc(
        beginning.year,
        beginning.month,
        beginning.day,
      ).difference(origin).inDays;
      if (delta > offset) offset = delta;
    }
    // Jump near cutoff, then inspect at most a full interval of weeks.
    for (var attempts = 0; attempts < 366 * 7 + 8; attempts++, offset++) {
      final candidate = calendar(base.year, base.month, base.day + offset);
      if (end != null && candidate.isAfter(end!)) return null;
      if (!candidate.isAfter(cutoff) ||
          (beginning != null && candidate.isBefore(beginning))) {
        continue;
      }
      final week = (offset + base.weekday - 1) ~/ 7;
      var businessDays = offset ~/ 7 * 5;
      for (var day = 1; day <= offset % 7; day++) {
        if (DateTime.utc(base.year, base.month, base.day + day).weekday <= 5) {
          businessDays++;
        }
      }
      final matches = rule == 'weekly'
          ? week % interval == 0 &&
                (weekdays.isEmpty
                    ? candidate.weekday == base.weekday
                    : weekdays.contains(candidate.weekday))
          : (rule == 'workday'
                    ? businessDays % interval == 0
                    : offset % interval == 0) &&
                (rule != 'workday' || candidate.weekday <= 5) &&
                (weekdays.isEmpty || weekdays.contains(candidate.weekday));
      if (matches && !exceptions.excludes(candidate)) return candidate;
    }
    return null;
  }
}

Object? _freeze(Object? value) {
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.unmodifiable(
      value.map((key, entry) => MapEntry(key, _freeze(entry))),
    );
  }
  if (value is List) return List.unmodifiable(value.map(_freeze));
  return value;
}
