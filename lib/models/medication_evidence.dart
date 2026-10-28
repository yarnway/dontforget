import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'task_details.dart';

class MedicationSource {
  const MedicationSource({
    required this.id,
    required this.kind,
    required this.label,
    this.recordId,
    this.text = '',
  });
  final String id, kind, label, text;
  final String? recordId;
  factory MedicationSource.fromJson(dynamic data) {
    if (data is! Map ||
        !const {'manual', 'text', 'image', 'audio'}.contains(data['kind'])) {
      throw const FormatException('Invalid medication source');
    }
    final id = TaskDetails.text(data['id'], 64),
        label = TaskDetails.text(data['label'], 160);
    if (id.isEmpty || label.trim().isEmpty) {
      throw const FormatException('Missing medication source');
    }
    return MedicationSource(
      id: id,
      kind: data['kind'],
      label: label,
      recordId: data['record_id'] == null
          ? null
          : TaskDetails.text(data['record_id'], 160),
      text: TaskDetails.text(data['text'] ?? '', 16000),
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'label': label,
    'record_id': recordId,
    'text': text,
  };
}

class MedicationCitation {
  const MedicationCitation({
    required this.field,
    required this.sourceId,
    required this.value,
    required this.quote,
  });
  final String field, sourceId, value, quote;
  factory MedicationCitation.fromJson(dynamic data) {
    if (data is! Map) {
      throw const FormatException('Invalid medication citation');
    }
    final field = TaskDetails.text(data['field'], 32),
        id = TaskDetails.text(data['source_id'], 64),
        quote = TaskDetails.text(data['quote'], 512);
    if (id.isEmpty || quote.trim().isEmpty) {
      throw const FormatException('Missing citation');
    }
    return MedicationCitation(
      field: field,
      sourceId: id,
      value: TaskDetails.text(data['value'], 512),
      quote: quote,
    );
  }
  Map<String, dynamic> toJson() => {
    'field': field,
    'source_id': sourceId,
    'value': value,
    'quote': quote,
  };
}

class MedicationFacts {
  static const medicineFields = {
    'name',
    'strength',
    'amount',
    'unit',
    'meal',
    'times',
    'start',
    'end',
    'notes',
  };
  static const planFields = {'title', 'person', 'start', 'end'};
  static const requiredMedicineFields = {
    'name',
    'strength',
    'amount',
    'unit',
    'meal',
    'times',
    'start',
    'end',
  };
  static List<MedicationCitation> citations(dynamic raw, Set<String> fields) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > 48) {
      throw const FormatException('Too many citations');
    }
    final all = raw.map(MedicationCitation.fromJson).toList();
    if (all.any((e) => !fields.contains(e.field))) {
      throw const FormatException('Unknown citation field');
    }
    return List.unmodifiable(all);
  }

  static Map<String, String> resolutions(dynamic raw, Set<String> fields) {
    if (raw == null) return const {};
    if (raw is! Map ||
        raw.keys.any((e) => !fields.contains(e)) ||
        raw.values.any(
          (e) => e is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(e),
        )) {
      throw const FormatException('Invalid field review');
    }
    return Map.unmodifiable(Map<String, String>.from(raw));
  }

  static String canonical(String field, dynamic value) {
    if (value == null) return '';
    if (field == 'times') {
      final values = value is List
          ? value.map((e) => e.toString()).toList()
          : value.toString().split(RegExp('[,，、\\s]+'));
      return (values
              .map((e) => e.trim().replaceAll('：', ':'))
              .where((e) => e.isNotEmpty)
              .toList()
            ..sort())
          .join(',');
    }
    final text = value.toString().trim();
    if (field == 'amount') {
      final number = num.tryParse(text);
      if (number != null && number.isFinite) {
        return number % 1 == 0 ? number.toInt().toString() : number.toString();
      }
    }
    return text;
  }

  static String fingerprint(
    String field,
    dynamic value,
    List<MedicationCitation> citations,
  ) {
    final claims =
        citations
            .where((e) => e.field == field)
            .map(
              (e) =>
                  jsonEncode([e.sourceId, canonical(field, e.value), e.quote]),
            )
            .toList()
          ..sort();
    return sha256
        .convert(
          utf8.encode(jsonEncode([field, canonical(field, value), claims])),
        )
        .toString();
  }

  static List<String> conflicts(
    Map<String, dynamic> values,
    List<MedicationCitation> citations,
    Map<String, String> reviewed, {
    Set<String> requiredFields = const {},
  }) {
    final result = <String>[];
    for (final field in {
      ...citations.map((e) => e.field),
      ...requiredFields.where((f) => canonical(f, values[f]).isNotEmpty),
    }) {
      final claims = citations
          .where((e) => e.field == field)
          .map((e) => canonical(field, e.value))
          .toSet();
      if ((claims.length > 1 ||
              !claims.contains(canonical(field, values[field]))) &&
          reviewed[field] != fingerprint(field, values[field], citations)) {
        result.add(field);
      }
    }
    return result;
  }

  static void validateSources(
    List<MedicationSource> sources,
    Iterable<MedicationCitation> citations,
  ) {
    if (sources.length > 8 ||
        sources.map((e) => e.id).toSet().length != sources.length ||
        sources.fold<int>(0, (n, e) => n + e.text.length) > 16000) {
      throw const FormatException('Too many medication sources');
    }
    final byId = {for (final s in sources) s.id: s};
    for (final citation in citations) {
      final source = byId[citation.sourceId];
      if (source == null ||
          (source.kind != 'image' &&
              source.text.isNotEmpty &&
              !source.text.contains(citation.quote))) {
        throw const FormatException('Citation does not match source');
      }
    }
  }
}

class MealTime {
  const MealTime({required this.id, required this.label, required this.time});
  final String id, label, time;
  static final clock = RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$');
  int get minute =>
      int.parse(time.substring(0, 2)) * 60 + int.parse(time.substring(3));
  factory MealTime.fromJson(dynamic raw) {
    if (raw is! Map) throw const FormatException('Invalid meal time');
    final id = TaskDetails.text(raw['id'], 64),
        label = TaskDetails.text(raw['label'] ?? '', 80),
        time = TaskDetails.text(raw['time'] ?? '', 5);
    if (id.isEmpty || label.trim().isEmpty || !clock.hasMatch(time)) {
      throw const FormatException('Explicit meal label and time required');
    }
    return MealTime(id: id, label: label, time: time);
  }
  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'time': time};
}

class MealDoseTime {
  const MealDoseTime({required this.mealId, this.offsetMinutes});
  final String mealId;
  final int? offsetMinutes;
  factory MealDoseTime.fromJson(dynamic raw) {
    if (raw is! Map) throw const FormatException('Invalid meal link');
    final offset = raw['offset'];
    if (offset != null && (offset is! int || offset < -180 || offset > 180)) {
      throw const FormatException('Invalid meal offset');
    }
    return MealDoseTime(
      mealId: TaskDetails.text(raw['meal_id'] ?? '', 64),
      offsetMinutes: offset,
    );
  }
  Map<String, dynamic> toJson() => {'meal_id': mealId, 'offset': offsetMinutes};
  int resolve(List<MealTime> meals) {
    final meal = meals.where((e) => e.id == mealId).firstOrNull;
    if (meal == null ||
        offsetMinutes == null ||
        offsetMinutes! < -180 ||
        offsetMinutes! > 180) {
      throw const FormatException('Meal and offset required');
    }
    final result = meal.minute + offsetMinutes!;
    if (result < 0 || result >= 1440) {
      throw const FormatException(
        'Meal offset crosses a calendar day; enter an explicit clock time',
      );
    }
    return result;
  }
}
