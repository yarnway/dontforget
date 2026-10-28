import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/database_helper.dart';
import 'providers.dart';

final workspaceDraftsProvider =
    StateNotifierProvider<WorkspaceDrafts, Map<String, dynamic>>(
      (ref) => WorkspaceDrafts(ref.read(databaseHelperProvider)),
    );

/// Uses the business DB's ownership, transaction and recovery generation gate.
/// Settings updates omit this column, so saving a key cannot overwrite drafts.
class WorkspaceDrafts extends StateNotifier<Map<String, dynamic>> {
  static const _anyExpected = Object();
  WorkspaceDrafts(this.database) : super({}) {
    generation = database.captureGeneration();
    ready = _load();
    _writes = ready.then<void>((_) {}, onError: (Object _) {});
  }
  final DatabaseHelper database;
  late final DataGeneration generation;
  late final Future<void> ready;
  late Future<void> _writes;
  bool _edited = false;
  bool failed = false;
  bool loaded = false;

  Future<void> _load() async {
    try {
      final rows = await database.read(
        generation,
        (db) => db.query('Settings', where: 'id = ?', whereArgs: ['default']),
      );
      database.checkGeneration(generation);
      if (rows.length != 1) throw StateError('Settings unavailable');
      final raw = rows.single['workspace_drafts_json'];
      if (raw == null) {
        loaded = true;
        return;
      }
      if (raw is! String || raw.length > 1048576) {
        throw const FormatException('Invalid drafts');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid drafts');
      }
      if (!_edited) {
        if (mounted) state = decoded;
      }
      loaded = true;
    } catch (_) {
      failed = true;
      rethrow;
    }
  }

  Future<Object?> readPersistedKey(String key) async {
    await ready;
    database.checkGeneration(generation);
    return database.read(generation, (db) async {
      final rows = await db.query(
        'Settings',
        where: 'id = ?',
        whereArgs: ['default'],
      );
      if (rows.length != 1) throw StateError('Settings unavailable');
      final raw = rows.single['workspace_drafts_json'];
      final data = raw == null
          ? <String, dynamic>{}
          : jsonDecode(raw as String);
      if (data is! Map<String, dynamic>) {
        throw const FormatException('Invalid drafts');
      }
      return data[key];
    });
  }

  Future<void> compareAndPut(String key, Object? expected, Object? value) =>
      _put(key, value, expected: expected);
  Future<void> put(String key, Object? value) => _put(key, value);
  Future<void> _put(
    String key,
    Object? value, {
    Object? expected = _anyExpected,
  }) {
    late Future<void> operation;
    try {
      final frozen = value == null ? null : jsonDecode(jsonEncode(value));
      final previous = _writes;
      operation = database.runOperation(generation, () async {
        await previous;
        // Never write defaults over unreadable drafts.
        await ready;
        database.checkGeneration(generation);
        late Map<String, dynamic> next;
        await database.writeTransaction(generation, (db) async {
          // Secure-credential cleanup metadata shares this row. Merge the
          // latest committed workspace rather than overwriting another writer.
          final rows = await db.query(
            'Settings',
            where: 'id = ?',
            whereArgs: ['default'],
          );
          if (rows.length != 1) throw StateError('Settings unavailable');
          final stored = rows.single['workspace_drafts_json'];
          final current = stored == null
              ? <String, dynamic>{}
              : jsonDecode(stored as String);
          if (current is! Map<String, dynamic>) {
            throw const FormatException('Invalid drafts');
          }
          next = {...current};
          if (!identical(expected, _anyExpected) &&
              jsonEncode(current[key]) != jsonEncode(expected)) {
            throw StateError('Workspace entry changed');
          }
          if (frozen == null) {
            next.remove(key);
          } else {
            next[key] = frozen;
          }
          final raw = jsonEncode(next);
          if (raw.length > 1048576) {
            throw const FormatException('Drafts too large');
          }
          final count = await db.update(
            'Settings',
            {'workspace_drafts_json': raw},
            where: 'id = ?',
            whereArgs: ['default'],
          );
          if (count != 1) throw StateError('Settings unavailable');
        });
        database.checkGeneration(generation);
        if (mounted) {
          _edited = true;
          failed = false;
          state = next;
        }
      });
    } catch (error, stack) {
      operation = Future<void>.error(error, stack);
    }
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _) {
        failed = true;
      },
    );
    return operation;
  }

  Future<void> get flushed => _writes;
}
