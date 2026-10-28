import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/providers/task_templates_provider.dart';
import 'package:dont_forget/models/task_template.dart';
import 'package:dont_forget/models/task_template_transfer.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/models/task_metadata_patch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
  });
  tearDown(() async => h.dispose());
  Reminder task(
    String id, {
    TaskDetails details = const TaskDetails(),
    bool completed = false,
  }) => Reminder(
    id: id,
    taskTitle: id,
    quadrantLevel: 2,
    createdAt: DateTime(2030),
    isCompleted: completed,
    triggerTime: DateTime(2035),
    eventTime: DateTime(2035, 1, 2),
    detailsJson: details.encode(),
  );
  test(
    'metadata changes apply atomically without rescheduling or altering dates, outcomes, attachments or checklist',
    () async {
      await h.seed(
        task(
          'a',
          details: const TaskDetails(
            project: 'old',
            tags: ['keep', 'remove'],
            attachmentIds: [],
            checklist: [ChecklistItem('i', 'Keep item', done: true)],
          ),
        ),
      );
      await h.seed(
        task(
          'b',
          completed: true,
          details: const TaskDetails(tags: ['existing']),
        ),
      );
      final before = await h.rows();
      h.notifications.scheduled.clear();
      h.notifications.cancelled.clear();
      final result = await h.notifier.updateMetadataBatch(
        before,
        TaskMetadataPatch(
          project: 'new',
          tagMode: TagEditMode.add,
          tags: ['new'],
        ),
        h.database.captureGeneration(),
      );
      expect(result.changed, 2);
      expect(h.notifications.scheduled, isEmpty);
      expect(h.notifications.cancelled, isEmpty);
      for (final row in await h.rows()) {
        final previous = before.singleWhere((e) => e.id == row.id);
        expect(row.triggerTime, previous.triggerTime);
        expect(row.eventTime, previous.eventTime);
        expect(row.isCompleted, previous.isCompleted);
        expect(row.noticeRevision, previous.noticeRevision);
        expect(
          row.details.checklist.map((e) => e.toJson()),
          previous.details.checklist.map((e) => e.toJson()),
        );
        expect(row.details.project, 'new');
        expect(row.details.tags, contains('new'));
      }
      await h.close();
      await h.open();
      expect((await h.row('a')).details.tags, ['keep', 'remove', 'new']);
    },
  );
  test(
    'keep, clear, add, remove and replace are distinct, bounded operations',
    () {
      const old = TaskDetails(project: 'P', tags: ['a', 'b']);
      expect(TaskMetadataPatch().apply(old).project, 'P');
      expect(TaskMetadataPatch(project: '').apply(old).project, '');
      expect(
        TaskMetadataPatch(
          tagMode: TagEditMode.add,
          tags: ['b', 'c'],
        ).apply(old).tags,
        ['a', 'b', 'c'],
      );
      expect(
        TaskMetadataPatch(
          tagMode: TagEditMode.remove,
          tags: ['a'],
        ).apply(old).tags,
        ['b'],
      );
      expect(
        TaskMetadataPatch(tagMode: TagEditMode.replace).apply(old).tags,
        isEmpty,
      );
      for (final build in [
        () => TaskMetadataPatch(project: 'x\ny'),
        () => TaskMetadataPatch(tags: ['a']),
        () => TaskMetadataPatch(tagMode: TagEditMode.add, tags: ['a', 'a']),
        () => TaskMetadataPatch(project: 'x' * 129),
        () => TaskMetadataPatch(
          tagMode: TagEditMode.add,
          tags: List.generate(17, (i) => '$i'),
        ),
      ]) {
        expect(build, throwsFormatException);
      }
      expect(
        () => TaskMetadataPatch(
          tagMode: TagEditMode.add,
          tags: ['extra'],
        ).apply(TaskDetails(tags: List.generate(16, (i) => '$i'))),
        throwsFormatException,
      );
    },
  );
  test(
    'one stale or invalid selected task prevents every metadata update',
    () async {
      await h.seed(task('a'));
      await h.seed(task('b'));
      final before = await h.rows();
      await (await h.database.database).update(
        'Reminders',
        {'task_title': 'changed'},
        where: 'id = ?',
        whereArgs: ['b'],
      );
      await expectLater(
        h.notifier.updateMetadataBatch(
          before,
          TaskMetadataPatch(project: 'bad'),
          h.database.captureGeneration(),
        ),
        throwsA(anything),
      );
      expect((await h.row('a')).details.project, isEmpty);
      expect((await h.row('b')).taskTitle, 'changed');
    },
  );
  test(
    'metadata excludes child tasks and deleted content; 50-task limit is enforced',
    () async {
      final root = task('root'),
          child = task('child', details: const TaskDetails(planId: 'root'));
      await h.seed(root);
      await h.seed(child);
      await expectLater(
        h.notifier.updateMetadataBatch(
          [root],
          TaskMetadataPatch(project: 'x'),
          h.database.captureGeneration(),
        ),
        throwsA(anything),
      );
      expect(
        () => h.notifier.updateMetadataBatch(
          List.generate(51, (i) => task('$i')),
          TaskMetadataPatch(project: 'x'),
          h.database.captureGeneration(),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'database write failure rolls back all metadata and preserves provider state',
    () async {
      await h.seed(task('a'));
      await h.seed(task('b'));
      final before = await h.rows();
      await (await h.database.database).execute(
        "CREATE TRIGGER fail_metadata BEFORE UPDATE ON Reminders WHEN NEW.id = 'b' BEGIN SELECT RAISE(ABORT, 'synthetic metadata failure'); END",
      );
      await expectLater(
        h.notifier.updateMetadataBatch(
          before,
          TaskMetadataPatch(project: 'x'),
          h.database.captureGeneration(),
        ),
        throwsA(anything),
      );
      expect((await h.row('a')).details.project, isEmpty);
    },
  );
  test(
    'unified archive stops active ordinary and study reminders without marking them completed',
    () async {
      for (final kind in ['task', 'study']) {
        await h.seed(task(kind, details: TaskDetails(kind: kind)));
        final row = await h.row(kind);
        await h.notifier.changeContentArchive(
          row,
          [],
          true,
          h.database.captureGeneration(),
        );
        final archived = await h.row(kind);
        expect(archived.isCompleted, isFalse);
        expect(archived.details.archivedAt, isNotNull);
        expect(h.notifications.cancelled, contains(kind));
        await h.notifier.changeContentArchive(
          archived,
          [],
          false,
          h.database.captureGeneration(),
        );
        expect((await h.row(kind)).isVisible, isTrue);
        expect(h.notifications.scheduled, contains(kind));
      }
    },
  );
  test(
    'plan archive handles all previewed members while preserving independently archived and deleted children',
    () async {
      final old = DateTime(2020);
      await h.seed(
        task('root', details: const TaskDetails(kind: 'medicationPlan')),
      );
      await h.seed(
        task(
          'future',
          details: const TaskDetails(kind: 'medication', planId: 'root'),
        ),
      );
      await h.seed(
        task(
          'taken',
          completed: true,
          details: const TaskDetails(
            kind: 'medication',
            planId: 'root',
            doseOutcome: 'taken',
          ),
        ),
      );
      await h.seed(
        task(
          'prior',
          details: TaskDetails(
            kind: 'medication',
            planId: 'root',
            archivedAt: old,
          ),
        ),
      );
      await h.seed(
        task(
          'deleted',
          details: TaskDetails(
            kind: 'medication',
            planId: 'root',
            deletedAt: old,
          ),
        ),
      );
      final baseline = await h.rows();
      await h.notifier.changeContentArchive(
        await h.row('root'),
        baseline.where((e) => e.details.planId == 'root').toList(),
        true,
        h.database.captureGeneration(),
      );
      expect((await h.row('future')).isVisible, isFalse);
      expect((await h.row('taken')).details.effectiveDoseOutcome, 'taken');
      expect((await h.row('prior')).details.archivedAt, old);
      expect((await h.row('deleted')).details.archivedAt, isNull);
      final frozen = await h.rows();
      await h.notifier.changeContentArchive(
        await h.row('root'),
        frozen.where((e) => e.details.planId == 'root').toList(),
        false,
        h.database.captureGeneration(),
      );
      expect((await h.row('future')).isVisible, isTrue);
      expect((await h.row('prior')).details.archivedAt, old);
      expect((await h.row('deleted')).details.deletedAt, old);
    },
  );
  test(
    'new or edited group members after preview prevent archive of the complete group',
    () async {
      await h.seed(task('root'));
      final root = await h.row('root');
      await h.seed(task('new', details: const TaskDetails(planId: 'root')));
      await expectLater(
        h.notifier.changeContentArchive(
          root,
          [],
          true,
          h.database.captureGeneration(),
        ),
        throwsA(anything),
      );
      expect((await h.row('root')).isVisible, isTrue);
    },
  );
  test(
    'native cancellation failure is reported after archive is durably committed',
    () async {
      await h.seed(task('root'));
      h.notifications.fail = true;
      final result = await h.notifier.changeContentArchive(
        await h.row('root'),
        [],
        true,
        h.database.captureGeneration(),
      );
      expect(result.nativeSyncFailures, greaterThan(0));
      expect((await h.row('root')).details.archivedAt, isNotNull);
    },
  );
  test('archival and classification persist in database snapshots', () async {
    await h.seed(
      task(
        'a',
        details: const TaskDetails(tags: ['work'], project: 'P'),
      ),
    );
    await h.notifier.changeContentArchive(
      await h.row('a'),
      [],
      true,
      h.database.captureGeneration(),
    );
    final encoded = jsonEncode((await h.row('a')).toJson());
    await h.close();
    await h.open();
    expect(jsonEncode((await h.row('a')).toJson()), encoded);
  });
  for (final format in ['json', 'sqlite']) {
    test(
      '$format actual recovery preserves imported templates, classification and archive and rejects old controllers',
      () async {
        await h.seed(task('a'));
        await h.notifier.updateMetadataBatch(
          [await h.row('a')],
          TaskMetadataPatch(
            project: 'Project',
            tagMode: TagEditMode.replace,
            tags: ['tag'],
          ),
          h.database.captureGeneration(),
        );
        await h.notifier.changeContentArchive(
          await h.row('a'),
          [],
          true,
          h.database.captureGeneration(),
        );
        await h.container.read(taskTemplateStoreProvider).importTemplates([], [
          const TemplateImportChoice(
            TaskTemplate(
              id: 'remote',
              name: 'Template',
              title: 'Reusable',
              items: [],
            ),
            TemplateImportAction.copy,
          ),
        ]);
        final original = (await h.row('a')).detailsJson;
        await h.database.createMirrorBackup();
        final source = await File(
          '${h.directory.path}/${format == 'json' ? 'ha_snapshot.json' : 'dont_forget_v3.mirror.db'}',
        ).copy('${h.directory.path}/restore-$format');
        final inspector = BackupInspector(databaseFactoryFfi);
        final preview = await inspector.inspect(source);
        final oldGeneration = h.database.captureGeneration(),
            oldRow = await h.row('a'),
            oldController = h.notifier;
        await oldController.changeContentArchive(
          oldRow,
          [],
          false,
          oldGeneration,
        );
        await DatabaseRecovery(
          h.database,
          inspector: inspector,
          notifications: NotificationService.forTesting(
            FlutterLocalNotificationsPlugin(),
            usesNativeNotifications: false,
          ),
        ).restore(source, expectedDigest: preview.digest);
        await expectLater(
          Future.sync(
            () => oldController.updateMetadataBatch(
              [oldRow],
              TaskMetadataPatch(project: 'stale'),
              oldGeneration,
            ),
          ),
          throwsA(isA<DatabaseAccessException>()),
        );
        await h.close();
        await h.open();
        expect((await h.row('a')).detailsJson, original);
        expect(
          (await h.container.read(taskTemplateStoreProvider).load())
              .single
              .name,
          'Template',
        );
      },
    );
  }
}
