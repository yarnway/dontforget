import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import '../models/settings.dart';
import '../models/legacy_credentials.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  Database? _database;
  Future<Database>? _opening;
  Future<void>? _backup;
  Future<void>? _closing;
  final String? _directory;
  final DatabaseFactory? _factory;

  DatabaseHelper._init() : _directory = null, _factory = null;

  @visibleForTesting
  DatabaseHelper.forTesting(String directory, DatabaseFactory factory)
    : _directory = directory,
      _factory = factory;

  Future<Database> get database async {
    if (_closing != null) await _closing;
    if (_database != null) return _database!;
    final opening = _opening ??= _initDB('dont_forget_v3.db');
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

  Future<Database> _initDB(String filePath) async {
    // Initialize FFI for desktop platforms
    if (_factory == null &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbDir = await _getDatabaseDirectory();
    final targetPath = join(dbDir, filePath);

    // Auto-migrate legacy DB from previous development/relative path if target doesn't exist
    final targetFile = File(targetPath);
    if (_directory == null && !targetFile.existsSync()) {
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
        version: 8,
        onCreate: _createDB,
        onUpgrade: _upgradeDB,
      ),
    );
  }

  Future<void> createMirrorBackup() async {
    if (_closing != null) return _closing;
    return _backup ??= _createMirrorBackup().whenComplete(() => _backup = null);
  }

  Future<void> _createMirrorBackup() async {
    final db = await database;
    await _backupDatabase(db);
  }

  Future<void> _backupDatabase(Database db) async {
    final dbDir = await _getDatabaseDirectory();
    final mirrorPath = join(dbDir, 'dont_forget_v3.mirror.db');
    final snapshotPath = join(dbDir, 'ha_snapshot.json');
    final temporary = await Directory(dbDir).createTemp('backup-');
    Database? mirror;
    try {
      // One read transaction includes committed WAL data and keeps all tables
      // from the same point in time. Never copy an open SQLite file directly.
      final data = await db.transaction(
        (txn) async => <String, Object?>{
          'version': 8,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'settings': await txn.query('Settings'),
          'media_records': await txn.query('MediaRecords'),
          'reminders': await txn.query('Reminders'),
        },
      );
      final temporaryMirror = join(temporary.path, 'mirror.db');
      mirror = await (_factory ?? databaseFactory).openDatabase(
        temporaryMirror,
        options: OpenDatabaseOptions(version: 8, onCreate: _createDB),
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
  FOREIGN KEY (record_id) REFERENCES MediaRecords (id) ON DELETE CASCADE
)
''');
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
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

  Future<void> close() {
    return _closing ??= _close().whenComplete(() => _closing = null);
  }

  Future<void> _close() async {
    // No database is opened just to close an unused helper.
    try {
      if (_backup != null) await _backup;
      if (_opening != null) _database = await _opening;
      final db = _database;
      if (db != null) await _backupDatabase(db);
    } finally {
      final db = _database;
      _database = null;
      await db?.close();
    }
  }
}
