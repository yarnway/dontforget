import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory root;
  late DatabaseHelper helper;
  final legacy =
      AppSettings.defaults().copyWith(appearance: AppAppearance.dark).toJson()
        ..remove('input_send_mode');
  Future<File> createLegacy({bool broken = false}) async {
    final file = File('${root.path}/dont_forget_v3.db');
    final db = await databaseFactoryFfi.openDatabase(file.path);
    final sql = (await File('test/fixtures/schema_v11.sql').readAsString())
        .split('\n')
        .where((line) => !line.startsWith('--'))
        .join('\n');
    for (final statement in sql.split(';')) {
      if (statement.trim().isNotEmpty) await db.execute(statement);
    }
    await db.insert('Settings', legacy);
    if (broken) {
      await db.execute('ALTER TABLE Settings ADD COLUMN input_send_mode TEXT');
    }
    await db.setVersion(11);
    await db.close();
    return file;
  }

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('dontforget-send-mode-');
    helper = DatabaseHelper.forTesting(root.path, databaseFactoryFfi);
  });
  tearDown(() async {
    await helper.close(createBackup: false);
    await root.delete(recursive: true);
  });

  test(
    'v11 upgrades with Enter default and an untouched inspected snapshot',
    () async {
      await createLegacy();
      final db = await helper.database;
      expect(await db.getVersion(), 12);
      expect((await db.query('Settings')).single, {
        ...legacy,
        'input_send_mode': 'enter',
      });
      final snapshotDir = root.listSync().whereType<Directory>().singleWhere(
        (d) => d.path.contains('schema-upgrade-v11-to-v12-'),
      );
      final snapshot = File('${snapshotDir.path}/snapshot.json');
      final bytes = await snapshot.readAsBytes();
      final preview = await BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: root,
      ).inspect(snapshot);
      expect(preview.version, 11);
      expect(jsonDecode(utf8.decode(bytes))['settings'], [legacy]);
      expect(await snapshot.readAsBytes(), bytes);
      await db.update('Settings', {'input_send_mode': 'button'});
      await helper.close();
      expect(
        AppSettings.fromJson(
          (await (await helper.database).query('Settings')).single,
        ).inputSendMode,
        InputSendMode.button,
      );
    },
  );

  test(
    'failed send preference migration preserves the old schema and rows',
    () async {
      final file = await createLegacy(broken: true);
      await expectLater(helper.database, throwsA(isA<DatabaseException>()));
      await helper.close(createBackup: false);
      final db = await databaseFactoryFfi.openDatabase(file.path);
      expect(await db.getVersion(), 11);
      expect((await db.query('Settings')).single, {
        ...legacy,
        'input_send_mode': null,
      });
      expect(
        (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
        'ok',
      );
      await db.close();
    },
  );

  test(
    'send preference survives model settings and rejects invalid enum values',
    () {
      expect(AppSettings.fromJson(legacy).inputSendMode, InputSendMode.enter);
      final settings = AppSettings.defaults().copyWith(
        inputSendMode: InputSendMode.button,
      );
      expect(
        AppSettings.fromJson(settings.toJson()).inputSendMode,
        InputSendMode.button,
      );
      expect(
        settings.copyWith(language: 'ja').primaryModelSettings.inputSendMode,
        InputSendMode.button,
      );
      for (final bad in ['unknown', '', 1, true]) {
        expect(
          () => AppSettings.fromJson({...legacy, 'input_send_mode': bad}),
          throwsFormatException,
        );
      }
    },
  );

  for (final format in ['json', 'sqlite']) {
    test(
      'v11 $format restore adds Enter preference without changing the source',
      () async {
        final sourceDb = await createLegacy();
        final source = format == 'sqlite'
            ? sourceDb
            : await File('${root.path}/legacy.json').writeAsString(
                jsonEncode({
                  'version': 11,
                  'timestamp': DateTime.now().toIso8601String(),
                  'settings': [legacy],
                  'media_records': [],
                  'reminders': [],
                }),
              );
        final bytes = await source.readAsBytes();
        final inspector = BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        );
        final preview = await inspector.inspect(source);
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
          ).restore(source, expectedDigest: preview.digest);
          expect((await (await target.database).query('Settings')).single, {
            ...legacy,
            'input_send_mode': 'enter',
          });
          expect(await source.readAsBytes(), bytes);
        } finally {
          await target.close();
        }
      },
    );
  }
}
