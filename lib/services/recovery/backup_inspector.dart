import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as paths;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../models/settings.dart';

class BackupPreview {
  const BackupPreview({
    required this.version,
    required this.digest,
    required this.counts,
    required this.containsCredentials,
    required this.missingMedia,
    required this.unresolvedReferences,
    this.timestamp,
  });
  final int version;
  final String digest;
  final Map<String, int> counts;
  final bool containsCredentials;
  final int missingMedia;
  final int unresolvedReferences;
  final DateTime? timestamp;
}

/// Reads a bounded private copy. Never opens or replaces the application's DB.
/// Sidecar-bearing SQLite files are not standalone backups and are rejected.
class BackupInspector {
  BackupInspector(
    this.factory, {
    this.maxBytes = 64 * 1024 * 1024,
    this.maxRows = 100000,
  });
  final DatabaseFactory factory;
  final int maxBytes;
  final int maxRows;

  Future<BackupPreview> inspect(File source) async {
    Directory? temporary;
    Database? db;
    try {
      for (final suffix in ['-wal', '-journal']) {
        if (await File('${source.path}$suffix').exists()) {
          throw const FormatException('请选择已完成的独立备份，不要选择正在使用的数据库。');
        }
      }
      if (await source.length() > maxBytes) {
        throw const FormatException('备份超过检查大小上限。');
      }
      temporary = await Directory.systemTemp.createTemp('dontforget-inspect-');
      final copy = File('${temporary.path}/candidate');
      final sink = copy.openWrite();
      var total = 0;
      try {
        await for (final chunk in source.openRead()) {
          total += chunk.length;
          if (total > maxBytes) throw const FormatException('备份超过检查大小上限。');
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      final digest = (await sha256.bind(copy.openRead()).first).toString();
      final header = await copy.open();
      final signature = await header.read(16);
      await header.close();
      Map<String, dynamic> data;
      if (ascii.decode(signature, allowInvalid: true) ==
          'SQLite format 3\u0000') {
        db = await factory.openDatabase(
          copy.path,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
        );
        if ((await db.rawQuery(
              'PRAGMA integrity_check',
            )).single.values.single !=
            'ok') {
          throw const FormatException('备份数据库完整性检查失败。');
        }
        final version = await db.getVersion();
        _version(version);
        final objects = await db.rawQuery(
          "SELECT name,type FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
        );
        if (objects.any((o) => o['type'] != 'table' && o['type'] != 'index')) {
          throw const FormatException('备份包含不支持的数据库对象。');
        }
        final names = objects
            .where((o) => o['type'] == 'table')
            .map((o) => o['name'])
            .toSet();
        if (names.length != 3 || !names.containsAll(_tables.keys)) {
          throw const FormatException('备份表结构不匹配。');
        }
        data = {'version': version, 'timestamp': null};
        for (final entry in _tables.entries) {
          final columns = (await db.rawQuery(
            'PRAGMA table_info(${entry.key})',
          )).map((r) => r['name']).toSet();
          final expected = _columns(entry.value, version).keys.toSet();
          if (columns.length != expected.length ||
              !columns.containsAll(expected)) {
            throw const FormatException('备份字段不匹配。');
          }
          final count =
              (await db.rawQuery(
                    'SELECT count(*) FROM ${entry.key}',
                  )).single.values.single
                  as int;
          if (count > maxRows) throw const FormatException('备份记录数超过检查上限。');
          data[entry.value] = await db.query(entry.key);
        }
      } else {
        final text = await copy.readAsString();
        final decoded = await _decode(text);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('备份格式不匹配。');
        }
        data = decoded;
      }
      final validated = await _runValidation(data, maxRows);
      var missing = 0;
      for (final path in validated.paths) {
        // A path index is not the file itself. Do not fetch URLs or expand paths.
        if (!paths.isAbsolute(path) ||
            path.startsWith('//') ||
            path.startsWith(r'\\') ||
            !await File(path).exists()) {
          missing++;
        }
      }
      return BackupPreview(
        version: data['version'],
        digest: digest,
        counts: Map.unmodifiable(validated.counts),
        containsCredentials: validated.credentials,
        missingMedia: missing,
        unresolvedReferences: validated.unresolved,
        timestamp: data['timestamp'] == null
            ? null
            : DateTime.parse(data['timestamp']),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      // Never surface raw SQLite rows, JSON fragments, paths or credentials.
      throw const FormatException('无法检查此备份，请选择有效的 JSON 快照或独立镜像数据库。');
    } finally {
      await db?.close();
      if (temporary != null) await temporary.delete(recursive: true);
    }
  }
}

const _tables = {
  'Settings': 'settings',
  'MediaRecords': 'media_records',
  'Reminders': 'reminders',
};
const _settings = {
  'id': 's',
  'api_key': 's?',
  'base_url': 's?',
  'model_name': 's?',
  'language': 's?',
};
const _media = {
  'id': 's',
  'type': 's',
  'content_or_path': 's',
  'created_at': 'd',
};
const _reminders = {
  'id': 's',
  'record_id': 's?',
  'task_title': 's',
  'task_summary': 's?',
  'quadrant_level': 'q',
  'urgency_level': 's?',
  'importance_level': 's?',
  'trigger_time': 'd?',
  'is_completed': 'b',
  'is_recurring': 'b?',
  'recurrence_rule': 's?',
  'recurrence_description': 's?',
  'is_emotion_filtered': 'b?',
  'sub_tasks': 's?',
  'created_at': 'd?',
  'review_level': 'i?',
  'next_review_at': 'd?',
  'original_quadrant_level': 'q?',
  'is_dynamically_promoted': 'b?',
  'linked_task_ids': 's?',
  'context_trigger': 's?',
};
Map<String, String> _columns(String table, int version) => switch (table) {
  'settings' => {
    ..._settings,
    if (version == 9) ...{'ai_profiles_json': 's', 'ai_fallback_enabled': 'b'},
  },
  'media_records' => _media,
  _ => _reminders,
};
void _version(Object? version) {
  if (version is! int || version < 7 || version > 9) {
    throw const FormatException('不支持此备份版本。');
  }
}

class _Validated {
  _Validated(this.counts, this.credentials, this.paths, this.unresolved);
  final Map<String, int> counts;
  final bool credentials;
  final List<String> paths;
  final int unresolved;
}

_Validated _validate(Map<String, dynamic> data, int maxRows) {
  _version(data['version']);
  if (data.keys.length != 5 ||
      !data.keys.toSet().containsAll([
        'version',
        'timestamp',
        ..._tables.values,
      ])) {
    throw const FormatException('备份顶层结构不匹配。');
  }
  if (data['timestamp'] != null &&
      (data['timestamp'] is! String ||
          DateTime.tryParse(data['timestamp']) == null)) {
    throw const FormatException('备份时间无效。');
  }
  final ids = <String, Set<String>>{};
  final counts = <String, int>{};
  for (final table in _tables.values) {
    final rows = data[table];
    if (rows is! List || rows.length > maxRows) {
      throw const FormatException('备份记录数量无效。');
    }
    counts[table] = rows.length;
    ids[table] = {};
    final columns = _columns(table, data['version']);
    for (final row in rows) {
      if (row is! Map ||
          row.length != columns.length ||
          !row.keys.toSet().containsAll(columns.keys)) {
        throw const FormatException('备份记录字段不匹配。');
      }
      for (final entry in columns.entries) {
        final v = row[entry.key], type = entry.value;
        if (v == null && type.endsWith('?')) continue;
        final ok = switch (type[0]) {
          's' => v is String,
          'd' => v is String && DateTime.tryParse(v) != null,
          'b' => v is int && (v == 0 || v == 1),
          'q' => v is int && v >= 1 && v <= 4,
          'i' => v is int && v >= 0 && v <= 5,
          _ => false,
        };
        if (!ok) throw const FormatException('备份字段类型或取值无效。');
      }
      if ((row['id'] as String).isEmpty || !ids[table]!.add(row['id'])) {
        throw const FormatException('备份记录 ID 重复或为空。');
      }
    }
  }
  if (counts['settings'] != 1 || !ids['settings']!.contains('default')) {
    throw const FormatException('备份必须包含唯一的默认设置。');
  }
  final settings = AppSettings.fromJson(
    Map<String, dynamic>.from((data['settings'] as List).single),
  );
  final paths = <String>[];
  for (final row in data['media_records']) {
    if (!['text', 'audio', 'image', 'video', 'file'].contains(row['type'])) {
      throw const FormatException('备份媒体类型不支持。');
    }
    if (row['type'] != 'text') paths.add(row['content_or_path']);
  }
  var unresolved = 0;
  for (final row in data['reminders']) {
    if (row['record_id'] != null &&
        !ids['media_records']!.contains(row['record_id'])) {
      unresolved++;
    }
    final linked = row['linked_task_ids'];
    if (linked != null && linked != '') {
      final list = jsonDecode(linked);
      if (list is! List || list.any((v) => v is! String)) {
        throw const FormatException('事项关联结构无效。');
      }
      unresolved += list.where((v) => !ids['reminders']!.contains(v)).length;
    }
    if (row['sub_tasks'] != null && row['sub_tasks'] != '') {
      final parts = jsonDecode(row['sub_tasks']);
      if (parts is! List) throw const FormatException('子任务结构无效。');
    }
    if (row['recurrence_rule'] != null &&
        ![
          'none',
          'daily',
          'workday',
          'weekly',
          'monthly',
          'yearly',
        ].contains(row['recurrence_rule'])) {
      throw const FormatException('循环规则不支持。');
    }
  }
  return _Validated(
    counts,
    settings.apiKey.isNotEmpty ||
        settings.aiProfiles.any((p) => p.settings.apiKey.isNotEmpty),
    paths,
    unresolved,
  );
}

Future<dynamic> _decode(String text) => Isolate.run(() => jsonDecode(text));
Future<_Validated> _runValidation(Map<String, dynamic> data, int maxRows) =>
    Isolate.run(() => _validate(data, maxRows));
