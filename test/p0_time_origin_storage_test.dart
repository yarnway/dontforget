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
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DatabaseHelper helper;
  final oldTask =
      Reminder(
          id: 'legacy',
          taskTitle: 'Legacy',
          quadrantLevel: 2,
          triggerTime: DateTime.utc(2030, 1, 1, 9),
        ).toJson()
        ..remove('trigger_time_origin')
        ..remove('event_time')
        ..remove('recurrence_event_anchor_time')
        ..remove('suggested_trigger_time')
        ..remove('source_text')
        ..remove('capture_pending')
        ..remove('is_pinned');

  final upgradedTask = {
    ...oldTask,
    'trigger_time_origin': 'unknown',
    'event_time': null,
    'recurrence_event_anchor_time': null,
    'suggested_trigger_time': null,
    'source_text': null,
    'capture_pending': 0,
    'is_pinned': 0,
  };

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('dontforget-origin-');
    helper = DatabaseHelper.forTesting(root.path, databaseFactoryFfi);
  });
  tearDown(() async {
    await helper.close(createBackup: false);
    await root.delete(recursive: true);
  });

  Future<File> createVersion13() async {
    final file = File('${root.path}/dont_forget_v3.db');
    final db = await databaseFactoryFfi.openDatabase(file.path);
    final sql = (await File('test/fixtures/schema_v13.sql').readAsString())
        .split('\n')
        .where((line) => !line.startsWith('--'))
        .join('\n');
    for (final statement in sql.split(';')) {
      if (statement.trim().isNotEmpty) await db.execute(statement);
    }
    await db.insert('Settings', AppSettings.defaults().toJson());
    await db.insert('Reminders', oldTask);
    await db.setVersion(13);
    await db.close();
    return file;
  }

  test(
    'v13 migration keeps original data and marks old time origin unknown',
    () async {
      await createVersion13();
      final db = await helper.database;
      expect(await db.getVersion(), 15);
      expect((await db.query('Reminders')).single, upgradedTask);
      final snapshot = root.listSync().whereType<Directory>().singleWhere(
        (item) => item.path.contains('schema-upgrade-v13-to-v15-'),
      );
      final inspector = BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: root,
      );
      expect(
        (await inspector.inspect(
          File('${snapshot.path}/snapshot.json'),
        )).version,
        13,
      );
      await helper.createMirrorBackup();
      expect(
        (await inspector.inspect(
          File('${root.path}/dont_forget_v3.mirror.db'),
        )).version,
        15,
      );
    },
  );

  for (final format in ['json', 'sqlite']) {
    test(
      'v13 $format restores with unknown origin without changing the source',
      () async {
        final original = await createVersion13();
        final source = format == 'sqlite'
            ? await original.copy('${root.path}/source-v13.db')
            : await File('${root.path}/source-v13.json').writeAsString(
                jsonEncode({
                  'version': 13,
                  'timestamp': '2026-10-27T00:00:00Z',
                  'settings': [AppSettings.defaults().toJson()],
                  'media_records': [],
                  'reminders': [oldTask],
                }),
              );
        final bytes = await source.readAsBytes();
        final inspector = BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        );
        final preview = await inspector.inspect(source);
        final target = DatabaseHelper.forTesting(
          '${root.path}/target',
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
          final row = (await (await target.database).query('Reminders')).single;
          expect(row, upgradedTask);
          expect(await source.readAsBytes(), bytes);
        } finally {
          await target.close(createBackup: false);
        }
      },
    );
  }

  test('a changed occurrence never retains an old AI time origin', () {
    final time = DateTime.utc(2030, 1, 1, 9);
    final task = Reminder(
      id: 'ai',
      taskTitle: 'AI',
      quadrantLevel: 2,
      triggerTime: time,
      timeOrigin: ReminderTimeOrigin.aiSuggested,
    );
    expect(
      Reminder.fromJson(task.toJson()).timeOrigin,
      ReminderTimeOrigin.aiSuggested,
    );
    expect(
      task.copyWith(taskTitle: 'edit').timeOrigin,
      ReminderTimeOrigin.aiSuggested,
    );
    expect(
      task
          .copyWith(triggerTime: time.add(const Duration(minutes: 5)))
          .timeOrigin,
      ReminderTimeOrigin.unknown,
    );
    expect(
      task
          .copyWith(
            triggerTime: time.add(const Duration(hours: 1)),
            timeOrigin: ReminderTimeOrigin.manual,
          )
          .timeOrigin,
      ReminderTimeOrigin.manual,
    );
    expect(Reminder.fromJson(oldTask).timeOrigin, ReminderTimeOrigin.unknown);
  });

  test('v15 backup rejects an unrecognized origin', () async {
    final db = await helper.database;
    final task = Reminder(
      id: 'bad-origin',
      taskTitle: 'Synthetic',
      quadrantLevel: 2,
      triggerTime: DateTime.utc(2030, 1, 1, 9),
    );
    await db.insert('Reminders', task.toJson());
    final data = {
      'version': 15,
      'timestamp': '2026-10-27T00:00:00Z',
      'settings': await db.query('Settings'),
      'media_records': await db.query('MediaRecords'),
      'reminders': [
        {
          ...(await db.query('Reminders')).single,
          'trigger_time_origin': 'untrusted',
        },
      ],
    };
    final source = await File(
      '${root.path}/invalid-origin.json',
    ).writeAsString(jsonEncode(data));
    await expectLater(
      BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: root,
      ).inspect(source),
      throwsA(
        isA<BackupInspectionException>().having(
          (error) => error.code,
          'code',
          BackupInspectionError.invalidData,
        ),
      ),
    );
  });
}
