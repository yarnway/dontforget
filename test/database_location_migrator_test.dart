import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/data/database_location_migrator.dart';
import 'package:dont_forget/services/desktop_window_service.dart';
import 'package:dont_forget/services/storage_directory_lease.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory root, source, target;
  File file(Directory dir, String name) => File(p.join(dir.path, name));
  Future<String> hash(File f) async =>
      (await sha256.bind(f.openRead()).first).toString();
  Future<Map<String, String>> snapshot(Directory d) async => {
    await for (final entity in d.list(recursive: true, followLinks: false))
      if (entity is File &&
          p.basename(entity.path) != StorageDirectoryLease.lockName)
        p.relative(entity.path, from: d.path): await hash(entity),
  };
  Future<Database> openSource({bool readOnly = false}) =>
      databaseFactoryFfi.openDatabase(
        file(source, DatabaseLocationMigrator.databaseFileName).path,
        options: OpenDatabaseOptions(readOnly: readOnly, singleInstance: false),
      );
  Future<void> seed() async {
    final db = await openSource();
    try {
      await db.execute('CREATE TABLE payload(id TEXT PRIMARY KEY, value TEXT)');
      await db.insert('payload', {'id': 'keep', 'value': '旧版合成数据'});
    } finally {
      await db.close();
    }
  }

  Future<String> resolve() => DatabaseLocationMigrator.resolveAndMigrate(
    targetDir: target.path,
    candidateLegacyDirs: [source.path],
  );
  Future<void> expectRows(Directory d) async {
    final db = await databaseFactoryFfi.openDatabase(
      file(d, DatabaseLocationMigrator.databaseFileName).path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      expect(await db.query('payload'), [
        {'id': 'keep', 'value': '旧版合成数据'},
      ]);
      expect(
        (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
        'ok',
      );
    } finally {
      await db.close();
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dontforget-location-');
    root = Directory(await root.resolveSymbolicLinks());
    source = await Directory(p.join(root.path, 'legacy')).create();
    target = await Directory(p.join(root.path, 'current')).create();
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'missing legacy data selects target without creating a database',
    () async {
      expect(await resolve(), target.path);
      expect(await target.list().toList(), isEmpty);
    },
  );

  test(
    'real SQLite and operational files migrate without changing source bytes',
    () async {
      await seed();
      await file(
        source,
        'notification-epoch.json',
      ).writeAsString('{"epoch":"keep"}');
      await file(
        source,
        'device-window-preferences.json',
      ).writeAsString('{"version":1,"preferences":{"width":1280}}');
      await file(
        source,
        'device-capture-shortcut.json',
      ).writeAsString('{"version":1,"enabled":true}');
      final before = await snapshot(source);
      expect(await resolve(), target.path);
      expect(await snapshot(source), before);
      for (final e in before.entries) {
        expect(await hash(file(target, e.key)), e.value);
      }
      await expectRows(target);
      final receipt = jsonDecode(
        await file(target, DatabaseLocationMigrator.receiptName).readAsString(),
      );
      expect(receipt['files'], before);
      expect(
        await file(target, DatabaseLocationMigrator.pendingName).exists(),
        isFalse,
      );
    },
  );

  test('existing target database wins and is never replaced', () async {
    await seed();
    await file(
      target,
      DatabaseLocationMigrator.databaseFileName,
    ).writeAsString('existing target');
    final before = await snapshot(target);
    expect(await resolve(), target.path);
    expect(await snapshot(target), before);
  });

  test('unrelated files and old temporary copies are preserved', () async {
    await seed();
    await file(
      target,
      'dont_forget_v3.db.tmp',
    ).writeAsString('unknown old partial copy');
    await file(target, 'notes.tmp').writeAsString('unrelated');
    expect(await resolve(), target.path);
    expect(
      await file(target, 'dont_forget_v3.db.tmp').readAsString(),
      'unknown old partial copy',
    );
    expect(await file(target, 'notes.tmp').readAsString(), 'unrelated');
    await expectRows(target);
  });

  test('uncreatable target falls back to intact legacy data', () async {
    await seed();
    final blocker = await file(root, 'blocked').writeAsString('keep');
    expect(
      await DatabaseLocationMigrator.resolveAndMigrate(
        targetDir: p.join(blocker.path, 'db'),
        candidateLegacyDirs: [source.path],
      ),
      source.path,
    );
    await expectRows(source);
  });

  test('corrupt source is never published and retains its bytes', () async {
    await file(
      source,
      DatabaseLocationMigrator.databaseFileName,
    ).writeAsString('not SQLite');
    final before = await snapshot(source);
    expect(await resolve(), source.path);
    expect(await snapshot(source), before);
    expect(
      await file(target, DatabaseLocationMigrator.databaseFileName).exists(),
      isFalse,
    );
  });

  for (final name in [
    'dont_forget_v3.db-wal',
    'dont_forget_v3.db-shm',
    'dont_forget_v3.db-journal',
    'recovery.pending.json',
    'notification-rollback.intent.json',
  ]) {
    test('$name keeps recovery at its original location', () async {
      await seed();
      await file(source, name).writeAsString('preserve');
      final before = await snapshot(source);
      expect(await resolve(), source.path);
      expect(await snapshot(source), before);
      expect(
        await file(target, DatabaseLocationMigrator.databaseFileName).exists(),
        isFalse,
      );
    });
  }

  test(
    'closed WAL-mode database stays at source without creating WAL or SHM',
    () async {
      await seed();
      final db = await openSource();
      await db.rawQuery('PRAGMA journal_mode=WAL');
      await db.close();
      final before = await snapshot(source);
      expect(await resolve(), source.path);
      expect(await snapshot(source), before);
    },
  );

  test(
    'target recovery takes precedence while its database is moved away',
    () async {
      await seed();
      await file(
        target,
        'recovery.pending.json',
      ).writeAsString('preserve target recovery');
      final before = await snapshot(target);
      expect(await resolve(), target.path);
      expect(await snapshot(target), before);
    },
  );

  test(
    'legacy recovery with its database moved away does not create a blank target',
    () async {
      await file(
        source,
        'recovery.pending.json',
      ).writeAsString('preserve source recovery');
      expect(await resolve(), source.path);
      expect(
        await file(target, DatabaseLocationMigrator.databaseFileName).exists(),
        isFalse,
      );
    },
  );

  test(
    'legacy orphaned operational state does not silently select a blank target',
    () async {
      await file(
        source,
        'notification-epoch.json',
      ).writeAsString('preserve source identity');
      await expectLater(
        resolve(),
        throwsA(isA<DatabaseLocationMigrationException>()),
      );
      expect(
        await file(target, DatabaseLocationMigrator.databaseFileName).exists(),
        isFalse,
      );
    },
  );

  test(
    'unexplained target sidecars block initialization and preserve both stores',
    () async {
      await seed();
      await file(
        target,
        'notification-epoch.json',
      ).writeAsString('other dataset');
      final before = await snapshot(target);
      await expectLater(
        resolve(),
        throwsA(isA<DatabaseLocationMigrationException>()),
      );
      expect(await snapshot(target), before);
      await expectRows(source);
    },
  );

  test(
    'an active source directory lease is respected and can later be retried',
    () async {
      await seed();
      final lease = await StorageDirectoryLease.acquire(source);
      try {
        await expectLater(
          resolve(),
          throwsA(isA<DatabaseLocationMigrationException>()),
        );
      } finally {
        await lease.close();
      }
      expect(await resolve(), target.path);
    },
  );

  test(
    'an active target owner never sends the app to a second database',
    () async {
      await seed();
      final lease = await StorageDirectoryLease.acquire(target);
      try {
        await expectLater(resolve(), throwsA(isA<FileSystemException>()));
      } finally {
        await lease.close();
      }
      expect(await resolve(), target.path);
    },
  );

  test(
    'a live SQLite reader predating directory leases prevents copying',
    () async {
      await seed();
      final db = await openSource(readOnly: true);
      try {
        await db.execute('BEGIN');
        await db.query('payload');
        await expectLater(
          resolve(),
          throwsA(isA<DatabaseLocationMigrationException>()),
        );
        expect(
          await file(
            target,
            DatabaseLocationMigrator.databaseFileName,
          ).exists(),
          isFalse,
        );
        await db.execute('ROLLBACK');
      } finally {
        await db.close();
      }
      expect(await resolve(), target.path);
    },
  );

  test('concurrent resolution shares one migration result', () async {
    await seed();
    expect(await Future.wait([resolve(), resolve(), resolve()]), [
      target.path,
      target.path,
      target.path,
    ]);
    await expectRows(target);
    expect(
      (await target.list().toList()).where(
        (f) => p.basename(f.path).startsWith('.dontforget-location-stage-'),
      ),
      isEmpty,
    );
  });

  test(
    'same-size operational file changes during staging are rejected',
    () async {
      await seed();
      await file(source, 'notification-epoch.json').writeAsString('old');
      expect(
        await DatabaseLocationMigrator.migrateDirectory(
          sourceDir: source.path,
          destinationDir: target.path,
          checkpoint: (at) async {
            if (at == LocationMigrationCheckpoint.staged) {
              await file(
                source,
                'notification-epoch.json',
              ).writeAsString('new');
            }
          },
        ),
        isFalse,
      );
      expect(
        await file(source, 'notification-epoch.json').readAsString(),
        'new',
      );
      expect(
        await file(target, DatabaseLocationMigrator.databaseFileName).exists(),
        isFalse,
      );
    },
  );

  for (final point in [
    LocationMigrationCheckpoint.prepared,
    LocationMigrationCheckpoint.sidecarsPublished,
    LocationMigrationCheckpoint.databasePublished,
  ]) {
    test(
      'interrupted ${point.name} restarts from a complete durable decision',
      () async {
        await seed();
        await file(source, 'notification-epoch.json').writeAsString('original');
        final before = await snapshot(source);
        await expectLater(
          DatabaseLocationMigrator.migrateDirectory(
            sourceDir: source.path,
            destinationDir: target.path,
            checkpoint: (at) async {
              if (at == point) throw const LocationMigrationInterruption();
            },
          ),
          throwsA(isA<LocationMigrationInterruption>()),
        );
        expect(
          await file(target, DatabaseLocationMigrator.pendingName).exists(),
          isTrue,
        );
        expect(
          await file(
            target,
            DatabaseLocationMigrator.databaseFileName,
          ).exists(),
          point == LocationMigrationCheckpoint.databasePublished,
        );
        expect(await resolve(), target.path);
        await expectRows(target);
        expect(await snapshot(source), before);
        expect(
          await file(target, DatabaseLocationMigrator.pendingName).exists(),
          isFalse,
        );
      },
    );
  }

  test(
    'ordinary partial publication failure rolls back its own files',
    () async {
      await seed();
      await file(source, 'notification-epoch.json').writeAsString('original');
      expect(
        await DatabaseLocationMigrator.migrateDirectory(
          sourceDir: source.path,
          destinationDir: target.path,
          checkpoint: (at) async {
            if (at == LocationMigrationCheckpoint.sidecarsPublished) {
              throw const FileSystemException('synthetic disk failure');
            }
          },
        ),
        isFalse,
      );
      expect(
        await file(target, DatabaseLocationMigrator.pendingName).exists(),
        isFalse,
      );
      expect(await file(target, 'notification-epoch.json').exists(), isFalse);
      expect(await resolve(), target.path);
    },
  );

  test(
    'changed partial target leaves recovery gate and unrelated files intact',
    () async {
      await seed();
      await file(source, 'notification-epoch.json').writeAsString('original');
      await expectLater(
        DatabaseLocationMigrator.migrateDirectory(
          sourceDir: source.path,
          destinationDir: target.path,
          checkpoint: (at) async {
            if (at == LocationMigrationCheckpoint.sidecarsPublished) {
              throw const LocationMigrationInterruption();
            }
          },
        ),
        throwsA(isA<LocationMigrationInterruption>()),
      );
      await file(
        target,
        'notification-epoch.json',
      ).writeAsString('foreign data');
      final before = await snapshot(target);
      await expectLater(
        resolve(),
        throwsA(isA<DatabaseLocationMigrationException>()),
      );
      expect(await snapshot(target), before);
    },
  );

  for (final removed in [false, true]) {
    test(
      'precommit recovery preserves staging when source is ${removed ? "missing" : "changed"}',
      () async {
        await seed();
        await expectLater(
          DatabaseLocationMigrator.migrateDirectory(
            sourceDir: source.path,
            destinationDir: target.path,
            checkpoint: (at) async {
              if (at == LocationMigrationCheckpoint.prepared) {
                throw const LocationMigrationInterruption();
              }
            },
          ),
          throwsA(isA<LocationMigrationInterruption>()),
        );
        if (removed) {
          await file(
            source,
            DatabaseLocationMigrator.databaseFileName,
          ).delete();
        } else {
          final db = await openSource();
          try {
            await db.update('payload', {
              'value': 'source changed after interruption',
            });
          } finally {
            await db.close();
          }
        }
        final before = await snapshot(target);
        await expectLater(
          resolve(),
          throwsA(isA<DatabaseLocationMigrationException>()),
        );
        expect(await snapshot(target), before);
        expect(
          await file(
            target,
            DatabaseLocationMigrator.databaseFileName,
          ).exists(),
          isFalse,
        );
      },
    );
  }

  test(
    'pending intent paths cannot remove files outside the owned target',
    () async {
      await seed();
      final outside = await file(root, 'outside').writeAsString('preserve');
      await file(target, DatabaseLocationMigrator.pendingName).writeAsString(
        jsonEncode({
          'version': 1,
          'source': source.path,
          'stage': '.dontforget-location-stage-synthetic',
          'files': {
            DatabaseLocationMigrator.databaseFileName: '0' * 64,
            DatabaseLocationMigrator.receiptName: '0' * 64,
            '../outside': await hash(outside),
          },
        }),
      );
      final before = await snapshot(target);
      await expectLater(
        resolve(),
        throwsA(isA<DatabaseLocationMigrationException>()),
      );
      expect(await outside.readAsString(), 'preserve');
      expect(await snapshot(target), before);
    },
  );

  test(
    'a directory at the target database path is never replaced or followed',
    () async {
      await seed();
      final blocker = await Directory(
        file(target, DatabaseLocationMigrator.databaseFileName).path,
      ).create();
      await File(p.join(blocker.path, 'keep')).writeAsString('preserve');
      final before = await snapshot(target);
      await expectLater(
        resolve(),
        throwsA(isA<DatabaseLocationMigrationException>()),
      );
      expect(await snapshot(target), before);
    },
  );

  test(
    'an unclaimed staging copy never causes a blank or replacement database',
    () async {
      await seed();
      final orphan = await Directory(
        p.join(target.path, '.dontforget-location-stage-unclaimed'),
      ).create();
      await file(
        source,
        DatabaseLocationMigrator.databaseFileName,
      ).copy(p.join(orphan.path, DatabaseLocationMigrator.databaseFileName));
      final before = await snapshot(target);
      await expectLater(
        resolve(),
        throwsA(isA<DatabaseLocationMigrationException>()),
      );
      expect(await snapshot(target), before);
      expect(
        await file(target, DatabaseLocationMigrator.databaseFileName).exists(),
        isFalse,
      );
    },
  );

  test(
    'malformed pending intent never initializes an empty target database',
    () async {
      await seed();
      await file(
        target,
        DatabaseLocationMigrator.pendingName,
      ).writeAsString('{broken');
      final before = await snapshot(target);
      await expectLater(resolve(), throwsFormatException);
      expect(await snapshot(target), before);
    },
  );

  test(
    'incremental journal, stable native IDs and local geometry move together',
    () async {
      final helper = DatabaseHelper.forTesting(
        source.path,
        databaseFactoryFfi,
        migrateNotificationJournal: true,
      );
      await helper.database;
      final epoch = await helper.readNotificationEpoch();
      await helper.withNotificationJournal((j) => j.reset(epoch));
      final reserved = await helper.withNotificationJournal(
        (j) => j.begin(
          epoch,
          'keep',
          action: 'schedule',
          attemptedAt: DateTime.utc(2026),
        ),
      );
      await DesktopWindowService.save(
        helper,
        const WindowPreferences(width: 1360, x: -200, y: 50),
      );
      await helper.close(createBackup: false);
      final before = await snapshot(source);
      expect(await resolve(), target.path);
      final reopened = DatabaseHelper.forTesting(
        target.path,
        databaseFactoryFfi,
        migrateNotificationJournal: true,
      );
      try {
        expect(await reopened.readNotificationEpoch(), epoch);
        final journal = (await reopened.withNotificationJournal(
          (j) => j.read(),
        ))!;
        expect(journal.entries['keep']!.nativeId, reserved.nativeId);
        expect(journal.entries['keep']!.status, 'pending');
        expect((await DesktopWindowService.load(reopened)).width, 1360);
        expect(await snapshot(source), before);
      } finally {
        await reopened.close(createBackup: false);
      }
    },
  );

  test(
    'historical v7 fields survive location migration then current schema upgrade',
    () async {
      final db = await openSource();
      for (final sql in (await File(
        'test/fixtures/schema_v7.sql',
      ).readAsString()).split(';')) {
        if (sql.trim().isNotEmpty) await db.execute(sql);
      }
      await db.setVersion(7);
      await db.insert('Settings', {
        'id': 'default',
        'api_key': '',
        'language': 'ja',
        'model_name': 'synthetic-model',
      });
      await db.insert('Reminders', {
        'id': 'legacy',
        'task_title': '旧库迁移验收',
        'task_summary': '保留原字段',
        'quadrant_level': 2,
        'is_completed': 0,
        'trigger_time': '2099-01-01T12:00:00',
        'linked_task_ids': '[]',
      });
      final beforeRows = await db.query('Reminders');
      await db.close();
      final before = await snapshot(source);
      expect(await resolve(), target.path);
      final helper = DatabaseHelper.forTesting(target.path, databaseFactoryFfi);
      try {
        final upgraded = await helper.database;
        expect(await upgraded.getVersion(), DatabaseHelper.schemaVersion);
        final after = (await upgraded.query('Reminders')).single;
        for (final e in beforeRows.single.entries) {
          expect(after[e.key], e.value);
        }
        expect((await upgraded.query('Settings')).single['language'], 'ja');
        expect(await snapshot(source), before);
        expect(
          (await upgraded.rawQuery(
            'PRAGMA integrity_check',
          )).single.values.single,
          'ok',
        );
      } finally {
        await helper.close(createBackup: false);
      }
    },
  );

  Future<void> aliasDirectory(Directory link, Directory actual) async {
    if (Platform.isWindows) {
      final result = await Process.run('cmd.exe', [
        '/d',
        '/c',
        'mklink',
        '/J',
        link.path,
        actual.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
    } else {
      await Link(link.path).create(actual.path);
    }
  }

  test(
    'a redirected parent directory is canonicalized before migration',
    () async {
      await seed();
      final actual = await Directory(
        p.join(root.path, 'redirected-support'),
      ).create();
      final alias = Directory(p.join(root.path, 'support-alias'));
      await aliasDirectory(alias, actual);
      try {
        final destination = p.join(alias.path, 'databases');
        expect(
          await DatabaseLocationMigrator.resolveAndMigrate(
            targetDir: destination,
            candidateLegacyDirs: [source.path],
          ),
          destination,
        );
        await expectRows(Directory(p.join(actual.path, 'databases')));
      } finally {
        await Link(alias.path).delete();
      }
    },
  );

  test(
    'canonical aliases cannot hide source-target directory overlap',
    () async {
      await seed();
      final alias = Directory(p.join(root.path, 'source-alias'));
      await aliasDirectory(alias, source);
      try {
        final before = await snapshot(source);
        await expectLater(
          DatabaseLocationMigrator.migrateDirectory(
            sourceDir: source.path,
            destinationDir: p.join(alias.path, 'nested-target'),
          ),
          throwsA(isA<DatabaseLocationMigrationException>()),
        );
        expect(await snapshot(source), before);
      } finally {
        await Link(alias.path).delete();
      }
    },
  );

  test('candidate enumeration stays Windows-specific', () {
    expect(
      DatabaseLocationMigrator.getLegacyCandidates(),
      Platform.isWindows ? isNotEmpty : isEmpty,
    );
  });
}
