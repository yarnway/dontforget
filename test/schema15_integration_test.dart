import 'dart:convert';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/learning_queue_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('dontforget-schema15-');
  });
  tearDown(() async => root.delete(recursive: true));

  Map<String, Object?> settings(bool capture) => {
    ...(AppSettings.defaults().toJson()..remove('workspace_drafts_json')),
    if (capture)
      'workspace_drafts_json': jsonEncode({'composer': 'keep draft'}),
  };
  Map<String, Object?> progress() => {
    'hello': WordProgress(
      level: 1,
      due: DateTime.utc(2030, 5, 2, 20),
      reviewed: DateTime.utc(2030, 5, 1, 20),
      firstReviewed: DateTime.utc(2030, 5, 1, 20),
      reviews: 1,
      grade: 2,
    ).toJson(),
  };
  Map<String, Object?> reminder(bool capture, {bool full = false}) {
    final row = Reminder(
      id: 'original',
      taskTitle: 'Keep original',
      quadrantLevel: 2,
      createdAt: DateTime.utc(2026, 10, 27),
      triggerTime: DateTime.utc(2030, 5, 1, 8),
      timeOrigin: ReminderTimeOrigin.aiSuggested,
    ).toJson();
    row.remove('details_json');
    if (capture) {
      row.remove('trigger_time_origin');
      if (full) {
        row['capture_proposal_json'] = jsonEncode([
          {'id': 'proposal', 'task_title': 'Proposed', 'quadrant_level': 2},
        ]);
        row['word_progress_json'] = jsonEncode(progress());
      } else {
        row.remove('capture_proposal_json');
        row.remove('word_progress_json');
      }
      row.addAll({
        'event_time': '2030-05-01T09:00:00.000Z',
        'recurrence_event_anchor_time': '2030-05-01T09:00:00.000Z',
        'suggested_trigger_time': '2030-05-01T08:45:00.000Z',
        'source_text': 'original input',
        'capture_pending': 1,
        'is_pinned': 1,
      });
    } else {
      for (final field in const [
        'event_time',
        'recurrence_event_anchor_time',
        'suggested_trigger_time',
        'source_text',
        'capture_proposal_json',
        'word_progress_json',
        'capture_pending',
        'is_pinned',
      ]) {
        row.remove(field);
      }
    }
    return row;
  }

  Future<File> create14(
    String path,
    bool capture, {
    bool empty = false,
    bool full = false,
  }) async {
    final file = File(path);
    final db = await databaseFactoryFfi.openDatabase(file.path);
    final fixture = !capture
        ? 'schema_v14.sql'
        : full
        ? 'schema_v14_capture_full.sql'
        : 'schema_v14_capture.sql';
    final sql = (await File('test/fixtures/$fixture').readAsString())
        .split('\n')
        .where((line) => !line.startsWith('--'))
        .join('\n');
    for (final statement in sql.split(';')) {
      if (statement.trim().isNotEmpty) await db.execute(statement);
    }
    await db.insert('Settings', settings(capture));
    if (!empty) await db.insert('Reminders', reminder(capture, full: full));
    await db.setVersion(14);
    await db.close();
    return file;
  }

  void expectPreserved(
    Map<String, Object?> actualSettings,
    Map<String, Object?> actualReminder,
    bool capture, {
    bool full = false,
  }) {
    expect(
      actualSettings['workspace_drafts_json'],
      capture ? settings(true)['workspace_drafts_json'] : null,
    );
    final expected = reminder(capture, full: full);
    for (final entry in expected.entries) {
      expect(actualReminder[entry.key], entry.value, reason: entry.key);
    }
    expect(
      actualReminder['trigger_time_origin'],
      capture ? 'unknown' : 'aiSuggested',
    );
    expect(
      actualReminder['event_time'],
      capture ? expected['event_time'] : null,
    );
    expect(actualReminder['capture_pending'], capture ? 1 : 0);
    expect(actualReminder['is_pinned'], capture ? 1 : 0);
  }

  for (final variant in ['origin', 'capture', 'capture-full']) {
    final capture = variant != 'origin';
    final full = variant == 'capture-full';
    test('v14 $variant database upgrades without losing fields', () async {
      await create14('${root.path}/dont_forget_v3.db', capture, full: full);
      final helper = DatabaseHelper.forTesting(root.path, databaseFactoryFfi);
      try {
        final db = await helper.database;
        expect(await db.getVersion(), DatabaseHelper.schemaVersion);
        expectPreserved(
          (await db.query('Settings')).single,
          (await db.query('Reminders')).single,
          capture,
          full: full,
        );
        final snapshot = root.listSync().whereType<Directory>().singleWhere(
          (dir) => dir.path.contains(
            'schema-upgrade-v14-to-v${DatabaseHelper.schemaVersion}-',
          ),
        );
        final inspector = BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        );
        expect(
          (await inspector.inspect(
            File('${snapshot.path}/snapshot.json'),
          )).version,
          14,
        );
        await helper.createMirrorBackup();
        expect(
          (await inspector.inspect(
            File('${root.path}/dont_forget_v3.mirror.db'),
          )).version,
          DatabaseHelper.schemaVersion,
        );
      } finally {
        await helper.close(createBackup: false);
      }
    });

    for (final format in ['json', 'sqlite']) {
      test('v14 $variant $format restore preserves source and data', () async {
        final original = await create14(
          '${root.path}/source.db',
          capture,
          full: full,
        );
        final source = format == 'sqlite'
            ? original
            : await File('${root.path}/source.json').writeAsString(
                jsonEncode({
                  'version': 14,
                  'timestamp': '2026-10-27T00:00:00Z',
                  'settings': [settings(capture)],
                  'media_records': [],
                  'reminders': [reminder(capture, full: full)],
                }),
              );
        final bytes = await source.readAsBytes();
        final inspector = BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        );
        final preview = await inspector.inspect(source);
        expect(preview.version, 14);
        final target = DatabaseHelper.forTesting(
          '${root.path}/target',
          databaseFactoryFfi,
        );
        try {
          await DatabaseRecovery(
            target,
            inspector: inspector,
            notifications: NotificationService.forTesting(
              FlutterLocalNotificationsPlugin(),
              usesNativeNotifications: false,
            ),
          ).restore(source, expectedDigest: preview.digest);
          final db = await target.database;
          expect(await db.getVersion(), DatabaseHelper.schemaVersion);
          expectPreserved(
            (await db.query('Settings')).single,
            (await db.query('Reminders')).single,
            capture,
            full: full,
          );
          expect(await source.readAsBytes(), bytes);
        } finally {
          await target.close(createBackup: false);
        }
      });
    }

    test('v14 $variant backup with no reminders can be identified', () async {
      final dbFile = await create14(
        '${root.path}/empty.db',
        capture,
        empty: true,
        full: full,
      );
      final jsonFile = await File('${root.path}/empty.json').writeAsString(
        jsonEncode({
          'version': 14,
          'timestamp': null,
          'settings': [settings(capture)],
          'media_records': [],
          'reminders': [],
        }),
      );
      final inspector = BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: root,
      );
      expect((await inspector.inspect(dbFile)).version, 14);
      expect((await inspector.inspect(jsonFile)).version, 14);
    });
  }

  for (final field in ['capture_proposal_json', 'word_progress_json']) {
    test('v14 capture with only $field upgrades and inspects', () async {
      final file = await create14('${root.path}/dont_forget_v3.db', true);
      final db = await databaseFactoryFfi.openDatabase(file.path);
      await db.execute('ALTER TABLE Reminders ADD COLUMN $field TEXT');
      final value = field == 'capture_proposal_json'
          ? jsonEncode([
              {'id': 'proposal', 'task_title': 'Proposed', 'quadrant_level': 2},
            ])
          : jsonEncode(progress());
      await db.update('Reminders', {field: value});
      final snapshot = {
        'version': 14,
        'timestamp': null,
        'settings': await db.query('Settings'),
        'media_records': await db.query('MediaRecords'),
        'reminders': await db.query('Reminders'),
      };
      await db.close();
      final jsonFile = await File(
        '${root.path}/partial.json',
      ).writeAsString(jsonEncode(snapshot));
      final inspector = BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: root,
      );
      expect((await inspector.inspect(file)).version, 14);
      expect((await inspector.inspect(jsonFile)).version, 14);
      final helper = DatabaseHelper.forTesting(root.path, databaseFactoryFfi);
      try {
        final migrated = (await (await helper.database).query(
          'Reminders',
        )).single;
        expect(migrated[field], value);
        expect(migrated['trigger_time_origin'], 'unknown');
      } finally {
        await helper.close(createBackup: false);
      }
    });
  }

  test(
    'partial v14 hybrid fails closed without changing its version',
    () async {
      final file = await create14('${root.path}/dont_forget_v3.db', false);
      final source = await databaseFactoryFfi.openDatabase(file.path);
      await source.execute('ALTER TABLE Reminders ADD COLUMN event_time TEXT');
      await source.close();
      final helper = DatabaseHelper.forTesting(root.path, databaseFactoryFfi);
      try {
        await expectLater(helper.database, throwsA(isA<StateError>()));
        final unchanged = await databaseFactoryFfi.openDatabase(
          file.path,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
        );
        try {
          expect(await unchanged.getVersion(), 14);
          expect(
            (await unchanged.query('Reminders')).single['task_title'],
            'Keep original',
          );
        } finally {
          await unchanged.close();
        }
      } finally {
        await helper.close(createBackup: false);
      }
    },
  );

  test(
    'mixed v14 JSON fields are rejected without touching the source',
    () async {
      final source = await File('${root.path}/mixed.json').writeAsString(
        jsonEncode({
          'version': 14,
          'timestamp': null,
          'settings': [settings(false)],
          'media_records': [],
          'reminders': [
            {...reminder(false), 'event_time': '2030-05-01T09:00:00.000Z'},
          ],
        }),
      );
      final original = await source.readAsBytes();
      await expectLater(
        BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        ).inspect(source),
        throwsA(
          isA<BackupInspectionException>().having(
            (error) => error.code,
            'code',
            BackupInspectionError.invalidSchema,
          ),
        ),
      );
      expect(await source.readAsBytes(), original);
    },
  );

  for (final format in ['json', 'sqlite']) {
    test(
      'current $format round trip retains large drafts and AI and word state',
      () async {
        final live = DatabaseHelper.forTesting(
          '${root.path}/live',
          databaseFactoryFfi,
        );
        final target = DatabaseHelper.forTesting(
          '${root.path}/restored',
          databaseFactoryFfi,
        );
        final drafts = WorkspaceDrafts(live);
        final inspector = BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        );
        final text = List.filled(350001, 'x').join();
        final proposal = Reminder(
          id: 'model',
          taskTitle: 'Suggested',
          quadrantLevel: 2,
          triggerTime: DateTime.utc(2030, 5, 1, 8, 45),
          timeOrigin: ReminderTimeOrigin.aiSuggested,
          eventTime: DateTime.utc(2030, 5, 1, 9),
        );
        final original = Reminder.fromJson({
          ...proposal
              .copyWith(
                taskTitle: 'Original',
                sourceText: 'Preserve original',
                timeOrigin: ReminderTimeOrigin.manual,
                captureProposalJson: jsonEncode([proposal.toJson()]),
                wordProgressJson: jsonEncode(progress()),
              )
              .toJson(),
          'id': 'original',
        });
        try {
          await drafts.ready;
          await drafts.put('capture', {'id': 'unsent', 'text': text});
          await live.writeTransaction(
            live.captureGeneration(),
            (db) => db.insert('Reminders', original.toJson()),
          );
          await live.createMirrorBackup();
          final source = File(
            '${root.path}/live/${format == 'json' ? 'ha_snapshot.json' : 'dont_forget_v3.mirror.db'}',
          );
          final before = await source.readAsBytes();
          final preview = await inspector.inspect(source);
          expect(preview.version, DatabaseHelper.schemaVersion);
          await DatabaseRecovery(
            target,
            inspector: inspector,
            notifications: NotificationService.forTesting(
              FlutterLocalNotificationsPlugin(),
              usesNativeNotifications: false,
            ),
          ).restore(source, expectedDigest: preview.digest);
          final db = await target.database;
          expect(await db.getVersion(), DatabaseHelper.schemaVersion);
          expect((await db.query('Reminders')).single, original.toJson());
          final restored = jsonDecode(
            (await db.query('Settings')).single['workspace_drafts_json']
                as String,
          );
          expect(restored['capture'], {'id': 'unsent', 'text': text});
          expect(await source.readAsBytes(), before);
        } finally {
          drafts.dispose();
          await live.close(createBackup: false);
          await target.close(createBackup: false);
        }
      },
    );
  }

  test('malformed persisted drafts cannot pass backup inspection', () async {
    final source = await File('${root.path}/invalid-draft.json').writeAsString(
      jsonEncode({
        'version': 14,
        'timestamp': null,
        'settings': [
          {...settings(true), 'workspace_drafts_json': '[1, 2]'},
        ],
        'media_records': [],
        'reminders': [],
      }),
    );
    await expectLater(
      BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: root,
      ).inspect(source),
      throwsA(
        isA<BackupInspectionException>().having(
          (error) => error.code,
          'code',
          BackupInspectionError.invalidData,
        ),
      ),
    );
  });
}
