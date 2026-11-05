import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/desktop_window_service.dart';
import 'package:dont_forget/services/device_window_preferences_store.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Exercise Android's real rollback-journal mode using SQLite, not a mocked
// sidecar deletion. Read-only inspectors retain their normal strict policy.
class _TruncateFactory implements DatabaseFactory {
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) async {
    final db = await databaseFactoryFfi.openDatabase(path, options: options);
    if (options?.readOnly != true) {
      await db.rawQuery('PRAGMA journal_mode=TRUNCATE');
    }
    return db;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RebuildProbe extends NotificationService {
  _RebuildProbe(this.failures, {this.beforeRebuild})
    : super.forTesting(
        FlutterLocalNotificationsPlugin(),
        usesNativeNotifications: false,
      );
  int failures;
  final Future<void> Function(List<String>)? beforeRebuild;
  final attempts = <List<String>>[];
  bool paused = false;
  @override
  bool get isPausedForMaintenance => paused;
  @override
  Future<void> pauseForMaintenance() async {
    paused = true;
  }

  @override
  Future<void> resumeFromReminders(Iterable<Reminder> reminders) async {
    attempts.add(reminders.map((r) => r.id).toList());
    await beforeRebuild?.call(attempts.last);
    if (failures-- > 0) {
      throw StateError('synthetic notification rebuild failure');
    }
    paused = false;
  }
}

void main() {
  late Directory root;
  late DatabaseHelper live;
  late BackupInspector inspector;
  late File sqliteSource;
  late File jsonSource;
  late String mirrorHash;
  NotificationService notifications() => NotificationService.forTesting(
    FlutterLocalNotificationsPlugin(),
    usesNativeNotifications: false,
  );
  late String snapshotHash;

  Future<String> hash(File file) async =>
      sha256.convert(await file.readAsBytes()).toString();
  String livePath(String name) => p.join(root.path, 'live', name);
  Future<List<String>> ids() => live.read(
    live.captureGeneration(),
    (db) async => (await db.query(
      'Reminders',
    )).map((row) => row['id'] as String).toList(),
  );
  Future<void> backupsUnchanged() async {
    expect(await hash(File(livePath('dont_forget_v3.mirror.db'))), mirrorHash);
    expect(await hash(File(livePath('ha_snapshot.json'))), snapshotHash);
  }

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('recovery-engine-test-');
    live = DatabaseHelper.forTesting(
      p.join(root.path, 'live'),
      databaseFactoryFfi,
    );
    inspector = BackupInspector(databaseFactoryFfi, temporaryDirectory: root);
    await live.writeTransaction(live.captureGeneration(), (db) async {
      await db.insert(
        'Reminders',
        Reminder(
          id: 'old',
          taskTitle: 'Original task',
          quadrantLevel: 2,
        ).toJson(),
      );
    });
    await live.createMirrorBackup();
    mirrorHash = await hash(File(livePath('dont_forget_v3.mirror.db')));
    snapshotHash = await hash(File(livePath('ha_snapshot.json')));
    final source = DatabaseHelper.forTesting(
      p.join(root.path, 'source'),
      databaseFactoryFfi,
    );
    await source.writeTransaction(source.captureGeneration(), (db) async {
      await db.insert(
        'Reminders',
        Reminder(
          id: 'new',
          taskTitle: 'Recovered task',
          quadrantLevel: 2,
        ).toJson(),
      );
      await db.update('Settings', {
        'api_key': 'synthetic-key',
        'workspace_drafts_json': jsonEncode({
          'capture': {'text': 'imported unsent draft'},
          'windowPreferences': {'width': 1700, 'height': 950},
        }),
      });
    });
    await source.close();
    sqliteSource = File(
      p.join(root.path, 'source', 'dont_forget_v3.mirror.db'),
    );
    jsonSource = File(p.join(root.path, 'source', 'ha_snapshot.json'));
  });

  tearDown(() async {
    await live.close();
    await root.delete(recursive: true);
  });

  for (final format in ['sqlite', 'json']) {
    test(
      '$format restores exact preview content and retains independent rollback',
      () async {
        final source = format == 'sqlite' ? sqliteSource : jsonSource;
        final before = await hash(source);
        final oldGeneration = live.captureGeneration();
        final result = await DatabaseRecovery(
          live,
          notifications: notifications(),
          inspector: inspector,
        ).restore(source, expectedDigest: before);
        expect(await ids(), ['new']);
        expect(live.isCurrent(oldGeneration), isFalse);
        expect(await hash(source), before);
        expect(
          await File(p.join(result.rollbackDirectory, 'rollback.db')).exists(),
          isTrue,
        );
        expect(
          await File(
            p.join(result.rollbackDirectory, 'completed.json'),
          ).exists(),
          isTrue,
        );
        expect(
          await File(livePath(DatabaseRecovery.journalName)).exists(),
          isFalse,
        );
        await backupsUnchanged();
        final rollback = await databaseFactoryFfi.openDatabase(
          p.join(result.rollbackDirectory, 'rollback.db'),
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
        );
        try {
          expect((await rollback.query('Reminders')).single['id'], 'old');
        } finally {
          await rollback.close();
        }
      },
    );
  }

  for (final format in ['sqlite', 'json']) {
    test(
      '$format business restore retains device geometry and imported drafts',
      () async {
        const local = WindowPreferences(
          width: 1440,
          height: 900,
          x: -700,
          y: 100,
        );
        await DesktopWindowService.save(live, local);
        final deviceFile = File(
          livePath(DeviceWindowPreferencesStore.fileName),
        );
        final before = await hash(deviceFile);
        final source = format == 'sqlite' ? sqliteSource : jsonSource;
        await DatabaseRecovery(
          live,
          notifications: notifications(),
          inspector: inspector,
        ).restore(source, expectedDigest: await hash(source));
        expect(await ids(), ['new']);
        expect(await hash(deviceFile), before);
        expect(await DesktopWindowService.load(live), local);
        final settings = await live.read(
          live.captureGeneration(),
          (db) => db.query('Settings'),
        );
        final drafts = jsonDecode(
          settings.single['workspace_drafts_json'] as String,
        );
        expect(drafts['capture']['text'], 'imported unsent draft');
        expect(drafts['windowPreferences']['width'], 1700);
        await backupsUnchanged();
      },
    );
  }

  test(
    'changed source identity is rejected without taking maintenance',
    () async {
      final generation = live.captureGeneration();
      await expectLater(
        DatabaseRecovery(
          live,
          notifications: notifications(),
          inspector: inspector,
        ).restore(jsonSource, expectedDigest: '0' * 64),
        throwsA(isA<BackupInspectionException>()),
      );
      expect(live.isCurrent(generation), isTrue);
      expect(await ids(), ['old']);
      await backupsUnchanged();
    },
  );

  for (final point in [
    RecoveryCheckpoint.candidateReady,
    RecoveryCheckpoint.rollbackReady,
    RecoveryCheckpoint.journalPrepared,
    RecoveryCheckpoint.originalMoved,
    RecoveryCheckpoint.candidateInstalled,
    RecoveryCheckpoint.candidateOpened,
  ]) {
    test(
      'failure at ${point.name} preserves or rolls back the original',
      () async {
        final sourceHash = await hash(sqliteSource);
        final engine = DatabaseRecovery(
          live,
          notifications: notifications(),
          inspector: inspector,
          checkpoint: (at) async {
            if (at == point) {
              throw const FileSystemException('injected failure');
            }
          },
        );
        await expectLater(
          engine.restore(sqliteSource, expectedDigest: sourceHash),
          throwsA(
            isA<DatabaseRecoveryException>().having(
              (e) => e.rolledBack,
              'rolled back',
              isTrue,
            ),
          ),
        );
        expect(await ids(), ['old']);
        expect(await hash(sqliteSource), sourceHash);
        expect(
          await File(livePath(DatabaseRecovery.journalName)).exists(),
          isFalse,
        );
        await backupsUnchanged();
      },
    );
  }

  for (final point in [
    RecoveryCheckpoint.journalPrepared,
    RecoveryCheckpoint.originalMoved,
    RecoveryCheckpoint.candidateInstalled,
    RecoveryCheckpoint.candidateOpened,
    RecoveryCheckpoint.committed,
  ]) {
    test('restart resolves ${point.name} from durable decision', () async {
      final engine = DatabaseRecovery(
        live,
        notifications: notifications(),
        inspector: inspector,
        checkpoint: (at) async {
          if (at == point) throw const RecoveryInterruption();
        },
      );
      await expectLater(
        engine.restore(sqliteSource, expectedDigest: await hash(sqliteSource)),
        throwsA(isA<RecoveryInterruption>()),
      );
      expect(
        () => live.captureGeneration(),
        throwsA(isA<DatabaseAccessException>()),
      );
      await live
          .close(); // Only releases the failed instance, never creates a backup.
      await backupsUnchanged();
      live = DatabaseHelper.forTesting(
        p.join(root.path, 'live'),
        databaseFactoryFfi,
      );
      await expectLater(
        live.read(live.captureGeneration(), (db) => db.query('Reminders')),
        throwsA(isA<DatabaseRecoveryRequiredException>()),
      );
      await DatabaseRecovery(
        live,
        notifications: notifications(),
        inspector: inspector,
      ).recoverInterrupted();
      expect(await ids(), [
        point == RecoveryCheckpoint.committed ? 'new' : 'old',
      ]);
      expect(
        await File(livePath(DatabaseRecovery.journalName)).exists(),
        isFalse,
      );
      await backupsUnchanged();
    });
  }

  for (final point in [
    RecoveryCheckpoint.rollbackStarted,
    RecoveryCheckpoint.rollbackInstalled,
  ]) {
    test('interrupted ${point.name} can be retried on restart', () async {
      final engine = DatabaseRecovery(
        live,
        notifications: notifications(),
        inspector: inspector,
        checkpoint: (at) async {
          if (at == RecoveryCheckpoint.candidateOpened) {
            throw StateError('rollback requested');
          }
          if (at == point) throw const RecoveryInterruption();
        },
      );
      await expectLater(
        engine.restore(jsonSource, expectedDigest: await hash(jsonSource)),
        throwsA(
          isA<DatabaseRecoveryException>().having(
            (e) => e.rolledBack,
            'incomplete',
            isFalse,
          ),
        ),
      );
      await live.close();
      live = DatabaseHelper.forTesting(
        p.join(root.path, 'live'),
        databaseFactoryFfi,
      );
      await DatabaseRecovery(
        live,
        notifications: notifications(),
        inspector: inspector,
      ).recoverInterrupted();
      expect(await ids(), ['old']);
      await backupsUnchanged();
    });
  }

  test(
    'unknown live-file identity blocks restart and preserves recovery evidence',
    () async {
      final engine = DatabaseRecovery(
        live,
        notifications: notifications(),
        inspector: inspector,
        checkpoint: (at) async {
          if (at == RecoveryCheckpoint.candidateInstalled) {
            throw const RecoveryInterruption();
          }
        },
      );
      await expectLater(
        engine.restore(sqliteSource, expectedDigest: await hash(sqliteSource)),
        throwsA(isA<RecoveryInterruption>()),
      );
      await live.close();
      final current = File(livePath('dont_forget_v3.db'));
      await current.writeAsString('unrecognized file', flush: true);
      final unknownHash = await hash(current);
      live = DatabaseHelper.forTesting(
        p.join(root.path, 'live'),
        databaseFactoryFfi,
      );
      await expectLater(
        DatabaseRecovery(
          live,
          notifications: notifications(),
          inspector: inspector,
        ).recoverInterrupted(),
        throwsA(isA<DatabaseRecoveryException>()),
      );
      expect(await hash(current), unknownHash);
      expect(
        await File(livePath(DatabaseRecovery.journalName)).exists(),
        isTrue,
      );
      expect(
        () => live.captureGeneration(),
        throwsA(isA<DatabaseAccessException>()),
      );
      await backupsUnchanged();
    },
  );

  test(
    'malformed journal blocks startup without opening or rewriting database',
    () async {
      await live.close();
      final current = File(livePath('dont_forget_v3.db'));
      final before = await hash(current);
      await File(
        livePath(DatabaseRecovery.journalName),
      ).writeAsString(jsonEncode({'operationId': '../escape'}));
      live = DatabaseHelper.forTesting(
        p.join(root.path, 'live'),
        databaseFactoryFfi,
      );
      await expectLater(
        DatabaseRecovery(
          live,
          notifications: notifications(),
          inspector: inspector,
        ).recoverInterrupted(),
        throwsA(isA<DatabaseRecoveryException>()),
      );
      expect(await hash(current), before);
      expect(
        () => live.captureGeneration(),
        throwsA(isA<DatabaseAccessException>()),
      );
    },
  );

  test(
    'startup without journal acquires ownership without opening a database',
    () async {
      await live.close();
      live = DatabaseHelper.forTesting(
        p.join(root.path, 'empty'),
        databaseFactoryFfi,
      );
      await DatabaseRecovery(
        live,
        notifications: notifications(),
        inspector: inspector,
      ).recoverInterrupted();
      expect(
        await File(p.join(root.path, 'empty', 'dont_forget_v3.db')).exists(),
        isFalse,
      );
    },
  );

  test(
    'candidate notification failure retains committed data and retries that decision',
    () async {
      final probe = _RebuildProbe(1);
      await expectLater(
        DatabaseRecovery(
          live,
          inspector: inspector,
          notifications: probe,
        ).restore(sqliteSource, expectedDigest: await hash(sqliteSource)),
        throwsA(
          isA<DatabaseRecoveryException>().having(
            (e) => e.rolledBack,
            'rolled back',
            isFalse,
          ),
        ),
      );
      expect(probe.attempts, [
        ['new'],
      ]);
      expect(probe.isPausedForMaintenance, isTrue);
      expect(
        () => live.captureGeneration(),
        throwsA(isA<DatabaseAccessException>()),
      );
      final journal =
          jsonDecode(
                await File(
                  livePath(DatabaseRecovery.journalName),
                ).readAsString(),
              )
              as Map;
      expect(journal['state'], 'committed');
      await live.close();
      await backupsUnchanged();
      live = DatabaseHelper.forTesting(
        p.join(root.path, 'live'),
        databaseFactoryFfi,
      );
      final restarted = _RebuildProbe(0);
      await DatabaseRecovery(
        live,
        inspector: inspector,
        notifications: restarted,
      ).recoverInterrupted();
      expect(restarted.attempts, [
        ['new'],
      ]);
      expect(await ids(), ['new']);
    },
  );

  test(
    'failed rollback notification rebuild keeps gate closed for restart retry',
    () async {
      final probe = _RebuildProbe(1);
      await expectLater(
        DatabaseRecovery(
          live,
          inspector: inspector,
          notifications: probe,
          checkpoint: (at) async {
            if (at == RecoveryCheckpoint.candidateOpened) {
              throw StateError('failure before data decision');
            }
          },
        ).restore(sqliteSource, expectedDigest: await hash(sqliteSource)),
        throwsA(
          isA<DatabaseRecoveryException>().having(
            (e) => e.rolledBack,
            'rolled back',
            isFalse,
          ),
        ),
      );
      expect(probe.isPausedForMaintenance, isTrue);
      expect(probe.attempts, [
        ['old'],
      ]);
      expect(
        () => live.captureGeneration(),
        throwsA(isA<DatabaseAccessException>()),
      );
      expect(
        await File(livePath(DatabaseRecovery.journalName)).exists(),
        isTrue,
      );
      await live.close();
      await backupsUnchanged();
      live = DatabaseHelper.forTesting(
        p.join(root.path, 'live'),
        databaseFactoryFfi,
      );
      final restarted = _RebuildProbe(0);
      await DatabaseRecovery(
        live,
        inspector: inspector,
        notifications: restarted,
      ).recoverInterrupted();
      expect(restarted.attempts, [
        ['old'],
      ]);
      expect(await ids(), ['old']);
      expect(
        await File(livePath(DatabaseRecovery.journalName)).exists(),
        isFalse,
      );
    },
  );

  test(
    'candidate notifications only activate after the durable committed decision',
    () async {
      final probe = _RebuildProbe(
        0,
        beforeRebuild: (tasks) async {
          expect(tasks, ['new']);
          final journal =
              jsonDecode(
                    await File(
                      livePath(DatabaseRecovery.journalName),
                    ).readAsString(),
                  )
                  as Map;
          expect(journal['state'], 'committed');
        },
      );
      await DatabaseRecovery(
        live,
        inspector: inspector,
        notifications: probe,
      ).restore(sqliteSource, expectedDigest: await hash(sqliteSource));
      expect(await ids(), ['new']);
      expect(probe.isPausedForMaintenance, isFalse);
    },
  );

  test('Android TRUNCATE journals restore JSON and retain the original rollback bytes', () async {
    await live.close(createBackup: false);
    live = DatabaseHelper.forTesting(p.join(root.path, 'live'), _TruncateFactory());
    final sql = await live.database;
    await sql.execute("UPDATE Reminders SET task_title='Original task TRUNCATE'");
    final journal = File(livePath('dont_forget_v3.db-journal'));
    expect(await journal.exists(), isTrue);
    expect(await journal.length(), 0);
    final before = await hash(jsonSource);
    final result = await DatabaseRecovery(live, inspector: inspector,
        notifications: notifications()).restore(jsonSource, expectedDigest: before);
    expect(await ids(), ['new']);
    final rollback = File(p.join(result.rollbackDirectory, 'rollback.db'));
    expect(await rollback.exists(), isTrue);
    final old = await databaseFactoryFfi.openDatabase(rollback.path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
    try {
      expect((await old.query('Reminders')).single['id'], 'old');
    } finally {
      await old.close();
    }
    expect(await hash(jsonSource), before);
    expect(await File(livePath(DatabaseRecovery.journalName)).exists(), isFalse);
    await backupsUnchanged();
    await live.close(createBackup: false);
    live = DatabaseHelper.forTesting(p.join(root.path, 'live'), _TruncateFactory());
    expect(await ids(), ['new']);
  });

  for (final point in [RecoveryCheckpoint.candidateOpened, RecoveryCheckpoint.committed]) {
    test('TRUNCATE empty journal survives restart at ${point.name}', () async {
      await live.close(createBackup: false);
      live = DatabaseHelper.forTesting(p.join(root.path, 'live'), _TruncateFactory());
      await (await live.database).execute("UPDATE Reminders SET task_title='TRUNCATE restart'");
      await expectLater(DatabaseRecovery(live, inspector: inspector,
        notifications: notifications(), checkpoint: (at) async {
          if (at == point) {
            // Model Android's retained, already-truncated rollback journal at
            // process interruption. No SQL transaction is active here.
            await File(livePath('dont_forget_v3.db-journal')).writeAsBytes([]);
            throw const RecoveryInterruption();
          }
        }).restore(jsonSource, expectedDigest: await hash(jsonSource)),
        throwsA(isA<RecoveryInterruption>()));
      await live.close(createBackup: false);
      live = DatabaseHelper.forTesting(p.join(root.path, 'live'), _TruncateFactory());
      await DatabaseRecovery(live, inspector: inspector, notifications: notifications()).recoverInterrupted();
      expect(await ids(), [point == RecoveryCheckpoint.committed ? 'new' : 'old']);
      expect(await File(livePath(DatabaseRecovery.journalName)).exists(), isFalse);
      await backupsUnchanged();
    });
  }

  test('nonempty PERSIST journal is retained and blocks primary replacement', () async {
    final sql = await live.database;
    await sql.rawQuery('PRAGMA journal_mode=PERSIST');
    await sql.execute("UPDATE Reminders SET task_title='PERSIST retained'");
    final journal = File(livePath('dont_forget_v3.db-journal'));
    expect(await journal.length(), greaterThan(0));
    final before = await hash(journal);
    await expectLater(DatabaseRecovery(live, inspector: inspector,
      notifications: notifications()).restore(jsonSource, expectedDigest: await hash(jsonSource)),
      throwsA(isA<DatabaseRecoveryException>().having((e) => e.rolledBack, 'original preserved', true)));
    expect(await ids(), ['old']);
    expect(await hash(journal), before);
    await backupsUnchanged();
  });

  for (final target in ['source', 'live']) {
    test(
      'WAL $target is rejected before replacement even with no sidecars',
      () async {
        final file = target == 'source'
            ? sqliteSource
            : File(livePath('dont_forget_v3.db'));
        if (target == 'live') {
          final lease = await live.beginMaintenance();
          await lease.closeWithoutBackup();
          await lease.resume();
        }
        final wal = await databaseFactoryFfi.openDatabase(
          file.path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await wal.rawQuery('PRAGMA journal_mode=WAL');
        await wal.close();
        expect(await File('${file.path}-wal').exists(), isFalse);
        expect((await file.readAsBytes())[18], 2);
        final before = await hash(sqliteSource);
        await expectLater(
          DatabaseRecovery(
            live,
            inspector: inspector,
            notifications: notifications(),
          ).restore(sqliteSource, expectedDigest: before),
          throwsA(
            isA<DatabaseRecoveryException>().having(
              (e) => e.rolledBack,
              'original preserved',
              isTrue,
            ),
          ),
        );
        expect(await ids(), ['old']);
        expect(await hash(sqliteSource), before);
        expect(
          await File(livePath(DatabaseRecovery.journalName)).exists(),
          isFalse,
        );
        await backupsUnchanged();
      },
    );
  }
}
