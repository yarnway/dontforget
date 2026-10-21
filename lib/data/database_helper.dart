import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import '../models/settings.dart';
import '../models/legacy_credentials.dart';
import '../services/notification_epoch_store.dart';
import '../services/notification_journal.dart';

part 'database_access.dart';

class DatabaseHelper {
  static const schemaVersion = 9;
  static final DatabaseHelper instance = DatabaseHelper._init();
  Database? _database;
  Future<Database>? _opening;
  Future<void>? _backup;
  Future<void>? _closing;
  _AccessState _accessState = _AccessState.ready;
  int _generation = 0;
  int _activeOperations = 0;
  Completer<void>? _drained;
  DatabaseMaintenanceLease? _maintenance;
  Future<String>? _ownershipOpening;
  String? _ownedDirectory;
  RandomAccessFile? _ownershipLock;
  NotificationEpochStore? _notificationEpochStore;
  NotificationJournal? _notificationJournal;
  static final Map<String, DatabaseHelper> _directoryOwners = {};
  static final Object _operationZoneKey = Object();
  final String? _directory;
  final DatabaseFactory? _factory;

  DatabaseHelper._init() : _directory = null, _factory = null;

  @visibleForTesting
  DatabaseHelper.forTesting(String directory, DatabaseFactory factory)
    : _directory = directory,
      _factory = factory;

  /// Raw handles are only available on an explicitly isolated test helper.
  @visibleForTesting
  Future<Database> get database {
    if (_directory == null) {
      throw StateError('Use scoped database operations.');
    }
    return runOperation(captureGeneration(), _openDatabase);
  }

  DataGeneration captureGeneration() {
    _checkReady();
    return DataGeneration._(this, _generation);
  }

  bool isCurrent(DataGeneration generation) =>
      _accessState == _AccessState.ready &&
      identical(generation._owner, this) &&
      generation._value == _generation;

  void checkGeneration(DataGeneration generation) {
    _checkReady();
    if (!identical(generation._owner, this) ||
        generation._value != _generation) {
      throw const DatabaseAccessException(DatabaseAccessError.staleGeneration);
    }
  }

  void _checkReady() {
    if (_accessState == _AccessState.faulted) {
      throw const DatabaseAccessException(DatabaseAccessError.faulted);
    }
    if (_accessState != _AccessState.ready) {
      throw const DatabaseAccessException(DatabaseAccessError.maintenance);
    }
  }

  /// Includes non-SQL side effects in maintenance draining without opening a DB.
  Future<T> runOperation<T>(
    DataGeneration generation,
    Future<T> Function() operation,
  ) {
    final inherited = Zone.current[_operationZoneKey];
    final nested =
        inherited is _OperationAdmission &&
        inherited.active &&
        identical(inherited.helper, this) &&
        identical(inherited.generation, generation);
    if (!nested) checkGeneration(generation);
    _activeOperations++;
    final admission = _OperationAdmission(this, generation);
    return runZoned(() async {
      try {
        return await operation();
      } finally {
        admission.active = false;
        _activeOperations--;
        if (_activeOperations == 0) {
          _drained?.complete();
          _drained = null;
        }
      }
    }, zoneValues: {_operationZoneKey: admission});
  }

  Future<T> read<T>(
    DataGeneration generation,
    Future<T> Function(DatabaseExecutor) operation,
  ) => runOperation(generation, () async {
    final scope = _ScopedExecutor(await _openDatabase(), writable: false);
    try {
      return await operation(scope);
    } finally {
      await scope.finish();
    }
  });

  Future<T> writeTransaction<T>(
    DataGeneration generation,
    Future<T> Function(Transaction) operation,
  ) => runOperation(generation, () async {
    final db = await _openDatabase();
    return db.transaction((txn) async {
      final scope = _ScopedExecutor(txn, writable: true);
      try {
        return await operation(scope);
      } finally {
        await scope.finish();
      }
    });
  });

  Future<void> _waitForOperations() {
    if (_activeOperations == 0) return Future<void>.value();
    return (_drained ??= Completer<void>()).future;
  }

  void _checkOutsideOperation() {
    final admission = Zone.current[_operationZoneKey];
    if (admission is _OperationAdmission &&
        admission.active &&
        identical(admission.helper, this)) {
      throw StateError('Cannot drain a database operation from itself.');
    }
  }

  Future<DatabaseMaintenanceLease> beginMaintenance() {
    _checkOutsideOperation();
    _checkReady();
    _accessState = _AccessState.maintenance;
    _generation++;
    return _beginMaintenance();
  }

  Future<DatabaseMaintenanceLease> _beginMaintenance() async {
    try {
      await _waitForOperations();
      final directory = await _acquireOwnership();
      return _maintenance = DatabaseMaintenanceLease._(this, directory);
    } catch (_) {
      _accessState = _AccessState.faulted;
      rethrow;
    }
  }

  /// Obtains process ownership before startup inspects a recovery journal.
  /// This does not open, initialize, or migrate the database.
  Future<String> acquireOwnership() =>
      runOperation(captureGeneration(), _acquireOwnership);

  /// Reads only the local notification identity, never business rows. Recovery
  /// needs this sidecar while its SQL gate is closed, including on cold startup.
  /// A live maintenance lease retains exclusive ownership during the file I/O.
  Future<String> readNotificationEpoch() {
    return _notificationOperation(
      _readAdmittedNotificationEpoch,
      _readOwnedNotificationEpoch,
    );
  }

  /// Keeps local platform bookkeeping inside the same process ownership and
  /// maintenance admission as notification epoch reads, including recovery.
  Future<T> withNotificationJournal<T>(
    Future<T> Function(NotificationJournal) action,
  ) {
    Future<T> owned() {
      final directory = _ownedDirectory;
      if (directory == null ||
          _ownershipLock == null ||
          !identical(_directoryOwners[directory], this)) {
        throw const DatabaseAccessException(
          DatabaseAccessError.ownedByAnotherProcess,
        );
      }
      return action(
        _notificationJournal ??= NotificationJournal(Directory(directory)),
      );
    }

    Future<T> admitted() async {
      await _acquireOwnership();
      return owned();
    }

    return _notificationOperation(admitted, owned);
  }

  Future<T> _notificationOperation<T>(
    Future<T> Function() admitted,
    Future<T> Function() owned,
  ) {
    if (_accessState == _AccessState.faulted) {
      throw const DatabaseAccessException(DatabaseAccessError.faulted);
    }
    if (_accessState == _AccessState.closing) {
      throw const DatabaseAccessException(DatabaseAccessError.maintenance);
    }
    final inherited = Zone.current[_operationZoneKey];
    if (inherited is _OperationAdmission &&
        inherited.active &&
        identical(inherited.helper, this)) {
      // Already admitted side effects must be able to finish while maintenance
      // waits for them. The nested operation remains part of that same drain.
      return runOperation(inherited.generation, admitted);
    }
    if (_accessState == _AccessState.ready) {
      return runOperation(captureGeneration(), admitted);
    }
    final lease = _maintenance;
    if (_accessState == _AccessState.maintenance && lease != null) {
      return lease._perform(owned);
    }
    // A new caller cannot join the gap while earlier operations are draining
    // and no exclusive maintenance lease has been issued yet.
    throw const DatabaseAccessException(DatabaseAccessError.maintenance);
  }

  Future<String> _readAdmittedNotificationEpoch() async {
    await _acquireOwnership();
    return _readOwnedNotificationEpoch();
  }

  Future<String> _readOwnedNotificationEpoch() {
    final directory = _ownedDirectory;
    if (directory == null ||
        _ownershipLock == null ||
        !identical(_directoryOwners[directory], this)) {
      throw const DatabaseAccessException(
        DatabaseAccessError.ownedByAnotherProcess,
      );
    }
    // Cache the serializer, not the identity: every call reads the durable
    // file so an epoch rotated by recovery is visible immediately.
    final store = _notificationEpochStore ??= NotificationEpochStore(
      Directory(directory),
    );
    return store.readOrCreate();
  }

  Future<String> _acquireOwnership() {
    if (_ownedDirectory != null) return Future.value(_ownedDirectory!);
    return _ownershipOpening ??= _lockDirectory().whenComplete(() {
      _ownershipOpening = null;
    });
  }

  Future<String> _lockDirectory() async {
    final directory = await _getDatabaseDirectory();
    final canonical = await Directory(directory).resolveSymbolicLinks();
    if (_directoryOwners.containsKey(canonical)) {
      throw const DatabaseAccessException(
        DatabaseAccessError.ownedByAnotherProcess,
      );
    }
    _directoryOwners[canonical] = this;
    RandomAccessFile? handle;
    try {
      final lockFile = File(join(canonical, '.dontforget.owner.lock'));
      final type = await FileSystemEntity.type(
        lockFile.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw const DatabaseAccessException(
          DatabaseAccessError.ownedByAnotherProcess,
        );
      }
      handle = await lockFile.open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive);
      _ownershipLock = handle;
      _ownedDirectory = canonical;
      return canonical;
    } catch (_) {
      await handle?.close();
      if (identical(_directoryOwners[canonical], this)) {
        _directoryOwners.remove(canonical);
      }
      throw const DatabaseAccessException(
        DatabaseAccessError.ownedByAnotherProcess,
      );
    }
  }

  Future<void> _releaseOwnership() async {
    final directory = _ownedDirectory;
    final handle = _ownershipLock;
    if (handle == null) return;
    await handle.close();
    _ownershipLock = null;
    _notificationEpochStore = null;
    _notificationJournal = null;
    _ownedDirectory = null;
    if (identical(_directoryOwners[directory], this)) {
      _directoryOwners.remove(directory);
    }
  }

  Future<Database> _openDatabase({
    bool allowRecovery = false,
    bool migrate = true,
  }) async {
    if (_database != null) return _database!;
    final opening = _opening ??= _initDB(
      allowRecovery: allowRecovery,
      migrate: migrate,
    );
    try {
      return _database = await opening;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
  }

  Future<String> _getDatabaseDirectory() async {
    if (_directory != null) {
      await Directory(_directory).create(recursive: true);
      return _directory;
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        final supportDir = await getApplicationSupportDirectory();
        final dbDir = Directory(join(supportDir.path, 'databases'));
        if (!await dbDir.exists()) {
          await dbDir.create(recursive: true);
        }
        return dbDir.path;
      } catch (e) {
        debugPrint('Error getting application support directory: $e');
        if (Platform.isWindows) {
          final localAppData =
              Platform.environment['LOCALAPPDATA'] ??
              Platform.environment['APPDATA'] ??
              Platform.environment['USERPROFILE'] ??
              '.';
          final fallbackDir = Directory(
            join(localAppData, 'DontForget', 'databases'),
          );
          if (!fallbackDir.existsSync()) {
            fallbackDir.createSync(recursive: true);
          }
          return fallbackDir.path;
        }
      }
    }
    return await sqflite.getDatabasesPath();
  }

  void _initializeFactory() {
    // Initialize FFI for desktop platforms
    if (_factory == null &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  Future<Database> _initDB({
    bool allowRecovery = false,
    bool migrate = true,
  }) async {
    _initializeFactory();
    final dbDir = await _acquireOwnership();
    if (!allowRecovery && await _hasRecoveryJournal(dbDir)) {
      throw const DatabaseRecoveryRequiredException();
    }
    const filePath = 'dont_forget_v3.db';
    final targetPath = join(dbDir, filePath);

    // Auto-migrate legacy DB from previous development/relative path if target doesn't exist
    final targetFile = File(targetPath);
    if (!allowRecovery && _directory == null && !targetFile.existsSync()) {
      try {
        final legacyDir = join(
          Directory.current.path,
          '.dart_tool',
          'sqflite_common_ffi',
          'databases',
          filePath,
        );
        final legacyFile = File(legacyDir);
        if (legacyFile.existsSync()) {
          legacyFile.copySync(targetPath);
        }
      } catch (_) {}
    }

    // An open failure may be a permission/lock/migration error. Never replace
    // the user's database with an older backup merely because opening failed.
    return (_factory ?? databaseFactory).openDatabase(
      targetPath,
      options: OpenDatabaseOptions(
        version: migrate ? schemaVersion : null,
        readOnly: !migrate,
        onCreate: migrate ? _createDB : null,
        onUpgrade: migrate ? _upgradeDB : null,
      ),
    );
  }

  static Future<bool> _hasRecoveryJournal(String directory) async =>
      await FileSystemEntity.type(
        join(directory, 'recovery.pending.json'),
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound;

  Future<void> createMirrorBackup() {
    final generation = captureGeneration();
    return _backup ??= runOperation(
      generation,
      _createMirrorBackup,
    ).whenComplete(() => _backup = null);
  }

  Future<void> _createMirrorBackup() async {
    final db = await _openDatabase();
    await _backupDatabase(db);
  }

  Future<void> _backupDatabase(Database db) async {
    final dbDir = await _acquireOwnership();
    final mirrorPath = join(dbDir, 'dont_forget_v3.mirror.db');
    final snapshotPath = join(dbDir, 'ha_snapshot.json');
    final temporary = await Directory(dbDir).createTemp('backup-');
    Database? mirror;
    try {
      // One read transaction includes committed WAL data and keeps all tables
      // from the same point in time. Never copy an open SQLite file directly.
      final data = await db.transaction(
        (txn) async => <String, Object?>{
          'version': schemaVersion,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'settings': await txn.query('Settings'),
          'media_records': await txn.query('MediaRecords'),
          'reminders': await txn.query('Reminders'),
        },
      );
      final temporaryMirror = join(temporary.path, 'mirror.db');
      mirror = await (_factory ?? databaseFactory).openDatabase(
        temporaryMirror,
        options: OpenDatabaseOptions(
          version: schemaVersion,
          onCreate: _createDB,
        ),
      );
      await mirror.transaction((txn) async {
        for (final entry in const {
          'Settings': 'settings',
          'MediaRecords': 'media_records',
          'Reminders': 'reminders',
        }.entries) {
          await txn.delete(entry.key);
          for (final row in data[entry.value] as List<Map<String, Object?>>) {
            await txn.insert(entry.key, row);
          }
        }
      });
      final check = await mirror.rawQuery('PRAGMA integrity_check');
      if (check.length != 1 || check.single.values.single != 'ok') {
        throw StateError('Backup integrity check failed');
      }
      await mirror.close();
      mirror = null;
      final snapshot = File(join(temporary.path, 'snapshot.json'));
      await snapshot.writeAsString(jsonEncode(data), flush: true);
      // Each artifact replaces its predecessor only after it is complete.
      await File(temporaryMirror).rename(mirrorPath);
      await snapshot.rename(snapshotPath);
    } finally {
      await mirror?.close();
      await temporary.delete(recursive: true);
    }
  }

  Future _createDB(Database db, int version) async {
    const idType = 'TEXT PRIMARY KEY';
    const textType = 'TEXT NOT NULL';
    const integerType = 'INTEGER NOT NULL';
    const boolType = 'BOOLEAN NOT NULL';

    await db.execute('''
CREATE TABLE Settings (
  id $textType,
  api_key TEXT,
  base_url TEXT,
  model_name TEXT,
  language TEXT
)
''');

    await db.insert('Settings', AppSettings.defaults().toJson());

    await db.execute('''
CREATE TABLE MediaRecords (
  id $idType,
  type $textType,
  content_or_path $textType,
  created_at $textType
)
''');

    await db.execute('''
CREATE TABLE Reminders (
  id $idType,
  record_id TEXT,
  task_title $textType,
  task_summary TEXT,
  quadrant_level $integerType,
  urgency_level TEXT,
  importance_level TEXT,
  trigger_time TEXT,
  is_completed $boolType,
  is_recurring INTEGER DEFAULT 0,
  recurrence_rule TEXT DEFAULT 'none',
  recurrence_description TEXT,
  is_emotion_filtered INTEGER DEFAULT 0,
  sub_tasks TEXT,
  created_at TEXT,
  review_level INTEGER DEFAULT 0,
  next_review_at TEXT,
  original_quadrant_level INTEGER,
  is_dynamically_promoted INTEGER DEFAULT 0,
  linked_task_ids TEXT,
  context_trigger TEXT,
  notice_revision INTEGER NOT NULL DEFAULT 0,
  notice_acknowledged_at TEXT,
  upcoming_dismissed_at TEXT,
  snoozed_at TEXT,
  recurrence_anchor_time TEXT,
  FOREIGN KEY (record_id) REFERENCES MediaRecords (id) ON DELETE CASCADE
)
''');
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 9) {
      // These columns are new in v9. Let failures roll back the entire
      // migration instead of hiding an incomplete reminder-state schema.
      await db.execute(
        'ALTER TABLE Reminders ADD COLUMN notice_revision INTEGER NOT NULL DEFAULT 0',
      );
      for (final column in [
        'notice_acknowledged_at',
        'upcoming_dismissed_at',
        'snoozed_at',
        'recurrence_anchor_time',
      ]) {
        await db.execute('ALTER TABLE Reminders ADD COLUMN $column TEXT');
      }
    }
    if (oldVersion < 8) {
      final settings = await db.query('Settings');
      for (final row in settings) {
        if (isLegacyBundledCredential(row['api_key'] as String? ?? '')) {
          await db.update(
            'Settings',
            {'api_key': ''},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }
    }

    if (oldVersion < 4) {
      try {
        await db.execute(
          'ALTER TABLE Reminders ADD COLUMN is_recurring INTEGER DEFAULT 0',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE Reminders ADD COLUMN recurrence_rule TEXT DEFAULT "none"',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE Reminders ADD COLUMN recurrence_description TEXT',
        );
      } catch (_) {}
    }
    if (oldVersion < 5) {
      try {
        await db.execute(
          'ALTER TABLE Reminders ADD COLUMN is_emotion_filtered INTEGER DEFAULT 0',
        );
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE Reminders ADD COLUMN sub_tasks TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE Reminders ADD COLUMN created_at TEXT');
      } catch (_) {}
    }
    if (oldVersion < 6) {
      try {
        await db.execute(
          'ALTER TABLE Reminders ADD COLUMN review_level INTEGER DEFAULT 0',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE Reminders ADD COLUMN next_review_at TEXT',
        );
      } catch (_) {}
    }
    if (oldVersion < 7) {
      try {
        await db.execute(
          'ALTER TABLE Reminders ADD COLUMN original_quadrant_level INTEGER',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE Reminders ADD COLUMN is_dynamically_promoted INTEGER DEFAULT 0',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE Reminders ADD COLUMN linked_task_ids TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          'ALTER TABLE Reminders ADD COLUMN context_trigger TEXT',
        );
      } catch (_) {}
      try {
        await db.execute(
          'UPDATE Reminders SET original_quadrant_level = quadrant_level WHERE original_quadrant_level IS NULL',
        );
      } catch (_) {}
    }
  }

  /// Normal shutdown creates the existing mirror backup unless explicitly
  /// disabled by a caller such as a read-only CLI command.
  Future<void> close({bool createBackup = true}) {
    if (_closing != null) return _closing!;
    _checkOutsideOperation();
    if (_accessState == _AccessState.maintenance) {
      throw const DatabaseAccessException(DatabaseAccessError.maintenance);
    }
    final wasFaulted = _accessState == _AccessState.faulted;
    final pendingBackup = _backup;
    _accessState = wasFaulted ? _AccessState.faulted : _AccessState.closing;
    _generation++;
    return _closing =
        _close(
          backup: createBackup && !wasFaulted,
          pendingBackup: pendingBackup,
        ).whenComplete(() {
          _closing = null;
          if (_accessState == _AccessState.closing) {
            _accessState = _AccessState.ready;
          }
        });
  }

  Future<void> _close({
    required bool backup,
    required Future<void>? pendingBackup,
  }) async {
    try {
      await _waitForOperations();
      if (pendingBackup != null) await pendingBackup;
      final db = _database;
      if (backup && db != null) await _backupDatabase(db);
    } finally {
      try {
        await _closeDatabase();
        await _releaseOwnership();
      } catch (_) {
        _accessState = _AccessState.faulted;
        rethrow;
      }
    }
  }

  Future<void> _closeDatabase() async {
    final db = _database;
    if (db == null) return;
    await db.close();
    _database = null;
  }
}
