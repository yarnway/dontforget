import 'backup_export_name.dart';

/// Bounded location references only. Reading history never opens a saved file.
class BackupExportHistory {
  static const maxEntries = 20;
  static const _versionKey = 'history_version';
  static const _previousKey = 'previous_exports';

  static Map<String, dynamic>? _record(Object? value) {
    if (value is! Map) return null;
    final at = value['at'], location = value['location'];
    if (at is! String ||
        at.length > 64 ||
        DateTime.tryParse(at) == null ||
        location is! String ||
        location.trim().isEmpty ||
        location.length > 8192 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(location)) {
      return null;
    }
    final name =
        BackupExportName.display(value['name']) ??
        BackupExportName.fromLocation(location);
    return {
      'at': at,
      'location': location,
      if (name != null) 'name': name,
      if (value['encrypted'] is bool) 'encrypted': value['encrypted'],
      for (final key in ['media', 'missing'])
        if (value[key] is int && value[key] >= 0) key: value[key],
      if (value['format'] is int && value['format'] > 0)
        'format': value['format'],
    };
  }

  static bool _same(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a['at'] == b['at'] &&
      a['location'] == b['location'] &&
      a['name'] == b['name'];

  /// The existing last-export map remains readable without a migration write.
  static List<Map<String, dynamic>> read(Object? value) {
    final latest = _record(value);
    if (latest == null) return const [];
    final result = <Map<String, dynamic>>[latest];
    if (value is Map && value[_versionKey] == 1) {
      final previous = value[_previousKey];
      if (previous is List) {
        // Inspect only the bounded slots this version writes, including when
        // imported metadata is malformed or much larger than expected.
        for (final raw in previous.take(maxEntries - 1)) {
          final record = _record(raw);
          if (record != null && !result.any((entry) => _same(entry, record))) {
            result.add(record);
          }
        }
      }
    }
    return List.unmodifiable(result.map(Map<String, dynamic>.unmodifiable));
  }

  static Map<String, dynamic> prepend(
    Map<String, dynamic> latest,
    Object? existing,
  ) {
    if (existing is Map &&
        existing.containsKey(_versionKey) &&
        existing[_versionKey] != 1) {
      throw const FormatException('Unsupported backup history version');
    }
    final record = _record(latest);
    if (record == null) throw const FormatException('Invalid backup record');
    return {
      ...record,
      _versionKey: 1,
      _previousKey: read(
        existing,
      ).where((entry) => !_same(entry, record)).take(maxEntries - 1).toList(),
    };
  }
}
