import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/study_plan.dart';
import 'package:dont_forget/models/vocabulary_entry.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/spaced_repetition_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications extends NotificationService {
  _Notifications()
    : super.forTesting(
        FlutterLocalNotificationsPlugin(),
        usesNativeNotifications: false,
      );
  final scheduled = <Reminder>[];
  final cancelled = <String>[];
  bool fail = false;
  @override
  Future<void> scheduleReminderStrict(Reminder reminder) async {
    if (fail) throw StateError('Synthetic scheduling rejection');
    scheduled.add(reminder);
  }

  @override
  Future<void> cancelReminderStrict(String id) async {
    cancelled.add(id);
  }
}

void main() {
  late Directory root;
  late DatabaseHelper helper;
  late _Notifications notifications;
  RemindersNotifier? notifier;
  final original = Reminder(
    id: 'legacy',
    taskTitle: 'Existing review',
    quadrantLevel: 2,
    spacedRepetitionLevel: 2,
    nextReviewAt: DateTime(2030, 1, 1),
  );
  final legacy = original.toJson()..remove('review_notifications_enabled');
  Future<File> createLegacy({bool broken = false}) async {
    final file = File('${root.path}/dont_forget_v3.db');
    final db = await databaseFactoryFfi.openDatabase(file.path);
    final sql = (await File(
      'test/fixtures/schema_v12.sql',
    ).readAsString()).split('\n').where((s) => !s.startsWith('--')).join('\n');
    for (final statement in sql.split(';')) {
      if (statement.trim().isNotEmpty) await db.execute(statement);
    }
    await db.insert('Settings', AppSettings.defaults().toJson());
    await db.insert('Reminders', legacy);
    if (broken) {
      await db.execute(
        'ALTER TABLE Reminders ADD COLUMN review_notifications_enabled INTEGER',
      );
    }
    await db.setVersion(12);
    await db.close();
    return file;
  }

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('dontforget-study-');
    helper = DatabaseHelper.forTesting(root.path, databaseFactoryFfi);
    notifications = _Notifications();
  });
  tearDown(() async {
    notifier?.dispose();
    notifier = null;
    await helper.close(createBackup: false);
    await root.delete(recursive: true);
  });

  test(
    'v12 preserves app-only cards and creates an inspectable rollback snapshot',
    () async {
      await createLegacy();
      final db = await helper.database;
      expect(await db.getVersion(), 13);
      expect((await db.query('Reminders')).single, {
        ...legacy,
        'review_notifications_enabled': 0,
      });
      final directory = root.listSync().whereType<Directory>().singleWhere(
        (d) => d.path.contains('schema-upgrade-v12-to-v13-'),
      );
      final snapshot = File('${directory.path}/snapshot.json');
      final bytes = await snapshot.readAsBytes();
      expect(jsonDecode(utf8.decode(bytes))['reminders'], [legacy]);
      expect(
        (await BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        ).inspect(snapshot)).version,
        12,
      );
      expect(await snapshot.readAsBytes(), bytes);
    },
  );
  test(
    'failed review notification migration rolls back schema and data',
    () async {
      final file = await createLegacy(broken: true);
      await expectLater(helper.database, throwsA(isA<DatabaseException>()));
      await helper.close(createBackup: false);
      final db = await databaseFactoryFfi.openDatabase(file.path);
      expect(await db.getVersion(), 12);
      expect((await db.query('Reminders')).single, {
        ...legacy,
        'review_notifications_enabled': null,
      });
      await db.close();
    },
  );
  for (final format in ['json', 'sqlite']) {
    test(
      'v12 $format restore keeps review notifications off without mutating source',
      () async {
        final dbFile = await createLegacy();
        final source = format == 'sqlite'
            ? dbFile
            : await File('${root.path}/legacy.json').writeAsString(
                jsonEncode({
                  'version': 12,
                  'timestamp': DateTime.now().toIso8601String(),
                  'settings': [AppSettings.defaults().toJson()],
                  'media_records': [],
                  'reminders': [legacy],
                }),
              );
        final bytes = await source.readAsBytes();
        final inspector = BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        );
        final preview = await inspector.inspect(source);
        final target = DatabaseHelper.forTesting(
          '${root.path}/target',
          databaseFactoryFfi,
        );
        try {
          await DatabaseRecovery(
            target,
            inspector: inspector,
            notifications: notifications,
          ).restore(source, expectedDigest: preview.digest);
          expect((await (await target.database).query('Reminders')).single, {
            ...legacy,
            'review_notifications_enabled': 0,
          });
          expect(await source.readAsBytes(), bytes);
        } finally {
          await target.close();
        }
      },
    );
  }
  test(
    'whole batch rollback, retry, feedback update and disable reach native scheduling',
    () async {
      final db = await helper.database;
      final current = notifier = RemindersNotifier(
        helper,
        notifications: notifications,
        runLoadEffects: false,
      );
      await current.ready;
      final plan = StudyPlan(
        batches: List.generate(
          3,
          (i) => StudyBatch(
            title: 'Batch $i',
            content: const VocabularyEntry(
              word: 'recall',
              ipa: '/rɪˈkɔːl/',
              partOfSpeech: 'verb',
              meaning: '回想；记起',
              usage: 'recall a word',
              example: 'Try to recall the word.',
              translation: '尝试回想这个单词。',
            ).toNotes(),
          ),
        ),
      );
      final rows = plan.reminders(
        edited: plan.batches,
        firstReminder: DateTime(2030, 1, 1, 20, 30),
      );
      await db.execute(
        "CREATE TRIGGER reject_batch BEFORE INSERT ON Reminders WHEN NEW.id = '${rows[1].id}' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
      );
      final generation = helper.captureGeneration();
      await expectLater(
        current.addStudyPlan(rows, generation),
        throwsA(isA<DatabaseException>()),
      );
      expect(await db.query('Reminders'), isEmpty);
      expect(notifications.scheduled, isEmpty);
      await db.execute('DROP TRIGGER reject_batch');
      notifications.fail = true;
      final saved = await current.addStudyPlan(rows, generation);
      expect(saved.changed, 3);
      expect(saved.nativeSyncFailures, 3);
      expect(await db.query('Reminders'), hasLength(3));
      notifications.fail = false;
      expect((await current.addStudyPlan(rows, generation)).changed, 0);
      expect(await db.query('Reminders'), hasLength(3));
      expect(notifications.scheduled, hasLength(3));
      const service = SpacedRepetitionService();
      await current.updateReminder(
        service.reviewCard(
          rows.first,
          true,
          referenceTime: DateTime(2030, 1, 1),
        ),
        baseline: rows.first,
      );
      final reviewed = current.state.first;
      expect(reviewed.noticeRevision, 1);
      expect(reviewed.triggerTime, DateTime(2030, 1, 2, 20, 30));
      expect(notifications.scheduled.last.triggerTime, reviewed.nextReviewAt);
      await current.updateReminder(
        service.disableCard(reviewed),
        baseline: reviewed,
      );
      expect(notifications.cancelled.last, rows.first.id);
      await helper.close();
      final reopened = (await (await helper.database).query(
        'Reminders',
      )).map(Reminder.fromJson).toList();
      expect(reopened.where((r) => r.reviewNotificationsEnabled), hasLength(2));
      expect(
        reopened.every((r) => r.taskSummary == plan.batches.first.content),
        isTrue,
      );
      expect(
        VocabularyEntry.parseNotes(reopened.first.taskSummary!).single.ipa,
        '/rɪˈkɔːl/',
      );
      await expectLater(
        current.addStudyPlan(rows, generation),
        throwsA(isA<DatabaseAccessException>()),
      );
    },
  );

  test(
    'manual learning alarm edits keep review date aligned and clearing opts out',
    () async {
      final current = notifier = RemindersNotifier(
        helper,
        notifications: notifications,
        runLoadEffects: false,
      );
      await current.ready;
      final task = original.copyWith(
        reviewNotificationsEnabled: true,
        triggerTime: DateTime(2030, 1, 1, 20),
      );
      await current.addReminder(task);
      final later = DateTime(2030, 1, 3, 21);
      await current.updateReminder(
        task.copyWith(triggerTime: later),
        baseline: task,
      );
      final edited = current.state.single;
      expect(edited.nextReviewAt, later);
      await current.updateReminder(
        edited.copyWith(triggerTime: null),
        baseline: edited,
      );
      expect(current.state.single.reviewNotificationsEnabled, isFalse);
      expect(current.state.single.nextReviewAt, later);
      expect(notifications.cancelled.last, task.id);
    },
  );

  for (final format in ['json', 'sqlite']) {
    test(
      'current $format backup restores opt-in learning notification state',
      () async {
        final task = original.copyWith(
          reviewNotificationsEnabled: true,
          triggerTime: DateTime(2030, 1, 1),
          noticeRevision: 3,
        );
        final db = await helper.database;
        await db.insert('Reminders', task.toJson());
        await helper.createMirrorBackup();
        final source = File(
          '${root.path}/${format == 'json' ? 'ha_snapshot.json' : 'dont_forget_v3.mirror.db'}',
        );
        final bytes = await source.readAsBytes();
        final inspector = BackupInspector(
          databaseFactoryFfi,
          temporaryDirectory: root,
        );
        final preview = await inspector.inspect(source);
        expect(preview.version, 13);
        final target = DatabaseHelper.forTesting(
          '${root.path}/restored-current',
          databaseFactoryFfi,
        );
        try {
          await DatabaseRecovery(
            target,
            inspector: inspector,
            notifications: notifications,
          ).restore(source, expectedDigest: preview.digest);
          expect(
            (await (await target.database).query('Reminders')).single,
            task.toJson(),
          );
          expect(await source.readAsBytes(), bytes);
        } finally {
          await target.close();
        }
      },
    );
  }
}
