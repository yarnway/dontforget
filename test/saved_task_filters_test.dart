import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/saved_task_filter.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/saved_task_filters_provider.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const filter = SavedTaskFilter(
  id: 'sample',
  name: 'Work',
  view: 'pause',
  query: 'project',
);
Matcher failure(SavedTaskFilterFailure reason) =>
    isA<SavedTaskFilterException>().having(
      (error) => error.reason,
      'reason',
      reason,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('saved filter format', () {
    test('legacy absence and immutable round trip', () {
      expect(SavedTaskFilter.decode(null), isEmpty);
      final values = SavedTaskFilter.decode(SavedTaskFilter.encode([filter]));
      expect(values.single.sameAs(filter), isTrue);
      expect(() => values.clear(), throwsUnsupportedError);
    });
    test(
      'malformed values, unknown fields and duplicate identities fail closed',
      () {
        for (final raw in [
          1,
          {},
          {'version': 2, 'items': []},
          {'version': 1.0, 'items': []},
          {
            'version': 1,
            'items': [filter.toJson(), filter.toJson()],
          },
          {
            'version': 1,
            'items': [
              filter.toJson(),
              {...filter.toJson(), 'id': 'other', 'name': 'work'},
            ],
          },
          {
            'version': 1,
            'items': [
              {...filter.toJson(), 'view': 'unknown'},
            ],
          },
          {
            'version': 1,
            'items': [
              {...filter.toJson(), 'id': '../other'},
            ],
          },
          {
            'version': 1,
            'items': [
              {...filter.toJson(), 'name': '  '},
            ],
          },
          {
            'version': 1,
            'items': [
              {...filter.toJson(), 'name': 'line\nbreak'},
            ],
          },
          {
            'version': 1,
            'items': [
              {...filter.toJson(), 'query': 'a' * 241},
            ],
          },
          {
            'version': 1,
            'items': [
              {...filter.toJson(), 'unexpected': true},
            ],
          },
          {
            'version': 1,
            'items': [
              for (var i = 0; i < 13; i++)
                {...filter.toJson(), 'id': 'id-$i', 'name': 'Name $i'},
            ],
          },
        ]) {
          expect(() => SavedTaskFilter.decode(raw), throwsFormatException);
        }
      },
    );
  });

  group('durable named filters', () {
    late Directory directory;
    late DatabaseHelper database;
    late ProviderContainer container;
    late SavedTaskFilterStore store;
    Future<void> open() async {
      database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
      container = ProviderContainer(
        overrides: [databaseHelperProvider.overrideWithValue(database)],
      );
      await container.read(settingsProvider.notifier).ready;
      store = container.read(savedTaskFilterStoreProvider);
      await store.load();
    }

    Future<String?> rawDrafts() async =>
        (await (await database.database).query(
              'Settings',
            )).single['workspace_drafts_json']
            as String?;
    setUp(() async {
      sqfliteFfiInit();
      directory = await Directory.systemTemp.createTemp(
        'dontforget-saved-filters-',
      );
      await open();
    });
    tearDown(() async {
      await container.read(workspaceDraftsProvider.notifier).flushed;
      container.dispose();
      await database.close(createBackup: false);
      await directory.delete(recursive: true);
    });
    test(
      'parallel saves preserve unrelated drafts and survive database reopen',
      () async {
        await Future.wait([
          store.save(' Work ', 'manage', ' project '),
          store.save('History', 'history', 'other'),
          container.read(workspaceDraftsProvider.notifier).put(
            'medicationDraft',
            {'fixture': true},
          ),
        ]);
        final ids = (await store.load()).map((item) => item.id).toList();
        container.dispose();
        await database.close(createBackup: false);
        await open();
        final items = await store.load();
        expect(items.map((item) => item.id), ids);
        expect(items.map((item) => item.name), ['Work', 'History']);
        expect(items.first.matches('manage', ' project '), isTrue);
        expect(container.read(workspaceDraftsProvider)['medicationDraft'], {
          'fixture': true,
        });
        expect(
          await (await database.database).getVersion(),
          DatabaseHelper.schemaVersion,
        );
      },
    );
    test(
      'duplicate names and limit do not mutate prior state; queue recovers',
      () async {
        await store.save('Work', 'manage', '');
        final before = await rawDrafts();
        await expectLater(
          store.save('WORK', 'archive', ''),
          throwsA(failure(SavedTaskFilterFailure.duplicateName)),
        );
        expect(await rawDrafts(), before);
        for (var i = 1; i < 12; i++) {
          await store.save('Filter $i', 'manage', '');
        }
        await expectLater(
          store.save('Overflow', 'manage', ''),
          throwsA(failure(SavedTaskFilterFailure.limitReached)),
        );
        expect(await store.load(), hasLength(12));
      },
    );
    test(
      'rename checks stale snapshot; removal and repeated undo preserve order',
      () async {
        await store.save('First', 'pause', '');
        await store.save('Second', 'history', '');
        final first = (await store.load()).first;
        await store.rename(first, 'Renamed');
        await expectLater(
          store.remove(first),
          throwsA(failure(SavedTaskFilterFailure.changed)),
        );
        final renamed = (await store.load()).first;
        final index = await store.remove(renamed);
        await store.restore(renamed, index);
        await store.restore(renamed, index);
        expect((await store.load()).map((item) => item.name), [
          'Renamed',
          'Second',
        ]);
      },
    );
    test('undo refuses to overwrite a conflicting newly saved name', () async {
      await store.save('Work', 'pause', '');
      final item = (await store.load()).single;
      final index = await store.remove(item);
      await store.save('Work', 'history', '');
      await expectLater(
        store.restore(item, index),
        throwsA(failure(SavedTaskFilterFailure.duplicateName)),
      );
      expect((await store.load()).single.view, 'history');
    });
    test(
      'SQLite write failure leaves database and published state unchanged',
      () async {
        await store.save('Work', 'manage', '');
        final before = await rawDrafts();
        final db = await database.database;
        await db.execute(
          "CREATE TRIGGER fail_filters BEFORE UPDATE ON Settings BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END",
        );
        await expectLater(
          store.save('Other', 'history', ''),
          throwsA(isA<DatabaseException>()),
        );
        expect(await rawDrafts(), before);
        expect((await store.load()).map((item) => item.name), ['Work']);
        await db.execute('DROP TRIGGER fail_filters');
        await store.save('Other', 'history', '');
        expect(await store.load(), hasLength(2));
      },
    );
    test(
      'corrupt namespace blocks overwrite and preserves unrelated draft bytes',
      () async {
        await container.read(workspaceDraftsProvider.notifier).put(
          SavedTaskFilter.storageKey,
          {'version': 99, 'items': []},
        );
        final before = await rawDrafts();
        await expectLater(store.load(), throwsFormatException);
        await expectLater(
          store.save('New', 'manage', ''),
          throwsFormatException,
        );
        expect(await rawDrafts(), before);
      },
    );
    test(
      'recovery generation invalidates old save, rename and undo callbacks',
      () async {
        await store.save('Work', 'pause', '');
        final item = (await store.load()).single;
        final before = await rawDrafts();
        final lease = await database.beginMaintenance();
        await lease.resume();
        for (final action in <Future<void> Function()>[
          () => store.save('Old', 'manage', ''),
          () => store.rename(item, 'Old'),
          () => store.restore(item, 0),
        ]) {
          await expectLater(action(), throwsA(isA<DatabaseAccessException>()));
        }
        expect(await rawDrafts(), before);
      },
    );
    test(
      'current JSON and SQLite backups accept filters; malformed namespace rejects',
      () async {
        await store.save('Work', 'manage', 'project');
        await database.createMirrorBackup();
        for (final name in ['ha_snapshot.json', 'dont_forget_v3.mirror.db']) {
          final preview = await BackupInspector(
            databaseFactoryFfi,
          ).inspect(File('${directory.path}/$name'));
          expect(preview.version, DatabaseHelper.schemaVersion);
        }
        final source = File('${directory.path}/ha_snapshot.json');
        final raw = jsonDecode(await source.readAsString());
        raw['settings'][0]['workspace_drafts_json'] = jsonEncode({
          SavedTaskFilter.storageKey: {'version': 2, 'items': []},
        });
        final bad = await File(
          '${directory.path}/invalid-filters.json',
        ).writeAsString(jsonEncode(raw));
        await expectLater(
          BackupInspector(databaseFactoryFfi).inspect(bad),
          throwsA(
            isA<BackupInspectionException>().having(
              (error) => error.code,
              'code',
              BackupInspectionError.invalidData,
            ),
          ),
        );
        expect((await store.load()).single.name, 'Work');
      },
    );
    for (final format in ['json', 'sqlite']) {
      test(
        '$format recovery restores saved filters and unrelated drafts exactly',
        () async {
          await store.save('Work', 'pause', 'project');
          await container.read(workspaceDraftsProvider.notifier).put(
            'departureDraft',
            {'synthetic': true},
          );
          final before = await rawDrafts();
          await database.createMirrorBackup();
          final original = format == 'json'
              ? 'ha_snapshot.json'
              : 'dont_forget_v3.mirror.db';
          final source = await File(
            '${directory.path}/$original',
          ).copy('${directory.path}/source-$format');
          final inspector = BackupInspector(databaseFactoryFfi);
          final preview = await inspector.inspect(source);
          await store.save('Later', 'history', '');
          await DatabaseRecovery(
            database,
            inspector: inspector,
            notifications: NotificationService.forTesting(
              FlutterLocalNotificationsPlugin(),
              usesNativeNotifications: false,
            ),
          ).restore(source, expectedDigest: preview.digest);
          expect(await rawDrafts(), before);
          await expectLater(
            store.load(),
            throwsA(isA<DatabaseAccessException>()),
          );
          container.dispose();
          await database.close(createBackup: false);
          await open();
          expect((await store.load()).single.name, 'Work');
          expect(container.read(workspaceDraftsProvider)['departureDraft'], {
            'synthetic': true,
          });
        },
      );
    }
  });
}
