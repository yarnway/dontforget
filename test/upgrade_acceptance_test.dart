import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/settings.dart';

// Uses the historical schema directly, never a downgraded current database.
void main() {
  late Directory directory;
  late DatabaseHelper helper;
  late Map<String, List<Map<String, Object?>>> before;

  Map<String, List<Map<String, Object?>>> getUpgradedRows() => {
    for (final table in before.entries)
      table.key: [
        for (final row in table.value)
          {
            ...row,
            if (table.key == 'Settings') ...AppSettings.fromJson(row).toJson(),
            if (table.key == 'Reminders') ...{
              'notice_revision': 0,
              'notice_acknowledged_at': null,
              'upcoming_dismissed_at': null,
              'snoozed_at': null,
              'recurrence_anchor_time': null,
            },
          },
      ],
  };

  Future<Map<String, List<Map<String, Object?>>>> rows(Database db) async => {
    for (final table in ['Settings', 'MediaRecords', 'Reminders'])
      table: await db.query(table, orderBy: 'id'),
  };

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('dontforget-v7-upgrade-');
    final db = await databaseFactoryFfi.openDatabase(
      join(directory.path, 'dont_forget_v3.db'),
      options: OpenDatabaseOptions(
        version: 7,
        onCreate: (db, _) async {
          final sql = await File('test/fixtures/schema_v7.sql').readAsString();
          for (final statement in sql.split(';')) {
            if (statement.trim().isNotEmpty) await db.execute(statement);
          }
        },
      ),
    );
    await db.insert('Settings', {
      'id': 'default',
      'api_key': 'synthetic-user-owned-key',
      'base_url': 'https://example.invalid/v1',
      'model_name': 'synthetic-model',
      'language': 'ja',
    });
    await db.insert('MediaRecords', {
      'id': 'voice',
      'type': 'audio',
      'content_or_path': join(directory.path, '附件 with spaces.m4a'),
      'created_at': '2026-01-31T23:59:00',
    });
    for (var i = 0; i < 4; i++) {
      await db.insert('Reminders', {
        'id': 'legacy-$i',
        'record_id': i == 0 ? 'voice' : null,
        'task_title': '旧版验收 $i',
        'task_summary': i == 2 ? null : 'Synthetic fixture only',
        'quadrant_level': i + 1,
        'urgency_level': 'General',
        'importance_level': 'Important',
        'trigger_time': i == 3 ? null : '2026-01-31T23:59:00',
        'is_completed': i == 1 ? 1 : 0,
        'is_recurring': i == 0 ? 1 : 0,
        'recurrence_rule': i == 0 ? 'monthly' : 'none',
        'recurrence_description': i == 0 ? '每月最后一天' : null,
        'is_emotion_filtered': 0,
        'sub_tasks': i == 0 ? '[{"title":"附件核对","isCompleted":false}]' : null,
        'created_at': '2026-01-01T10:00:00',
        'review_level': i,
        'next_review_at': i == 2 ? '2026-02-01T10:00:00' : null,
        'original_quadrant_level': i + 1,
        'is_dynamically_promoted': 0,
        'linked_task_ids': i < 2 ? '["legacy-${1 - i}"]' : '[]',
        'context_trigger': i == 3 ? 'home' : null,
      });
    }
    before = await rows(db);
    await db.close();
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
  });

  tearDown(() async {
    await helper.close();
    await directory.delete(recursive: true);
  });

  test(
    'historical v7 schema preserves all fields through upgrade and backup',
    () async {
      final db = await helper.database;
      expect(await db.getVersion(), DatabaseHelper.schemaVersion);
      expect(await rows(db), getUpgradedRows());
      expect(
        (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
        'ok',
      );
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      await helper.createMirrorBackup();
      final snapshot =
          jsonDecode(
                await File(
                  join(directory.path, 'ha_snapshot.json'),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      for (final entry in {
        'Settings': 'settings',
        'MediaRecords': 'media_records',
        'Reminders': 'reminders',
      }.entries) {
        expect(snapshot[entry.value], getUpgradedRows()[entry.key]);
      }
      await helper.close();
      expect(await rows(await helper.database), getUpgradedRows());
      // The synthetic missing attachment path is preserved, not silently rewritten.
      expect(
        File(
          before['MediaRecords']!.single['content_or_path']! as String,
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'failed v7 migration preserves the database and can retry after repair',
    () async {
      final path = join(directory.path, 'dont_forget_v3.db');
      final legacy = await databaseFactoryFfi.openDatabase(path);
      await legacy.execute(
        'ALTER TABLE Settings RENAME TO UnavailableSettings',
      );
      await legacy.close();
      final original = await File(path).readAsBytes();
      final mirror = File(join(directory.path, 'dont_forget_v3.mirror.db'));
      await mirror.writeAsString(
        'sentinel older backup: must not replace primary',
      );
      await expectLater(helper.database, throwsA(isA<DatabaseException>()));
      expect(await File(path).readAsBytes(), original);
      expect(
        await mirror.readAsString(),
        'sentinel older backup: must not replace primary',
      );

      final inspection = await databaseFactoryFfi.openDatabase(path);
      expect(await inspection.getVersion(), 7);
      expect(
        await inspection.query('Reminders', orderBy: 'id'),
        before['Reminders'],
      );
      await inspection.execute(
        'ALTER TABLE UnavailableSettings RENAME TO Settings',
      );
      await inspection.close();
      final upgraded = await helper.database;
      expect(await upgraded.getVersion(), DatabaseHelper.schemaVersion);
      expect(await rows(upgraded), getUpgradedRows());
    },
  );
}
