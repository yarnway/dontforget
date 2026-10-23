import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import '../benchmark/notification_startup.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:dont_forget/services/storage_directory_lease.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const epoch = '00000000-0000-4000-8000-000000000001';
  const next = '00000000-0000-4000-8000-000000000002';
  late Directory dir;
  DatabaseHelper? helper;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('product-incremental-');
    dir = Directory(await dir.resolveSymbolicLinks());
  });
  tearDown(() async {
    await helper?.close(createBackup: false);
    helper = null;
    await dir.delete(recursive: true);
  });
  DatabaseHelper open({bool upgrade = true}) =>
      helper = DatabaseHelper.forTesting(
        dir.path,
        databaseFactoryFfi,
        migrateNotificationJournal: upgrade,
      );
  Future<NotificationJournalEntry> begin(NotificationJournal j, String id) =>
      j.begin(
        epoch,
        id,
        action: 'schedule',
        triggerUtcMicros: DateTime.utc(2099).microsecondsSinceEpoch,
        noticeRevision: 0,
        attemptedAt: DateTime.utc(2026, 10, 23),
      );

  test(
    'legacy upgrade, batch writes and rollback pin preserve latest IDs',
    () async {
      final legacy = NotificationJournal(dir);
      await legacy.reset(epoch);
      final original = await begin(legacy, 'old');
      final originalBytes = await File(
        '${dir.path}/${NotificationJournal.fileName}',
      ).readAsBytes();
      final db = open();
      await db.withNotificationJournal((j) async {
        expect(j.usesIncrementalStorage, isTrue);
        final entries = await Future.wait(
          List.generate(257, (i) => begin(j, 'new-$i')),
        );
        expect(entries.map((e) => e.nativeId).toSet(), hasLength(257));
        await j.record(epoch, 'old', action: 'schedule', status: 'failed');
      });
      expect(
        await File('${dir.path}/${NotificationJournal.fileName}').readAsBytes(),
        originalBytes,
      );
      final latest = (await db.withNotificationJournal((j) => j.read()))!;
      expect(latest.entries['old']!.nativeId, original.nativeId);
      expect(latest.entries['old']!.status, 'failed');
      final maintenance = await db.beginMaintenance();
      await maintenance.rollbackNotificationStorage();
      await maintenance.resume();
      await db.close(createBackup: false);
      final reopened = open();
      await reopened.withNotificationJournal((j) async {
        expect(j.usesIncrementalStorage, isFalse);
        expect((await j.read())!.toJson(), latest.toJson());
        await j.record(epoch, 'old', action: 'schedule', status: 'submitted');
      });
      expect(
        (await NotificationJournal(dir).read())!.entries['old']!.status,
        'submitted',
      );
    },
  );

  test(
    'fresh store upgrades before first intent; recovery resets epoch under gate',
    () async {
      final db = open();
      await db.withNotificationJournal((j) => j.reset(epoch));
      await db.withNotificationJournal((j) => begin(j, 'old'));
      final ticket = db.captureGeneration();
      final lease = await db.beginMaintenance();
      await db.withNotificationJournal((j) => j.reset(next));
      expect(
        () => db.checkGeneration(ticket),
        throwsA(isA<DatabaseAccessException>()),
      );
      final state = (await db.withNotificationJournal((j) => j.read()))!;
      expect(state.epoch, next);
      expect(state.entries, isEmpty);
      await lease.rollbackNotificationStorage();
      await lease.resume();
      await db.close(createBackup: false);
      expect((await NotificationJournal(dir).read())!.toJson(), state.toJson());
    },
  );

  test(
    'closing a borrowed journal never releases the database lease',
    () async {
      final db = open();
      await db.withNotificationJournal((j) => j.reset(epoch));
      await db.withNotificationJournal((j) => j.close());
      await expectLater(
        StorageDirectoryLease.acquire(dir),
        throwsA(isA<FileSystemException>()),
      );
      await db.close(createBackup: false);
      final lease = await StorageDirectoryLease.acquire(dir);
      await lease.close();
    },
  );

  test(
    'unknown selection or corrupt selected generation blocks SQL without touching legacy',
    () async {
      final legacy = NotificationJournal(dir);
      await legacy.reset(epoch);
      await begin(legacy, 'old');
      final old = await File(
        '${dir.path}/${NotificationJournal.fileName}',
      ).readAsBytes();
      final db = open();
      await db.acquireOwnership();
      await db.close(createBackup: false);
      final manifest = File(
        '${dir.path}/notification-incremental/current.json',
      );
      await manifest.writeAsString('{bad');
      await expectLater(
        open().database,
        throwsA(isA<DatabaseRecoveryRequiredException>()),
      );
      expect(
        await File('${dir.path}/${NotificationJournal.fileName}').readAsBytes(),
        old,
      );
    },
  );

  test('v1 policy does not migrate an unselected directory', () async {
    final db = open(upgrade: false);
    await db.withNotificationJournal((j) => j.reset(epoch));
    await db.withNotificationJournal((j) => begin(j, 'old'));
    expect(
      await Directory('${dir.path}/notification-incremental').exists(),
      isFalse,
    );
    expect(
      await db.withNotificationJournal((j) async => j.usesIncrementalStorage),
      isFalse,
    );
  });

  test(
    'close drains accepted intents, rejects new writes and retains the borrowed lease',
    () async {
      final owner = await StorageDirectoryLease.acquire(dir);
      final journal = await NotificationJournal.openOwned(
        owner,
        migrateLegacy: true,
      );
      try {
        await journal.reset(epoch);
        final admitted = begin(journal, 'accepted');
        final closing = journal.close();
        await expectLater(begin(journal, 'rejected'), throwsStateError);
        final saved = await admitted;
        await closing;
        await expectLater(journal.read(), throwsStateError);
        await expectLater(
          StorageDirectoryLease.acquire(dir),
          throwsA(isA<FileSystemException>()),
        );
        expect(saved.status, 'pending');
      } finally {
        await owner.close();
      }
      final db = open();
      expect(
        (await db.withNotificationJournal((j) => j.read()))!.entries.keys,
        ['accepted'],
      );
    },
  );

  test(
    'pinning an unused v1 store prevents a subsequent automatic migration',
    () async {
      final db = open();
      final maintenance = await db.beginMaintenance();
      await maintenance.rollbackNotificationStorage();
      await maintenance.resume();
      await db.close(createBackup: false);
      final again = open();
      await again.withNotificationJournal((j) => j.reset(epoch));
      await again.withNotificationJournal((j) => begin(j, 'old'));
      expect(
        await again.withNotificationJournal(
          (j) async => j.usesIncrementalStorage,
        ),
        isFalse,
      );
    },
  );

  for (final checkpoint in [
    RecoveryCheckpoint.candidateInstalled,
    RecoveryCheckpoint.candidateOpened,
  ]) {
    test(
      'SQL restore failure at ${checkpoint.name} rebuilds the incremental epoch and rolls back latest state',
      () async {
        final source = DatabaseHelper.forTesting(
          '${dir.path}/source',
          databaseFactoryFfi,
        );
        await source.writeTransaction(
          source.captureGeneration(),
          (sql) => sql.insert(
            'Reminders',
            Reminder(
              id: 'replacement',
              taskTitle: 'Synthetic replacement',
              quadrantLevel: 3,
              triggerTime: DateTime.utc(2099),
            ).toJson(),
          ),
        );
        await source.close();
        final backup = File('${dir.path}/source/ha_snapshot.json');
        final digest = sha256.convert(await backup.readAsBytes()).toString();
        final db = open();
        final task = Reminder(
          id: 'original',
          taskTitle: 'Synthetic original',
          quadrantLevel: 3,
          triggerTime: DateTime.utc(2099),
        );
        await db.writeTransaction(
          db.captureGeneration(),
          (sql) => sql.insert('Reminders', task.toJson()),
        );
        final transport = RecordingNotificationTransport();
        final service = NotificationService.forTesting(
          transport,
          usesNativeNotifications: true,
          database: db,
        );
        try {
          await service.init();
          await service.pauseForMaintenance();
          await service.resumeFromReminders([task]);
          final before = (await db.withNotificationJournal((j) => j.read()))!;
          final recovery = DatabaseRecovery(
            db,
            notifications: service,
            inspector: BackupInspector(
              databaseFactoryFfi,
              temporaryDirectory: dir,
            ),
            checkpoint: (point) async {
              if (point == checkpoint) {
                throw const FileSystemException('isolated restore failure');
              }
            },
          );
          await expectLater(
            recovery.restore(backup, expectedDigest: digest),
            throwsA(
              isA<DatabaseRecoveryException>().having(
                (e) => e.rolledBack,
                'rolled back',
                isTrue,
              ),
            ),
          );
          final after = (await db.withNotificationJournal((j) => j.read()))!;
          expect(after.epoch, isNot(before.epoch));
          expect(after.entries.keys, ['original']);
          expect(
            after.entries['original']!.nativeId,
            before.entries['original']!.nativeId,
          );
          expect(after.entries['original']!.status, 'submitted');
          expect(transport.pending.keys, [after.entries['original']!.nativeId]);
          expect(
            await db.read(
              db.captureGeneration(),
              (sql) async => (await sql.query('Reminders')).single['id'],
            ),
            'original',
          );
          expect(sha256.convert(await backup.readAsBytes()).toString(), digest);
          await service.pauseForMaintenance();
          final maintenance = await db.beginMaintenance();
          await maintenance.rollbackNotificationStorage();
          await maintenance.resume();
          expect(
            (await NotificationJournal(dir).read())!.toJson(),
            after.toJson(),
          );
        } finally {
          await service.pauseForMaintenance();
        }
      },
    );
  }

  for (final point in ['pending', 'effect', 'submitted']) {
    test(
      'product writer survives SIGKILL after $point with durable stable ID',
      () async {
        final legacy = NotificationJournal(dir);
        await legacy.reset(epoch);
        await legacy.reserve(epoch, 'task');
        final id = (await legacy.read())!.entries['task']!.nativeId;
        final config = File('.dart_tool/package_config.json').absolute;
        final packages =
            (jsonDecode(await config.readAsString()) as Map)['packages']
                as List;
        final flutter =
            packages.singleWhere((p) => p['name'] == 'flutter') as Map;
        final sdk = Directory.fromUri(
          config.uri.resolve(flutter['rootUri'] as String),
        ).parent.parent;
        final dart =
            '${sdk.path}/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
        final child = await Process.start(dart, [
          '--packages=${config.path}',
          'test/fixtures/journal_crash_worker.dart',
          dir.path,
          'product:$point',
        ]);
        final errors = child.stderr.transform(utf8.decoder).join();
        try {
          expect(
            await child.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .first
                .timeout(const Duration(seconds: 20)),
            'DURABLE_BOUNDARY',
          );
          expect(child.kill(ProcessSignal.sigkill), isTrue);
          await child.exitCode.timeout(const Duration(seconds: 10));
          expect(await errors, isEmpty);
        } finally {
          child.kill(ProcessSignal.sigkill);
        }
        final db = open();
        final state = (await db.withNotificationJournal((j) => j.read()))!;
        expect(state.entries['task']!.nativeId, id);
        expect(
          state.entries['task']!.status,
          point == 'submitted' ? 'submitted' : 'pending',
        );
        expect(
          await File('${dir.path}/effect.json').exists(),
          point != 'pending',
        );
        final lease = await db.beginMaintenance();
        await lease.rollbackNotificationStorage();
        await lease.resume();
        expect(
          (await NotificationJournal(dir).read())!.toJson(),
          state.toJson(),
        );
      },
      skip: Platform.isWindows ? 'POSIX SIGKILL boundary' : false,
    );
  }
}
