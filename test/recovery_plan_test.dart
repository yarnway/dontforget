import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications extends NotificationService {
  _Notifications()
    : super.forTesting(
        FlutterLocalNotificationsPlugin(),
        usesNativeNotifications: false,
      );
  int pauses = 0;
  final resumedIds = <List<String>>[];

  @override
  Future<void> pauseForMaintenance() async {
    pauses++;
    await super.pauseForMaintenance();
  }

  @override
  Future<void> resumeFromReminders(Iterable<Reminder> reminders) async {
    resumedIds.add(reminders.map((r) => r.id).toList());
    await super.resumeFromReminders(reminders);
  }
}

void main() {
  late Directory root;
  late DatabaseHelper live;
  late File source;
  late DatabaseRecovery engine;
  late _Notifications notifications;

  Future<String> hash(File file) async =>
      sha256.convert(await file.readAsBytes()).toString();
  Future<RecoveryPlan> prepare() async =>
      engine.prepare(source, expectedDigest: await hash(source));
  Future<List<String>> ids() => live.read(
    live.captureGeneration(),
    (db) async => (await db.query(
      'Reminders',
    )).map((row) => row['id'] as String).toList(),
  );

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('recovery-plan-test-');
    live = DatabaseHelper.forTesting(
      p.join(root.path, 'live'),
      databaseFactoryFfi,
    );
    await live.writeTransaction(live.captureGeneration(), (db) async {
      await db.insert(
        'Reminders',
        Reminder(id: 'old', taskTitle: 'Old task', quadrantLevel: 2).toJson(),
      );
      await db.insert(
        'MediaRecords',
        MediaRecord(
          id: 'old-media',
          type: 'text',
          contentOrPath: 'Old text',
          createdAt: DateTime(2026, 1, 1),
        ).toJson(),
      );
    });
    final backup = DatabaseHelper.forTesting(
      p.join(root.path, 'backup'),
      databaseFactoryFfi,
    );
    await backup.writeTransaction(backup.captureGeneration(), (db) async {
      await db.insert(
        'Reminders',
        Reminder(id: 'new', taskTitle: 'New task', quadrantLevel: 1).toJson(),
      );
    });
    await backup.close();
    source = File(p.join(root.path, 'backup', 'ha_snapshot.json'));
    notifications = _Notifications();
    engine = DatabaseRecovery(
      live,
      inspector: BackupInspector(databaseFactoryFfi, temporaryDirectory: root),
      notifications: notifications,
    );
  });

  tearDown(() async {
    await live.close();
    await root.delete(recursive: true);
  });

  test(
    'preparation is read-only and binds immutable counts and rollback path',
    () async {
      final generation = live.captureGeneration();
      final primary = File(p.join(root.path, 'live', 'dont_forget_v3.db'));
      final before = await hash(primary);
      final sourceBefore = await hash(source);
      final plan = await prepare();
      expect(plan.currentCounts, {
        'settings': 1,
        'media_records': 1,
        'reminders': 1,
      });
      expect(plan.preview.counts, {
        'settings': 1,
        'media_records': 0,
        'reminders': 1,
      });
      expect(
        () => plan.currentCounts['reminders'] = 100,
        throwsUnsupportedError,
      );
      expect(
        () => plan.preview.counts['reminders'] = 100,
        throwsUnsupportedError,
      );
      expect(plan.rollbackDirectory, endsWith('recovery-${plan.operationId}'));
      expect(await Directory(plan.rollbackDirectory).exists(), isFalse);
      expect(plan.currentSnapshotDigest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(await hash(primary), before);
      expect(await hash(source), sourceBefore);
      expect(live.isCurrent(generation), isTrue);
      expect(notifications.pauses, 0);
      expect(notifications.resumedIds, isEmpty);
    },
  );

  test('accepted plan uses exactly the displayed rollback directory', () async {
    final plan = await prepare();
    final result = await engine.restorePlan(plan);
    expect(result.operationId, plan.operationId);
    expect(result.rollbackDirectory, plan.rollbackDirectory);
    expect(await ids(), ['new']);
    expect(
      await File(p.join(plan.rollbackDirectory, 'rollback.db')).exists(),
      isTrue,
    );
    expect(notifications.resumedIds, [
      ['new'],
    ]);
    await expectLater(
      engine.restorePlan(plan),
      throwsA(
        isA<DatabaseRecoveryException>()
            .having(
              (e) => e.reason,
              'reason',
              RecoveryFailureReason.invalidPlan,
            )
            .having((e) => e.canContinue, 'can continue', isTrue),
      ),
    );
  });

  for (final table in ['Settings', 'MediaRecords', 'Reminders']) {
    test(
      'same-count $table edit invalidates confirmation and preserves latest data',
      () async {
        final plan = await prepare();
        final column = switch (table) {
          'Settings' => 'api_key',
          'MediaRecords' => 'content_or_path',
          _ => 'task_title',
        };
        await live.writeTransaction(live.captureGeneration(), (db) async {
          await db.update(table, {column: 'Changed after confirmation'});
        });
        await expectLater(
          engine.restorePlan(plan),
          throwsA(
            isA<DatabaseRecoveryException>()
                .having(
                  (e) => e.reason,
                  'reason',
                  RecoveryFailureReason.currentDataChanged,
                )
                .having(
                  (e) => e.outcome,
                  'outcome',
                  RecoveryFailureOutcome.unchanged,
                ),
          ),
        );
        expect(await ids(), ['old']);
        expect(
          await live.read(live.captureGeneration(), (db) => db.query(table)),
          everyElement(containsPair(column, 'Changed after confirmation')),
        );
        expect(await Directory(plan.rollbackDirectory).exists(), isFalse);
        expect(notifications.isPausedForMaintenance, isFalse);
        expect(notifications.resumedIds, [
          ['old'],
        ]);
        // A new confirmation is required and can be prepared immediately.
        final refreshed = await prepare();
        expect(
          refreshed.currentSnapshotDigest,
          isNot(plan.currentSnapshotDigest),
        );
        await engine.restorePlan(refreshed);
        expect(await ids(), ['new']);
      },
    );
  }

  test(
    'maintenance drains an admitted writer before validating the snapshot',
    () async {
      final plan = await prepare();
      final entered = Completer<void>();
      final release = Completer<void>();
      final writing = live.writeTransaction(live.captureGeneration(), (
        db,
      ) async {
        entered.complete();
        await release.future;
        await db.update('Reminders', {'task_title': 'Admitted final edit'});
      });
      await entered.future;
      final restoring = engine.restorePlan(plan);
      final rejection = expectLater(
        restoring,
        throwsA(
          isA<DatabaseRecoveryException>().having(
            (e) => e.reason,
            'reason',
            RecoveryFailureReason.currentDataChanged,
          ),
        ),
      );
      expect(notifications.pauses, 0);
      release.complete();
      await writing;
      await rejection;
      expect(await ids(), ['old']);
      expect(await Directory(plan.rollbackDirectory).exists(), isFalse);
      expect(notifications.resumedIds, [
        ['old'],
      ]);
    },
  );

  test(
    'source mutation after confirmation is rejected before replacement',
    () async {
      final plan = await prepare();
      final data =
          jsonDecode(await source.readAsString()) as Map<String, dynamic>;
      (data['reminders'] as List).single['task_title'] = 'Changed source';
      await source.writeAsString(jsonEncode(data), flush: true);
      await expectLater(
        engine.restorePlan(plan),
        throwsA(
          isA<DatabaseRecoveryException>()
              .having(
                (e) => e.reason,
                'reason',
                RecoveryFailureReason.sourceChanged,
              )
              .having(
                (e) => e.outcome,
                'outcome',
                RecoveryFailureOutcome.unchanged,
              ),
        ),
      );
      expect(await ids(), ['old']);
      expect(await Directory(plan.rollbackDirectory).exists(), isFalse);
      expect(notifications.isPausedForMaintenance, isFalse);
      expect(notifications.resumedIds, [
        ['old'],
      ]);
      await engine.restorePlan(await prepare());
      expect(await ids(), ['new']);
    },
  );

  test('unavailable source is a recoverable stale confirmation', () async {
    final plan = await prepare();
    await source.delete();
    await expectLater(
      engine.restorePlan(plan),
      throwsA(
        isA<DatabaseRecoveryException>()
            .having(
              (e) => e.reason,
              'reason',
              RecoveryFailureReason.sourceChanged,
            )
            .having((e) => e.canContinue, 'can continue', isTrue),
      ),
    );
    expect(await ids(), ['old']);
    expect(notifications.isPausedForMaintenance, isFalse);
  });

  test(
    'plan from another helper cannot pause or mutate this database',
    () async {
      final plan = await prepare();
      final foreign = DatabaseHelper.forTesting(
        p.join(root.path, 'foreign'),
        databaseFactoryFfi,
      );
      final foreignNotifications = _Notifications();
      try {
        await expectLater(
          DatabaseRecovery(
            foreign,
            notifications: foreignNotifications,
          ).restorePlan(plan),
          throwsA(
            isA<DatabaseRecoveryException>().having(
              (e) => e.reason,
              'reason',
              RecoveryFailureReason.invalidPlan,
            ),
          ),
        );
        expect(foreignNotifications.pauses, 0);
        expect(
          await File(
            p.join(root.path, 'foreign', 'dont_forget_v3.db'),
          ).exists(),
          isFalse,
        );
        // The rightful owner can still execute its own plan.
        await engine.restorePlan(plan);
        expect(await ids(), ['new']);
      } finally {
        await foreign.close();
      }
    },
  );

  test(
    'a different recovery generation always requires renewed confirmation',
    () async {
      final plan = await prepare();
      final lease = await live.beginMaintenance();
      await lease.resume();
      await expectLater(
        engine.restorePlan(plan),
        throwsA(
          isA<DatabaseRecoveryException>()
              .having(
                (e) => e.reason,
                'reason',
                RecoveryFailureReason.currentDataChanged,
              )
              .having((e) => e.canContinue, 'can continue', isTrue),
        ),
      );
      expect(await ids(), ['old']);
      expect(notifications.pauses, 0);
    },
  );

  test(
    'preoccupied rollback path is preserved and requires a new plan',
    () async {
      final plan = await prepare();
      await Directory(plan.rollbackDirectory).create();
      final sentinel = File(p.join(plan.rollbackDirectory, 'keep.txt'));
      await sentinel.writeAsString('unrelated file');
      await expectLater(
        engine.restorePlan(plan),
        throwsA(
          isA<DatabaseRecoveryException>()
              .having(
                (e) => e.reason,
                'reason',
                RecoveryFailureReason.invalidPlan,
              )
              .having((e) => e.canContinue, 'can continue', isTrue),
        ),
      );
      expect(await sentinel.readAsString(), 'unrelated file');
      expect(await ids(), ['old']);
      expect(notifications.isPausedForMaintenance, isFalse);
    },
  );

  test(
    'new source sidecars invalidate confirmation before replacement',
    () async {
      source = File(p.join(root.path, 'backup', 'dont_forget_v3.mirror.db'));
      final plan = await prepare();
      await File('${source.path}-wal').writeAsString('unconfirmed WAL');
      await expectLater(
        engine.restorePlan(plan),
        throwsA(
          isA<DatabaseRecoveryException>()
              .having(
                (e) => e.reason,
                'reason',
                RecoveryFailureReason.sourceChanged,
              )
              .having((e) => e.canContinue, 'can continue', isTrue),
        ),
      );
      expect(await ids(), ['old']);
      expect(await Directory(plan.rollbackDirectory).exists(), isFalse);
    },
  );

  test('a faulted gate is never described as safe to continue', () async {
    final plan = await prepare();
    final failing = DatabaseRecovery(
      live,
      inspector: engine.inspector,
      notifications: notifications,
      checkpoint: (at) async {
        if (at == RecoveryCheckpoint.committed) {
          throw StateError('durable decision needs restart');
        }
      },
    );
    await expectLater(
      failing.restorePlan(plan),
      throwsA(
        isA<DatabaseRecoveryException>()
            .having(
              (e) => e.outcome,
              'outcome',
              RecoveryFailureOutcome.restartRequired,
            )
            .having(
              (e) => e.rollbackDirectory,
              'rollback directory',
              plan.rollbackDirectory,
            ),
      ),
    );
    await expectLater(
      failing.restorePlan(plan),
      throwsA(
        isA<DatabaseRecoveryException>().having(
          (e) => e.canContinue,
          'can continue',
          isFalse,
        ),
      ),
    );
  });
}
