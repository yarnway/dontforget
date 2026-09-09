import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart';
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

  Future<Database> _initDB(String filePath) async {
    // Initialize FFI for desktop platforms
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    
    final dbPath = await sqflite.getDatabasesPath();
    final path = join(dbPath, filePath);

    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
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
  }

  Future<void> close() async {
    final db = await instance.database;
    db.close();
  }
}
