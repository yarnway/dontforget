part of 'database_helper.dart';

enum DatabaseAccessError {
  maintenance,
  staleGeneration,
  faulted,
  ownedByAnotherProcess,
  expiredScope,
  recoveryRequired,
}

class DatabaseAccessException implements Exception {
  const DatabaseAccessException(this.code);
  final DatabaseAccessError code;

  @override
  String toString() => 'Database access unavailable: ${code.name}';
}

class DatabaseRecoveryRequiredException extends DatabaseAccessException {
  const DatabaseRecoveryRequiredException()
    : super(DatabaseAccessError.recoveryRequired);
}

/// An opaque ticket belonging to exactly one helper and data generation.
class DataGeneration {
  const DataGeneration._(this._owner, this._value);
  final DatabaseHelper _owner;
  final int _value;
}

enum _AccessState { ready, closing, maintenance, faulted }

class _OperationAdmission {
  _OperationAdmission(this.helper, this.generation);
  final DatabaseHelper helper;
  final DataGeneration generation;
  bool active = true;
}

/// Exclusive access after normal operations, opening and backup have drained.
/// Closing the database retains process ownership until maintenance is resolved.
class DatabaseMaintenanceLease {
  DatabaseMaintenanceLease._(this._helper, this.directory);
  final DatabaseHelper _helper;
  final String directory;
  String get path => join(directory, 'dont_forget_v3.db');
  bool _ended = false;
  bool _busy = false;
  int _notificationOperations = 0;
  bool _validatedOpen = false;
  int? _validatedVersion;

  void _checkIdentity() {
    if (_ended || !identical(_helper._maintenance, this)) {
      throw const DatabaseAccessException(DatabaseAccessError.expiredScope);
    }
    if (_helper._accessState == _AccessState.faulted) {
      throw const DatabaseAccessException(DatabaseAccessError.faulted);
    }
  }

  void _checkActive() {
    _checkIdentity();
    if (_busy || _notificationOperations != 0) {
      throw const DatabaseAccessException(DatabaseAccessError.maintenance);
    }
  }

  // Only the ownership-checked epoch/journal helpers may use this admission.
  // Their own stores serialize writes. SQL/file replacement and lease release
  // stay blocked until every admitted sidecar operation has settled.
  Future<T> _performNotification<T>(Future<T> Function() action) {
    _checkIdentity();
    if (_busy) {
      throw const DatabaseAccessException(DatabaseAccessError.maintenance);
    }
    _notificationOperations++;
    return Future<T>.sync(action).whenComplete(() => _notificationOperations--);
  }

  Future<T> _perform<T>(Future<T> Function() action) {
    _checkActive();
    _busy = true;
    return Future<T>.sync(action).whenComplete(() => _busy = false);
  }

  /// Export the latest operational state before opening a v1-only binary.
  /// The explicit v1 selector also prevents automatic upgrade on next launch.
  Future<void> rollbackNotificationStorage() => _perform(() async {
    await _helper._notificationJournal!.rollbackToV1();
  });

  Future<void> closeWithoutBackup() => _perform(() async {
    _validatedOpen = false;
    _validatedVersion = null;
    try {
      await _helper._closeDatabase();
    } catch (_) {
      _helper._accessState = _AccessState.faulted;
      rethrow;
    }
  });

  /// Opens the current primary using the application's schema callbacks.
  /// A pending recovery journal is deliberately allowed only through this lease.
  /// Pending journals must be reconciled without migrations, which would
  /// change the file identity before the durable decision can be archived.
  Future<void> validateAndOpen({bool migrate = true}) => _perform(() async {
    _validatedOpen = false;
    _validatedVersion = null;
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Recovery requires an existing primary database.');
    }
    final database = await _helper._openDatabase(
      allowRecovery: true,
      migrate: migrate,
    );
    _validatedVersion = await _checkIntegrity(database, allowLegacy: !migrate);
    _validatedOpen = true;
  });

  /// Reads final data for rebuilding side effects while normal access stays
  /// blocked. Validation must have succeeded through this lease first.
  Future<T> read<T>(Future<T> Function(DatabaseExecutor) operation) =>
      _perform(() async {
        final database = _helper._database;
        if (!_validatedOpen || database == null) {
          throw StateError('Validate the primary database before reading it.');
        }
        final scope = _ScopedExecutor(database, writable: false);
        try {
          return await operation(scope);
        } finally {
          await scope.finish();
        }
      });

  Future<int> _checkIntegrity(
    Database database, {
    bool allowLegacy = false,
  }) async {
    final rows = await database.rawQuery('PRAGMA integrity_check');
    if (rows.length != 1 || rows.single.values.single != 'ok') {
      throw StateError('Database integrity check failed.');
    }
    final version = await database.rawQuery('PRAGMA user_version');
    final acceptedVersions = allowLegacy
        ? {7, 8, 9, 10, 11, DatabaseHelper.schemaVersion}
        : {DatabaseHelper.schemaVersion};
    if (version.length != 1 ||
        !acceptedVersions.contains(version.single.values.single)) {
      throw StateError('Database schema version does not match.');
    }
    return version.single.values.single as int;
  }

  Future<String> _candidatePath(String candidate) async {
    final normalized = normalize(absolute(candidate));
    if (!isWithin(directory, normalized) || dirname(normalized) == directory) {
      throw StateError('Candidate must be in a private operation directory.');
    }
    final parent = await Directory(dirname(normalized)).resolveSymbolicLinks();
    if (!isWithin(directory, parent) || parent != dirname(normalized)) {
      throw StateError('Candidate directory must be canonical.');
    }
    final type = await FileSystemEntity.type(normalized, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw StateError('Candidate must be a regular file.');
    }
    return normalized;
  }

  Future<void> createCandidateFromRows(
    String candidate,
    Map<String, List<Map<String, Object?>>> rows,
  ) => _perform(() async {
    final target = await _candidatePath(candidate);
    if (await File(target).exists()) {
      throw StateError('Candidate already exists.');
    }
    const tables = ['Settings', 'MediaRecords', 'Reminders'];
    if (rows.length != tables.length ||
        tables.any((table) => !rows.containsKey(table))) {
      throw ArgumentError('Candidate requires exactly three business tables.');
    }
    _helper._initializeFactory();
    final database = await (_helper._factory ?? databaseFactory).openDatabase(
      target,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.schemaVersion,
        singleInstance: false,
        onCreate: _helper._createDB,
      ),
    );
    try {
      await database.transaction((transaction) async {
        for (final table in tables.reversed) {
          await transaction.delete(table);
        }
        var batch = transaction.batch();
        var pending = 0;
        for (final table in tables) {
          for (final row in rows[table]!) {
            batch.insert(table, row);
            if (++pending == 500) {
              await batch.commit(noResult: true);
              batch = transaction.batch();
              pending = 0;
            }
          }
        }
        if (pending != 0) await batch.commit(noResult: true);
      });
      await _checkIntegrity(database);
    } finally {
      await _closeCandidate(database);
    }
  });

  Future<void> validateCandidate(String candidate) => _perform(() async {
    final target = await _candidatePath(candidate);
    if (!await File(target).exists()) {
      throw StateError('Candidate does not exist.');
    }
    _helper._initializeFactory();
    final database = await (_helper._factory ?? databaseFactory).openDatabase(
      target,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.schemaVersion,
        singleInstance: false,
        onUpgrade: _helper._upgradeDB,
      ),
    );
    try {
      await _checkIntegrity(database);
    } finally {
      await _closeCandidate(database);
    }
  });

  Future<void> _closeCandidate(Database database) async {
    try {
      await database.close();
    } catch (_) {
      _helper._accessState = _AccessState.faulted;
      rethrow;
    }
  }

  Future<void> resume() async {
    _checkActive();
    if (_validatedVersion != null &&
        _validatedVersion != DatabaseHelper.schemaVersion) {
      throw StateError(
        'Upgrade and validate the database before resuming access.',
      );
    }
    // An unresolved journal must never be bypassed by returning an open handle.
    if (await DatabaseHelper._hasRecoveryJournal(directory)) {
      throw const DatabaseRecoveryRequiredException();
    }
    _checkActive();
    _ended = true;
    _helper._maintenance = null;
    _helper._generation++;
    _helper._accessState = _AccessState.ready;
  }

  /// Keeps the gate closed; only an explicit process restart/recovery may reopen.
  void fail() {
    if (_ended || !identical(_helper._maintenance, this)) {
      throw const DatabaseAccessException(DatabaseAccessError.expiredScope);
    }
    if (_busy || _notificationOperations != 0) {
      throw const DatabaseAccessException(DatabaseAccessError.maintenance);
    }
    _ended = true;
    _helper._maintenance = null;
    _helper._generation++;
    _helper._accessState = _AccessState.faulted;
  }
}

/// Does not expose Database, batch, or cursor handles that can outlive a lease.
/// SQL started inside the callback is drained even if the caller forgets await.
class _ScopedExecutor implements Transaction {
  _ScopedExecutor(this._delegate, {required this.writable});
  final DatabaseExecutor _delegate;
  final bool writable;
  bool _active = true;
  final List<Future<void>> _pending = [];
  Object? _failure;
  StackTrace? _failureStack;

  Future<T> _call<T>(Future<T> Function() operation, {bool write = false}) {
    if (!_active) {
      throw const DatabaseAccessException(DatabaseAccessError.expiredScope);
    }
    if (write && !writable) {
      throw StateError('Writes require a database transaction.');
    }
    final result = Future<T>.sync(operation);
    _pending.add(
      result.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          _failure ??= error;
          _failureStack ??= stack;
        },
      ),
    );
    return result;
  }

  Future<void> finish() async {
    _active = false;
    await Future.wait(_pending);
    if (_failure != null) Error.throwWithStackTrace(_failure!, _failureStack!);
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      _call(() => _delegate.execute(sql, arguments), write: true);

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      _call(() => _delegate.rawInsert(sql, arguments), write: true);

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) => _call(
    () => _delegate.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    ),
    write: true,
  );

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => _call(
    () => _delegate.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    ),
  );

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    if (!writable) {
      // SQLite accepts INSERT/UPDATE/DELETE ... RETURNING through rawQuery.
      // Keep the read API deliberately limited to the application's SELECTs
      // and explicitly read-only schema/integrity pragmas, without SQL batches.
      final statement = sql.trim().replaceFirst(RegExp(r';$'), '').trim();
      final select = RegExp(r'^SELECT\b', caseSensitive: false);
      final pragma = RegExp(
        r'^PRAGMA\s+(?:(?:main|temp)\.)?'
        r'(?:(?:integrity_check|quick_check|user_version|foreign_key_check)|'
        r'(?:table_info|table_xinfo|foreign_key_list|index_list|index_info)'
        r'\s*\(\s*(?:[a-z_][a-z0-9_]*|\x27[a-z_][a-z0-9_]*\x27)\s*\))$',
        caseSensitive: false,
      );
      if (statement.contains(';') ||
          (!select.hasMatch(statement) && !pragma.hasMatch(statement))) {
        throw StateError('Only read-only queries are allowed in a read scope.');
      }
    }
    return _call(() => _delegate.rawQuery(sql, arguments));
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      _call(() => _delegate.rawUpdate(sql, arguments), write: true);

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) => _call(
    () => _delegate.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    ),
    write: true,
  );

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      _call(() => _delegate.rawDelete(sql, arguments), write: true);

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _call(
        () => _delegate.delete(table, where: where, whereArgs: whereArgs),
        write: true,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('This operation cannot escape a database scope.');
}
