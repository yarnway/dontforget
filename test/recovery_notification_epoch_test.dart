import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_epoch_store.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications extends NotificationService {
  _Notifications(this.readEpoch)
    : super.forTesting(
        FlutterLocalNotificationsPlugin(),
        usesNativeNotifications: false,
      );

  final Future<String> Function() readEpoch;
  final resumedEpochs = <String>[];
  bool paused = false;
  bool failRebuild = false;

  @override
  bool get isPausedForMaintenance => paused;

  @override
  Future<void> pauseForMaintenance() async => paused = true;

  @override
  Future<void> resumeFromReminders(Iterable<Reminder> reminders) async {
    resumedEpochs.add(await readEpoch());
    if (failRebuild) throw StateError('Synthetic native rebuild failure');
    paused = false;
  }
}

void main() {
  late Directory root;
  late Directory liveDirectory;
  late DatabaseHelper live;
  late BackupInspector inspector;
  late NotificationEpochStore epochs;
  late _Notifications notifications;
  late File jsonSource;
  late File sqliteSource;
  late File epochFile;
  late String originalEpoch;

  File primary() => File(p.join(liveDirectory.path, 'dont_forget_v3.db'));
  File pending() =>
      File(p.join(liveDirectory.path, DatabaseRecovery.journalName));
  Future<String> hash(File file) async =>
      sha256.convert(await file.readAsBytes()).toString();
  Future<List<Map<String, Object?>>> reminders() => live.read(
    live.captureGeneration(),
    (database) => database.query('Reminders'),
  );

  DatabaseRecovery engine({
    Future<void> Function(RecoveryCheckpoint)? checkpoint,
  }) => DatabaseRecovery(
    live,
    inspector: inspector,
    notifications: notifications,
    checkpoint: checkpoint,
  );

  Future<void> restart() async {
    await live.close(createBackup: false);
    live = DatabaseHelper.forTesting(liveDirectory.path, databaseFactoryFfi);
    epochs = NotificationEpochStore(liveDirectory);
    notifications = _Notifications(epochs.readOrCreate);
  }

  setUp(() async {
    sqfliteFfiInit();
    final temporary = await Directory.systemTemp.createTemp('recovery-epoch-');
    root = Directory(await temporary.resolveSymbolicLinks());
    liveDirectory = Directory(p.join(root.path, 'live'));
    live = DatabaseHelper.forTesting(liveDirectory.path, databaseFactoryFfi);
    inspector = BackupInspector(databaseFactoryFfi, temporaryDirectory: root);
    await live.writeTransaction(live.captureGeneration(), (database) async {
      await database.insert(
        'Reminders',
        Reminder(
          id: 'same-occurrence',
          taskTitle: 'Original synthetic task',
          quadrantLevel: 3,
          createdAt: DateTime.utc(2030, 1, 1),
          triggerTime: DateTime.utc(2030, 1, 31, 9),
          noticeRevision: 7,
        ).toJson(),
      );
    });
    await live.createMirrorBackup();
    jsonSource = await File(
      p.join(liveDirectory.path, 'ha_snapshot.json'),
    ).copy(p.join(root.path, 'input.json'));
    sqliteSource = await File(
      p.join(liveDirectory.path, 'dont_forget_v3.mirror.db'),
    ).copy(p.join(root.path, 'input.sqlite'));
    epochs = NotificationEpochStore(Directory(await live.acquireOwnership()));
    originalEpoch = await epochs.readOrCreate();
    epochFile = File(
      p.join(liveDirectory.path, NotificationEpochStore.fileName),
    );
    notifications = _Notifications(epochs.readOrCreate);
  });

  tearDown(() async {
    await live.close(createBackup: false);
    await root.delete(recursive: true);
  });

  for (final format in ['json', 'sqlite']) {
    test(
      '$format restoring identical rows rotates identity before installation',
      () async {
        final source = format == 'json' ? jsonSource : sqliteSource;
        final beforeRows = await reminders();
        final sourceHash = await hash(source);
        var checkedBeforeInstall = false;
        final result = await engine(
          checkpoint: (point) async {
            if (point == RecoveryCheckpoint.journalPrepared) {
              expect(await epochs.readOrCreate(), originalEpoch);
            }
            if (point == RecoveryCheckpoint.originalMoved) {
              expect(await epochs.readOrCreate(), isNot(originalEpoch));
              expect(notifications.resumedEpochs, isEmpty);
              checkedBeforeInstall = true;
            }
          },
        ).restore(source, expectedDigest: sourceHash);
        final restoredEpoch = await epochs.readOrCreate();
        expect(checkedBeforeInstall, isTrue);
        expect(restoredEpoch, isNot(originalEpoch));
        expect(await reminders(), beforeRows);
        expect(notifications.resumedEpochs, [restoredEpoch]);
        expect(await hash(source), sourceHash);
        expect(await pending().exists(), isFalse);
        final businessJson = jsonDecode(await jsonSource.readAsString()) as Map;
        expect(businessJson.keys, isNot(contains('epoch')));
        expect(businessJson.toString(), isNot(contains(restoredEpoch)));
        expect(
          await File(
            p.join(result.rollbackDirectory, NotificationEpochStore.fileName),
          ).exists(),
          isFalse,
        );
        await restart();
        await live.acquireOwnership();
        expect(await epochs.readOrCreate(), restoredEpoch);
      },
    );
  }

  test(
    'preparation and a rejected source do not rotate or create a journal',
    () async {
      final recovery = engine();
      await recovery.prepare(
        jsonSource,
        expectedDigest: await hash(jsonSource),
      );
      expect(await epochs.readOrCreate(), originalEpoch);
      expect(notifications.resumedEpochs, isEmpty);
      await expectLater(
        recovery.restore(jsonSource, expectedDigest: '0' * 64),
        throwsA(isA<BackupInspectionException>()),
      );
      expect(await epochs.readOrCreate(), originalEpoch);
      expect(await pending().exists(), isFalse);
      expect(notifications.paused, isFalse);
    },
  );

  test('a stale confirmation does not rotate or install a candidate', () async {
    final recovery = engine();
    final plan = await recovery.prepare(
      jsonSource,
      expectedDigest: await hash(jsonSource),
    );
    await live.writeTransaction(
      live.captureGeneration(),
      (database) =>
          database.update('Reminders', {'task_title': 'Newer local edit'}),
    );
    await expectLater(
      recovery.restorePlan(plan),
      throwsA(
        isA<DatabaseRecoveryException>().having(
          (error) => error.outcome,
          'outcome',
          RecoveryFailureOutcome.unchanged,
        ),
      ),
    );
    expect(await epochs.readOrCreate(), originalEpoch);
    expect((await reminders()).single['task_title'], 'Newer local edit');
    expect(await pending().exists(), isFalse);
  });

  for (final point in [
    RecoveryCheckpoint.candidateReady,
    RecoveryCheckpoint.rollbackReady,
  ]) {
    test(
      'failure at ${point.name} does not rotate before switching is prepared',
      () async {
        await expectLater(
          engine(
            checkpoint: (at) async {
              if (at == point) {
                throw StateError('Synthetic preparation failure');
              }
            },
          ).restore(jsonSource, expectedDigest: await hash(jsonSource)),
          throwsA(
            isA<DatabaseRecoveryException>().having(
              (error) => error.canContinue,
              'can continue',
              isTrue,
            ),
          ),
        );
        expect(await epochs.readOrCreate(), originalEpoch);
        expect(notifications.resumedEpochs, [originalEpoch]);
        expect(await pending().exists(), isFalse);
      },
    );
  }

  for (final point in [
    RecoveryCheckpoint.journalPrepared,
    RecoveryCheckpoint.committed,
    RecoveryCheckpoint.rollbackStarted,
  ]) {
    test(
      'restart from ${point.name} rotates before rebuilding notifications',
      () async {
        final data = jsonDecode(await jsonSource.readAsString()) as Map;
        (data['reminders'] as List).single['task_title'] =
            'Recovered synthetic task';
        await jsonSource.writeAsString(jsonEncode(data));
        await expectLater(
          engine(
            checkpoint: (at) async {
              if (point == RecoveryCheckpoint.rollbackStarted &&
                  at == RecoveryCheckpoint.candidateOpened) {
                throw StateError('Synthetic rollback request');
              }
              if (at == point) throw const RecoveryInterruption();
            },
          ).restore(jsonSource, expectedDigest: await hash(jsonSource)),
          throwsA(
            anyOf(
              isA<RecoveryInterruption>(),
              isA<DatabaseRecoveryException>(),
            ),
          ),
        );
        final beforeRetry = await epochs.readOrCreate();
        expect(notifications.resumedEpochs, isEmpty);
        await restart();
        await engine().recoverInterrupted();
        final afterRetry = await epochs.readOrCreate();
        expect(afterRetry, isNot(beforeRetry));
        expect(afterRetry, isNot(originalEpoch));
        expect(notifications.resumedEpochs, [afterRetry]);
        expect(
          (await reminders()).single['task_title'],
          point == RecoveryCheckpoint.committed
              ? 'Recovered synthetic task'
              : 'Original synthetic task',
        );
        expect(await pending().exists(), isFalse);
      },
    );
  }

  test(
    'committed notification retry rotates again without changing the data decision',
    () async {
      notifications.failRebuild = true;
      await expectLater(
        engine().restore(jsonSource, expectedDigest: await hash(jsonSource)),
        throwsA(isA<DatabaseRecoveryException>()),
      );
      final firstEpoch = await epochs.readOrCreate();
      expect(firstEpoch, isNot(originalEpoch));
      expect(notifications.resumedEpochs, [firstEpoch]);
      final committedHash = await hash(primary());
      await restart();
      notifications.failRebuild = true;
      await expectLater(
        engine().recoverInterrupted(),
        throwsA(isA<DatabaseRecoveryException>()),
      );
      final secondEpoch = await epochs.readOrCreate();
      expect(secondEpoch, isNot(firstEpoch));
      expect(notifications.resumedEpochs, [secondEpoch]);
      expect(await hash(primary()), committedHash);
      expect(await pending().exists(), isTrue);
      await restart();
      await engine().recoverInterrupted();
      final thirdEpoch = await epochs.readOrCreate();
      expect(thirdEpoch, isNot(secondEpoch));
      expect(notifications.resumedEpochs, [thirdEpoch]);
      expect(await pending().exists(), isFalse);
    },
  );

  test(
    'corrupt identity blocks candidate installation and preserves a retryable prepared decision',
    () async {
      final before = await hash(primary());
      final originalIdentity = await epochFile.readAsString();
      await epochFile.writeAsString('{broken');
      await expectLater(
        engine().restore(jsonSource, expectedDigest: await hash(jsonSource)),
        throwsA(
          isA<DatabaseRecoveryException>().having(
            (error) => error.canContinue,
            'can continue',
            isFalse,
          ),
        ),
      );
      expect(await hash(primary()), before);
      expect(await epochFile.readAsString(), '{broken');
      expect(notifications.paused, isTrue);
      expect(notifications.resumedEpochs, isEmpty);
      expect(
        () => live.captureGeneration(),
        throwsA(isA<DatabaseAccessException>()),
      );
      final journal = jsonDecode(await pending().readAsString()) as Map;
      expect(journal['state'], 'prepared');
      expect(
        await File(
          p.join(
            liveDirectory.path,
            'recovery-${journal['operationId']}',
            'displaced.db',
          ),
        ).exists(),
        isFalse,
      );
      await restart();
      await expectLater(
        engine().recoverInterrupted(),
        throwsA(isA<DatabaseRecoveryException>()),
      );
      expect(await hash(primary()), before);
      expect(notifications.resumedEpochs, isEmpty);
      // Repair only this test-owned sidecar, then verify the preserved decision retries.
      await epochFile.writeAsString(originalIdentity);
      await restart();
      await engine().recoverInterrupted();
      expect(await epochs.readOrCreate(), isNot(originalEpoch));
      expect(await pending().exists(), isFalse);
    },
  );

  test(
    'committed recovery refuses a corrupt identity before enabling notifications',
    () async {
      await expectLater(
        engine(
          checkpoint: (at) async {
            if (at == RecoveryCheckpoint.committed) {
              throw const RecoveryInterruption();
            }
          },
        ).restore(jsonSource, expectedDigest: await hash(jsonSource)),
        throwsA(isA<RecoveryInterruption>()),
      );
      final before = await hash(primary());
      final journalBytes = await pending().readAsBytes();
      await epochFile.writeAsString('{broken');
      await restart();
      await expectLater(
        engine().recoverInterrupted(),
        throwsA(isA<DatabaseRecoveryException>()),
      );
      expect(await hash(primary()), before);
      expect(await pending().readAsBytes(), journalBytes);
      expect(notifications.paused, isTrue);
      expect(notifications.resumedEpochs, isEmpty);
    },
  );

  test(
    'an epoch write I/O failure leaves the primary untouched and notifications paused',
    () async {
      // Permission denial is real filesystem I/O, not a fake store exception.
      // Root can bypass POSIX permissions; that host cannot exercise this case.
      final uid = await Process.run('id', ['-u']);
      if (uid.exitCode == 0 && uid.stdout.toString().trim() == '0') {
        markTestSkipped('Root bypasses POSIX directory write permissions.');
        return;
      }
      final before = await hash(primary());
      try {
        await expectLater(
          engine(
            checkpoint: (at) async {
              if (at == RecoveryCheckpoint.journalPrepared) {
                final result = await Process.run('chmod', [
                  '500',
                  liveDirectory.path,
                ]);
                expect(result.exitCode, 0);
              }
            },
          ).restore(jsonSource, expectedDigest: await hash(jsonSource)),
          throwsA(
            isA<DatabaseRecoveryException>().having(
              (error) => error.canContinue,
              'can continue',
              isFalse,
            ),
          ),
        );
        expect(await hash(primary()), before);
        expect(await epochs.readOrCreate(), originalEpoch);
        expect(notifications.resumedEpochs, isEmpty);
        expect(notifications.paused, isTrue);
        expect(
          (jsonDecode(await pending().readAsString()) as Map)['state'],
          'prepared',
        );
      } finally {
        final result = await Process.run('chmod', ['700', liveDirectory.path]);
        expect(result.exitCode, 0);
      }
      await restart();
      await engine().recoverInterrupted();
      expect(await epochs.readOrCreate(), isNot(originalEpoch));
      expect(await pending().exists(), isFalse);
    },
    skip: Platform.isWindows ? 'Requires POSIX directory permissions.' : false,
  );
}
