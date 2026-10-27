import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'reminder.dart';
import 'task_details.dart';

class MedicationPlan {
  MedicationPlan({
    String? id,
    this.title = '',
    this.person = '',
    this.start,
    this.end,
    this.medicines = const [],
    this.source = '',
    this.recordId,
  }) : id = id ?? const Uuid().v4();
  final String id, title, person, source;
  final String? recordId;
  final DateTime? start, end;
  final List<Medicine> medicines;
  static DateTime? day(dynamic value) {
    if (value == null || value == '') return null;
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const FormatException('Invalid course date');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null || dateKey(parsed) != value) {
      throw const FormatException('Invalid course date');
    }
    return parsed;
  }

  static String dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  factory MedicationPlan.fromJson(
    Map data, {
    String? id,
    String? recordId,
    String? source,
  }) {
    final values = data['medicines'];
    if (values is! List || values.length > 32) {
      throw const FormatException('Invalid medication list');
    }
    final parsed = values.map((e) => Medicine.fromJson(e)).toList();
    if (parsed.map((e) => e.id).toSet().length != parsed.length) {
      throw const FormatException('Duplicate medication');
    }
    return MedicationPlan(
      id: id ?? data['id'] as String?,
      title: TaskDetails.text(data['title'] ?? '', 160),
      person: TaskDetails.text(data['person'] ?? '', 80),
      start: day(data['start']),
      end: day(data['end']),
      medicines: parsed,
      source: source ?? TaskDetails.text(data['source'] ?? '', 16000),
      recordId: recordId ?? data['record_id'] as String?,
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'person': person,
    'start': start == null ? null : dateKey(start!),
    'end': end == null ? null : dateKey(end!),
    'medicines': medicines.map((m) => m.toJson()).toList(),
    'source': source,
    'record_id': recordId,
  };
  List<String> get issues {
    final problems = <String>[];
    if (title.trim().isEmpty) problems.add('planTitle');
    if (start == null ||
        end == null ||
        end!.isBefore(start!) ||
        DateTime.utc(end!.year, end!.month, end!.day)
                .difference(DateTime.utc(start!.year, start!.month, start!.day))
                .inDays >
            92) {
      problems.add('courseDates');
    }
    if (medicines.isEmpty) problems.add('medicineMissing');
    for (var i = 0; i < medicines.length; i++) {
      if (!medicines[i].complete) problems.add('medicine:${i + 1}');
    }
    return problems;
  }

  ({Reminder owner, List<Reminder> doses}) build({required DateTime now}) {
    if (issues.isNotEmpty) {
      throw const FormatException('Medication information needs confirmation');
    }
    final doses = <Reminder>[];
    for (final medicine in medicines) {
      final rawFirst = medicine.start ?? start!, rawLast = medicine.end ?? end!;
      final first = DateTime(rawFirst.year, rawFirst.month, rawFirst.day),
          last = DateTime(rawLast.year, rawLast.month, rawLast.day);
      if (first.isBefore(DateTime(start!.year, start!.month, start!.day)) ||
          last.isAfter(DateTime(end!.year, end!.month, end!.day)) ||
          last.isBefore(first)) {
        throw const FormatException('Invalid medication dates');
      }
      for (
        var date = first;
        !date.isAfter(last);
        date = DateTime(date.year, date.month, date.day + 1)
      ) {
        for (final minute in medicine.minutes) {
          final at = DateTime(
            date.year,
            date.month,
            date.day,
            minute ~/ 60,
            minute % 60,
          );
          if (!at.isAfter(now)) continue;
          final name = medicine.name.trim();
          doses.add(
            Reminder(
              id: '$id:${medicine.id}:${dateKey(date)}:$minute',
              recordId: recordId,
              taskTitle: name,
              taskSummary:
                  '${medicine.strength} · ${medicine.amount} ${medicine.unit}\n${medicine.meal}\n${medicine.notes}',
              quadrantLevel: 2,
              triggerTime: at,
              eventTime: at,
              createdAt: now,
              sourceText: medicine.evidence.isEmpty
                  ? source
                  : medicine.evidence,
              detailsJson: TaskDetails(
                kind: 'medication',
                planId: id,
                data: medicine.toJson(),
              ).encode(),
            ),
          );
          if (doses.length > 1000) {
            throw const FormatException('Course has too many doses');
          }
        }
      }
    }
    if (doses.isEmpty) {
      throw const FormatException('Course has no future doses');
    }
    doses.sort((a, b) => a.triggerTime!.compareTo(b.triggerTime!));
    return (
      owner: Reminder(
        id: id,
        recordId: recordId,
        taskTitle: title.trim(),
        sourceText: source,
        taskSummary: person,
        quadrantLevel: 2,
        createdAt: now,
        detailsJson: TaskDetails(
          kind: 'medicationPlan',
          data: toJson(),
        ).encode(),
      ),
      doses: doses,
    );
  }

  String encode() => jsonEncode(toJson());
}

class Medicine {
  Medicine({
    String? id,
    this.name = '',
    this.strength = '',
    this.amount = '',
    this.unit = '',
    this.meal = '',
    this.times = const [],
    this.start,
    this.end,
    this.notes = '',
    this.evidence = '',
    this.unresolved = const [],
  }) : id = id ?? const Uuid().v4();
  final String id, name, strength, amount, unit, meal, notes, evidence;
  final List<String> times, unresolved;
  final DateTime? start, end;
  static final clock = RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$');
  List<int> get minutes =>
      times
          .map(
            (t) =>
                int.parse(t.substring(0, 2)) * 60 + int.parse(t.substring(3)),
          )
          .toSet()
          .toList()
        ..sort();
  bool get complete =>
      name.trim().isNotEmpty &&
      strength.trim().isNotEmpty &&
      (num.tryParse(amount)?.isFinite ?? false) &&
      num.parse(amount) > 0 &&
      num.parse(amount) < 1000000 &&
      unit.trim().isNotEmpty &&
      meal.trim().isNotEmpty &&
      times.isNotEmpty &&
      times.length <= 8 &&
      times.every(clock.hasMatch) &&
      times.toSet().length == times.length &&
      unresolved.isEmpty;
  factory Medicine.fromJson(dynamic data) {
    if (data is! Map) throw const FormatException('Invalid medication');
    List<String> list(String key, int limit) {
      final items = data[key] ?? [];
      if (items is! List || items.length > limit) {
        throw const FormatException('Invalid medication fields');
      }
      return items.map((e) => TaskDetails.text(e, 512)).toList();
    }

    return Medicine(
      id: data['id'] == null ? null : TaskDetails.text(data['id'], 48),
      name: TaskDetails.text(data['name'] ?? '', 160),
      strength: TaskDetails.text(data['strength'] ?? '', 160),
      amount: TaskDetails.text(data['amount']?.toString() ?? '', 32),
      unit: TaskDetails.text(data['unit'] ?? '', 40),
      meal: TaskDetails.text(data['meal'] ?? '', 160),
      times: list('times', 8),
      start: MedicationPlan.day(data['start']),
      end: MedicationPlan.day(data['end']),
      notes: TaskDetails.text(data['notes'] ?? '', 2000),
      evidence: TaskDetails.text(data['evidence'] ?? '', 4000),
      unresolved: list('unresolved', 16),
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'strength': strength,
    'amount': amount,
    'unit': unit,
    'meal': meal,
    'times': times,
    'start': start == null ? null : MedicationPlan.dateKey(start!),
    'end': end == null ? null : MedicationPlan.dateKey(end!),
    'notes': notes,
    'evidence': evidence,
    'unresolved': unresolved,
  };
}
