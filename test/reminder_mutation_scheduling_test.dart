import 'dart:async';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Native extends NotificationService {
  _Native() : super.forTesting(_UnusedPlugin(), usesNativeNotifications: false);
  final scheduled = <Reminder>[];
  final cancelled = <String>[];
  final failures = <String>{};
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<void> scheduleReminderStrict(Reminder reminder) async {
    scheduled.add(reminder);
    if (entered?.isCompleted == false) entered!.complete();
    await release?.future;
    if (failures.contains(reminder.id)) throw StateError('native schedule');
  }

  @override
  Future<void> cancelReminderStrict(String id) async {
    cancelled.add(id);
    if (failures.contains(id)) throw StateError('native cancel');
  }
}

// No platform or OS notification request is made in this suite.
class _UnusedPlugin extends Fake implements FlutterLocalNotificationsPlugin {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper helper;
  late Database database;
  late _Native native;
  RemindersNotifier? notifier;
  Reminder task(String id, {int quadrant = 3}) => Reminder(
    id: id,
    taskTitle: 'Synthetic $id',
    quadrantLevel: quadrant,
    triggerTime: DateTime.now().add(const Duration(hours: 2)),
  );
  Future<Reminder> saved(String id) async => Reminder.fromJson(
    (await database.query(
      'Reminders',
      where: 'id = ?',
      whereArgs: [id],
    )).single,
  );
  Future<RemindersNotifier> load({bool effects = false}) async {
    notifier = RemindersNotifier(
      helper,
      notifications: native,
      runLoadEffects: effects,
    );
    await notifier!.ready;
    return notifier!;
  }

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('mutation-scheduling-');
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    database = await helper.database;
    native = _Native();
  });
  tearDown(() async {
    notifier?.dispose();
    notifier = null;
    await helper.close(createBackup: false);
    await directory.delete(recursive: true);
  });

  test(
    'add and edits schedule committed content once; metadata alone does not',
    () async {
      final current = await load();
      final added = await current.addReminder(task('edit'));
      expect(added.nativeSyncFailed, isFalse);
      expect(native.scheduled.single.toJson(), (await saved('edit')).toJson());
      final changed = await current.updateReminder(
        added.reminder!.copyWith(taskTitle: 'New title', quadrantLevel: 1),
      );
      expect(native.scheduled, hasLength(2));
      expect(native.scheduled.last.toJson(), changed.reminder!.toJson());
      expect(changed.reminder!.noticeRevision, 0);
      await current.updateReminder(
        changed.reminder!.copyWith(subTasks: '["step"]'),
      );
      expect(native.scheduled, hasLength(2));
      expect((await saved('edit')).subTasks, '["step"]');
    },
  );

  test(
    'native failure preserves commit; unchanged save retries without revising',
    () async {
      final current = await load();
      native.failures.add('retry');
      final result = await current.addReminder(task('retry'));
      expect(result.nativeSyncFailed, isTrue);
      expect((await saved('retry')).toJson(), result.reminder!.toJson());
      native.failures.clear();
      final retry = await current.updateReminder(result.reminder!);
      expect(retry.disposition, ReminderActionDisposition.alreadyApplied);
      expect(retry.nativeSyncFailed, isFalse);
      expect(native.scheduled, hasLength(2));
      expect((await saved('retry')).noticeRevision, 0);
      await current.updateReminder(retry.reminder!);
      expect(native.scheduled, hasLength(2));
    },
  );

  test('failed insertion or update never emits a native mutation', () async {
    final current = await load();
    final original = task('write');
    await current.addReminder(original);
    native.scheduled.clear();
    await expectLater(
      current.addReminder(original),
      throwsA(isA<DatabaseException>()),
    );
    await database.execute(
      "CREATE TRIGGER reject_write BEFORE UPDATE ON Reminders "
      "BEGIN SELECT RAISE(ABORT, 'isolated failure'); END",
    );
    await expectLater(
      current.updateReminder(original.copyWith(taskTitle: 'Rejected')),
      throwsA(isA<DatabaseException>()),
    );
    expect(native.scheduled, isEmpty);
    expect((await saved('write')).taskTitle, original.taskTitle);
  });

  test('a queued delete cannot be overtaken by an older schedule', () async {
    final current = await load();
    native.entered = Completer<void>();
    native.release = Completer<void>();
    final adding = current.addReminder(task('ordered'));
    await native.entered!.future;
    final deleting = current.deleteReminder('ordered');
    await Future<void>.delayed(Duration.zero);
    expect(await database.query('Reminders'), hasLength(1));
    expect(native.cancelled, isEmpty);
    native.release!.complete();
    await adding;
    await deleting;
    expect(await database.query('Reminders'), isEmpty);
    expect(native.scheduled, hasLength(1));
    expect(native.cancelled, ['ordered']);
  });

  test(
    'queued independent edits preserve both saved and scheduled fields',
    () async {
      final current = await load();
      final original = task('queued');
      await current.addReminder(original);
      native.entered = Completer<void>();
      native.release = Completer<void>();
      final title = current.updateReminder(
        original.copyWith(taskTitle: 'Queued title'),
      );
      await native.entered!.future;
      final quadrant = current.updateReminder(
        original.copyWith(quadrantLevel: 1),
        baseline: original,
      );
      native.release!.complete();
      await Future.wait([title, quadrant]);
      expect(native.scheduled.last.taskTitle, 'Queued title');
      expect(native.scheduled.last.quadrantLevel, 1);
      expect(native.scheduled.last.toJson(), (await saved('queued')).toJson());
    },
  );

  test(
    'maintenance drains admitted native work and rejects queued old mutation',
    () async {
      final current = await load();
      native.entered = Completer<void>();
      native.release = Completer<void>();
      final adding = current.addReminder(task('admitted'));
      await native.entered!.future;
      final queued = current.addReminder(task('old-queued'));
      final addedRejected = expectLater(
        adding,
        throwsA(isA<DatabaseAccessException>()),
      );
      final queuedRejected = expectLater(
        queued,
        throwsA(isA<DatabaseAccessException>()),
      );
      var granted = false;
      final maintaining = helper.beginMaintenance().then((lease) {
        granted = true;
        return lease;
      });
      await Future<void>.delayed(Duration.zero);
      expect(granted, isFalse);
      native.release!.complete();
      await Future.wait([addedRejected, queuedRejected]);
      final lease = await maintaining;
      expect(native.scheduled.map((r) => r.id), ['admitted']);
      await lease.resume();
      expect((await database.query('Reminders')).map((r) => r['id']), [
        'admitted',
      ]);
    },
  );

  test(
    'failed delete cancellation retries after row removal and then retires',
    () async {
      final current = await load();
      await current.addReminder(task('deleted'));
      native.failures.add('deleted');
      final result = await current.deleteReminder('deleted');
      expect(result.nativeSyncFailed, isTrue);
      expect(result.reminder!.id, 'deleted');
      expect(await database.query('Reminders'), isEmpty);
      expect(await current.retryNotificationDelivery(), (
        attempted: 1,
        failed: 1,
      ));
      native.failures.clear();
      expect(await current.retryNotificationDelivery(), (
        attempted: 1,
        failed: 0,
      ));
      expect(await current.retryNotificationDelivery(), (
        attempted: 0,
        failed: 0,
      ));
      expect(await database.query('Reminders'), isEmpty);
    },
  );

  test(
    'moving an alarm to the past cancels it and retains a failed cancellation',
    () async {
      final current = await load();
      final original = task('past');
      await current.addReminder(original);
      native.failures.add('past');
      final result = await current.updateReminder(
        original.copyWith(
          triggerTime: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
      );
      expect(result.nativeSyncFailed, isTrue);
      expect(native.scheduled, hasLength(1));
      expect(native.cancelled, ['past']);
      native.failures.clear();
      expect(await current.retryNotificationDelivery(), (
        attempted: 1,
        failed: 0,
      ));
      expect(native.cancelled, ['past', 'past']);
      expect(await current.retryNotificationDelivery(), (
        attempted: 0,
        failed: 0,
      ));
    },
  );

  test(
    'ordinary overdue content edits preserve delivered banners without replay',
    () async {
      final current = await load();
      final overdue = task('overdue').copyWith(
        triggerTime: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      await current.addReminder(overdue);
      await current.updateReminder(
        overdue.copyWith(taskTitle: 'Still overdue'),
      );
      expect(native.scheduled, isEmpty);
      expect(native.cancelled, isEmpty);
    },
  );

  test(
    'startup promotes then schedules once using committed priority',
    () async {
      await database.insert(
        'Reminders',
        task('promoted', quadrant: 2).toJson(),
      );
      await load(effects: true);
      expect(native.scheduled, hasLength(1));
      expect(native.scheduled.single.quadrantLevel, 1);
      expect(
        native.scheduled.single.toJson(),
        (await saved('promoted')).toJson(),
      );
    },
  );

  test(
    'promotion uses current database and skips acknowledged or externally completed rows',
    () async {
      final active = task('active', quadrant: 2);
      final completed = task('completed', quadrant: 2);
      final acknowledged = task(
        'acknowledged',
        quadrant: 2,
      ).copyWith(noticeAcknowledgedAt: DateTime.now());
      for (final r in [active, completed, acknowledged]) {
        await database.insert('Reminders', r.toJson());
      }
      final current = await load();
      await database.update(
        'Reminders',
        {'is_completed': 1},
        where: 'id = ?',
        whereArgs: ['completed'],
      );
      await database.update(
        'Reminders',
        {'task_title': 'Latest LAN title'},
        where: 'id = ?',
        whereArgs: ['active'],
      );
      native.failures.add('active');
      final result = await current.scanAndApplyDynamicUrgency();
      expect(result.changed, 1);
      expect(result.nativeSyncFailures, 1);
      expect(native.scheduled.single.taskTitle, 'Latest LAN title');
      expect(native.scheduled.single.quadrantLevel, 1);
      expect((await saved('completed')).quadrantLevel, 2);
      expect((await saved('acknowledged')).quadrantLevel, 2);
      expect((await current.scanAndApplyDynamicUrgency()).changed, 0);
    },
  );

  test(
    'bulk removal cancels only removed rows and reports partial native failures',
    () async {
      for (final r in [
        task('one').copyWith(isCompleted: true),
        task('two').copyWith(isCompleted: true),
        task('keep'),
      ]) {
        await database.insert('Reminders', r.toJson());
      }
      final current = await load();
      native.failures.add('two');
      final result = await current.clearCompletedReminders();
      expect(result.changed, 2);
      expect(result.nativeSyncFailures, 1);
      expect(native.cancelled, ['one', 'two']);
      expect(current.state.single.id, 'keep');
      native.failures.clear();
      expect(await current.retryNotificationDelivery(), (
        attempted: 2,
        failed: 0,
      ));
      expect(native.cancelled.last, 'two');
      expect(native.scheduled.single.id, 'keep');
    },
  );

  test('deleted snapshot and undo use last committed contents', () async {
    final current = await load();
    final original = task('undo');
    await current.addReminder(original);
    await current.updateReminder(
      original.copyWith(taskTitle: 'Latest content'),
    );
    final deleted = await current.deleteReminder(original.id);
    await current.restoreDeletedReminder(
      deleted.reminder!,
      helper.captureGeneration(),
    );
    expect(native.scheduled.last.taskTitle, 'Latest content');
    expect((await saved('undo')).taskTitle, 'Latest content');
  });

  for (final linked in [false, true]) {
    test(
      'undo preserves saved relationships and other rows (linked=$linked)',
      () async {
        final original = task('restore').copyWith(
          taskTitle: 'Shared synthetic acceptance content',
          linkedTaskIds: linked ? ['peer'] : [],
        );
        final peer = task('peer').copyWith(
          taskTitle: 'Shared synthetic acceptance content',
          linkedTaskIds: linked ? [original.id] : [],
        );
        await database.insert('Reminders', original.toJson());
        await database.insert('Reminders', peer.toJson());
        final current = await load();
        final generation = helper.captureGeneration();
        final deleted = await current.deleteReminder(original.id);
        final restored = await current.restoreDeletedReminder(
          deleted.reminder!,
          generation,
        );
        expect(restored.reminder!.toJson(), original.toJson());
        expect((await saved(original.id)).toJson(), original.toJson());
        expect((await saved(peer.id)).toJson(), peer.toJson());
        expect(native.scheduled.single.toJson(), original.toJson());
      },
    );
  }

  test('undo from an earlier dataset cannot insert or schedule', () async {
    final current = await load();
    final original = task('old-undo');
    await current.addReminder(original);
    final generation = helper.captureGeneration();
    final deleted = await current.deleteReminder(original.id);
    native.scheduled.clear();
    final lease = await helper.beginMaintenance();
    await lease.resume();
    await expectLater(
      current.restoreDeletedReminder(deleted.reminder!, generation),
      throwsA(
        isA<DatabaseAccessException>().having(
          (e) => e.code,
          'code',
          DatabaseAccessError.staleGeneration,
        ),
      ),
    );
    expect(await database.query('Reminders'), isEmpty);
    expect(native.scheduled, isEmpty);
  });

  test(
    'missing-row edit fails without recreating or scheduling a task',
    () async {
      final current = await load();
      await expectLater(
        current.updateReminder(task('missing')),
        throwsStateError,
      );
      expect(native.scheduled, isEmpty);
      expect(await database.query('Reminders'), isEmpty);
    },
  );
  test('refresh across recovery discards old cancellation retries', () async {
    final current = await load();
    await current.addReminder(task('old-dataset'));
    native.failures.add('old-dataset');
    expect(
      (await current.deleteReminder('old-dataset')).nativeSyncFailed,
      isTrue,
    );
    final lease = await helper.beginMaintenance();
    await lease.resume();
    await current.refreshReminders();
    native.cancelled.clear();
    expect(await current.retryNotificationDelivery(), (
      attempted: 0,
      failed: 0,
    ));
    expect(native.cancelled, isEmpty);
  });
}
