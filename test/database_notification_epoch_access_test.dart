import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_epoch_store.dart';
import 'package:dont_forget/services/macos_notification_scheduler.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  late Directory root;
  late Directory directory;
  late DatabaseHelper database;
  final services = <NotificationService>[];
  final nativeCalls = <MethodCall>[];

  Future<String> hash(File file) async =>
      sha256.convert(await file.readAsBytes()).toString();
  File primary() => File(p.join(directory.path, 'dont_forget_v3.db'));
  NotificationService realService() {
    final service = NotificationService.forDatabase(database);
    services.add(service);
    return service;
  }

  Future<File> source({
    String id = 'isolated-real-service-task',
    String format = 'json',
  }) async {
    await database.writeTransaction(database.captureGeneration(), (db) async {
      await db.insert(
        'Reminders',
        Reminder(
          id: id,
          taskTitle: 'Synthetic real service recovery',
          quadrantLevel: 3,
          triggerTime: DateTime.utc(2030, 1, 31, 9),
        ).toJson(),
      );
    });
    await database.createMirrorBackup();
    return File(
      p.join(
        directory.path,
        format == 'json' ? 'ha_snapshot.json' : 'dont_forget_v3.mirror.db',
      ),
    ).copy(p.join(root.path, 'input.$format'));
  }

  void expectNativeEpoch(NotificationService service, String epoch) {
    // CI Linux/Windows use the real timer service without native scheduling.
    // Darwin additionally verifies the real plugin's serialized channel payload.
    if (!service.usesNativeNotifications) return;
    final schedules = nativeCalls
        .where(
          (call) => call.method == 'zonedSchedule' || call.method == 'schedule',
        )
        .toList();
    expect(schedules, hasLength(1));
    final payload = NotificationPayload.tryParse(
      (schedules.single.arguments as Map)['payload'] as String,
    );
    expect(payload?.datasetEpoch, epoch);
    expect(nativeCalls.any((call) => call.method == 'cancelAll'), isTrue);
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    sqfliteFfiInit();
    final temporary = await Directory.systemTemp.createTemp(
      'database-notification-epoch-',
    );
    root = Directory(await temporary.resolveSymbolicLinks());
    directory = Directory(p.join(root.path, 'live'));
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    nativeCalls.clear();
    services.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MacOSNotificationScheduler.channel, (
          call,
        ) async {
          nativeCalls.add(call);
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          nativeCalls.add(call);
          // Darwin 17.2.x returns false when no permissions were requested;
          // callbacks are nevertheless initialized before this response.
          if (call.method == 'initialize') return false;
          if (call.method == 'getNotificationAppLaunchDetails') {
            return {'notificationLaunchedApp': false};
          }
          return null;
        });
  });

  tearDown(() async {
    for (final service in services) {
      await service.pauseForMaintenance();
    }
    await database.close(createBackup: false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MacOSNotificationScheduler.channel, null);
    debugDefaultTargetPlatformOverride = null;
    await root.delete(recursive: true);
  });

  test(
    'concurrent owned sidecar reads do not open SQL and observe later rotations',
    () async {
      final first = await Future.wait(
        List.generate(5, (_) => database.readNotificationEpoch()),
      );
      expect(first.toSet(), hasLength(1));
      expect(await primary().exists(), isFalse);
      final rotated = await NotificationEpochStore(directory).rotate();
      expect(rotated, isNot(first.first));
      expect(await database.readNotificationEpoch(), rotated);
      expect(await primary().exists(), isFalse);
    },
  );

  test(
    'another helper cannot use epoch reads to bypass directory ownership',
    () async {
      final first = await database.readNotificationEpoch();
      final competing = DatabaseHelper.forTesting(
        directory.path,
        databaseFactoryFfi,
      );
      try {
        await expectLater(
          competing.readNotificationEpoch(),
          throwsA(
            isA<DatabaseAccessException>().having(
              (error) => error.code,
              'code',
              DatabaseAccessError.ownedByAnotherProcess,
            ),
          ),
        );
        expect(await database.readNotificationEpoch(), first);
        expect(await primary().exists(), isFalse);
      } finally {
        await competing.close(createBackup: false);
      }
    },
  );

  test(
    'a valid maintenance lease can read epoch while SQL and new admissions stay closed',
    () async {
      final first = await database.readNotificationEpoch();
      final generation = database.captureGeneration();
      final lease = await database.beginMaintenance();
      expect(await database.readNotificationEpoch(), first);
      expect(
        () => database.captureGeneration(),
        throwsA(isA<DatabaseAccessException>()),
      );
      expect(
        () => database.read(generation, (db) => db.query('Reminders')),
        throwsA(isA<DatabaseAccessException>()),
      );
      expect(await primary().exists(), isFalse);
      await lease.resume();
      expect(await database.readNotificationEpoch(), first);
    },
  );

  test(
    'maintenance sidecars may overlap but keep SQL and lease release closed',
    () async {
      await database.database;
      final lease = await database.beginMaintenance();
      await lease.validateAndOpen();
      final firstRelease = Completer<void>();
      final secondRelease = Completer<void>();
      final entered = Completer<void>();
      var count = 0;
      Future<void> sidecar(Completer<void> release) =>
          database.withNotificationJournal((_) async {
            if (++count == 2) entered.complete();
            await release.future;
          });
      final first = sidecar(firstRelease);
      final second = sidecar(secondRelease);
      await entered.future;
      expect(
        () => lease.read((db) => db.query('Reminders')),
        throwsA(isA<DatabaseAccessException>()),
      );
      expect(
        () => lease.closeWithoutBackup(),
        throwsA(isA<DatabaseAccessException>()),
      );
      expect(() => lease.fail(), throwsA(isA<DatabaseAccessException>()));
      await expectLater(
        lease.resume(),
        throwsA(isA<DatabaseAccessException>()),
      );
      firstRelease.complete();
      await first;
      await expectLater(
        lease.resume(),
        throwsA(isA<DatabaseAccessException>()),
      );
      secondRelease.complete();
      await second;
      await lease.resume();
      expect(await database.readNotificationEpoch(), isNotEmpty);
    },
  );

  test(
    'an admitted producer can finish an epoch read while maintenance drains',
    () async {
      final entered = Completer<void>();
      final continueRead = Completer<void>();
      final readFinished = Completer<String>();
      final finishOperation = Completer<void>();
      final operation = database.runOperation(
        database.captureGeneration(),
        () async {
          entered.complete();
          await continueRead.future;
          readFinished.complete(await database.readNotificationEpoch());
          await finishOperation.future;
        },
      );
      await entered.future;
      var leaseIssued = false;
      final pendingLease = database.beginMaintenance().then((lease) {
        leaseIssued = true;
        return lease;
      });
      expect(
        () => database.readNotificationEpoch(),
        throwsA(isA<DatabaseAccessException>()),
      );
      continueRead.complete();
      final epoch = await readFinished.future;
      expect(leaseIssued, isFalse);
      expect(await primary().exists(), isFalse);
      finishOperation.complete();
      await operation;
      final lease = await pendingLease;
      expect(await database.readNotificationEpoch(), epoch);
      await lease.resume();
    },
  );

  test('closing and faulted helpers reject epoch access', () async {
    await database.readNotificationEpoch();
    final entered = Completer<void>();
    final release = Completer<void>();
    final operation = database.runOperation(
      database.captureGeneration(),
      () async {
        entered.complete();
        await release.future;
        expect(
          () => database.readNotificationEpoch(),
          throwsA(isA<DatabaseAccessException>()),
        );
      },
    );
    await entered.future;
    final closing = database.close(createBackup: false);
    expect(
      () => database.readNotificationEpoch(),
      throwsA(isA<DatabaseAccessException>()),
    );
    release.complete();
    await operation;
    await closing;
    final lease = await database.beginMaintenance();
    lease.fail();
    expect(
      () => database.readNotificationEpoch(),
      throwsA(
        isA<DatabaseAccessException>().having(
          (error) => error.code,
          'code',
          DatabaseAccessError.faulted,
        ),
      ),
    );
  });

  test(
    'production forDatabase service restores with the real helper maintenance gate',
    () async {
      final input = await source();
      final service = realService();
      await service.init();
      final before = await database.readNotificationEpoch();
      expect(service.datasetEpoch, before);
      nativeCalls.clear();
      await DatabaseRecovery(
        database,
        inspector: BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        ),
        notifications: service,
      ).restore(input, expectedDigest: await hash(input));
      final after = await database.readNotificationEpoch();
      expect(after, isNot(before));
      expect(service.datasetEpoch, after);
      expect(service.isPausedForMaintenance, isFalse);
      expect(
        await File(
          p.join(directory.path, DatabaseRecovery.journalName),
        ).exists(),
        isFalse,
      );
      expectNativeEpoch(service, after);
    },
  );

  test(
    'cold committed recovery initializes production notifications under the lease',
    () async {
      final input = await source();
      final before = await database.readNotificationEpoch();
      final firstService = realService();
      expect(firstService.datasetEpoch, isNull);
      await expectLater(
        DatabaseRecovery(
          database,
          inspector: BackupInspector(
            databaseFactoryFfi,
            temporaryDirectory: root,
          ),
          notifications: firstService,
          checkpoint: (point) async {
            if (point == RecoveryCheckpoint.committed) {
              throw const RecoveryInterruption();
            }
          },
        ).restore(input, expectedDigest: await hash(input)),
        throwsA(isA<RecoveryInterruption>()),
      );
      await database.close(createBackup: false);
      database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
      final service = realService();
      expect(service.datasetEpoch, isNull);
      nativeCalls.clear();
      await DatabaseRecovery(
        database,
        notifications: service,
      ).recoverInterrupted();
      final after = await database.readNotificationEpoch();
      expect(after, isNot(before));
      expect(service.datasetEpoch, after);
      expect(service.isPausedForMaintenance, isFalse);
      expect(
        await File(
          p.join(directory.path, DatabaseRecovery.journalName),
        ).exists(),
        isFalse,
      );
      expectNativeEpoch(service, after);
      final rows = await database.read(
        database.captureGeneration(),
        (db) => db.query('Reminders'),
      );
      expect(rows.single['id'], 'isolated-real-service-task');
    },
  );

  for (final format in ['json', 'sqlite']) {
    for (final kind in ['long', 'nul']) {
      test(
        'production service restores a valid $format $kind ID without blocking committed recovery',
        () async {
          final id = kind == 'long' ? 'x' * 10000 : 'synthetic\u0000legacy-id';
          final input = await source(id: id, format: format);
          final inspector = BackupInspector(
            databaseFactoryFfi,
            temporaryDirectory: root,
          );
          final preview = await inspector.inspect(input);
          final service = realService();
          final before = await database.readNotificationEpoch();
          await DatabaseRecovery(
            database,
            inspector: inspector,
            notifications: service,
          ).restore(input, expectedDigest: preview.digest);
          final after = await database.readNotificationEpoch();
          expect(after, isNot(before));
          expect(service.datasetEpoch, after);
          expect(service.isPausedForMaintenance, isFalse);
          expect(
            await File(
              p.join(directory.path, DatabaseRecovery.journalName),
            ).exists(),
            isFalse,
          );
          final row = (await database.read(
            database.captureGeneration(),
            (db) => db.query('Reminders'),
          )).single;
          expect(row['id'], id);
          expectNativeEpoch(service, after);
          if (service.usesNativeNotifications) {
            final schedule = nativeCalls.singleWhere(
              (call) =>
                  call.method == 'zonedSchedule' || call.method == 'schedule',
            );
            final encoded = (schedule.arguments as Map)['payload'] as String;
            expect(encoded.length, lessThan(400));
            expect(
              NotificationPayload.tryParse(
                encoded,
              )!.matches(Reminder.fromJson(row), currentDatasetEpoch: after),
              isTrue,
            );
          }
        },
      );
    }
  }
}
