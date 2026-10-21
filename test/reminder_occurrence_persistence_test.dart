import 'dart:convert';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/lan_sync_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Native implements FlutterLocalNotificationsPlugin {
  bool failCancel = false;
  bool failSchedule = false;
  bool failInitialize = false;
  int schedules = 0;
  int cancellations = 0;
  final Set<int> pending = {};

  @override
  dynamic noSuchMethod(Invocation call) {
    switch (call.memberName) {
      case #initialize:
        return failInitialize
            ? Future<bool>.error(StateError('Synthetic initialization failure'))
            : Future<bool>.value(true);
      case #getNotificationAppLaunchDetails:
        return Future<NotificationAppLaunchDetails?>.value(
          const NotificationAppLaunchDetails(false),
        );
      case #cancel:
        cancellations++;
        if (failCancel) {
          return Future<void>.error(StateError('Synthetic cancel failure'));
        }
        pending.remove(call.positionalArguments.first);
        return Future<void>.value();
      case #cancelAll:
        pending.clear();
        return Future<void>.value();
      case #zonedSchedule:
        schedules++;
        if (failSchedule) {
          return Future<void>.error(StateError('Synthetic scheduling failure'));
        }
        pending.add(call.positionalArguments.first as int);
        return Future<void>.value();
      default:
        throw UnsupportedError('${call.memberName}');
    }
  }
}

void main() {
  final now = DateTime(2030, 1, 1, 9, 1);
  late Directory directory;
  late DatabaseHelper helper;
  late Database db;
  late _Native native;
  late NotificationService notifications;
  RemindersNotifier? notifier;

  Reminder task(String id, {bool recurring = false, bool upcoming = false}) =>
      Reminder(
        id: id,
        taskTitle: 'Synthetic $id',
        quadrantLevel: 2,
        triggerTime: upcoming
            ? now.add(const Duration(days: 2))
            : DateTime(2030, 1, 1, 9),
        isRecurring: recurring,
        recurrenceRule: recurring ? 'daily' : 'none',
      );

  Future<RemindersNotifier> load({bool effects = false}) async {
    notifier?.dispose();
    final value = notifier = RemindersNotifier(
      helper,
      notifications: notifications,
      runLoadEffects: effects,
    );
    await value.ready;
    return value;
  }

  Future<Reminder> stored(String id) async => Reminder.fromJson(
    (await db.query('Reminders', where: 'id = ?', whereArgs: [id])).single,
  );

  Future<void> seed(Reminder item) async {
    await db.insert('Reminders', item.toJson());
  }

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('reminder-occurrence-');
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    db = await helper.database;
    native = _Native();
    notifications = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
      now: () => now,
    );
    notifier = null;
  });

  tearDown(() async {
    notifier?.dispose();
    await notifications.pauseForMaintenance();
    await helper.close(createBackup: false);
    await directory.delete(recursive: true);
  });

  test(
    'due acknowledgement survives a real database reopen and is never rescheduled',
    () async {
      final original = task('due');
      await seed(original);
      final current = await load();
      final result = await current.acknowledgeOccurrence(
        original,
        phase: ReminderNoticePhase.due,
        now: now,
      );
      expect(result.disposition, ReminderActionDisposition.applied);
      expect(result.nativeSyncFailed, isFalse);
      expect((await stored('due')).noticeAcknowledgedAt, now);
      current.dispose();
      notifier = null;
      await helper.close(createBackup: false);
      db = await helper.database;
      final reopened = await load(effects: true);
      expect(reopened.state.single.noticeAcknowledgedAt, now);
      expect(native.schedules, 0);
      await notifications.pauseForMaintenance();
      await notifications.resumeFromReminders([
        task('future', upcoming: true).copyWith(noticeAcknowledgedAt: now),
      ]);
      expect(native.schedules, 0);
    },
  );

  test(
    'upcoming dismissal persists separately and does not cancel the future reminder',
    () async {
      final original = task('upcoming', upcoming: true);
      await seed(original);
      final current = await load();
      final result = await current.acknowledgeOccurrence(
        original,
        phase: ReminderNoticePhase.upcoming,
        now: now,
      );
      expect(result.reminder!.upcomingDismissedAt, now);
      expect(result.reminder!.noticeAcknowledgedAt, isNull);
      expect(native.cancellations, 0);
      final reopened = await load(effects: true);
      expect(reopened.state.single.upcomingDismissedAt, now);
      expect(native.pending, contains(original.id.hashCode));
      expect(native.schedules, 1);
    },
  );

  test(
    'repeated snooze and restart preserve the original daily recurrence anchor',
    () async {
      final original = task('daily', recurring: true);
      await seed(original);
      final current = await load();
      final first = await current.snoozeOccurrence(original, now: now);
      expect(first.reminder!.triggerTime, DateTime(2030, 1, 1, 9, 6));
      expect(first.reminder!.recurrenceAnchorTime, original.triggerTime);
      expect(first.reminder!.noticeRevision, 1);
      final reopened = await load();
      final second = await reopened.snoozeOccurrence(
        reopened.state.single,
        now: DateTime(2030, 1, 1, 9, 7),
      );
      expect(second.reminder!.triggerTime, DateTime(2030, 1, 1, 9, 12));
      expect(second.reminder!.recurrenceAnchorTime, original.triggerTime);
      expect(second.reminder!.snoozedAt, DateTime(2030, 1, 1, 9, 7));
      final completed = await reopened.completeOccurrence(
        second.reminder!,
        now: DateTime(2030, 1, 1, 9, 13),
      );
      expect(completed.reminder!.triggerTime, DateTime(2030, 1, 2, 9));
      expect(completed.reminder!.noticeRevision, 3);
      expect(completed.reminder!.recurrenceAnchorTime, original.triggerTime);
      expect(completed.reminder!.snoozedAt, isNull);
      expect(completed.reminder!.isCompleted, isFalse);
      expect((await stored('daily')).toJson(), completed.reminder!.toJson());
    },
  );

  for (final snoozeFirst in [false, true]) {
    test('monthly completion preserves January 31 across February and March '
        '(snooze: $snoozeFirst)', () async {
      final anchor = DateTime(2030, 1, 31, 9);
      final original = task(
        'monthly',
        recurring: true,
      ).copyWith(triggerTime: anchor, recurrenceRule: 'monthly');
      await seed(original);
      final current = await load();
      var pending = original;
      if (snoozeFirst) {
        pending = (await current.snoozeOccurrence(
          pending,
          now: anchor.add(const Duration(minutes: 1)),
        )).reminder!;
      }
      final first = await current.completeOccurrence(
        pending,
        now: anchor.add(const Duration(minutes: 7)),
      );
      expect(first.reminder!.triggerTime, DateTime(2030, 2, 28, 9));
      expect((await stored('monthly')).recurrenceAnchorTime, anchor);
      final reopened = await load();
      final second = await reopened.completeOccurrence(
        reopened.state.single,
        now: DateTime(2030, 2, 28, 9, 1),
      );
      expect(second.reminder!.triggerTime, DateTime(2030, 3, 31, 9));
      expect(second.reminder!.recurrenceAnchorTime, anchor);
      expect(second.reminder!.snoozedAt, isNull);
      expect((await stored('monthly')).toJson(), second.reminder!.toJson());
    });

    test('yearly completion restores February 29 after a non-leap year '
        '(snooze: $snoozeFirst)', () async {
      final anchor = DateTime(2032, 2, 29, 9);
      final original = task(
        'yearly',
        recurring: true,
      ).copyWith(triggerTime: anchor, recurrenceRule: 'yearly');
      await seed(original);
      final current = await load();
      var pending = original;
      if (snoozeFirst) {
        pending = (await current.snoozeOccurrence(
          pending,
          now: anchor.add(const Duration(minutes: 1)),
        )).reminder!;
      }
      final first = await current.completeOccurrence(
        pending,
        now: anchor.add(const Duration(minutes: 7)),
      );
      expect(first.reminder!.triggerTime, DateTime(2033, 2, 28, 9));
      expect((await stored('yearly')).recurrenceAnchorTime, anchor);
      final reopened = await load();
      final second = await reopened.completeOccurrence(
        reopened.state.single,
        now: DateTime(2035, 3, 1, 9),
      );
      expect(second.reminder!.triggerTime, DateTime(2036, 2, 29, 9));
      expect(second.reminder!.recurrenceAnchorTime, anchor);
      expect(second.reminder!.snoozedAt, isNull);
      expect((await stored('yearly')).toJson(), second.reminder!.toJson());
    });
  }

  test(
    'early completion advances beyond the current future occurrence',
    () async {
      final anchor = DateTime(2030, 1, 31, 9);
      final original = task(
        'early',
        recurring: true,
      ).copyWith(triggerTime: anchor, recurrenceRule: 'monthly');
      await seed(original);
      final current = await load();
      final first = await current.completeOccurrence(
        original,
        now: anchor.add(const Duration(minutes: 1)),
      );
      final second = await current.completeOccurrence(
        first.reminder!,
        now: anchor.add(const Duration(minutes: 2)),
      );
      expect(first.reminder!.triggerTime, DateTime(2030, 2, 28, 9));
      expect(second.reminder!.triggerTime, DateTime(2030, 3, 31, 9));
      expect((await stored('early')).noticeRevision, 2);
    },
  );

  test(
    'manual recurrence rule edit resets a retained calendar anchor',
    () async {
      final anchor = DateTime(2030, 1, 31, 9);
      final original = task(
        'edited-rule',
        recurring: true,
      ).copyWith(triggerTime: anchor, recurrenceRule: 'monthly');
      await seed(original);
      final current = await load();
      final first = await current.completeOccurrence(
        original,
        now: anchor.add(const Duration(minutes: 1)),
      );
      await current.updateReminder(
        first.reminder!.copyWith(recurrenceRule: 'yearly'),
      );
      final saved = await stored('edited-rule');
      expect(saved.recurrenceAnchorTime, isNull);
      expect(saved.noticeRevision, 2);
      expect(
        saved.getNextOccurrence(after: saved.triggerTime),
        DateTime(2031, 2, 28, 9),
      );
    },
  );

  test(
    'two concurrent snoozes only apply once and reject the old occurrence',
    () async {
      final original = task('due');
      await seed(original);
      final current = await load();
      final results = await Future.wait([
        current.snoozeOccurrence(original, now: now),
        current.snoozeOccurrence(original, now: now),
      ]);
      expect(results.map((r) => r.disposition), [
        ReminderActionDisposition.applied,
        ReminderActionDisposition.stale,
      ]);
      expect(native.schedules, 1);
      expect((await stored('due')).noticeRevision, 1);
    },
  );

  test(
    'acknowledgement wins over a queued old snooze while explicit completion stays available',
    () async {
      final original = task('due');
      await seed(original);
      final current = await load();
      final acknowledgement = current.acknowledgeOccurrence(
        original,
        phase: ReminderNoticePhase.due,
        now: now,
      );
      final snooze = current.snoozeOccurrence(original, now: now);
      await acknowledgement;
      expect((await snooze).disposition, ReminderActionDisposition.stale);
      expect((await stored('due')).triggerTime, original.triggerTime);
      expect((await stored('due')).noticeAcknowledgedAt, now);
      expect(native.schedules, 0);
      expect(
        (await current.completeOccurrence(
          current.state.single,
          now: now,
        )).disposition,
        ReminderActionDisposition.applied,
      );
    },
  );

  test(
    'actions read persisted revision even when provider state has not refreshed',
    () async {
      final original = task('due');
      await seed(original);
      final current = await load();
      await db.update(
        'Reminders',
        {
          'notice_revision': 1,
          'trigger_time': now.add(const Duration(hours: 1)).toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: ['due'],
      );
      final result = await current.completeOccurrence(original, now: now);
      expect(result.disposition, ReminderActionDisposition.stale);
      expect((await stored('due')).isCompleted, isFalse);
      expect(native.cancellations, 0);
    },
  );

  test(
    'generic old task updates cannot erase acknowledgement metadata',
    () async {
      final original = task('due');
      await seed(original);
      final current = await load();
      await current.acknowledgeOccurrence(
        original,
        phase: ReminderNoticePhase.due,
        now: now,
      );
      await current.updateReminder(
        original.copyWith(taskTitle: 'Edited title'),
      );
      expect((await stored('due')).noticeAcknowledgedAt, now);
      expect(current.state.single.noticeAcknowledgedAt, now);
      expect(current.state.single.taskTitle, 'Edited title');
    },
  );

  test('generic old snapshot cannot restore the pre-snooze time', () async {
    final original = task('due');
    await seed(original);
    final current = await load();
    await current.snoozeOccurrence(original, now: now);
    await expectLater(
      current.updateReminder(original.copyWith(taskTitle: 'Old edit')),
      throwsA(isA<StaleReminderOccurrenceException>()),
    );
    final saved = await stored('due');
    expect(saved.triggerTime, now.add(const Duration(minutes: 5)));
    expect(saved.taskTitle, original.taskTitle);
    expect(saved.noticeRevision, 1);
  });

  test(
    'queued independent title edit preserves a snooze committed ahead of it',
    () async {
      final original = task('due');
      await seed(original);
      final current = await load();
      final snooze = current.snoozeOccurrence(original, now: now);
      final title = current.updateReminder(
        original.copyWith(taskTitle: 'Queued title'),
      );
      await snooze;
      await title;
      final saved = await stored('due');
      expect(saved.triggerTime, now.add(const Duration(minutes: 5)));
      expect(saved.taskTitle, 'Queued title');
      expect(saved.noticeRevision, 1);
    },
  );

  test(
    'a deliberate time edit resets acknowledgement and snooze metadata',
    () async {
      final original = task('daily', recurring: true);
      await seed(original);
      final current = await load();
      final snoozed = await current.snoozeOccurrence(original, now: now);
      final desired = DateTime(2030, 1, 3, 10);
      await current.updateReminder(
        snoozed.reminder!.copyWith(triggerTime: desired),
      );
      final saved = await stored('daily');
      expect(saved.triggerTime, desired);
      expect(saved.recurrenceAnchorTime, isNull);
      expect(saved.snoozedAt, isNull);
      expect(saved.noticeRevision, 2);
      expect(saved.getNextOccurrence(after: desired), DateTime(2030, 1, 4, 10));
    },
  );

  test(
    'batch acknowledgement is atomic on database failure and may retry',
    () async {
      await seed(task('alpha'));
      await seed(task('beta'));
      final current = await load();
      await db.execute(
        "CREATE TRIGGER reject_ack BEFORE UPDATE ON Reminders "
        "WHEN NEW.id = 'beta' BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END",
      );
      await expectLater(
        current.acknowledgeOccurrences(current.state, now: now),
        throwsA(isA<DatabaseException>()),
      );
      expect((await stored('alpha')).noticeAcknowledgedAt, isNull);
      expect(
        current.state.every((r) => r.noticeAcknowledgedAt == null),
        isTrue,
      );
      expect(native.cancellations, 0);
      await db.execute('DROP TRIGGER reject_ack');
      final results = await current.acknowledgeOccurrences(
        current.state,
        now: now,
      );
      expect(results.every((r) => r.accepted), isTrue);
      expect((await stored('beta')).noticeAcknowledgedAt, now);
    },
  );

  test(
    'saved acknowledgement reports cancellation failure and duplicate action retries it',
    () async {
      final original = task('due');
      await seed(original);
      final current = await load();
      native.failCancel = true;
      final result = await current.acknowledgeOccurrence(
        original,
        phase: ReminderNoticePhase.due,
        now: now,
      );
      expect(result.disposition, ReminderActionDisposition.applied);
      expect(result.nativeSyncFailed, isTrue);
      expect((await stored('due')).noticeAcknowledgedAt, now);
      native.failCancel = false;
      final retry = await current.acknowledgeOccurrence(
        original,
        phase: ReminderNoticePhase.due,
        now: now,
      );
      expect(retry.disposition, ReminderActionDisposition.alreadyApplied);
      expect(retry.nativeSyncFailed, isFalse);
      expect(native.cancellations, 2);
    },
  );

  test(
    'saved snooze survives scheduling failure with an explicit failure result',
    () async {
      final original = task('due');
      await seed(original);
      final current = await load();
      native.failSchedule = true;
      final result = await current.snoozeOccurrence(original, now: now);
      expect(result.disposition, ReminderActionDisposition.applied);
      expect(result.nativeSyncFailed, isTrue);
      expect(
        (await stored('due')).triggerTime,
        now.add(const Duration(minutes: 5)),
      );
      native.failSchedule = false;
      await notifications.scheduleReminderStrict(result.reminder!);
      expect(native.pending, contains(original.id.hashCode));
    },
  );

  test(
    'strict initialization failure reaches the caller and a later request retries',
    () async {
      native.failInitialize = true;
      await expectLater(
        notifications.scheduleReminderStrict(task('future', upcoming: true)),
        throwsStateError,
      );
      expect(native.schedules, 0);
      native.failInitialize = false;
      await notifications.scheduleReminderStrict(
        task('future', upcoming: true),
      );
      expect(native.schedules, 1);
    },
  );

  test(
    'ordinary task completion and reopening create distinct revisions',
    () async {
      final original = task('plain').copyWith(triggerTime: null);
      await seed(original);
      final current = await load();
      final completed = await current.completeOccurrence(original, now: now);
      expect(completed.reminder!.isCompleted, isTrue);
      expect(completed.reminder!.noticeRevision, 1);
      await current.updateReminder(
        completed.reminder!.copyWith(isCompleted: false),
      );
      expect((await stored('plain')).isCompleted, isFalse);
      expect((await stored('plain')).noticeRevision, 2);
      final stale = await current.completeOccurrence(original, now: now);
      expect(stale.disposition, ReminderActionDisposition.stale);
    },
  );

  test(
    'LAN completion preserves local content and refresh cancels the old request',
    () async {
      final original = task('local', upcoming: true).copyWith(
        taskTitle: 'Current local title',
        noticeRevision: 4,
        snoozedAt: now,
        recurrenceAnchorTime: DateTime(2030, 1, 1, 9),
      );
      await seed(original);
      final current = await load(effects: true);
      expect(native.pending, contains(original.id.hashCode));
      final lan = LanSyncService.forTesting();
      final client = HttpClient();
      try {
        final server = await lan.startServer(port: 0, dbHelper: helper);
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/sync'),
        );
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({
            'pin': server.pin,
            'reminders': [
              task(
                'local',
              ).copyWith(isCompleted: true, noticeRevision: 99).toJson(),
              task('foreign', upcoming: true)
                  .copyWith(
                    noticeRevision: 99,
                    noticeAcknowledgedAt: now,
                    upcomingDismissedAt: now,
                    snoozedAt: now,
                    recurrenceAnchorTime: DateTime(2030, 1, 1, 9),
                  )
                  .toJson(),
            ],
          }),
        );
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.ok);
        final local = await stored('local');
        expect(local.isCompleted, isTrue);
        expect(local.taskTitle, original.taskTitle);
        expect(local.triggerTime, original.triggerTime);
        expect(local.noticeRevision, 5);
        expect(local.snoozedAt, isNull);
        expect(local.recurrenceAnchorTime, isNull);
        final foreign = await stored('foreign');
        expect(foreign.noticeRevision, 0);
        expect(foreign.noticeAcknowledgedAt, isNull);
        expect(foreign.upcomingDismissedAt, isNull);
        expect(foreign.recurrenceAnchorTime, DateTime(2030, 1, 1, 9));
        await current.refreshReminders();
        expect(native.pending, isNot(contains(original.id.hashCode)));
        expect(native.pending, contains('foreign'.hashCode));
      } finally {
        client.close(force: true);
        await lan.stopServer();
      }
    },
  );
}
