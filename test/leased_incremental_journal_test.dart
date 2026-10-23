import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:dont_forget/services/storage_directory_lease.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../benchmark/leased_incremental_journal.dart';

void main() {
  const epoch = '00000000-0000-4000-8000-000000000001';
  late Directory dir;
  LeasedIncrementalJournal? session;
  late NotificationJournalSnapshot original;
  late String dart;
  setUpAll(() {
    sqfliteFfiInit();
    final config = File('.dart_tool/package_config.json').absolute;
    final packages =
        (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
    final flutter = packages.singleWhere((e) => e['name'] == 'flutter') as Map;
    final sdk = Directory.fromUri(
      config.uri.resolve(flutter['rootUri'] as String),
    ).parent.parent;
    dart =
        '${sdk.path}/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
  });
  setUp(() async {
    dir = Directory(
      await (await Directory.systemTemp.createTemp(
        'leased-journal-',
      )).resolveSymbolicLinks(),
    );
    final legacy = NotificationJournal(dir);
    await legacy.reset(epoch);
    await legacy.begin(
      epoch,
      'synthetic-0',
      action: 'schedule',
      triggerUtcMicros: DateTime.utc(2099).microsecondsSinceEpoch,
      noticeRevision: 0,
      attemptedAt: DateTime.utc(2026, 10, 23),
    );
    original = (await legacy.read())!;
  });
  tearDown(() async {
    await session?.close();
    session = null;
    await dir.delete(recursive: true);
  });
  NotificationJournalEntry updated() => NotificationJournalEntry.decode({
    ...original.entries.values.single.toJson(),
    'status': 'failed',
    'attempts': 2,
  });

  test(
    'migration keeps original v1 and rollback exports latest durable IDs',
    () async {
      final v1 = File('${dir.path}/${NotificationJournal.fileName}');
      final bytes = await v1.readAsBytes();
      session = await LeasedIncrementalJournal.acquire(dir);
      await session!.migrate();
      expect(await v1.readAsBytes(), bytes);
      await session!.append(epoch, [updated()]);
      final latest = (await session!.read())!;
      await session!.rollback();
      expect((await session!.read())!.toJson(), latest.toJson());
      expect(
        (await NotificationJournal(dir).read())!.toJson(),
        latest.toJson(),
      );
      expect(
        await File('${session!.managed.path}/source-v1.json').readAsBytes(),
        bytes,
      );
      expect(
        latest.entries.values.single.nativeId,
        original.entries.values.single.nativeId,
      );
      await session!.close();
      session = await LeasedIncrementalJournal.acquire(dir);
      await session!.migrate();
      expect((await session!.read())!.toJson(), latest.toJson());
    },
  );

  test(
    'SQL and incremental sessions cannot own the same process directory',
    () async {
      session = await LeasedIncrementalJournal.acquire(dir);
      final helper = DatabaseHelper.forTesting(dir.path, databaseFactoryFfi);
      await expectLater(
        helper.acquireOwnership(),
        throwsA(isA<DatabaseAccessException>()),
      );
      await helper.close(createBackup: false);
      expect((await session!.read())!.toJson(), original.toJson());
      await session!.close();
      session = null;
      await helper.acquireOwnership();
      await expectLater(
        LeasedIncrementalJournal.acquire(dir),
        throwsA(isA<FileSystemException>()),
      );
      await helper.close(createBackup: false);
      session = await LeasedIncrementalJournal.acquire(dir);
    },
  );

  test('directory budget refusal keeps v1 authoritative', () async {
    session = await LeasedIncrementalJournal.acquire(
      dir,
      maxDirectoryBytes: 4096,
    );
    await expectLater(session!.migrate(), throwsStateError);
    expect(
      await File(
        '${dir.path}/${LeasedIncrementalJournal.selectorName}',
      ).exists(),
      isFalse,
    );
    expect(
      (await NotificationJournal(dir).read())!.toJson(),
      original.toJson(),
    );
  });

  test(
    'repeated checkpoints keep current and previous generations only',
    () async {
      session = await LeasedIncrementalJournal.acquire(
        dir,
        checkpointEveryFrames: 1,
      );
      await session!.migrate();
      final unknown = File('${session!.managed.path}/retained-by-user.txt');
      await unknown.writeAsString('keep');
      for (var i = 0; i < 8; i++) {
        await session!.append(epoch, [updated()]);
      }
      final files = await session!.managed.list().toList();
      expect(
        files.where(
          (f) => RegExp(r'/[0-9a-f-]{36}\.(json|log)$').hasMatch(f.path),
        ),
        hasLength(4),
      );
      expect(await unknown.readAsString(), 'keep');
      await session!.close();
      session = await LeasedIncrementalJournal.acquire(dir);
      expect(
        (await session!.read())!.entries.values.single.toJson(),
        updated().toJson(),
      );
    },
  );

  test(
    'selected corrupt incremental state never falls back to valid v1',
    () async {
      session = await LeasedIncrementalJournal.acquire(dir);
      await session!.migrate();
      await session!.close();
      session = null;
      final managed = Directory('${dir.path}/notification-incremental');
      final manifest =
          jsonDecode(await File('${managed.path}/current.json').readAsString())
              as Map;
      await File(
        '${managed.path}/${manifest['generation']}.log',
      ).writeAsString('corrupt\n');
      await expectLater(
        LeasedIncrementalJournal.acquire(dir),
        throwsA(anything),
      );
      expect(
        (await NotificationJournal(dir).read())!.toJson(),
        original.toJson(),
      );
      final lease = await StorageDirectoryLease.acquire(dir);
      await lease.close();
    },
  );

  test('rollback input conflict is preserved instead of overwritten', () async {
    session = await LeasedIncrementalJournal.acquire(dir);
    await session!.migrate();
    await session!.append(epoch, [updated()]);
    session!.hook = (point) async {
      if (point == 'rollback_intent') throw StateError('interrupt');
    };
    await expectLater(session!.rollback(), throwsStateError);
    await session!.close();
    session = null;
    final v1 = File('${dir.path}/${NotificationJournal.fileName}');
    await v1.writeAsString('external edit');
    await expectLater(
      LeasedIncrementalJournal.acquire(dir),
      throwsFormatException,
    );
    expect(await v1.readAsString(), 'external edit');
    expect(
      await File('${dir.path}/${LeasedIncrementalJournal.intentName}').exists(),
      isTrue,
    );
  });

  test(
    'reclamation refuses linked files without following or deleting them',
    () async {
      session = await LeasedIncrementalJournal.acquire(dir);
      await session!.migrate();
      final target = File('${dir.path}/sentinel');
      await target.writeAsString('keep');
      await Link('${session!.managed.path}/untrusted').create(target.path);
      await expectLater(session!.collect(), throwsFormatException);
      expect(await target.readAsString(), 'keep');
    },
    skip: Platform.isWindows,
  );

  test('segment capacity rotates without changing identity', () async {
    session = await LeasedIncrementalJournal.acquire(
      dir,
      maxLogBytes: 1024,
      maxFrameBytes: 1024,
    );
    await session!.migrate();
    for (var i = 0; i < 8; i++) {
      await session!.append(epoch, [updated()]);
    }
    await session!.close();
    session = await LeasedIncrementalJournal.acquire(dir);
    expect(
      (await session!.read())!.entries.values.single.toJson(),
      updated().toJson(),
    );
  });

  test('a torn tail is checkpointed before the next append', () async {
    session = await LeasedIncrementalJournal.acquire(dir);
    await session!.migrate();
    await session!.append(epoch, [updated()]);
    final managed = session!.managed;
    await session!.close();
    session = null;
    final selected =
        jsonDecode(await File('${managed.path}/current.json').readAsString())
            as Map;
    await File(
      '${managed.path}/${selected['generation']}.log',
    ).writeAsString('torn', mode: FileMode.append);
    session = await LeasedIncrementalJournal.acquire(dir);
    await session!.append(epoch, [updated()]);
    await session!.close();
    session = await LeasedIncrementalJournal.acquire(dir);
    expect(
      (await session!.read())!.entries.values.single.toJson(),
      updated().toJson(),
    );
  });

  test(
    'v1 product refuses an incremental selection until latest-state rollback',
    () async {
      session = await LeasedIncrementalJournal.acquire(dir);
      await session!.migrate();
      await session!.append(epoch, [updated()]);
      await session!.close();
      session = null;
      final helper = DatabaseHelper.forTesting(dir.path, databaseFactoryFfi);
      await expectLater(
        helper.acquireOwnership(),
        throwsA(isA<DatabaseRecoveryRequiredException>()),
      );
      await helper.close(createBackup: false);
      session = await LeasedIncrementalJournal.acquire(dir);
      await session!.rollback();
      await session!.close();
      session = null;
      await helper.acquireOwnership();
      expect(
        (await helper.withNotificationJournal(
          (j) => j.read(),
        ))!.entries.values.single.toJson(),
        updated().toJson(),
      );
      await helper.close(createBackup: false);
    },
  );

  test('rollback refuses v1 changes made outside the held lease', () async {
    session = await LeasedIncrementalJournal.acquire(dir);
    await session!.migrate();
    final v1 = File('${dir.path}/${NotificationJournal.fileName}');
    await v1.writeAsString('external edit');
    await expectLater(session!.rollback(), throwsFormatException);
    expect(await v1.readAsString(), 'external edit');
    expect(
      await File('${dir.path}/${LeasedIncrementalJournal.intentName}').exists(),
      isFalse,
    );
  });

  test(
    'zero-byte unknown files cannot bypass the managed entry limit',
    () async {
      session = await LeasedIncrementalJournal.acquire(dir);
      await session!.migrate();
      for (var i = 0; i < LeasedIncrementalJournal.maxManagedFiles; i++) {
        await File('${session!.managed.path}/unknown-$i').create();
      }
      final before = await session!.managed.list().length;
      await expectLater(session!.collect(), throwsFormatException);
      expect(await session!.managed.list().length, before);
      expect(
        (await NotificationJournal(dir).read())!.toJson(),
        original.toJson(),
      );
    },
  );

  Future<void> killAt(String point) async {
    final child = await Process.start(dart, [
      '--packages=.dart_tool/package_config.json',
      'test/fixtures/journal_crash_worker.dart',
      dir.path,
      'leased:$point',
    ]);
    final errors = child.stderr.transform(utf8.decoder).join();
    try {
      final ready = await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 20));
      expect(ready, 'DURABLE_BOUNDARY');
      await expectLater(
        LeasedIncrementalJournal.acquire(dir),
        throwsA(isA<FileSystemException>()),
      );
      expect(child.kill(ProcessSignal.sigkill), isTrue);
      expect(
        await child.exitCode.timeout(const Duration(seconds: 10)),
        isNot(0),
      );
      expect(await errors, isEmpty);
    } finally {
      child.kill(ProcessSignal.sigkill);
    }
  }

  test(
    'OS releases a killed owner lease and leaves lock inode in place',
    () async {
      await killAt('hold');
      expect(
        await File('${dir.path}/${StorageDirectoryLease.lockName}').exists(),
        isTrue,
      );
      session = await LeasedIncrementalJournal.acquire(dir);
      expect((await session!.read())!.toJson(), original.toJson());
    },
  );
  for (final point in ['import_checkpoint', 'import_published']) {
    test('SIGKILL at $point selects one whole migration state', () async {
      await killAt(point);
      session = await LeasedIncrementalJournal.acquire(dir);
      expect((await session!.read())!.toJson(), original.toJson());
      final selected = File(
        '${dir.path}/${LeasedIncrementalJournal.selectorName}',
      );
      expect(await selected.exists(), point == 'import_published');
      if (point == 'import_checkpoint') await session!.migrate();
      await session!.append(epoch, [updated()]);
    });
  }
  for (final point in [
    'rollback_intent',
    'rollback_v1_published',
    'rollback_selected',
    'snapshot_flushed',
    'before_publish',
    'after_publish',
    'generation_removed',
  ]) {
    test('SIGKILL at $point retains latest state and reserved IDs', () async {
      session = await LeasedIncrementalJournal.acquire(dir);
      await session!.migrate();
      await session!.append(epoch, [updated()]);
      final latest = (await session!.read())!;
      if (point == 'generation_removed') {
        await File(
          '${session!.managed.path}/11111111-1111-4111-8111-111111111111.log',
        ).writeAsString('unselected');
      }
      await session!.close();
      session = null;
      await killAt(point);
      session = await LeasedIncrementalJournal.acquire(dir);
      expect((await session!.read())!.toJson(), latest.toJson());
      if (point.startsWith('rollback_')) {
        expect(
          (await NotificationJournal(dir).read())!.toJson(),
          latest.toJson(),
        );
      } else {
        await session!.collect();
      }
    });
  }
}
