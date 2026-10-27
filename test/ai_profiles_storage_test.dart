import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/ai_profile.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';

void main() {
  late Directory root;
  final legacy = {
    'id': 'default',
    'api_key': 'fixture-private',
    'base_url': 'https://custom.invalid/v1',
    'model_name': 'private-model',
    'language': 'ja',
  };
  Future<File> oldDatabase(String name, {bool broken = false}) async {
    final dir = await Directory('${root.path}/$name').create();
    final file = File('${dir.path}/dont_forget_v3.db');
    final db = await databaseFactoryFfi.openDatabase(
      file.path,
      options: OpenDatabaseOptions(
        version: 9,
        onCreate: (db, _) async {
          for (final sql in (await File(
            'test/fixtures/schema_v8.sql',
          ).readAsString()).split(';')) {
            if (sql.trim().isNotEmpty) await db.execute(sql);
          }
          await db.execute(
            'ALTER TABLE Reminders ADD COLUMN notice_revision INTEGER NOT NULL DEFAULT 0',
          );
          for (final key in [
            'notice_acknowledged_at',
            'upcoming_dismissed_at',
            'snoozed_at',
            'recurrence_anchor_time',
          ]) {
            await db.execute('ALTER TABLE Reminders ADD COLUMN $key TEXT');
          }
          if (broken) {
            await db.execute(
              'ALTER TABLE Settings ADD COLUMN ai_fallback_enabled INTEGER',
            );
          }
          await db.insert('Settings', legacy);
        },
      ),
    );
    await db.close();
    return file;
  }

  setUp(() async {
    sqfliteFfiInit();
    final raw = await Directory.systemTemp.createTemp(
      'dontforget-model-storage-',
    );
    root = Directory(await raw.resolveSymbolicLinks());
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'v9 upgrade preserves every legacy value, freezes order and keeps opt-in off',
    () async {
      final file = await oldDatabase('old');
      final before = await file.readAsBytes();
      final rollback = await file.copy('${root.path}/before-v9.db');
      final helper = DatabaseHelper.forTesting(
        file.parent.path,
        databaseFactoryFfi,
      );
      try {
        final db = await helper.database;
        expect(await db.getVersion(), DatabaseHelper.schemaVersion);
        final row = (await db.query('Settings')).single;
        for (final field in legacy.entries) {
          expect(row[field.key], field.value);
        }
        final settings = AppSettings.fromJson(row);
        expect(
          settings.effectiveProfiles.single.settings.apiKey,
          'fixture-private',
        );
        expect(
          settings.effectiveProfiles.single.settings.baseUrl,
          legacy['base_url'],
        );
        expect(
          settings.effectiveProfiles.single.settings.modelName,
          legacy['model_name'],
        );
        expect(settings.aiFallbackEnabled, isFalse);
        expect(() => settings.aiProfiles.clear(), throwsUnsupportedError);
        expect(await rollback.readAsBytes(), before);
        expect(
          (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
          'ok',
        );
      } finally {
        await helper.close();
      }
      final snapshots = file.parent
          .listSync()
          .whereType<Directory>()
          .where(
            (d) => d.path.contains(
              'schema-upgrade-v9-to-v${DatabaseHelper.schemaVersion}-',
            ),
          )
          .toList();
      expect(snapshots, hasLength(1));
      final snapshot = File('${snapshots.single.path}/snapshot.json');
      final exported = jsonDecode(await snapshot.readAsString());
      expect(exported['version'], 9);
      expect(exported['settings'], [legacy]);
      expect(
        (await BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        ).inspect(snapshot)).version,
        9,
      );
      final futureDb = await databaseFactoryFfi.openDatabase(file.path);
      await futureDb.setVersion(DatabaseHelper.schemaVersion + 1);
      await futureDb.close();
      final migrated = await file.readAsBytes();
      await expectLater(helper.database, throwsA(isA<StateError>()));
      expect(await file.readAsBytes(), migrated);
      await helper.close(createBackup: false);
      // Reconstruct a v9 database from the automatically retained logical copy.
      // The schema is frozen; backup content is inserted only as bound values.
      final rebuilt = await databaseFactoryFfi.openDatabase(
        '${root.path}/rebuilt-v9.db',
        options: OpenDatabaseOptions(
          version: 9,
          onCreate: (db, _) async {
            for (final sql
                in (await File('test/fixtures/schema_v9.sql').readAsString())
                    .split('\n')
                    .where((line) => !line.trimLeft().startsWith('--'))
                    .join('\n')
                    .split(';')) {
              if (sql.trim().isNotEmpty) await db.execute(sql);
            }
            for (final entry in {
              'Settings': 'settings',
              'MediaRecords': 'media_records',
              'Reminders': 'reminders',
            }.entries) {
              for (final row in exported[entry.value] as List) {
                await db.insert(
                  entry.key,
                  Map<String, Object?>.from(row as Map),
                );
              }
            }
          },
        ),
      );
      expect(await rebuilt.getVersion(), 9);
      expect((await rebuilt.query('Settings')).single, legacy);
      expect(
        (await rebuilt.rawQuery('PRAGMA integrity_check')).single.values.single,
        'ok',
      );
      await rebuilt.close();
      // Actual rollback uses the independent v9 file, not an in-place downgrade.
      final old = await databaseFactoryFfi.openDatabase(rollback.path);
      expect(await old.getVersion(), 9);
      expect((await old.query('Settings')).single, legacy);
      await old.close();
    },
  );

  test(
    'failed second migration statement rolls back first column and version',
    () async {
      final file = await oldDatabase('broken', broken: true);
      final helper = DatabaseHelper.forTesting(
        file.parent.path,
        databaseFactoryFfi,
      );
      await expectLater(helper.database, throwsA(isA<DatabaseException>()));
      final db = await databaseFactoryFfi.openDatabase(file.path);
      expect(await db.getVersion(), 9);
      expect(
        (await db.rawQuery(
          'PRAGMA table_info(Settings)',
        )).map((r) => r['name']),
        isNot(contains('ai_profiles_json')),
      );
      expect((await db.query('Settings')).single['api_key'], 'fixture-private');
      await db.close();
      await helper.close(createBackup: false);
    },
  );

  for (final format in ['sqlite', 'json']) {
    test(
      'current $format restores ordered disabled keys and reports sensitivity',
      () async {
        final source = DatabaseHelper.forTesting(
          '${root.path}/source',
          databaseFactoryFfi,
        );
        final settings = AppSettings.defaults().copyWith(
          aiProfiles: [
            AiProfile(
              id: 'off',
              label: 'Disabled fixture',
              enabled: false,
              settings: AppSettings.defaults().copyWith(
                apiKey: 'disabled-private-key',
              ),
            ),
            AiProfile(
              id: 'on',
              label: 'Enabled fixture',
              settings: AppSettings.defaults().copyWith(
                apiKey: 'enabled-private-key',
              ),
            ),
          ],
          aiFallbackEnabled: true,
        );
        final provider = ProviderContainer(
          overrides: [databaseHelperProvider.overrideWithValue(source)],
        );
        await provider.read(settingsProvider.notifier).ready;
        await provider.read(settingsProvider.notifier).updateSettings(settings);
        provider.dispose();
        await source.close();
        final file = File(
          '${root.path}/source/${format == 'json' ? 'ha_snapshot.json' : 'dont_forget_v3.mirror.db'}',
        );
        final before = await file.readAsBytes();
        final inspector = BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        );
        final preview = await inspector.inspect(file);
        expect(preview.version, DatabaseHelper.schemaVersion);
        expect(preview.containsCredentials, isTrue);
        final live = DatabaseHelper.forTesting(
          '${root.path}/live',
          databaseFactoryFfi,
        );
        try {
          await DatabaseRecovery(
            live,
            inspector: inspector,
            notifications: NotificationService.forTesting(
              FlutterLocalNotificationsPlugin(),
              usesNativeNotifications: false,
            ),
          ).restore(file, expectedDigest: preview.digest);
          final restored = AppSettings.fromJson(
            (await (await live.database).query('Settings')).single,
          );
          expect(restored.toJson(), settings.toJson());
          expect(await file.readAsBytes(), before);
        } finally {
          await live.close();
        }
      },
    );
  }

  test(
    'JSON restore preserves nullable legacy columns alongside model profiles',
    () async {
      final source = DatabaseHelper.forTesting(
        '${root.path}/nullable',
        databaseFactoryFfi,
      );
      final db = await source.database;
      await db.update('Settings', {
        'api_key': null,
        'base_url': null,
        'model_name': null,
        'language': null,
      });
      final original = (await db.query('Settings')).single;
      await source.close();
      final file = File('${root.path}/nullable/ha_snapshot.json');
      final inspector = BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: root,
      );
      final preview = await inspector.inspect(file);
      final live = DatabaseHelper.forTesting(
        '${root.path}/live',
        databaseFactoryFfi,
      );
      try {
        await DatabaseRecovery(
          live,
          inspector: inspector,
          notifications: NotificationService.forTesting(
            FlutterLocalNotificationsPlugin(),
            usesNativeNotifications: false,
          ),
        ).restore(file, expectedDigest: preview.digest);
        expect(
          (await (await live.database).query('Settings')).single,
          original,
        );
      } finally {
        await live.close();
      }
    },
  );

  test(
    'malformed nested profiles are rejected before saving or recovery',
    () async {
      final helper = DatabaseHelper.forTesting(
        '${root.path}/live',
        databaseFactoryFfi,
      );
      final container = ProviderContainer(
        overrides: [databaseHelperProvider.overrideWithValue(helper)],
      );
      await container.read(settingsProvider.notifier).ready;
      final before = (await (await helper.database).query('Settings')).single;
      final p = AiProfile(
        id: 'same',
        label: 'same',
        settings: AppSettings.defaults(),
      );
      await expectLater(
        container
            .read(settingsProvider.notifier)
            .updateSettings(
              AppSettings.defaults().copyWith(aiProfiles: [p, p]),
            ),
        throwsFormatException,
      );
      expect((await (await helper.database).query('Settings')).single, before);
      await helper.createMirrorBackup();
      final data = jsonDecode(
        await File('${root.path}/live/ha_snapshot.json').readAsString(),
      );
      data['settings'][0]['ai_profiles_json'] = '[{"id":"x","id":"y"}]';
      final malformed = await File(
        '${root.path}/malformed.json',
      ).writeAsString(jsonEncode(data));
      await expectLater(
        BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        ).inspect(malformed),
        throwsA(isA<BackupInspectionException>()),
      );
      container.dispose();
      await helper.close();
    },
  );
}
