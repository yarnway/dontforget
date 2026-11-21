import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/recovery/storage_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  group('Performance & bootstrap optimizations', () {
    late Directory directory;
    late DatabaseHelper helper;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('perf-opt-test-');
      directory = Directory(await directory.resolveSymbolicLinks());
      helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    });

    tearDown(() async {
      await helper.close(createBackup: false);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test(
      'StorageBootstrap caches one-shot snapshot per slot and invalidates on write',
      () async {
        final gen0 = helper.captureGeneration();
        await helper.writeTransaction(gen0, (db) async {
          await db.insert(
            'MediaRecords',
            MediaRecord(
              id: 'm1',
              type: 'text',
              contentOrPath: 'hello',
              createdAt: DateTime.utc(2026, 11, 21),
            ).toJson(),
          );
          await db.insert(
            'Reminders',
            Reminder(
              id: 'r1',
              taskTitle: 'Cached Task',
              quadrantLevel: 2,
            ).toJson(),
          );
        });

        await StorageBootstrap(helper).prepare();

        final gen = helper.captureGeneration();
        final reminders = helper.takeBootstrapReminders(gen);
        expect(reminders, isNotNull);
        expect(reminders!.map((r) => r.id), ['r1']);
        // One-shot: second take returns null so subsequent reloads read SQLite.
        expect(helper.takeBootstrapReminders(gen), isNull);

        final media = helper.takeBootstrapMediaRecords(gen);
        expect(media, isNotNull);
        expect(media!.map((m) => m.id), ['m1']);
        expect(helper.takeBootstrapMediaRecords(gen), isNull);

        // Any writeTransaction invalidates remaining unused bootstrap slots.
        await helper.writeTransaction(gen, (db) async {
          await db.update(
            'Reminders',
            {'task_title': 'Mutated'},
            where: 'id = ?',
            whereArgs: ['r1'],
          );
        });
        expect(helper.takeBootstrapSettingsRow(gen), isNull);
        expect(helper.takeBootstrapDraftsRow(gen), isNull);
      },
    );

    test(
      'SQLite session PRAGMAs apply without altering rollback journal header or schema',
      () async {
        await StorageBootstrap(helper).prepare();
        final db = await helper.database;
        final cacheSize =
            (await db.rawQuery('PRAGMA cache_size')).single.values.single;
        final tempStore =
            (await db.rawQuery('PRAGMA temp_store')).single.values.single;
        final journalMode = (await db.rawQuery(
          'PRAGMA journal_mode',
        )).single.values.single.toString().toLowerCase();
        final indexes = (await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name",
        )).map((r) => r['name']).toList();
        expect(cacheSize, -8000);
        expect(tempStore, 2); // MEMORY
        expect(journalMode, isNot('wal'));
        expect(indexes, [
          'sqlite_autoindex_MediaRecords_1',
          'sqlite_autoindex_Reminders_1',
        ]);
        // Close cleanly and verify rollback journal header bytes [18..19] == [1, 1].
        await helper.close(createBackup: false);
        final dbFile = File('${directory.path}/dont_forget_v3.db');
        final header = await dbFile.openRead(0, 20).first;
        expect(header[18], 1);
        expect(header[19], 1);
        expect(DatabaseRecovery(helper), isNotNull);
      },
    );

    test(
      'WorkspaceDrafts.putDebounced coalesces rapid writes and flushes on read/flushed',
      () async {
        await StorageBootstrap(helper).prepare();
        final drafts = WorkspaceDrafts(helper);
        await drafts.ready;

        for (var i = 0; i < 10; i++) {
          drafts.putDebounced('capture', {'text': 'typing-$i'});
        }
        drafts.putDebounced('goal', 'Ship v1.8.21');

        // Reading or awaiting flushed commits all buffered keys immediately.
        final persistedCapture = await drafts.readPersistedKey('capture');
        expect(persistedCapture, {'text': 'typing-9'});
        expect(await drafts.readPersistedKey('goal'), 'Ship v1.8.21');

        // Clearing via immediate put cancels any pending debounced write.
        drafts.putDebounced('capture', {'text': 'stale'});
        await drafts.put('capture', null);
        await drafts.flushed;
        expect(await drafts.readPersistedKey('capture'), isNull);
        drafts.dispose();
      },
    );

    test('Reminder.occurrenceIdentity returns stable memoized identity', () {
      final r = Reminder(
        id: 'task-42',
        taskTitle: 'Check memoization',
        quadrantLevel: 1,
        triggerTime: DateTime.utc(2026, 11, 21, 12, 0),
        noticeRevision: 3,
      );
      final first = r.occurrenceIdentity;
      final second = r.occurrenceIdentity;
      expect(identical(first, second), isTrue);
      expect(first, contains('task-42'));
      expect(first, contains(',3]'));
    });
  });
}
