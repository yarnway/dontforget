import 'dart:convert';

import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_route_service.dart';
import 'package:flutter_test/flutter_test.dart';

const epoch = '9c2361cc-ea7b-46bd-ab59-5e2873508ff1';
const otherEpoch = '1d43159f-2c14-4283-a921-8ea5d67ff1c9';

void main() {
  late NotificationRouteService service;
  late Reminder task;
  late List<Reminder> reminders;
  late List<Reminder> opened;
  late String currentEpoch;
  var dataReady = true;
  var navigatorReady = true;
  String payload(Reminder reminder, {String datasetEpoch = epoch}) =>
      NotificationPayload.forReminder(
        reminder,
        datasetEpoch: datasetEpoch,
      ).encode();

  setUp(() {
    task = Reminder(
      id: 'isolated-task',
      taskTitle: 'Synthetic task',
      quadrantLevel: 2,
      triggerTime: DateTime.utc(2026, 10, 21, 10),
      noticeRevision: 4,
    );
    reminders = [task];
    opened = [];
    currentEpoch = epoch;
    dataReady = true;
    navigatorReady = true;
    service = NotificationRouteService(
      readSnapshot: () => dataReady
          ? NotificationRouteSnapshot(
              datasetEpoch: currentEpoch,
              reminders: reminders,
            )
          : null,
      openReminder: (reminder) {
        if (!navigatorReady) return false;
        opened.add(reminder);
        return true;
      },
    );
  });

  tearDown(() => service.dispose());

  test('cold launch waits for data and Navigator without acknowledging', () {
    final before = task.toJson();
    expect(service.receive(payload(task)), NotificationRouteDisposition.queued);
    expect(opened, isEmpty);
    dataReady = false;
    service.setReady(true);
    expect(opened, isEmpty);
    dataReady = true;
    navigatorReady = false;
    service.flush();
    expect(service.pendingCount, 1);
    navigatorReady = true;
    service.flush();
    expect(opened.single, same(task));
    expect(task.toJson(), before);
    expect(task.noticeAcknowledgedAt, isNull);
    expect(service.pendingCount, 0);
  });

  test(
    'warm launch validates immediately and startup callback duplicates once',
    () {
      service.setReady(true);
      expect(
        service.receive(payload(task)),
        NotificationRouteDisposition.opened,
      );
      // Equivalent JSON with a different key order has the same identity.
      final reversed = jsonDecode(payload(task)) as Map<String, dynamic>;
      expect(
        service.receive(
          jsonEncode(Map.fromEntries(reversed.entries.toList().reversed)),
        ),
        NotificationRouteDisposition.duplicate,
      );
      expect(opened, hasLength(1));
      expect(
        service.receive('isolated-task'),
        NotificationRouteDisposition.rejected,
      );
    },
  );

  test('duplicate while queued is discarded before readiness', () {
    expect(service.receive(payload(task)), NotificationRouteDisposition.queued);
    expect(
      service.receive(payload(task)),
      NotificationRouteDisposition.duplicate,
    );
    expect(service.pendingCount, 1);
    service.setReady(true);
    expect(opened, hasLength(1));
  });

  test(
    'deleted, revised, rescheduled and acknowledged targets never navigate',
    () {
      for (final current in <Reminder?>[
        null,
        task.copyWith(noticeRevision: 5),
        task.copyWith(
          triggerTime: task.triggerTime!.add(const Duration(minutes: 5)),
        ),
        task.copyWith(isCompleted: true),
        task.copyWith(noticeAcknowledgedAt: DateTime.utc(2026)),
      ]) {
        // Use a separate service to keep each case independent of deduplication.
        final local = NotificationRouteService(
          readSnapshot: () => NotificationRouteSnapshot(
            datasetEpoch: epoch,
            reminders: current == null ? [] : [current],
          ),
          openReminder: (reminder) {
            opened.add(reminder);
            return true;
          },
        );
        local.receive(payload(task));
        local.setReady(true);
        expect(local.pendingCount, 0);
        expect(opened, isEmpty);
        local.dispose();
      }
    },
  );

  test(
    'recovery discards queued clicks and rejects late identical restored rows',
    () {
      service.receive(payload(task));
      service.setReady(false, discardPending: true);
      expect(service.pendingCount, 0);
      // The new data set deliberately has byte-identical reminder fields.
      currentEpoch = otherEpoch;
      expect(
        service.receive(payload(task)),
        NotificationRouteDisposition.queued,
      );
      service.setReady(true);
      expect(opened, isEmpty);
      expect(service.pendingCount, 0);
      expect(
        service.receive(payload(task, datasetEpoch: otherEpoch)),
        NotificationRouteDisposition.opened,
      );
      expect(opened, hasLength(1));
    },
  );

  test('snoozing allows the new occurrence but ignores its old click', () {
    service.setReady(true);
    service.receive(payload(task));
    final snoozed = task.copyWith(
      triggerTime: task.triggerTime!.add(const Duration(minutes: 5)),
      noticeRevision: 5,
    );
    reminders = [snoozed];
    expect(
      service.receive(payload(task)),
      NotificationRouteDisposition.duplicate,
    );
    expect(
      service.receive(payload(snoozed)),
      NotificationRouteDisposition.opened,
    );
    expect(opened, [task, snoozed]);
  });

  test('synchronous callback reentry cannot push the same route twice', () {
    late NotificationRouteService local;
    local = NotificationRouteService(
      readSnapshot: () =>
          NotificationRouteSnapshot(datasetEpoch: epoch, reminders: [task]),
      openReminder: (reminder) {
        opened.add(reminder);
        expect(
          local.receive(payload(reminder)),
          NotificationRouteDisposition.duplicate,
        );
        local.flush();
        return true;
      },
    );
    local.setReady(true);
    local.receive(payload(task));
    expect(opened, hasLength(1));
    local.dispose();
  });

  test(
    'navigation failure keeps the click available for an explicit retry',
    () {
      var fail = true;
      final local = NotificationRouteService(
        readSnapshot: () =>
            NotificationRouteSnapshot(datasetEpoch: epoch, reminders: [task]),
        openReminder: (reminder) {
          if (fail) throw StateError('Navigator unavailable');
          opened.add(reminder);
          return true;
        },
      );
      local.setReady(true);
      expect(() => local.receive(payload(task)), throwsStateError);
      expect(local.pendingCount, 1);
      fail = false;
      local.flush();
      expect(opened, hasLength(1));
      local.dispose();
    },
  );

  test('snapshot change between queued clicks is revalidated', () {
    final second = Reminder.fromJson(task.toJson()..['id'] = 'second');
    var localEpoch = epoch;
    final local = NotificationRouteService(
      readSnapshot: () => NotificationRouteSnapshot(
        datasetEpoch: localEpoch,
        reminders: [task, second],
      ),
      openReminder: (reminder) {
        opened.add(reminder);
        localEpoch = otherEpoch;
        return true;
      },
    );
    local.receive(payload(task));
    local.receive(payload(second));
    local.setReady(true);
    expect(opened, [task]);
    local.dispose();
  });

  test('unready queue is bounded and disposal prevents future navigation', () {
    final local = NotificationRouteService(
      maxPending: 2,
      maxRemembered: 2,
      readSnapshot: () => null,
      openReminder: (_) => throw StateError('Should not open'),
    );
    for (var index = 0; index < 5; index++) {
      local.receive(
        payload(Reminder.fromJson(task.toJson()..['id'] = 'task-$index')),
      );
    }
    expect(local.pendingCount, 2);
    local.dispose();
    expect(local.pendingCount, 0);
    local.setReady(true);
    expect(local.receive(payload(task)), NotificationRouteDisposition.rejected);
  });
}
