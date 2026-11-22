import 'dart:async';
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
  static const defaultDebounce = Duration(milliseconds: 350);

  WorkspaceDrafts(this.database) : super({}) {
    generation = database.captureGeneration();
    ready = _load();
    _writes = ready.then<void>((_) {}, onError: (Object _) {});
  }
  final DatabaseHelper database;
  late final DataGeneration generation;
  late final Future<void> ready;
  late Future<void> _writes;
  final Map<String, Object?> _pendingDebounced = {};
  final List<Completer<void>> _debouncedWaiters = [];
  Timer? _debounceTimer;
  bool _edited = false;
  bool failed = false;
  bool loaded = false;

  Future<void> _load() async {
    try {
      final cached = database.takeBootstrapDraftsRow(generation);
      final Map<String, Object?> row;
      if (cached != null) {
        row = cached;
      } else {
        final rows = await database.read(
          generation,
          (db) =>
              db.query('Settings', where: 'id = ?', whereArgs: ['default']),
        );
        database.checkGeneration(generation);
        if (rows.length != 1) throw StateError('Settings unavailable');
        row = rows.single;
      }
      database.checkGeneration(generation);
      final raw = row['workspace_drafts_json'];
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

  /// Immediately commits any buffered keystroke draft edits in one transaction.
  Future<void> _flushDebounced() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_pendingDebounced.isEmpty) return Future<void>.value();
    final batch = Map<String, Object?>.of(_pendingDebounced);
    final waiters = List<Completer<void>>.of(_debouncedWaiters);
    _pendingDebounced.clear();
    _debouncedWaiters.clear();
    final op = _putAllInternal(batch);
    op.then(
      (_) {
        for (final waiter in waiters) {
          if (!waiter.isCompleted) waiter.complete();
        }
      },
      onError: (Object error, StackTrace stack) {
        for (final waiter in waiters) {
          if (!waiter.isCompleted) waiter.completeError(error, stack);
        }
      },
    );
    return op;
  }

  /// Coalesces rapid typing into a single fsynced SQLite transaction while
  /// guaranteeing [flushed], [put], [readPersistedKey], and [dispose] flush
  /// pending drafts immediately without losing the latest keystroke.
  Future<void> putDebounced(
    String key,
    Object? value, {
    Duration delay = defaultDebounce,
  }) {
    final Object? frozen;
    try {
      frozen = value == null ? null : jsonDecode(jsonEncode(value));
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
    _pendingDebounced[key] = frozen;
    final waiter = Completer<void>();
    _debouncedWaiters.add(waiter);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(delay, () {
      unawaited(_flushDebounced().then<void>((_) {}, onError: (Object _) {}));
    });
    return waiter.future;
  }

  Future<Object?> readPersistedKey(String key) async {
    if (_pendingDebounced.isNotEmpty) {
      await _flushDebounced();
    }
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

  Future<void> compareAndPut(String key, Object? expected, Object? value) {
    if (_pendingDebounced.isNotEmpty) {
      unawaited(_flushDebounced().then<void>((_) {}, onError: (Object _) {}));
    }
    return _put(key, value, expected: expected);
  }

  Future<void> put(String key, Object? value) {
    _pendingDebounced.remove(key);
    if (_pendingDebounced.isNotEmpty) {
      unawaited(_flushDebounced().then<void>((_) {}, onError: (Object _) {}));
    } else if (_debounceTimer != null || _debouncedWaiters.isNotEmpty) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      final waiters = List<Completer<void>>.of(_debouncedWaiters);
      _debouncedWaiters.clear();
      final op = _put(key, value);
      op.then(
        (_) {
          for (final w in waiters) {
            if (!w.isCompleted) w.complete();
          }
        },
        onError: (Object e, StackTrace st) {
          for (final w in waiters) {
            if (!w.isCompleted) w.completeError(e, st);
          }
        },
      );
      return op;
    }
    return _put(key, value);
  }

  Future<void> putAll(Map<String, Object?> entries) {
    for (final k in entries.keys) {
      _pendingDebounced.remove(k);
    }
    if (_pendingDebounced.isNotEmpty) {
      unawaited(_flushDebounced().then<void>((_) {}, onError: (Object _) {}));
    } else if (_debounceTimer != null || _debouncedWaiters.isNotEmpty) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      final waiters = List<Completer<void>>.of(_debouncedWaiters);
      _debouncedWaiters.clear();
      final op = _putAllInternal(entries);
      op.then(
        (_) {
          for (final w in waiters) {
            if (!w.isCompleted) w.complete();
          }
        },
        onError: (Object e, StackTrace st) {
          for (final w in waiters) {
            if (!w.isCompleted) w.completeError(e, st);
          }
        },
      );
      return op;
    }
    return _putAllInternal(entries);
  }

  Future<void> _putAllInternal(Map<String, Object?> entries) {
    late Future<void> operation;
    try {
      final frozen = <String, Object?>{
        for (final entry in entries.entries)
          entry.key: entry.value == null
              ? null
              : jsonDecode(jsonEncode(entry.value)),
      };
      final previous = _writes;
      operation = database.runOperation(generation, () async {
        await previous;
        await ready;
        database.checkGeneration(generation);
        late Map<String, dynamic> next;
        await database.writeTransaction(generation, (db) async {
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
          for (final entry in frozen.entries) {
            if (entry.value == null) {
              next.remove(entry.key);
            } else {
              next[entry.key] = entry.value;
            }
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

  /// Immediately flushes any buffered keystroke drafts and cancels the pending
  /// debounce timer (safe to call from widget dispose()).
  void flushPending() {
    if (_pendingDebounced.isNotEmpty) {
      unawaited(_flushDebounced().then<void>((_) {}, onError: (Object _) {}));
    } else {
      _debounceTimer?.cancel();
      _debounceTimer = null;
    }
  }

  Future<void> get flushed {
    flushPending();
    return _writes;
  }

  @override
  void dispose() {
    flushPending();
    super.dispose();
  }
}
