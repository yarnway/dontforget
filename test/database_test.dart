import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:uuid/uuid.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('Database CRUD Operations', () async {
    final db = DatabaseHelper.instance;
    final id = const Uuid().v4();
    final reminder = Reminder(id: id, taskTitle: 'Test Task', quadrantLevel: 1, isCompleted: false);
    final database = await db.database;
    await database.insert('Reminders', reminder.toJson());
    final results = await database.query('Reminders', where: 'id = ?', whereArgs: [id]);
    expect(results.length, 1);
    expect(results.first['task_title'], 'Test Task');
  });

  test('Database Delete and Clear Completed Operations', () async {
    final db = DatabaseHelper.instance;
    final database = await db.database;

    final id1 = const Uuid().v4();
    final id2 = const Uuid().v4();
    final reminder1 = Reminder(id: id1, taskTitle: 'Task To Delete', quadrantLevel: 2, isCompleted: false);
    final reminder2 = Reminder(id: id2, taskTitle: 'Completed Task', quadrantLevel: 3, isCompleted: true);

    await database.insert('Reminders', reminder1.toJson());
    await database.insert('Reminders', reminder2.toJson());

    // Test single deletion
    await database.delete('Reminders', where: 'id = ?', whereArgs: [id1]);
    final check1 = await database.query('Reminders', where: 'id = ?', whereArgs: [id1]);
    expect(check1.isEmpty, true);

    // Test clear completed
    final deletedCount = await database.delete('Reminders', where: 'is_completed = 1');
    expect(deletedCount >= 1, true);
    final check2 = await database.query('Reminders', where: 'id = ?', whereArgs: [id2]);
    expect(check2.isEmpty, true);
  });
}
