import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ControlledFactory implements DatabaseFactory {
  final opened = Completer<void>();
  Completer<void>? releaseOpen;
  bool failClose = false;
  int primaryOpens = 0;
  int primaryCloses = 0;
  bool failBackupOpen = false;

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    final primary = paths.basename(path) == 'dont_forget_v3.db';
    if (!primary && failBackupOpen) {
      throw StateError('synthetic backup failure');
    }
    final database = await databaseFactoryFfi.openDatabase(
      path,
      options: options,
    );
    if (!primary) return database;
    primaryOpens++;
    if (!opened.isCompleted) opened.complete();
    await releaseOpen?.future;
    return _ControlledDatabase(database, this);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ControlledDatabase implements Database {
  _ControlledDatabase(this.delegate, this.factory);
  final Database delegate;
  final _ControlledFactory factory;

  @override
  Future<void> close() async {
    factory.primaryCloses++;
    if (factory.failClose) throw StateError('synthetic close failure');
    await delegate.close();
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) => delegate.transaction(action, exclusive: exclusive);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => delegate.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => delegate.rawQuery(sql, arguments);

  @override
  bool get isOpen => delegate.isOpen;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late _ControlledFactory factory;
  late DatabaseHelper helper;

  Matcher accessError(DatabaseAccessError code) =>
      isA<DatabaseAccessException>().having(
        (error) => error.code,
        'code',
        code,
      );

  Map<String, Object?> reminder(String id) =>
      Reminder(id: id, taskTitle: 'Synthetic task', quadrantLevel: 2).toJson();

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp(
      'dontforget-maintenance-',
    );
    factory = _ControlledFactory();
    helper = DatabaseHelper.forTesting(directory.path, factory);
  });

  tearDown(() async {
    factory.failClose = false;
    factory.failBackupOpen = false;
    await helper.close();
    await directory.delete(recursive: true);
  });

  test(
    'maintenance rejects new work synchronously and drains an in-flight open',
    () async {
      factory.releaseOpen = Completer<void>();
      final generation = helper.captureGeneration();
      final reading = helper.read(generation, (db) => db.query('Settings'));
      await factory.opened.future;
      var granted = false;
      final maintaining = helper.beginMaintenance().then((lease) {
        granted = true;
        return lease;
      });
      expect(helper.isCurrent(generation), isFalse);
      expect(
        helper.captureGeneration,
        throwsA(accessError(DatabaseAccessError.maintenance)),
      );
      expect(
        () => helper.read(generation, (db) => db.query('Settings')),
        throwsA(accessError(DatabaseAccessError.maintenance)),
      );
      expect(
        helper.createMirrorBackup,
        throwsA(accessError(DatabaseAccessError.maintenance)),
      );
      expect(granted, isFalse);
      factory.releaseOpen!.complete();
      expect(await reading, hasLength(1));
      final lease = await maintaining;
      expect(factory.primaryOpens, 1);
      await lease.closeWithoutBackup();
      expect(factory.primaryCloses, 1);
      await lease.resume();
      expect(
        () => helper.read(generation, (db) => db.query('Settings')),
        throwsA(accessError(DatabaseAccessError.staleGeneration)),
      );
      expect(
        await helper.read(
          helper.captureGeneration(),
          (db) => db.query('Settings'),
        ),
        hasLength(1),
      );
      expect(factory.primaryOpens, 2);
    },
  );

  test(
    'accepted transaction completes before maintenance and rejected writes never run',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final generation = helper.captureGeneration();
      final writing = helper.writeTransaction(generation, (txn) async {
        await txn.insert('Reminders', reminder('accepted'));
        entered.complete();
        await release.future;
      });
      await entered.future;
      final maintaining = helper.beginMaintenance();
      var rejectedRan = false;
      expect(
        () => helper.writeTransaction(generation, (txn) async {
          rejectedRan = true;
          await txn.insert('Reminders', reminder('rejected'));
        }),
        throwsA(accessError(DatabaseAccessError.maintenance)),
      );
      release.complete();
      await writing;
      final lease = await maintaining;
      expect(rejectedRan, isFalse);
      await lease.resume();
      final rows = await helper.read(
        helper.captureGeneration(),
        (db) => db.query('Reminders'),
      );
      expect(rows.map((row) => row['id']), ['accepted']);
    },
  );

  test('failing transaction rolls back and cannot prevent drain', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final writing = helper.writeTransaction(helper.captureGeneration(), (
      txn,
    ) async {
      await txn.insert('Reminders', reminder('rolled-back'));
      entered.complete();
      await release.future;
      throw StateError('synthetic transaction failure');
    });
    final failed = expectLater(writing, throwsStateError);
    await entered.future;
    final maintaining = helper.beginMaintenance();
    release.complete();
    await failed;
    final lease = await maintaining;
    await lease.resume();
    expect(
      await helper.read(
        helper.captureGeneration(),
        (db) => db.query('Reminders'),
      ),
      isEmpty,
    );
  });

  test(
    'scope cannot leak a transaction or raw database and drains unawaited SQL',
    () async {
      late Transaction leaked;
      await helper.writeTransaction(helper.captureGeneration(), (txn) async {
        leaked = txn;
        expect(() => txn.database, throwsUnsupportedError);
        unawaited(txn.insert('Reminders', reminder('unawaited')));
      });
      expect(
        () => leaked.insert('Reminders', reminder('late')),
        throwsA(accessError(DatabaseAccessError.expiredScope)),
      );
      final rows = await helper.read(helper.captureGeneration(), (db) async {
        expect(
          () => db.insert('Reminders', reminder('read-write')),
          throwsStateError,
        );
        return db.query('Reminders');
      });
      expect(rows.map((row) => row['id']), ['unawaited']);
    },
  );

  test(
    'unawaited failed SQL rolls back the transaction and releases admission',
    () async {
      await expectLater(
        helper.writeTransaction(helper.captureGeneration(), (txn) async {
          await txn.insert('Reminders', reminder('duplicate'));
          unawaited(txn.insert('Reminders', reminder('duplicate')));
        }),
        throwsA(isA<DatabaseException>()),
      );
      final lease = await helper.beginMaintenance();
      await lease.resume();
      expect(
        await helper.read(
          helper.captureGeneration(),
          (db) => db.query('Reminders'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'non-SQL operations drain and nested admitted SQL may finish after gate closes',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final generation = helper.captureGeneration();
      final running = helper.runOperation(generation, () async {
        entered.complete();
        await release.future;
        await helper.writeTransaction(
          generation,
          (txn) => txn.insert('Reminders', reminder('nested')),
        );
      });
      await entered.future;
      expect(factory.primaryOpens, 0);
      final maintaining = helper.beginMaintenance();
      release.complete();
      await running;
      final lease = await maintaining;
      await lease.resume();
      expect(
        await helper.read(
          helper.captureGeneration(),
          (db) => db.query('Reminders'),
        ),
        hasLength(1),
      );
    },
  );

  test(
    'an async callback inherited from a completed operation cannot reuse its old admission',
    () async {
      final release = Completer<void>();
      late Future<void> lateOperation;
      final generation = helper.captureGeneration();
      await helper.runOperation(generation, () async {
        lateOperation = release.future.then((_) async {
          await helper.writeTransaction(
            generation,
            (txn) => txn.insert('Reminders', reminder('late')),
          );
        });
      });
      final lease = await helper.beginMaintenance();
      await lease.resume();
      final failed = expectLater(
        lateOperation,
        throwsA(accessError(DatabaseAccessError.staleGeneration)),
      );
      release.complete();
      await failed;
      expect(factory.primaryOpens, 0);
    },
  );

  test(
    'maintenance close preserves backup artifacts and retains directory ownership',
    () async {
      await helper.read(
        helper.captureGeneration(),
        (db) => db.query('Settings'),
      );
      final mirror = File(
        paths.join(directory.path, 'dont_forget_v3.mirror.db'),
      );
      final snapshot = File(paths.join(directory.path, 'ha_snapshot.json'));
      await mirror.writeAsString('synthetic previous mirror');
      await snapshot.writeAsString('synthetic previous snapshot');
      final lease = await helper.beginMaintenance();
      await lease.closeWithoutBackup();
      expect(await mirror.readAsString(), 'synthetic previous mirror');
      expect(await snapshot.readAsString(), 'synthetic previous snapshot');
      final contender = DatabaseHelper.forTesting(
        directory.path,
        databaseFactoryFfi,
      );
      await expectLater(
        contender.acquireOwnership(),
        throwsA(accessError(DatabaseAccessError.ownedByAnotherProcess)),
      );
      await contender.close();
      await lease.resume();
      await helper.close();
      await contender.acquireOwnership();
      await contender.close();
    },
  );

  test(
    'failed maintenance close keeps the gate faulted and close only releases resources',
    () async {
      await helper.read(
        helper.captureGeneration(),
        (db) => db.query('Settings'),
      );
      final lease = await helper.beginMaintenance();
      factory.failClose = true;
      await expectLater(lease.closeWithoutBackup(), throwsStateError);
      expect(
        helper.captureGeneration,
        throwsA(accessError(DatabaseAccessError.faulted)),
      );
      await expectLater(
        lease.resume(),
        throwsA(accessError(DatabaseAccessError.faulted)),
      );
      factory.failClose = false;
      await helper.close();
      expect(
        helper.captureGeneration,
        throwsA(accessError(DatabaseAccessError.faulted)),
      );
      expect(
        await File(
          paths.join(directory.path, 'dont_forget_v3.mirror.db'),
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'explicit failure preserves journal and does not write a backup during shutdown',
    () async {
      await helper.read(
        helper.captureGeneration(),
        (db) => db.query('Settings'),
      );
      final lease = await helper.beginMaintenance();
      final journal = File(
        paths.join(lease.directory, 'recovery.pending.json'),
      );
      await journal.writeAsString('synthetic interruption');
      lease.fail();
      await helper.close();
      expect(await journal.readAsString(), 'synthetic interruption');
      expect(
        await File(paths.join(directory.path, 'ha_snapshot.json')).exists(),
        isFalse,
      );
      final restarted = DatabaseHelper.forTesting(
        directory.path,
        databaseFactoryFfi,
      );
      await expectLater(
        restarted.read(
          restarted.captureGeneration(),
          (db) => db.query('Settings'),
        ),
        throwsA(isA<DatabaseRecoveryRequiredException>()),
      );
      await restarted.close();
    },
  );

  test(
    'startup journal prevents creation but maintenance can validate before explicit resume',
    () async {
      final owned = await helper.acquireOwnership();
      expect(factory.primaryOpens, 0);
      final journal = File(paths.join(owned, 'recovery.pending.json'));
      await journal.writeAsString('{}');
      await expectLater(
        helper.read(helper.captureGeneration(), (db) => db.query('Settings')),
        throwsA(isA<DatabaseRecoveryRequiredException>()),
      );
      expect(factory.primaryOpens, 0);
      expect(
        await File(paths.join(owned, 'dont_forget_v3.db')).exists(),
        isFalse,
      );
      final lease = await helper.beginMaintenance();
      await expectLater(lease.validateAndOpen(), throwsStateError);
      expect(await File(lease.path).exists(), isFalse);
      final staging = await Directory(
        paths.join(lease.directory, 'recovery-startup'),
      ).create();
      final candidate = paths.join(staging.path, 'candidate.db');
      await lease.createCandidateFromRows(candidate, {
        'Settings': [],
        'MediaRecords': [],
        'Reminders': [],
      });
      await File(candidate).rename(lease.path);
      await lease.validateAndOpen();
      await expectLater(
        lease.resume(),
        throwsA(isA<DatabaseRecoveryRequiredException>()),
      );
      expect(
        helper.captureGeneration,
        throwsA(accessError(DatabaseAccessError.maintenance)),
      );
      await journal.delete();
      await lease.resume();
      await expectLater(
        lease.resume(),
        throwsA(accessError(DatabaseAccessError.expiredScope)),
      );
    },
  );

  test(
    'ordinary close drains, rejects racing reopen, then preserves normal reopen behavior',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final generation = helper.captureGeneration();
      final writing = helper.writeTransaction(generation, (txn) async {
        await txn.insert('Reminders', reminder('normal-close'));
        entered.complete();
        await release.future;
      });
      await entered.future;
      final closing = helper.close();
      expect(
        () => helper.read(generation, (db) => db.query('Settings')),
        throwsA(accessError(DatabaseAccessError.maintenance)),
      );
      release.complete();
      await writing;
      await closing;
      expect(
        await File(paths.join(directory.path, 'ha_snapshot.json')).exists(),
        isTrue,
      );
      expect(
        await helper.read(
          helper.captureGeneration(),
          (db) => db.query('Reminders'),
        ),
        hasLength(1),
      );
    },
  );

  test(
    'in-flight backup failure still drains before a maintenance lease is granted',
    () async {
      factory.releaseOpen = Completer<void>();
      factory.failBackupOpen = true;
      final backup = helper.createMirrorBackup();
      final failed = expectLater(backup, throwsStateError);
      await factory.opened.future;
      final maintaining = helper.beginMaintenance();
      factory.releaseOpen!.complete();
      await failed;
      final lease = await maintaining;
      factory.failBackupOpen = false;
      await lease.closeWithoutBackup();
      await lease.resume();
    },
  );

  test(
    'candidate creation reuses schema without opening or replacing the main database',
    () async {
      final lease = await helper.beginMaintenance();
      final staging = await Directory(
        paths.join(lease.directory, 'recovery-test'),
      ).create();
      final candidate = paths.join(staging.path, 'candidate.db');
      await lease.createCandidateFromRows(candidate, {
        'Settings': [],
        'MediaRecords': [],
        'Reminders': [reminder('candidate')],
      });
      await lease.validateCandidate(candidate);
      expect(factory.primaryOpens, 0);
      expect(await File(lease.path).exists(), isFalse);
      await expectLater(
        lease.createCandidateFromRows(candidate, {
          'Settings': [],
          'MediaRecords': [],
          'Reminders': [],
        }),
        throwsStateError,
      );
      await expectLater(lease.validateCandidate(lease.path), throwsStateError);
      await lease.resume();
    },
  );

  test(
    'candidate batches retain all rows and roll back earlier batches on failure',
    () async {
      final lease = await helper.beginMaintenance();
      final staging = await Directory(
        paths.join(lease.directory, 'recovery-batches'),
      ).create();
      final rows = [for (var i = 0; i < 1001; i++) reminder('batch-$i')];
      final candidate = paths.join(staging.path, 'complete.db');
      await lease.createCandidateFromRows(candidate, {
        'Settings': [],
        'MediaRecords': [],
        'Reminders': rows,
      });
      final complete = await databaseFactoryFfi.openDatabase(candidate);
      try {
        expect(
          await complete.query('Reminders', orderBy: 'id'),
          [...rows]
            ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String)),
        );
      } finally {
        await complete.close();
      }
      final failed = paths.join(staging.path, 'failed.db');
      await expectLater(
        lease.createCandidateFromRows(failed, {
          'Settings': [],
          'MediaRecords': [],
          // The duplicate is in the third chunk, after two batch commits.
          'Reminders': [...rows.take(1000), reminder('batch-0')],
        }),
        throwsA(isA<DatabaseException>()),
      );
      final rolledBack = await databaseFactoryFfi.openDatabase(failed);
      try {
        expect(await rolledBack.query('Reminders'), isEmpty);
        expect(await rolledBack.rawQuery('PRAGMA integrity_check'), [
          {'integrity_check': 'ok'},
        ]);
      } finally {
        await rolledBack.close();
      }
      expect(factory.primaryOpens, 0);
      expect(await File(lease.path).exists(), isFalse);
      await lease.resume();
    },
  );

  test(
    'explicit shutdown without backup preserves artifacts and releases ownership',
    () async {
      final generation = helper.captureGeneration();
      await helper.read(generation, (db) => db.query('Settings'));
      final mirror = File(
        paths.join(directory.path, 'dont_forget_v3.mirror.db'),
      );
      final snapshot = File(paths.join(directory.path, 'ha_snapshot.json'));
      await mirror.writeAsString('existing independent mirror');
      await snapshot.writeAsString('existing independent snapshot');
      final mirrorBefore = await mirror.readAsBytes();
      final snapshotBefore = await snapshot.readAsBytes();
      await helper.close(createBackup: false);
      expect(await mirror.readAsBytes(), mirrorBefore);
      expect(await snapshot.readAsBytes(), snapshotBefore);
      expect(factory.primaryCloses, 1);
      expect(helper.isCurrent(generation), isFalse);
      final next = DatabaseHelper.forTesting(
        directory.path,
        databaseFactoryFfi,
      );
      try {
        await next.acquireOwnership();
        expect(
          await next.read(
            next.captureGeneration(),
            (db) => db.query('Settings'),
          ),
          hasLength(1),
        );
      } finally {
        await next.close(createBackup: false);
      }
      expect(await mirror.readAsBytes(), mirrorBefore);
      expect(await snapshot.readAsBytes(), snapshotBefore);
    },
  );

  test('a generation from another helper is never accepted', () async {
    final other = DatabaseHelper.forTesting(
      paths.join(directory.path, 'other'),
      databaseFactoryFfi,
    );
    expect(
      () =>
          helper.read(other.captureGeneration(), (db) => db.query('Settings')),
      throwsA(accessError(DatabaseAccessError.staleGeneration)),
    );
    expect(factory.primaryOpens, 0);
    await other.close();
  });

  test(
    'maintenance reads require validation and cannot leak an executor',
    () async {
      await helper.read(
        helper.captureGeneration(),
        (db) => db.query('Settings'),
      );
      final lease = await helper.beginMaintenance();
      await expectLater(
        lease.read((db) => db.query('Settings')),
        throwsStateError,
      );
      await lease.validateAndOpen();
      late DatabaseExecutor escaped;
      final rows = await lease.read((db) async {
        escaped = db;
        return db.query('Settings');
      });
      expect(rows, hasLength(1));
      expect(
        () => escaped.query('Settings'),
        throwsA(accessError(DatabaseAccessError.expiredScope)),
      );
      expect(
        helper.captureGeneration,
        throwsA(accessError(DatabaseAccessError.maintenance)),
      );
      await lease.closeWithoutBackup();
      await expectLater(
        lease.read((db) => db.query('Settings')),
        throwsStateError,
      );
      await lease.resume();
    },
  );

  test(
    'read rawQuery rejects disguised writes and state-changing pragmas',
    () async {
      await helper.read(helper.captureGeneration(), (db) async {
        expect(
          () => db.rawQuery("DELETE FROM Settings RETURNING id"),
          throwsStateError,
        );
        expect(() => db.rawQuery('PRAGMA user_version = 99'), throwsStateError);
        expect(() => db.rawQuery('PRAGMA user_version(99)'), throwsStateError);
        expect(
          () => db.rawQuery('SELECT 1; DELETE FROM Settings'),
          throwsStateError,
        );
        expect(
          (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
          'ok',
        );
        expect(
          (await db.rawQuery('PRAGMA user_version')).single.values.single,
          DatabaseHelper.schemaVersion,
        );
        expect(await db.rawQuery("PRAGMA table_info('Settings')"), isNotEmpty);
        expect(await db.rawQuery('SELECT * FROM Settings'), hasLength(1));
      });
    },
  );

  test(
    'process ownership rejects a second process before any database creation',
    () async {
      final packageConfig =
          jsonDecode(
                await File('.dart_tool/package_config.json').readAsString(),
              )
              as Map;
      final flutterPackage = (packageConfig['packages'] as List)
          .cast<Map>()
          .firstWhere((entry) => entry['name'] == 'flutter');
      final root = File(
        '.dart_tool/package_config.json',
      ).absolute.uri.resolve(flutterPackage['rootUri'] as String).toFilePath();
      final dart = paths.normalize(
        paths.join(
          root,
          '..',
          '..',
          'bin',
          'cache',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        ),
      );
      final script = File(paths.join(directory.path, 'lock_holder.dart'));
      await script.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final file = await File(args.single).open(mode: FileMode.append);
  await file.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.first;
  await file.close();
}
''');
      final lockPath = paths.join(directory.path, '.dontforget.owner.lock');
      final child = await Process.start(dart, [script.path, lockPath]);
      final stderrFuture = child.stderr.transform(utf8.decoder).join();
      try {
        expect(
          await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
          'locked',
        );
        await expectLater(
          helper.acquireOwnership(),
          throwsA(accessError(DatabaseAccessError.ownedByAnotherProcess)),
        );
        expect(
          await File(paths.join(directory.path, 'dont_forget_v3.db')).exists(),
          isFalse,
        );
        child.stdin.writeln('release');
        await child.stdin.flush();
        expect(await child.exitCode, 0);
        expect(await stderrFuture, isEmpty);
        await helper.acquireOwnership();
      } finally {
        child.kill();
        await child.stdin.close();
        await child.exitCode;
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
