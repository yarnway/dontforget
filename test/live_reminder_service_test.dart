import 'dart:async';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/live_reminder_service.dart';
import 'package:flutter_test/flutter_test.dart';

const epoch = '11111111-1111-4111-8111-111111111111';
const restoredEpoch = '22222222-2222-4222-8222-222222222222';
final instant = DateTime(2026, 10, 27, 16);
Reminder task({String id = 'owned-task', int revision = 0, DateTime? time}) =>
    Reminder(
      id: id,
      taskTitle: 'Review vocabulary',
      taskSummary: 'Synthetic',
      quadrantLevel: 2,
      urgencyLevel: 'General',
      importanceLevel: 'Important',
      triggerTime: time ?? instant.add(const Duration(minutes: 25)),
      noticeRevision: revision,
    );

class Backend implements LiveReminderBackend {
  String? payload;
  Map<String, Object>? content;
  int starts = 0;
  int ends = 0;
  int updates = 0;
  bool failStart = false;
  LiveReminderAvailability availability = LiveReminderAvailability.available;
  Completer<void>? blockedRead;
  @override
  Future<LiveReminderStatus> read() async {
    await blockedRead?.future;
    return LiveReminderStatus(availability, payload: payload);
  }

  @override
  Future<void> start(Map<String, Object> content) async {
    if (failStart) throw StateError('synthetic OS refusal');
    starts++;
    this.content = content;
    payload = content['payload'] as String;
  }

  @override
  Future<void> synchronize(Map<String, Object>? value) async {
    updates++;
    content = value;
    payload = value?['payload'] as String?;
  }

  @override
  Future<void> end() async {
    ends++;
    content = null;
    payload = null;
  }
}

void main() {
  test(
    'eligibility rejects done, acknowledged, past, missing and distant dates',
    () {
      final current = task();
      expect(LiveReminderService.eligible(current, instant), isTrue);
      for (final invalid in [
        current.copyWith(isCompleted: true),
        current.copyWith(noticeAcknowledgedAt: instant),
        current.copyWith(triggerTime: null),
        task(time: instant),
        task(time: instant.add(const Duration(hours: 8, seconds: 1))),
      ]) {
        expect(LiveReminderService.eligible(invalid, instant), isFalse);
      }
      expect(
        LiveReminderService.eligible(
          task(time: instant.add(const Duration(hours: 8))),
          instant,
        ),
        isTrue,
      );
    },
  );

  test('explicit start is bounded and does not mutate task', () async {
    final backend = Backend();
    final service = LiveReminderService(backend, now: () => instant);
    addTearDown(service.dispose);
    final current = task().copyWith(taskTitle: '字' * 300);
    final before = current.toJson();
    await service.start(current, epoch, 'zh');
    expect(backend.starts, 1);
    expect((backend.content!['title'] as String).runes.length, 120);
    expect(
      NotificationPayload.tryParse(
        backend.payload,
      )!.matches(current, currentDatasetEpoch: epoch),
      isTrue,
    );
    expect(current.toJson(), before);
  });

  test('restart recovers selection and snooze updates same task', () async {
    final backend = Backend();
    backend.payload = NotificationPayload.forReminder(
      task(),
      datasetEpoch: epoch,
    ).encode();
    final service = LiveReminderService(backend, now: () => instant);
    addTearDown(service.dispose);
    final changed = task(
      revision: 1,
      time: instant.add(const Duration(hours: 1)),
    ).copyWith(taskTitle: 'Updated title');
    await service.synchronize([task(id: 'other'), changed], epoch, 'ja');
    expect(backend.starts, 0);
    expect(backend.content!['title'], 'Updated title');
    expect(backend.content!['language'], 'ja');
    expect(NotificationPayload.tryParse(backend.payload)!.noticeRevision, 1);
  });

  test(
    'delete, complete, acknowledge, expiry and restore end selection',
    () async {
      for (final scenario in [
        'delete',
        'complete',
        'acknowledge',
        'expiry',
        'restore',
      ]) {
        final backend = Backend();
        backend.payload = NotificationPayload.forReminder(
          task(),
          datasetEpoch: epoch,
        ).encode();
        final service = LiveReminderService(backend, now: () => instant);
        addTearDown(service.dispose);
        final rows = switch (scenario) {
          'delete' => <Reminder>[],
          'complete' => [task().copyWith(isCompleted: true)],
          'acknowledge' => [task().copyWith(noticeAcknowledgedAt: instant)],
          'expiry' => [task(time: instant)],
          _ => [task()],
        };
        await service.synchronize(
          rows,
          scenario == 'restore' ? restoredEpoch : epoch,
          'en',
        );
        expect(backend.payload, isNull, reason: scenario);
        expect(backend.starts, 0);
      }
    },
  );

  test('recovery invalidates start awaiting native capability read', () async {
    final backend = Backend()..blockedRead = Completer<void>();
    final service = LiveReminderService(backend, now: () => instant);
    addTearDown(service.dispose);
    final pending = service.start(task(), epoch, 'en');
    await Future<void>.delayed(Duration.zero);
    final cleanup = service.stop();
    backend.blockedRead!.complete();
    await Future.wait([pending, cleanup]);
    expect(backend.starts, 0);
    expect(backend.ends, 1);
    expect(backend.payload, isNull);
  });

  test('OS refusal does not poison explicit retry', () async {
    final backend = Backend()..failStart = true;
    final service = LiveReminderService(backend, now: () => instant);
    addTearDown(service.dispose);
    await expectLater(service.start(task(), epoch, 'en'), throwsStateError);
    backend.failStart = false;
    await service.start(task(), epoch, 'en');
    expect(backend.starts, 1);
    await service.stop();
    expect(backend.ends, 1);
  });

  test(
    'disabled activity permission does not start or request notification permission',
    () async {
      final backend = Backend()
        ..availability = LiveReminderAvailability.disabled;
      final service = LiveReminderService(backend, now: () => instant);
      addTearDown(service.dispose);
      await expectLater(service.start(task(), epoch, 'en'), throwsStateError);
      expect(backend.starts, 0);
      expect(service.status.availability, LiveReminderAvailability.disabled);
    },
  );

  test(
    'empty selection never creates an activity during startup reconciliation',
    () async {
      final backend = Backend();
      final service = LiveReminderService(backend, now: () => instant);
      addTearDown(service.dispose);
      await service.synchronize(
        List.generate(10000, (i) => task(id: '$i')),
        epoch,
        'en',
      );
      expect(backend.starts, 0);
      expect(backend.updates, 0);
    },
  );
  test(
    'malformed and permission-disabled native selections are ended',
    () async {
      for (final corrupt in [true, false]) {
        final backend = Backend()
          ..payload = corrupt
              ? '{bad'
              : NotificationPayload.forReminder(
                  task(),
                  datasetEpoch: epoch,
                ).encode()
          ..availability = corrupt
              ? LiveReminderAvailability.available
              : LiveReminderAvailability.disabled;
        final service = LiveReminderService(backend, now: () => instant);
        addTearDown(service.dispose);
        await service.synchronize([task()], epoch, 'en');
        expect(backend.ends, 1);
        expect(backend.payload, isNull);
      }
    },
  );
}
