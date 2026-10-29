import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/data/schema_15_compatibility.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/live_reminder_service.dart';
import 'package:dont_forget/services/notification_schedule_reader.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/task_search_index.dart';
import 'package:dont_forget/ui/widgets/task_board_data.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications implements NotificationService {
  final scheduled = <String>[];
  final canceled = <String>[];
  @override
  Future<void> scheduleReminderStrict(Reminder task) async =>
      scheduled.add(task.id);
  @override
  Future<void> cancelReminderStrict(String id) async => canceled.add(id);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('dontforget-schema16-');
  });
  tearDown(() async => root.delete(recursive: true));

  String details() => TaskDetails(
    checklist: const [ChecklistItem('passport', '带证件', done: true)],
    tags: const ['出行'],
    project: '保留原有项目',
    history: [TaskEvent('edited', DateTime.utc(2030, 5, 1, 6))],
    repeat: RepeatWindow(
      interval: 2,
      weekdays: const [1, 3, 5],
      end: DateTime.utc(2031, 5, 1),
    ),
    data: const {'original': 'retained'},
  ).encode();

  Map<String, Object?> row(Schema15Shape shape) {
    final result = Reminder(
      id: 'original',
      taskTitle: 'Preserve original',
      quadrantLevel: 2,
      triggerTime: DateTime.utc(2030, 5, 1, 8),
      eventTime: DateTime.utc(2030, 5, 1, 9),
      createdAt: DateTime.utc(2030, 5, 1, 6),
      timeOrigin: ReminderTimeOrigin.manual,
      sourceText: '  Original\ninput  ',
      capturePending: true,
      isPinned: true,
      detailsJson: shape == Schema15Shape.taskManagement ? details() : null,
    ).toJson();
    result.remove(
      shape == Schema15Shape.recordReminder
          ? 'details_json'
          : 'trigger_time_origin',
    );
    return result;
  }

  Future<String> fixture(Schema15Shape shape) => File(
    'test/fixtures/${shape == Schema15Shape.recordReminder ? 'schema_v15.sql' : 'schema_v15_task_management.sql'}',
  ).readAsString();

  Future<File> create15(
    Schema15Shape shape, {
    String name = 'source.db',
    bool empty = false,
    String Function(String)? changeSchema,
    String? invalidDetails,
  }) async {
    final file = File('${root.path}/$name');
    await file.parent.create(recursive: true);
    final db = await databaseFactoryFfi.openDatabase(file.path);
    try {
      var sql = await fixture(shape);
      if (changeSchema != null) sql = changeSchema(sql);
      sql = sql.split('\n').where((line) => !line.startsWith('--')).join('\n');
      for (final statement in sql.split(';')) {
        if (statement.trim().isNotEmpty) await db.execute(statement);
      }
      await db.insert('Settings', {
        ...AppSettings.defaults().toJson(),
        'workspace_drafts_json': jsonEncode({
          'capture': {'text': 'unsent draft', 'id': 'draft'},
        }),
      });
      if (!empty) {
        await db.insert('Reminders', {
          ...row(shape),
          if (invalidDetails != null) 'details_json': invalidDetails,
        });
      }
      await db.setVersion(15);
    } finally {
      await db.close();
    }
    return file;
  }

  Future<File> jsonBackup(File sqlite, {String name = 'source.json'}) async {
    final db = await databaseFactoryFfi.openDatabase(
      sqlite.path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      return await File('${root.path}/$name').writeAsString(
        jsonEncode({
          'version': 15,
          'timestamp': null,
          'settings': await db.query('Settings'),
          'media_records': await db.query('MediaRecords'),
          'reminders': await db.query('Reminders'),
        }),
      );
    } finally {
      await db.close();
    }
  }

  BackupInspector inspector() =>
      BackupInspector(databaseFactoryFfi, temporaryDirectory: root);
  NotificationService notifications() => NotificationService.forTesting(
    FlutterLocalNotificationsPlugin(),
    usesNativeNotifications: false,
  );

  Future<void> expectPreserved(
    DatabaseHelper helper,
    Schema15Shape shape,
  ) async {
    final db = await helper.database;
    expect(await db.getVersion(), 16);
    final saved = (await db.query('Reminders')).single;
    for (final entry in row(shape).entries) {
      expect(saved[entry.key], entry.value, reason: entry.key);
    }
    expect(
      saved['trigger_time_origin'],
      shape == Schema15Shape.recordReminder ? 'manual' : 'unknown',
    );
    expect(
      saved['details_json'],
      shape == Schema15Shape.taskManagement ? details() : null,
    );
    final drafts = jsonDecode(
      (await db.query('Settings')).single['workspace_drafts_json'] as String,
    );
    expect(drafts['capture']['text'], 'unsent draft');
    final parsed = Reminder.fromJson(saved);
    expect(
      parsed.copyWith(taskTitle: 'Edited').detailsJson,
      parsed.detailsJson,
    );
    await helper.createMirrorBackup();
    for (final name in ['ha_snapshot.json', 'dont_forget_v3.mirror.db']) {
      expect(
        (await inspector().inspect(
          File(p.join(p.dirname(db.path), name)),
        )).version,
        16,
      );
    }
  }

  for (final shape in Schema15Shape.values) {
    test(
      'v15 ${shape.name} upgrades to v16 and keeps an inspectable rollback snapshot',
      () async {
        await create15(shape, name: 'live/dont_forget_v3.db');
        final helper = DatabaseHelper.forTesting(
          '${root.path}/live',
          databaseFactoryFfi,
        );
        try {
          await expectPreserved(helper, shape);
          final snapshot = Directory('${root.path}/live')
              .listSync()
              .whereType<Directory>()
              .singleWhere(
                (d) => d.path.contains('schema-upgrade-v15-to-v16-'),
              );
          expect(
            (await inspector().inspect(
              File('${snapshot.path}/snapshot.json'),
            )).version,
            15,
          );
        } finally {
          await helper.close(createBackup: false);
        }
      },
    );
    for (final format in ['json', 'sqlite']) {
      test(
        'v15 ${shape.name} $format restore preserves fields and source bytes',
        () async {
          final sqlite = await create15(shape);
          final source = format == 'sqlite' ? sqlite : await jsonBackup(sqlite);
          final before = await source.readAsBytes();
          final preview = await inspector().inspect(source);
          final helper = DatabaseHelper.forTesting(
            '${root.path}/restored',
            databaseFactoryFfi,
          );
          try {
            await DatabaseRecovery(
              helper,
              inspector: inspector(),
              notifications: notifications(),
            ).restore(source, expectedDigest: preview.digest);
            await expectPreserved(helper, shape);
            expect(await source.readAsBytes(), before);
          } finally {
            await helper.close(createBackup: false);
          }
        },
      );
      test('empty v15 ${shape.name} $format backup restores to v16', () async {
        final sqlite = await create15(shape, empty: true);
        final source = format == 'sqlite' ? sqlite : await jsonBackup(sqlite);
        final preview = await inspector().inspect(source);
        final helper = DatabaseHelper.forTesting(
          '${root.path}/empty',
          databaseFactoryFfi,
        );
        try {
          await DatabaseRecovery(
            helper,
            inspector: inspector(),
            notifications: notifications(),
          ).restore(source, expectedDigest: preview.digest);
          final db = await helper.database;
          expect(await db.getVersion(), 16);
          expect(await db.query('Reminders'), isEmpty);
        } finally {
          await helper.close(createBackup: false);
        }
      });
    }
    for (final mutation in [
      'missing',
      'hybrid',
      'wrong-default',
      'wrong-type',
    ]) {
      test(
        'v15 ${shape.name} $mutation shape is rejected without changing its version',
        () async {
          final file = await create15(
            shape,
            name: 'bad/dont_forget_v3.db',
            empty: true,
            changeSchema: (sql) => switch (mutation) {
              'missing' => sql.replaceFirst(
                '  capture_proposal_json TEXT,\n',
                '',
              ),
              'hybrid' => sql.replaceFirst(
                '  word_progress_json TEXT,',
                '  word_progress_json TEXT,\n  ${shape == Schema15Shape.recordReminder ? 'details_json TEXT' : "trigger_time_origin TEXT NOT NULL DEFAULT 'unknown'"},',
              ),
              'wrong-default' => sql.replaceFirst(
                'capture_pending INTEGER NOT NULL DEFAULT 0',
                'capture_pending INTEGER NOT NULL DEFAULT 1',
              ),
              _ => sql.replaceFirst('event_time TEXT,', 'event_time INTEGER,'),
            },
          );
          final before = await file.readAsBytes();
          await expectLater(
            inspector().inspect(file),
            throwsA(
              isA<BackupInspectionException>().having(
                (e) => e.code,
                'code',
                BackupInspectionError.invalidSchema,
              ),
            ),
          );
          expect(await file.readAsBytes(), before);
          final helper = DatabaseHelper.forTesting(
            '${root.path}/bad',
            databaseFactoryFfi,
          );
          try {
            await expectLater(helper.database, throwsStateError);
          } finally {
            await helper.close(createBackup: false);
          }
          final unchanged = await databaseFactoryFfi.openDatabase(
            file.path,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          try {
            expect(await unchanged.getVersion(), 15);
          } finally {
            await unchanged.close();
          }
        },
      );
    }
  }

  for (final invalid in [
    '[]',
    '{"version":2}',
    '{"version":1,"paused":false,"paused":true}',
    '{"version":1,"paused":"true"}',
    '{"version":1,"history":[{}]}',
  ]) {
    test(
      'malformed v15 extension $invalid cannot migrate or restore',
      () async {
        final file = await create15(
          Schema15Shape.taskManagement,
          name: 'bad/dont_forget_v3.db',
          invalidDetails: invalid,
        );
        await expectLater(
          inspector().inspect(file),
          throwsA(
            isA<BackupInspectionException>().having(
              (e) => e.code,
              'code',
              BackupInspectionError.invalidData,
            ),
          ),
        );
        final helper = DatabaseHelper.forTesting(
          '${root.path}/bad',
          databaseFactoryFfi,
        );
        try {
          await expectLater(helper.database, throwsA(isA<Exception>()));
        } finally {
          await helper.close(createBackup: false);
        }
        final original = await databaseFactoryFfi.openDatabase(
          file.path,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
        );
        try {
          expect(await original.getVersion(), 15);
          expect(
            (await original.query('Reminders')).single['details_json'],
            invalid,
          );
        } finally {
          await original.close();
        }
      },
    );
  }

  test(
    'v15 invalid provenance is rejected by migration and backup inspection',
    () async {
      final file = await create15(
        Schema15Shape.recordReminder,
        name: 'bad/dont_forget_v3.db',
      );
      final db = await databaseFactoryFfi.openDatabase(file.path);
      await db.update('Reminders', {'trigger_time_origin': 'untrusted'});
      await db.close();
      await expectLater(
        inspector().inspect(file),
        throwsA(
          isA<BackupInspectionException>().having(
            (e) => e.code,
            'code',
            BackupInspectionError.invalidData,
          ),
        ),
      );
      final helper = DatabaseHelper.forTesting(
        '${root.path}/bad',
        databaseFactoryFfi,
      );
      try {
        await expectLater(helper.database, throwsStateError);
      } finally {
        await helper.close(createBackup: false);
      }
      final original = await databaseFactoryFfi.openDatabase(
        file.path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      try {
        expect(await original.getVersion(), 15);
        expect(
          (await original.query('Reminders')).single['trigger_time_origin'],
          'untrusted',
        );
      } finally {
        await original.close();
      }
    },
  );

  test('v15 JSON cannot mix reminder and task-management row shapes', () async {
    final file = File('${root.path}/mixed.json');
    await file.writeAsString(
      jsonEncode({
        'version': 15,
        'timestamp': null,
        'settings': [AppSettings.defaults().toJson()],
        'media_records': [],
        'reminders': [
          row(Schema15Shape.recordReminder),
          {...row(Schema15Shape.taskManagement), 'id': 'other'},
        ],
      }),
    );
    final before = await file.readAsBytes();
    await expectLater(
      inspector().inspect(file),
      throwsA(
        isA<BackupInspectionException>().having(
          (e) => e.code,
          'code',
          BackupInspectionError.invalidSchema,
        ),
      ),
    );
    expect(await file.readAsBytes(), before);
  });

  test(
    'restored lifecycle state cannot schedule, display hidden tasks, or become a live activity',
    () async {
      final helper = DatabaseHelper.forTesting(
        '${root.path}/lifecycle',
        databaseFactoryFfi,
      );
      final spy = _Notifications();
      final notifier = RemindersNotifier(
        helper,
        notifications: spy,
        runLoadEffects: false,
      );
      try {
        await notifier.ready;
        final at = DateTime.now().add(const Duration(hours: 2));
        for (final kind in ['active', 'paused', 'archived', 'deleted']) {
          await notifier.addReminder(
            Reminder(
              id: kind,
              taskTitle: kind,
              quadrantLevel: 2,
              triggerTime: at,
              detailsJson: TaskDetails(
                paused: kind == 'paused',
                archivedAt: kind == 'archived' ? DateTime.now() : null,
                deletedAt: kind == 'deleted' ? DateTime.now() : null,
              ).encode(),
            ),
          );
        }
        expect(spy.scheduled, ['active']);
        expect(spy.canceled, containsAll(['paused', 'archived', 'deleted']));
        final loaded = (await (await helper.database).query(
          'Reminders',
        )).map(Reminder.fromJson).toList();
        expect(
          TaskSearchIndex(
            loaded,
          ).search('', includeAllWhenEmpty: true).map((r) => r.id),
          ['active', 'paused'],
        );
        expect(
          TaskBoardData.project(
            loaded,
            isFolded: (_) => false,
          ).pending.reduce((a, b) => a + b),
          2,
        );
        for (final task in loaded.where((r) => r.id != 'active')) {
          expect(LiveReminderService.eligible(task, DateTime.now()), isFalse);
          expect(
            await NotificationScheduleReader(helper).readReminder(task),
            ReminderSchedulePhase.inactive,
          );
          final active = loaded.singleWhere((r) => r.id == 'active');
          const epoch = '00000000-0000-4000-8000-000000000001';
          final payload = NotificationPayload.forReminder(
            active,
            datasetEpoch: epoch,
          );
          final hiddenOccurrence = active.copyWith(
            detailsJson: task.detailsJson,
          );
          expect(
            payload.matches(hiddenOccurrence, currentDatasetEpoch: epoch),
            isFalse,
          );
          expect(
            () => NotificationPayload.forReminder(
              hiddenOccurrence,
              datasetEpoch: epoch,
            ),
            throwsArgumentError,
          );
        }
      } finally {
        notifier.dispose();
        await helper.close(createBackup: false);
      }
    },
  );

  test(
    'immediate context reminders still work without time but respect lifecycle state',
    () async {
      final service = notifications();
      final fired = <String>[];
      final subscription = service.onReminderDue.listen(
        (task) => fired.add(task.id),
      );
      final original = Reminder(
        id: 'context',
        taskTitle: 'Context',
        quadrantLevel: 1,
      );
      try {
        await service.fireReminderNow(original);
        for (final value in [
          const TaskDetails(paused: true),
          TaskDetails(deletedAt: DateTime.now()),
          TaskDetails(archivedAt: DateTime.now()),
        ]) {
          await service.fireReminderNow(
            original.copyWith(detailsJson: value.encode()),
          );
        }
        await Future<void>.delayed(Duration.zero);
        expect(fired, ['context']);
      } finally {
        await subscription.cancel();
        await service.pauseForMaintenance();
      }
    },
  );

  test(
    'confirming AI title edits preserves user checklist and project metadata',
    () async {
      final helper = DatabaseHelper.forTesting(
        '${root.path}/proposal',
        databaseFactoryFfi,
      );
      final notifier = RemindersNotifier(
        helper,
        notifications: _Notifications(),
        runLoadEffects: false,
      );
      try {
        await notifier.ready;
        final suggestion = Reminder(
          id: 'ai',
          taskTitle: 'Suggested',
          quadrantLevel: 2,
        );
        final original = Reminder(
          id: 'original',
          taskTitle: 'Original',
          quadrantLevel: 2,
          sourceText: 'Keep raw input',
          detailsJson: details(),
          captureProposalJson: jsonEncode([suggestion.toJson()]),
        );
        await notifier.addReminder(original);
        await notifier.applyCaptureProposal(original, [suggestion]);
        final saved = notifier.state.single;
        expect(saved.taskTitle, 'Suggested');
        expect(
          saved.details.patch({
            'history': original.details.toJson()['history'],
          }).encode(),
          original.detailsJson,
        );
        expect(
          saved.details.history.length,
          original.details.history.length + 1,
        );
        expect(saved.details.history.last.action, 'capture_applied');
        expect(saved.details.checklist.single.done, isTrue);
        expect(saved.details.project, '保留原有项目');
      } finally {
        notifier.dispose();
        await helper.close(createBackup: false);
      }
    },
  );
}
