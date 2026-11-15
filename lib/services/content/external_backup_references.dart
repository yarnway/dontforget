import 'dart:convert';
import '../recovery/backup_inspector.dart';

/// A bounded, explicit protection snapshot. Source files need not stay mounted.
/// Never stores a backup's settings, credentials, text or picker cache location.
class ExternalBackupReferences {
  static const storageKey = 'externalBackupReferences';
  static const maxEntries = 20;
  static const maxPaths = 4000;
  static const maxBytes = 256 * 1024;
  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static bool _validName(Object? name) =>
      name is String &&
      name.trim().isNotEmpty &&
      name.runes.length <= 255 &&
      !RegExp(r'[\x00-\x1f\x7f-\x9f/\\\u2028\u2029]').hasMatch(name);

  static List<Map<String, dynamic>> read(Object? raw) {
    if (raw == null) return const [];
    if (raw is! Map ||
        raw['version'] != 1 ||
        raw['entries'] is! List ||
        (raw['entries'] as List).length > maxEntries ||
        utf8.encode(jsonEncode(raw)).length > maxBytes) {
      throw const FormatException('Invalid external backup references');
    }
    final entries = <Map<String, dynamic>>[];
    final identities = <String>{};
    var count = 0;
    for (final item in raw['entries']) {
      if (item is! Map ||
          item['digest'] is! String ||
          !_digest.hasMatch(item['digest']) ||
          !identities.add(item['digest']) ||
          !_validName(item['name']) ||
          item['at'] is! String ||
          (item['at'] as String).length > 64 ||
          DateTime.tryParse(item['at']) == null ||
          item['paths'] is! List) {
        throw const FormatException('Invalid external backup reference');
      }
      final paths = <String>{};
      for (final path in item['paths']) {
        if (++count > maxPaths ||
            path is! String ||
            path.isEmpty ||
            path.length > 8192 ||
            path.contains('\u0000') ||
            !paths.add(path)) {
          throw const FormatException('Invalid external media reference');
        }
      }
      entries.add(
        Map.unmodifiable({
          'digest': item['digest'],
          'name': item['name'],
          'at': item['at'],
          'paths': List<String>.unmodifiable(paths),
        }),
      );
    }
    return List.unmodifiable(entries);
  }

  static Map<String, dynamic> _encode(List<Map<String, dynamic>> entries) {
    final result = {'version': 1, 'entries': entries};
    read(result);
    return result;
  }

  static Map<String, dynamic> add(
    Object? raw,
    BackupPreview preview,
    String name, {
    required DateTime at,
  }) {
    final entries = read(raw);
    final existing = entries.where((e) => e['digest'] == preview.digest);
    // Re-registering the same bytes is idempotent; never evict protections.
    if (existing.isNotEmpty) return _encode(entries);
    return _encode([
      {
        'digest': preview.digest,
        'name': _validName(name) ? name : 'backup',
        'at': at.toIso8601String(),
        'paths': preview.referencedMediaPaths.toList()..sort(),
      },
      ...entries,
    ]);
  }

  static Map<String, dynamic>? remove(Object? raw, String digest) {
    final entries = read(raw);
    if (!entries.any((e) => e['digest'] == digest)) {
      throw StateError('External backup reference changed');
    }
    final remaining = entries.where((e) => e['digest'] != digest).toList();
    return remaining.isEmpty ? null : _encode(remaining);
  }
}
