import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory root;
  late DatabaseHelper helper;
  final legacySettings =
      AppSettings.defaults()
          .copyWith(apiKey: 'synthetic-only', language: 'ja')
          .toJson()
        ..remove('appearance')
        ..remove('workspace_drafts_json')
        ..remove('input_send_mode');
  final task = Reminder(
    id: 'kept',
    taskTitle: 'Synthetic reminder',
    quadrantLevel: 2,
    noticeRevision: 7,
  ).toJson();

  Future<File> legacy({bool broken = false}) async {
    final file = File('${root.path}/dont_forget_v3.db');
    final db = await databaseFactoryFfi.openDatabase(
      file.path,
      options: OpenDatabaseOptions(
        version: 10,
        onCreate: (db, _) async {
          final schema =
              (await File('test/fixtures/schema_v10.sql').readAsString())
                  .split('\n')
                  .where((l) => !l.startsWith('--'))
                  .join('\n');
          for (final sql in schema.split(';')) {
            if (sql.trim().isNotEmpty) await db.execute(sql);
          }
          await db.insert('Settings', legacySettings);
          await db.insert(
            'Reminders',
            {...task}..removeWhere(
              (key, _) => const {
                'review_notifications_enabled',
                'event_time',
                'recurrence_event_anchor_time',
                'suggested_trigger_time',
                'details_json',
                'source_text',
                'capture_proposal_json',
                'word_progress_json',
                'capture_pending',
                'is_pinned',
              }.contains(key),
            ),
          );
          if (broken) {
            await db.execute('ALTER TABLE Settings ADD COLUMN appearance TEXT');
          }
        },
      ),
    );
    await db.close();
    return file;
  }

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('dontforget-appearance-');
    helper = DatabaseHelper.forTesting(root.path, databaseFactoryFfi);
  });
  tearDown(() async {
    await helper.close(createBackup: false);
    await root.delete(recursive: true);
  });

  test(
    'v10 upgrades with system appearance and a usable untouched rollback snapshot',
    () async {
      await legacy();
      final db = await helper.database;
      expect(await db.getVersion(), DatabaseHelper.schemaVersion);
      expect((await db.query('Settings')).single, {
        ...legacySettings,
        'appearance': 'system',
        'input_send_mode': 'enter',
        'workspace_drafts_json': null,
      });
      expect((await db.query('Reminders')).single, task);
      final snapshotDir = root.listSync().whereType<Directory>().singleWhere(
        (d) => d.path.contains(
          'schema-upgrade-v10-to-v${DatabaseHelper.schemaVersion}-',
        ),
      );
      final snapshot = File('${snapshotDir.path}/snapshot.json');
      final preview = await BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: root,
      ).inspect(snapshot);
      expect(preview.version, 10);
      final data = jsonDecode(await snapshot.readAsString());
      expect(data['settings'], [legacySettings]);
      expect(data['reminders'], [
        {...task}..removeWhere(
          (key, _) => const {
            'review_notifications_enabled',
            'event_time',
            'recurrence_event_anchor_time',
            'suggested_trigger_time',
            'details_json',
            'source_text',
            'capture_proposal_json',
            'word_progress_json',
            'capture_pending',
            'is_pinned',
          }.contains(key),
        ),
      ]);
      // Rebuild an independent v10 database with its frozen schema, not a downgrade.
      final rollback = await databaseFactoryFfi.openDatabase(
        '${root.path}/rollback-v10.db',
      );
      final schema = (await File('test/fixtures/schema_v10.sql').readAsString())
          .split('\n')
          .where((l) => !l.startsWith('--'))
          .join('\n');
      for (final sql in schema.split(';')) {
        if (sql.trim().isNotEmpty) await rollback.execute(sql);
      }
      await rollback.insert(
        'Settings',
        Map<String, Object?>.from(data['settings'].single as Map),
      );
      await rollback.insert(
        'Reminders',
        Map<String, Object?>.from(data['reminders'].single as Map),
      );
      await rollback.setVersion(10);
      expect((await rollback.query('Settings')).single, legacySettings);
      expect(
        (await rollback.rawQuery(
          'PRAGMA integrity_check',
        )).single.values.single,
        'ok',
      );
      await rollback.close();
      await helper.close();
      expect(
        (await (await helper.database).query('Settings')).single['appearance'],
        'system',
      );
    },
  );

  test(
    'failed appearance migration keeps the v10 schema and all rows',
    () async {
      final file = await legacy(broken: true);
      await expectLater(helper.database, throwsA(isA<DatabaseException>()));
      await helper.close(createBackup: false);
      final db = await databaseFactoryFfi.openDatabase(file.path);
      expect(await db.getVersion(), 10);
      expect((await db.query('Settings')).single, {
        ...legacySettings,
        'appearance': null,
      });
      expect(
        (await db.query('Reminders')).single,
        {...task}..removeWhere(
          (key, _) => const {
            'review_notifications_enabled',
            'event_time',
            'recurrence_event_anchor_time',
            'suggested_trigger_time',
            'details_json',
            'source_text',
            'capture_proposal_json',
            'word_progress_json',
            'capture_pending',
            'is_pinned',
          }.contains(key),
        ),
      );
      await db.close();
    },
  );

  for (final format in ['json', 'sqlite']) {
    test(
      'real v10 $format restores with system appearance and unchanged source',
      () async {
        final database = await legacy();
        final file = format == 'sqlite'
            ? database
            : await File('${root.path}/v10.json').writeAsString(
                jsonEncode({
                  'version': 10,
                  'timestamp': '2026-10-27T00:00:00Z',
                  'settings': [legacySettings],
                  'media_records': [],
                  'reminders': [
                    {...task}..removeWhere(
                      (key, _) => const {
                        'review_notifications_enabled',
                        'event_time',
                        'recurrence_event_anchor_time',
                        'suggested_trigger_time',
                        'details_json',
                        'source_text',
                        'capture_proposal_json',
                        'word_progress_json',
                        'capture_pending',
                        'is_pinned',
                      }.contains(key),
                    ),
                  ],
                }),
              );
        final before = await file.readAsBytes();
        final inspector = BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        );
        final preview = await inspector.inspect(file);
        expect(preview.version, 10);
        final target = DatabaseHelper.forTesting(
          '${root.path}/old-restored',
          databaseFactoryFfi,
        );
        try {
          await DatabaseRecovery(
            target,
            inspector: inspector,
            notifications: NotificationService.forTesting(
              FlutterLocalNotificationsPlugin(),
              usesNativeNotifications: false,
            ),
          ).restore(file, expectedDigest: preview.digest);
          final db = await target.database;
          expect((await db.query('Settings')).single, {
            ...legacySettings,
            'appearance': 'system',
            'input_send_mode': 'enter',
            'workspace_drafts_json': null,
          });
          expect((await db.query('Reminders')).single, task);
          expect(await file.readAsBytes(), before);
        } finally {
          await target.close();
        }
      },
    );

    test('appearance survives close, $format backup and recovery', () async {
      final db = await helper.database;
      await db.update('Settings', {
        'appearance': 'dark',
        'input_send_mode': 'button',
      });
      await helper.close();
      expect(
        AppSettings.fromJson(
          (await (await helper.database).query('Settings')).single,
        ).appearance,
        AppAppearance.dark,
      );
      final backup = File(
        '${root.path}/${format == 'json' ? 'ha_snapshot.json' : 'dont_forget_v3.mirror.db'}',
      );
      final bytes = await backup.readAsBytes();
      final inspector = BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: root,
      );
      final preview = await inspector.inspect(backup);
      expect(preview.version, DatabaseHelper.schemaVersion);
      final target = DatabaseHelper.forTesting(
        '${root.path}/restored',
        databaseFactoryFfi,
      );
      try {
        await DatabaseRecovery(
          target,
          inspector: inspector,
          notifications: NotificationService.forTesting(
            FlutterLocalNotificationsPlugin(),
            usesNativeNotifications: false,
          ),
        ).restore(backup, expectedDigest: preview.digest);
        expect(
          AppSettings.fromJson(
            (await (await target.database).query('Settings')).single,
          ).appearance,
          AppAppearance.dark,
        );
        expect(await backup.readAsBytes(), bytes);
        expect(
          AppSettings.fromJson(
            (await (await target.database).query('Settings')).single,
          ).inputSendMode,
          InputSendMode.button,
        );
      } finally {
        await target.close();
      }
    });
  }

  test(
    'legacy preferences default to system and invalid modes fail validation',
    () {
      expect(
        AppSettings.fromJson(legacySettings).appearance,
        AppAppearance.system,
      );
      for (final value in ['blue', '', 1, true]) {
        expect(
          () => AppSettings.fromJson({...legacySettings, 'appearance': value}),
          throwsFormatException,
        );
      }
      final dark = AppSettings.defaults().copyWith(
        appearance: AppAppearance.dark,
      );
      expect(dark.copyWith(language: 'ja').appearance, AppAppearance.dark);
      expect(dark.primaryModelSettings.appearance, AppAppearance.dark);
    },
  );
}
