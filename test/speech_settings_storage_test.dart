import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/speech_settings.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory root;
  late DatabaseHelper helper;
  final legacy = AppSettings.defaults().toJson()..remove('speech_config_json');
  Future<void> create16({bool drift = false}) async {
    final db = await databaseFactoryFfi.openDatabase(
      '${root.path}/dont_forget_v3.db',
    );
    final sql = (await File(
      'test/fixtures/schema_v16.sql',
    ).readAsString()).split('\n').where((l) => !l.startsWith('--')).join('\n');
    for (final statement in sql.split(';')) {
      if (statement.trim().isNotEmpty) await db.execute(statement);
    }
    await db.insert('Settings', {
      ...legacy,
      'workspace_drafts_json': '{"capture":{"text":"中文 English unsent"}}',
    });
    if (drift) {
      await db.execute(
        "ALTER TABLE Settings ADD COLUMN speech_config_json TEXT NOT NULL DEFAULT '{}' ",
      );
    }
    await db.setVersion(16);
    await db.close();
  }

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('speech-upgrade-');
    helper = DatabaseHelper.forTesting(root.path, databaseFactoryFfi);
  });
  tearDown(() async {
    await helper.close(createBackup: false);
    await root.delete(recursive: true);
  });
  test(
    'v16 upgrades speech independently and keeps an inspectable old snapshot and exact draft',
    () async {
      await create16();
      final db = await helper.database;
      expect(await db.getVersion(), 17);
      final row = (await db.query('Settings')).single;
      expect(
        row['workspace_drafts_json'],
        '{"capture":{"text":"中文 English unsent"}}',
      );
      expect(AppSettings.fromJson(row).speech.enabled, isFalse);
      expect(AppSettings.fromJson(row).speech.apiKey, isEmpty);
      final stage = root.listSync().whereType<Directory>().singleWhere(
        (d) => d.path.contains('schema-upgrade-v16-to-v17-'),
      );
      final snapshot = File('${stage.path}/snapshot.json');
      final preview = await BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: root,
      ).inspect(snapshot);
      expect(preview.version, 16);
      expect(
        (jsonDecode(await snapshot.readAsString())['settings'] as List).single
            .containsKey('speech_config_json'),
        isFalse,
      );
    },
  );
  test(
    'speech migration SQL drift rolls back without choosing a new blank database',
    () async {
      await create16(drift: true);
      await expectLater(helper.database, throwsA(isA<DatabaseException>()));
      await helper.close(createBackup: false);
      final db = await databaseFactoryFfi.openDatabase(
        '${root.path}/dont_forget_v3.db',
      );
      expect(await db.getVersion(), 16);
      expect(
        (await db.query('Settings')).single['workspace_drafts_json'],
        '{"capture":{"text":"中文 English unsent"}}',
      );
      expect(
        (await db.rawQuery('PRAGMA quick_check')).single.values.single,
        'ok',
      );
      await db.close();
    },
  );
  test('speech schema rejects unknown versions and malformed fields', () {
    final data = const SpeechSettings().toJson();
    for (final bad in [
      {...data, 'version': 2},
      {...data, 'enabled': 1},
      {...data, 'api_key': null},
      {...data, 'extra': true},
    ]) {
      expect(() => SpeechSettings.fromJson(bad), throwsFormatException);
    }
    expect(AppSettings.fromJson(legacy).speech.enabled, isFalse);
  });
}
