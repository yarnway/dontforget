import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/recovery/storage_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late DatabaseHelper helper;
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('bootstrap-test-');
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
  });
  tearDown(() async {
    final lease = await helper.beginMaintenance();
    await lease.closeWithoutBackup();
    await lease.resume();
    await helper.close();
    await directory.delete(recursive: true);
  });

  test('valid business schema opens before any provider is needed', () async {
    await StorageBootstrap(helper).prepare();
    final rows = await helper.read(
      helper.captureGeneration(),
      (db) => db.query('Settings'),
    );
    expect(rows.single['id'], 'default');
  });

  for (final table in ['Settings', 'MediaRecords', 'Reminders']) {
    test(
      'v8 database missing $table cannot pass startup as empty data',
      () async {
        await helper.writeTransaction(
          helper.captureGeneration(),
          (db) => db.execute('DROP TABLE $table'),
        );
        await expectLater(StorageBootstrap(helper).prepare(), throwsStateError);
      },
    );
  }

  test(
    'malformed task row fails business validation despite SELECT 1 succeeding',
    () async {
      await helper.writeTransaction(
        helper.captureGeneration(),
        (db) => db.insert('Reminders', {
          ...Reminder(
            id: 'bad',
            taskTitle: 'Synthetic',
            quadrantLevel: 2,
          ).toJson(),
          'trigger_time': 'not-a-date',
        }),
      );
      expect(
        await helper.read(
          helper.captureGeneration(),
          (db) => db.rawQuery('SELECT 1'),
        ),
        isNotEmpty,
      );
      await expectLater(
        StorageBootstrap(helper).prepare(),
        throwsFormatException,
      );
    },
  );
}
