import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'stored_json.dart';
import 'task_template.dart';

enum TemplateImportAction { skip, copy, replace }

class TemplateImportChoice {
  const TemplateImportChoice(this.item, this.action);
  final TaskTemplate item;
  final TemplateImportAction action;
}

class TaskTemplateTransfer {
  static const format = 'dontforget.templates';
  static const maxBytes = TaskTemplate.maxBytes + 128;
  static String encode(List<TaskTemplate> items) {
    TaskTemplate.encode(items);
    final result = jsonEncode({
      'format': format,
      'version': 1,
      'items': items.map((e) => e.toJson()).toList(),
    });
    if (utf8.encode(result).length > maxBytes) {
      throw const FormatException('Template file too large');
    }
    return result;
  }

  static List<TaskTemplate> decode(String source) {
    if (utf8.encode(source).length > maxBytes) {
      throw const FormatException('Template file too large');
    }
    final raw = decodeStoredJson(source);
    if (raw is! Map ||
        raw.length != 3 ||
        raw['format'] != format ||
        raw['version'] is! int ||
        raw['version'] != 1) {
      throw const FormatException('Unsupported template file');
    }
    return TaskTemplate.decode({'version': 1, 'items': raw['items']});
  }

  static List<TaskTemplate> merge(
    List<TaskTemplate> current,
    List<TemplateImportChoice> choices,
  ) {
    TaskTemplate.encode(current);
    TaskTemplate.encode(choices.map((e) => e.item));
    final next = List<TaskTemplate>.of(current);
    for (final choice in choices) {
      if (choice.action == TemplateImportAction.skip) continue;
      final source = choice.item;
      final at = next.indexWhere(
        (e) => e.name.toLowerCase() == source.name.toLowerCase(),
      );
      String id, name = source.name;
      if (choice.action == TemplateImportAction.replace) {
        if (at < 0) throw const FormatException('Replacement target changed');
        id = next[at].id;
      } else {
        id = const Uuid().v4();
        if (at >= 0) {
          var suffix = 2;
          do {
            final ending = ' ($suffix)';
            var prefix = '';
            for (final rune in source.name.runes) {
              final letter = String.fromCharCode(rune);
              if (prefix.length + letter.length > 64 - ending.length) break;
              prefix += letter;
            }
            name = '$prefix$ending';
            suffix++;
          } while (next.any((e) => e.name.toLowerCase() == name.toLowerCase()));
        }
      }
      final item = TaskTemplate.fromJson({
        ...source.toJson(),
        'id': id,
        'name': name,
      });
      if (choice.action == TemplateImportAction.replace) {
        next[at] = item;
      } else {
        next.add(item);
      }
    }
    TaskTemplate.encode(next);
    return List.unmodifiable(next);
  }
}
