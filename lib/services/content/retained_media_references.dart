import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show OpenDatabaseOptions;
import '../../data/database_helper.dart';
import '../../models/stored_json.dart';
import '../recovery/backup_inspector.dart';

/// Read-only copies of known app backups; never opens the live database again.
/// Unknown/corrupt/oversized retained material protects physical files instead
/// of guessing that the corresponding attachments are unused.
class RetainedMediaReferences {
  static const maxBytes = 64 * 1024 * 1024;
  static Future<({Set<String> paths, bool uncertain})> read(
    DatabaseHelper database,
  ) async {
    final directory = await database.notificationActionQueueDirectory;
    final candidates = <File>[];
    var uncertain = false;
    await for (final entry in directory.list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (entry is File &&
          const {
            'ha_snapshot.json',
            'dont_forget_v3.mirror.db',
          }.contains(name)) {
        candidates.add(entry);
      }
      if (entry is File &&
          name.startsWith('pre-migration-') &&
          name.endsWith('.json')) {
        candidates.add(entry);
      }
      if (entry is Directory && name.startsWith('recovery-')) {
        await for (final child in entry.list(followLinks: false)) {
          if (child is File &&
              const {
                'rollback.db',
                'source.backup',
              }.contains(p.basename(child.path))) {
            candidates.add(child);
          }
          if (child is Link) uncertain = true;
        }
      }
      if (entry is Directory && name.startsWith('schema-upgrade-')) {
        final snapshot = File(p.join(entry.path, 'snapshot.json'));
        if (await FileSystemEntity.type(snapshot.path, followLinks: false) ==
            FileSystemEntityType.file) {
          candidates.add(snapshot);
        } else {
          uncertain = true;
        }
      }
      if (entry is Link &&
          (name == 'ha_snapshot.json' ||
              name == 'dont_forget_v3.mirror.db' ||
              name.startsWith('recovery-') ||
              name.startsWith('schema-upgrade-'))) {
        uncertain = true;
      }
      if (candidates.length > 256) {
        uncertain = true;
        break;
      }
    }
    final paths = <String>{};
    for (final file in candidates) {
      Directory? temporary;
      try {
        var hasSidecar = false;
        for (final suffix in ['-wal', '-shm', '-journal']) {
          if (await FileSystemEntity.type(
                '${file.path}$suffix',
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound) {
            hasSidecar = true;
          }
        }
        if (hasSidecar) {
          uncertain = true;
          continue;
        }
        final before = await file.stat();
        if (before.size > maxBytes ||
            before.type != FileSystemEntityType.file) {
          uncertain = true;
          continue;
        }
        temporary = await Directory.systemTemp.createTemp(
          'dontforget-reference-read-',
        );
        final copy = await file.copy(p.join(temporary.path, 'copy'));
        final after = await file.stat();
        if (after.size != before.size ||
            after.modified != before.modified ||
            await copy.length() != before.size) {
          uncertain = true;
          continue;
        }
        final prefix = await copy
            .openRead(0, before.size < 16 ? before.size : 16)
            .expand((e) => e)
            .toList();
        List rows;
        if (ascii
            .decode(prefix, allowInvalid: true)
            .startsWith('SQLite format 3')) {
          final sql = await BackupInspector.platform().factory.openDatabase(
            copy.path,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          try {
            rows = await sql.query(
              'MediaRecords',
              columns: ['type', 'content_or_path'],
              limit: 100001,
            );
          } finally {
            await sql.close();
          }
        } else {
          final raw = decodeStoredJson(await copy.readAsString());
          if (raw is! Map ||
              raw['version'] is! int ||
              raw['version'] < 7 ||
              raw['version'] > DatabaseHelper.schemaVersion ||
              raw['settings'] is! List ||
              raw['reminders'] is! List ||
              raw['media_records'] is! List) {
            throw const FormatException('Unknown retained backup');
          }
          rows = raw['media_records'];
        }
        if (rows.length > 100000) {
          throw const FormatException('Retained backup too large');
        }
        for (final row in rows) {
          if (row is! Map ||
              row['type'] is! String ||
              row['content_or_path'] is! String) {
            throw const FormatException('Invalid retained references');
          }
          if (row['type'] != 'text') {
            paths.add(row['content_or_path'] as String);
          }
        }
      } catch (_) {
        uncertain = true;
      } finally {
        if (temporary != null) await temporary.delete(recursive: true);
      }
    }
    return (paths: paths, uncertain: uncertain);
  }
}
