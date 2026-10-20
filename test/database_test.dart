import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';

void main() {
  late Directory directory;
  late DatabaseHelper helper;
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('dontforget-test-');
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
  });
  tearDown(() async {
    await helper.close();
    await directory.delete(recursive: true);
  });

  test('Fresh database has no bundled credentials and supports CRUD', () async {
    final db = await helper.database;
    expect(await db.getVersion(), 8);
    expect((await db.query('Settings')).single['api_key'], isEmpty);
    await db.insert(
      'Reminders',
      Reminder(id: 'task', taskTitle: 'Test', quadrantLevel: 2).toJson(),
    );
    await db.update(
      'Reminders',
      {'is_completed': 1},
      where: 'id = ?',
      whereArgs: ['task'],
    );
    expect((await db.query('Reminders')).single['is_completed'], 1);
    expect(await db.delete('Reminders', where: 'is_completed = 1'), 1);
  });

  test('Disposed reminder notifier ignores delayed startup data', () async {
    final notifier = RemindersNotifier(helper);
    notifier.dispose();
    await notifier.ready;
  });

  test(
    'Concurrent opens share one handle and close permits reopening',
    () async {
      final handles = await Future.wait(
        List.generate(12, (_) => helper.database),
      );
      expect(handles.every((db) => identical(db, handles.first)), isTrue);
      await handles.first.insert(
        'Reminders',
        Reminder(id: 'kept', taskTitle: 'Kept', quadrantLevel: 1).toJson(),
      );
      await helper.close();
      final reopened = await helper.database;
      expect(reopened.isOpen, isTrue);
      expect((await reopened.query('Reminders')).single['id'], 'kept');
    },
  );

  test('Backup includes committed WAL data, settings and media', () async {
    final db = await helper.database;
    await db.rawQuery('PRAGMA journal_mode = WAL');
    await db.update('Settings', {'api_key': 'user-owned-test-key'});
    await db.insert('MediaRecords', {
      'id': 'media',
      'type': 'text',
      'content_or_path': 'original',
      'created_at': '2026-10-20T09:00:00',
    });
    await db.insert(
      'Reminders',
      Reminder(
        id: 'with-media',
        recordId: 'media',
        taskTitle: 'Saved',
        quadrantLevel: 1,
      ).toJson(),
    );
    await Future.wait([
      helper.createMirrorBackup(),
      helper.createMirrorBackup(),
    ]);
    final mirror = await databaseFactoryFfi.openDatabase(
      join(directory.path, 'dont_forget_v3.mirror.db'),
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      expect(
        (await mirror.query('Settings')).single['api_key'],
        'user-owned-test-key',
      );
      expect((await mirror.query('MediaRecords')).single['id'], 'media');
      expect((await mirror.query('Reminders')).single['record_id'], 'media');
      expect(
        (await mirror.rawQuery('PRAGMA integrity_check')).single.values.single,
        'ok',
      );
    } finally {
      await mirror.close();
    }
    final snapshot = jsonDecode(
      await File(join(directory.path, 'ha_snapshot.json')).readAsString(),
    );
    expect(snapshot['version'], 8);
    expect(snapshot['media_records'].single['id'], 'media');
    await db.update('Reminders', {'task_title': 'Updated'});
    await helper.createMirrorBackup();
    final updated = jsonDecode(
      await File(join(directory.path, 'ha_snapshot.json')).readAsString(),
    );
    expect(updated['reminders'].single['task_title'], 'Updated');
  });

  test(
    'Failed backup keeps the previous mirror and reports the failure',
    () async {
      final db = await helper.database;
      await helper.createMirrorBackup();
      final mirror = File(join(directory.path, 'dont_forget_v3.mirror.db'));
      final before = await mirror.readAsBytes();
      await db.execute(
        'ALTER TABLE MediaRecords RENAME TO TemporarilyUnavailable',
      );
      try {
        await expectLater(
          helper.createMirrorBackup(),
          throwsA(isA<DatabaseException>()),
        );
        expect(await mirror.readAsBytes(), before);
      } finally {
        await db.execute(
          'ALTER TABLE TemporarilyUnavailable RENAME TO MediaRecords',
        );
      }
    },
  );

  test('Close releases the handle even if an in-flight backup fails', () async {
    final db = await helper.database;
    await db.execute(
      'ALTER TABLE MediaRecords RENAME TO TemporarilyUnavailable',
    );
    final backup = helper.createMirrorBackup();
    final closing = helper.close();
    await Future.wait([
      expectLater(backup, throwsA(isA<DatabaseException>())),
      expectLater(closing, throwsA(isA<DatabaseException>())),
    ]);
    expect(db.isOpen, isFalse);
    final reopened = await helper.database;
    await reopened.execute(
      'ALTER TABLE TemporarilyUnavailable RENAME TO MediaRecords',
    );
  });

  test(
    'Open failure retains original files and allows a later retry',
    () async {
      final primary = File(join(directory.path, 'dont_forget_v3.db'));
      final mirror = File(join(directory.path, 'dont_forget_v3.mirror.db'));
      await primary.writeAsString('invalid primary - retain for recovery');
      await mirror.writeAsString('older backup - retain for recovery');
      await expectLater(helper.database, throwsA(isA<DatabaseException>()));
      expect(
        await primary.readAsString(),
        'invalid primary - retain for recovery',
      );
      expect(await mirror.readAsString(), 'older backup - retain for recovery');
      await primary.delete();
      expect((await helper.database).isOpen, isTrue);
    },
  );

  test('v7 migration preserves user configuration and records', () async {
    final db = await helper.database;
    await db.update('Settings', {
      'api_key': 'my-own-key',
      'model_name': 'my-model',
      'base_url': 'https://example.invalid/v1',
    });
    await db.insert(
      'Reminders',
      Reminder(
        id: 'existing',
        taskTitle: 'Existing',
        quadrantLevel: 3,
      ).toJson(),
    );
    await db.setVersion(7);
    await helper.close();
    final upgraded = await helper.database;
    expect(await upgraded.getVersion(), 8);
    final settings = (await upgraded.query('Settings')).single;
    expect(settings['api_key'], 'my-own-key');
    expect(settings['model_name'], 'my-model');
    expect((await upgraded.query('Reminders')).single['id'], 'existing');
  });

  test(
    'Settings save wins against startup load and inserts a missing row',
    () async {
      final notifier = SettingsNotifier(helper);
      final desired = notifier.state.copyWith(
        apiKey: 'user-key',
        modelName: 'custom',
      );
      await notifier.updateSettings(desired);
      expect(notifier.state.apiKey, 'user-key');
      final db = await helper.database;
      await db.delete('Settings');
      await notifier.updateSettings(desired.copyWith(language: 'en'));
      expect((await db.query('Settings')).single['language'], 'en');
      notifier.dispose();
    },
  );

  test('Settings failure preserves state and the database row', () async {
    final notifier = SettingsNotifier(helper);
    await notifier.ready;
    final before = notifier.state;
    final db = await helper.database;
    await db.execute(
      'CREATE TRIGGER reject_settings BEFORE INSERT ON Settings '
      "BEGIN SELECT RAISE(ABORT, 'test write failure'); END",
    );
    try {
      await expectLater(
        notifier.updateSettings(before.copyWith(apiKey: 'new')),
        throwsA(isA<DatabaseException>()),
      );
      expect(notifier.state, same(before));
      expect((await db.query('Settings')).single['api_key'], before.apiKey);
    } finally {
      await db.execute('DROP TRIGGER reject_settings');
      notifier.dispose();
    }
  });
}
