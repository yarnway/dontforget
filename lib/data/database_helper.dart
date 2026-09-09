import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('dont_forget_v3.db');
    return _database!;
  }

  Future<String> _getDatabaseDirectory() async {
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
          final localAppData = Platform.environment['LOCALAPPDATA'] ??
              Platform.environment['APPDATA'] ??
              Platform.environment['USERPROFILE'] ??
              '.';
          final fallbackDir = Directory(join(localAppData, 'DontForget', 'databases'));
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
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    
    final dbDir = await _getDatabaseDirectory();
    final targetPath = join(dbDir, filePath);

    // Auto-migrate legacy DB from previous development/relative path if target doesn't exist
    final targetFile = File(targetPath);
    if (!targetFile.existsSync()) {
      try {
        final legacyDir = join(Directory.current.path, '.dart_tool', 'sqflite_common_ffi', 'databases', filePath);
        final legacyFile = File(legacyDir);
        if (legacyFile.existsSync()) {
          legacyFile.copySync(targetPath);
        }
      } catch (_) {}
    }

    return await databaseFactory.openDatabase(
      targetPath,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: _createDB,
        onUpgrade: _upgradeDB,
      ),
    );
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

    // Initialize default settings configured for DeepSeek
    final defaultKey = utf8.decode(base64.decode('c2stZDdmZmNiNTAzMGMzNDI5OGExZTQ3NDEzN2JmODNmYjk='));
    await db.insert('Settings', {
      'id': 'default',
      'api_key': defaultKey,
      'base_url': 'https://api.deepseek.com',
      'model_name': 'deepseek-v4-flash-vision-exp',
      'language': 'zh',
    });

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
  FOREIGN KEY (record_id) REFERENCES MediaRecords (id) ON DELETE CASCADE
)
''');
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 4) {
      try {
        await db.execute('ALTER TABLE Reminders ADD COLUMN is_recurring INTEGER DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE Reminders ADD COLUMN recurrence_rule TEXT DEFAULT "none"');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE Reminders ADD COLUMN recurrence_description TEXT');
      } catch (_) {}
    }
    if (oldVersion < 5) {
      try {
        await db.execute('ALTER TABLE Reminders ADD COLUMN is_emotion_filtered INTEGER DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE Reminders ADD COLUMN sub_tasks TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE Reminders ADD COLUMN created_at TEXT');
      } catch (_) {}
    }
  }

  Future<void> close() async {
    final db = await instance.database;
    db.close();
  }
}
