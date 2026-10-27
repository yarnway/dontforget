import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/recovery/storage_bootstrap.dart';
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
  List<Reminder> finalReminders = [];
  bool failRebuild = false;
  @override
  Future<void> pauseForMaintenance() async {}
  @override
  Future<void> resumeFromReminders(Iterable<Reminder> reminders) async {
    if (failRebuild) throw StateError('Synthetic native rebuild failure');
    finalReminders = reminders.toList();
  }
}

class _OpenTrackingFactory implements DatabaseFactory {
  final List<OpenDatabaseOptions?> opens = [];
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) {
    opens.add(options);
    return databaseFactoryFfi.openDatabase(path, options: options);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _noticeDefaults = <String, Object?>{
  'notice_revision': 0,
  'notice_acknowledged_at': null,
  'upcoming_dismissed_at': null,
  'snoozed_at': null,
  'recurrence_anchor_time': null,
};

void main() {
  late Directory directory;
  late DatabaseHelper live;
  late BackupInspector inspector;
  late _Notifications notifications;

  Map<String, Object?> task({bool legacy = false}) {
    final instant = DateTime.utc(2030, 1, 31, 9);
    final row = Reminder(
      id: 'restored',
      taskTitle: 'Synthetic restored task',
      quadrantLevel: 2,
      createdAt: instant,
      triggerTime: instant,
      isRecurring: true,
      recurrenceRule: 'monthly',
      noticeRevision: 5,
      noticeAcknowledgedAt: instant,
      upcomingDismissedAt: instant,
      snoozedAt: instant,
      recurrenceAnchorTime: DateTime.utc(2030, 1, 31, 8),
    ).toJson();
    if (legacy) row.removeWhere((key, _) => _noticeDefaults.containsKey(key));
    return row;
  }

  Future<File> source(int version, String format, {String? date}) async {
    final row = task(legacy: version < 9);
    row.remove('review_notifications_enabled');
    row.remove('trigger_time_origin');
    if (date != null) {
      for (final field in [
        'trigger_time',
        'created_at',
        'next_review_at',
        if (version == 9)
          ..._noticeDefaults.keys.where((key) => key != 'notice_revision'),
      ]) {
        row[field] = date;
      }
      row['record_id'] = 'dated-media';
    }
    final tables = <String, List<Map<String, Object?>>>{
      'settings': [
        AppSettings.defaults().toJson()
          ..remove('ai_profiles_json')
          ..remove('ai_fallback_enabled')
          ..remove('appearance')
          ..remove('input_send_mode'),
      ],
      'media_records': [
        if (date != null)
          {
            'id': 'dated-media',
            'type': 'text',
            'content_or_path': 'Synthetic text',
            'created_at': date,
          },
      ],
      'reminders': [row],
    };
    if (format == 'json') {
      return File(
        p.join(directory.path, 'source-v$version.json'),
      ).writeAsString(
        jsonEncode({'version': version, 'timestamp': date, ...tables}),
      );
    }
    final path = p.join(directory.path, 'source-v$version.db');
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onCreate: (db, _) async {
          final schema = await File(
            'test/fixtures/schema_v8.sql',
          ).readAsString();
          for (final sql in schema.split(';')) {
            if (sql.trim().isNotEmpty) await db.execute(sql);
          }
          if (version == 9) {
            await db.execute(
              'ALTER TABLE Reminders ADD COLUMN notice_revision INTEGER NOT NULL DEFAULT 0',
            );
            for (final key in _noticeDefaults.keys.where(
              (key) => key != 'notice_revision',
            )) {
              await db.execute('ALTER TABLE Reminders ADD COLUMN $key TEXT');
            }
          }
          for (final pair in const {
            'Settings': 'settings',
            'MediaRecords': 'media_records',
            'Reminders': 'reminders',
          }.entries) {
            for (final row in tables[pair.value]!) {
              await db.insert(pair.key, row);
            }
          }
        },
      ),
    );
    await db.close();
    return File(path);
  }

  setUp(() async {
    sqfliteFfiInit();
    final raw = await Directory.systemTemp.createTemp('dontforget-schema9-');
    directory = Directory(await raw.resolveSymbolicLinks());
    live = DatabaseHelper.forTesting(
      p.join(directory.path, 'live'),
      databaseFactoryFfi,
    );
    inspector = BackupInspector(databaseFactoryFfi);
    notifications = _Notifications();
    await live.database;
  });

  tearDown(() async {
    await live.close(createBackup: false);
    await directory.delete(recursive: true);
  });

  for (final version in [7, 8, 9]) {
    for (final format in ['json', 'sqlite']) {
      test(
        'v$version $format restores into v9 and preserves source and notice state',
        () async {
          final input = await source(version, format);
          final before = sha256.convert(await input.readAsBytes());
          final preview = await inspector.inspect(input);
          expect(preview.version, version);
          final recovery = DatabaseRecovery(
            live,
            inspector: inspector,
            notifications: notifications,
          );
          await recovery.restore(input, expectedDigest: preview.digest);
          final db = await live.database;
          expect(await db.getVersion(), DatabaseHelper.schemaVersion);
          final row = (await db.query('Reminders')).single;
          expect(
            row,
            version == 9 ? task() : {...task(legacy: true), ..._noticeDefaults},
          );
          expect(
            notifications.finalReminders.single.noticeRevision,
            version == 9 ? 5 : 0,
          );
          expect(sha256.convert(await input.readAsBytes()), before);
          await live.createMirrorBackup();
          for (final name in ['ha_snapshot.json', 'dont_forget_v3.mirror.db']) {
            final backup = File(p.join(directory.path, 'live', name));
            expect(
              (await inspector.inspect(backup)).version,
              DatabaseHelper.schemaVersion,
            );
          }
        },
      );
    }
  }

  for (final version in [7, 8, 9]) {
    for (final format in ['json', 'sqlite']) {
      for (final date in [
        '2032-02-29t09:30:00.123456789z',
        '2032-02-29T17:30:00.1234567+0800',
        '2032-02-29t09:30:00.1Z',
      ]) {
        test(
          'v$version $format accepted timestamp survives full restore: $date',
          () async {
            final input = await source(version, format, date: date);
            final bytes = await input.readAsBytes();
            final preview = await inspector.inspect(input);
            await DatabaseRecovery(
              live,
              inspector: inspector,
              notifications: notifications,
            ).restore(input, expectedDigest: preview.digest);
            final restored = notifications.finalReminders.single;
            final expected = date.endsWith('.1Z')
                ? DateTime.utc(2032, 2, 29, 9, 30, 0, 100)
                : DateTime.utc(2032, 2, 29, 9, 30, 0, 123, 456);
            expect(restored.triggerTime, expected);
            expect(restored.createdAt, expected);
            expect(restored.nextReviewAt, expected);
            expect(
              restored.noticeAcknowledgedAt,
              version == 9 ? expected : isNull,
            );
            expect(
              restored.recurrenceAnchorTime,
              version == 9 ? expected : isNull,
            );
            await StorageBootstrap(live).prepare();
            expect(await input.readAsBytes(), bytes);
            expect(
              await File(
                p.join(directory.path, 'live', DatabaseRecovery.journalName),
              ).exists(),
              isFalse,
            );
            await live.createMirrorBackup();
            expect(
              (await inspector.inspect(
                File(p.join(directory.path, 'live', 'ha_snapshot.json')),
              )).version,
              DatabaseHelper.schemaVersion,
            );
          },
        );
      }
    }
  }

  test('v8 JSON cannot smuggle v9 occurrence metadata', () async {
    final input = await source(8, 'json');
    final decoded = jsonDecode(await input.readAsString()) as Map;
    (decoded['reminders'] as List).single['notice_revision'] = 1;
    await input.writeAsString(jsonEncode(decoded));
    await expectLater(
      inspector.inspect(input),
      throwsA(
        isA<BackupInspectionException>().having(
          (error) => error.code,
          'code',
          BackupInspectionError.invalidSchema,
        ),
      ),
    );
  });

  test('v9 cannot omit any occurrence metadata column', () async {
    final input = await source(9, 'json');
    final baseline = await input.readAsString();
    for (final key in _noticeDefaults.keys) {
      final decoded = jsonDecode(baseline) as Map;
      (decoded['reminders'] as List).single.remove(key);
      await input.writeAsString(jsonEncode(decoded));
      await expectLater(
        inspector.inspect(input),
        throwsA(
          isA<BackupInspectionException>().having(
            (error) => error.code,
            'code',
            BackupInspectionError.invalidSchema,
          ),
        ),
      );
    }
  });

  test('v9 rejects invalid revision and malformed notice dates', () async {
    final input = await source(9, 'json');
    final baseline = await input.readAsString();
    for (final entry in <String, List<Object?>>{
      'notice_revision': [-1, null, 0.5, '2'],
      for (final key in _noticeDefaults.keys.where(
        (key) => key != 'notice_revision',
      ))
        key: ['2026-02-30T00:00:00Z', 1, 'invalid'],
    }.entries) {
      for (final value in entry.value) {
        final decoded = jsonDecode(baseline) as Map;
        (decoded['reminders'] as List).single[entry.key] = value;
        await input.writeAsString(jsonEncode(decoded));
        await expectLater(
          inspector.inspect(input),
          throwsA(
            isA<BackupInspectionException>().having(
              (error) => error.code,
              'code',
              BackupInspectionError.invalidData,
            ),
          ),
        );
      }
    }
  });

  test('v9 SQLite must use non-null revision with zero default', () async {
    final input = await source(9, 'sqlite');
    final db = await databaseFactoryFfi.openDatabase(input.path);
    await db.execute('PRAGMA writable_schema = ON');
    await db.execute(
      "UPDATE sqlite_master SET sql = replace(sql, 'notice_revision INTEGER NOT NULL DEFAULT 0', 'notice_revision INTEGER DEFAULT 1') WHERE name='Reminders'",
    );
    await db.close();
    await expectLater(
      inspector.inspect(input),
      throwsA(
        isA<BackupInspectionException>().having(
          (error) => error.code,
          'code',
          BackupInspectionError.invalidSchema,
        ),
      ),
    );
  });

  test(
    'startup rejects persisted invalid notice revision before providers start',
    () async {
      final db = await live.database;
      await db.insert('Reminders', task()..['notice_revision'] = -1);
      await expectLater(
        StorageBootstrap(live).prepare(),
        throwsFormatException,
      );
    },
  );

  for (final state in ['committed', 'rollingBack']) {
    test(
      'v8 $state journal survives two failed rebuilds before v9 upgrade',
      () async {
        await live.close(createBackup: false);
        final input = await source(8, 'sqlite');
        final appDirectory = p.join(directory.path, 'live');
        const operationId = '00000000-0000-4000-8000-000000000001';
        final operation = await Directory(
          p.join(appDirectory, 'recovery-$operationId'),
        ).create();
        final rollback = await input.copy(
          p.join(operation.path, 'rollback.db'),
        );
        final oldDigest = sha256
            .convert(await rollback.readAsBytes())
            .toString();
        final candidate = await input.copy(
          p.join(operation.path, 'candidate.db'),
        );
        final candidateDb = await databaseFactoryFfi.openDatabase(
          candidate.path,
        );
        await candidateDb.update('Reminders', {
          'task_title': 'Committed synthetic task',
        });
        await candidateDb.close();
        final newDigest = sha256
            .convert(await candidate.readAsBytes())
            .toString();
        final primary = await candidate.copy(
          p.join(appDirectory, 'dont_forget_v3.db'),
        );
        final pending = File(
          p.join(appDirectory, DatabaseRecovery.journalName),
        );
        await pending.writeAsString(
          jsonEncode({
            'version': 1,
            'operationId': operationId,
            'oldDigest': oldDigest,
            'newDigest': newDigest,
            'state': state,
          }),
        );
        List<int>? retainedJournal;
        for (var attempt = 0; attempt < 2; attempt++) {
          live = DatabaseHelper.forTesting(appDirectory, databaseFactoryFfi);
          notifications.failRebuild = true;
          await expectLater(
            DatabaseRecovery(
              live,
              notifications: notifications,
            ).recoverInterrupted(),
            throwsA(isA<DatabaseRecoveryException>()),
          );
          await live.close(createBackup: false);
          expect(
            sha256.convert(await primary.readAsBytes()).toString(),
            state == 'committed' ? newDigest : oldDigest,
          );
          final journal = await pending.readAsBytes();
          if (retainedJournal != null) expect(journal, retainedJournal);
          retainedJournal = journal;
          final recorded = jsonDecode(utf8.decode(journal)) as Map;
          expect(recorded['oldDigest'], oldDigest);
          expect(recorded['newDigest'], newDigest);
          final check = await databaseFactoryFfi.openDatabase(
            primary.path,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          expect(await check.getVersion(), 8);
          await check.close();
        }
        live = DatabaseHelper.forTesting(appDirectory, databaseFactoryFfi);
        notifications.failRebuild = false;
        await DatabaseRecovery(
          live,
          notifications: notifications,
        ).recoverInterrupted();
        await StorageBootstrap(live).prepare();
        final finalDb = await live.database;
        expect(await finalDb.getVersion(), DatabaseHelper.schemaVersion);
        final row = (await finalDb.query('Reminders')).single;
        expect(row['notice_revision'], 0);
        expect(
          row['task_title'],
          state == 'committed'
              ? 'Committed synthetic task'
              : 'Synthetic restored task',
        );
        expect(await pending.exists(), isFalse);
        expect(
          await File(
            p.join(
              operation.path,
              state == 'committed' ? 'completed.json' : 'rolled-back.json',
            ),
          ).exists(),
          isTrue,
        );
      },
    );
  }

  test(
    'a legacy validation cannot reopen normal business access before upgrade',
    () async {
      await live.close(createBackup: false);
      final input = await source(8, 'sqlite');
      await input.copy(p.join(directory.path, 'live', 'dont_forget_v3.db'));
      final tracking = _OpenTrackingFactory();
      live = DatabaseHelper.forTesting(
        p.join(directory.path, 'live'),
        tracking,
      );
      final lease = await live.beginMaintenance();
      await lease.validateAndOpen(migrate: false);
      expect(tracking.opens.single!.readOnly, isTrue);
      expect(tracking.opens.single!.version, isNull);
      await expectLater(lease.resume(), throwsStateError);
      await lease.closeWithoutBackup();
      await lease.validateAndOpen();
      expect(tracking.opens.last!.readOnly, isFalse);
      expect(tracking.opens.last!.version, DatabaseHelper.schemaVersion);
      await lease.resume();
      expect(
        await (await live.database).getVersion(),
        DatabaseHelper.schemaVersion,
      );
    },
  );

  test(
    'v8 migration failures retain the complete old schema and version',
    () async {
      final input = await source(8, 'sqlite');
      final db = await databaseFactoryFfi.openDatabase(input.path);
      await db.execute('ALTER TABLE Reminders ADD COLUMN snoozed_at TEXT');
      await db.close();
      final targetDirectory = await Directory(
        p.join(directory.path, 'migration'),
      ).create();
      final target = await input.copy(
        p.join(targetDirectory.path, 'dont_forget_v3.db'),
      );
      final before = await target.readAsBytes();
      final helper = DatabaseHelper.forTesting(
        targetDirectory.path,
        databaseFactoryFfi,
      );
      await expectLater(helper.database, throwsA(isA<DatabaseException>()));
      await helper.close(createBackup: false);
      expect(await target.readAsBytes(), before);
      final check = await databaseFactoryFfi.openDatabase(
        target.path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      expect(await check.getVersion(), 8);
      expect(
        (await check.rawQuery(
          'PRAGMA table_info(Reminders)',
        )).any((row) => row['name'] == 'notice_revision'),
        isFalse,
      );
      await check.close();
    },
  );
}
