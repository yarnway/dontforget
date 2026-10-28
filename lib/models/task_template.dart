import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'task_details.dart';

/// Reusable content only; a template never carries dates, outcomes or notices.
class TaskTemplate {
  const TaskTemplate({
    required this.id,
    required this.name,
    required this.title,
    required this.items,
    this.tags = const [],
    this.project = '',
  });

  static const storageKey = 'taskTemplates';
  static const maxCount = 24;
  static const maxBytes = 262144;
  final String id, name, title, project;
  final List<String> items, tags;

  factory TaskTemplate.fromJson(dynamic raw) {
    const keys = {'id', 'name', 'title', 'items', 'tags', 'project'};
    if (raw is! Map ||
        raw.length != keys.length ||
        !raw.keys.toSet().containsAll(keys)) {
      throw const FormatException('Invalid task template');
    }
    String text(String key, int limit, {bool required = false}) {
      final v = TaskDetails.text(raw[key], limit);
      if (v != v.trim() ||
          (required && v.isEmpty) ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(v)) {
        throw const FormatException('Invalid template text');
      }
      return v;
    }

    List<String> list(String key, int count, int limit) {
      final v = raw[key];
      if (v is! List || v.length > count) {
        throw const FormatException('Invalid template list');
      }
      return List.unmodifiable(
        v.map((e) {
          final s = TaskDetails.text(e, limit);
          if (s.trim().isEmpty ||
              s != s.trim() ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(s)) {
            throw const FormatException('Invalid template item');
          }
          return s;
        }),
      );
    }

    final id = text('id', 64, required: true);
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9-]{0,63}$').hasMatch(id)) {
      throw const FormatException('Invalid template ID');
    }
    final tags = list('tags', 16, 64);
    if (tags.toSet().length != tags.length) {
      throw const FormatException('Duplicate template tag');
    }
    return TaskTemplate(
      id: id,
      name: text('name', 64, required: true),
      title: text('title', 160, required: true),
      items: list('items', 64, 512),
      tags: tags,
      project: text('project', 128),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'title': title,
    'items': items,
    'tags': tags,
    'project': project,
  };
  bool sameAs(TaskTemplate other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  TaskDetails instantiate() => TaskDetails(
    checklist: [
      for (final label in items) ChecklistItem(const Uuid().v4(), label),
    ],
    tags: List.of(tags),
    project: project,
  );

  static List<TaskTemplate> decode(dynamic raw) {
    if (raw == null) return const [];
    if (raw is! Map ||
        raw.length != 2 ||
        raw['version'] != 1 ||
        raw['version'] is! int ||
        raw['items'] is! List ||
        (raw['items'] as List).length > maxCount ||
        utf8.encode(jsonEncode(raw)).length > maxBytes) {
      throw const FormatException('Invalid template library');
    }
    final items = (raw['items'] as List).map(TaskTemplate.fromJson).toList();
    if (items.map((e) => e.id).toSet().length != items.length ||
        items.map((e) => e.name.toLowerCase()).toSet().length != items.length) {
      throw const FormatException('Duplicate template');
    }
    return List.unmodifiable(items);
  }

  static Map<String, dynamic> encode(Iterable<TaskTemplate> items) {
    final raw = {'version': 1, 'items': items.map((e) => e.toJson()).toList()};
    decode(raw);
    return raw;
  }
}
