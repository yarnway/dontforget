import 'dart:convert';

import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:flutter_test/flutter_test.dart';

const epoch = '9c2361cc-ea7b-46bd-ab59-5e2873508ff1';
const otherEpoch = '1d43159f-2c14-4283-a921-8ea5d67ff1c9';

Reminder task([String id = 'isolated:"task']) => Reminder(
  id: id,
  taskTitle: 'Synthetic notification',
  quadrantLevel: 2,
  triggerTime: DateTime.parse('2026-10-21T17:30:00.123456+08:00'),
  noticeRevision: 3,
);

void main() {
  test('payload round trips an occurrence using the UTC instant', () {
    final reminder = task();
    final payload = NotificationPayload.forReminder(
      reminder,
      datasetEpoch: epoch,
    );
    final restored = NotificationPayload.tryParse(payload.encode())!;
    // Pin the v1 encoding across app upgrades, not only self-round-trips.
    expect(
      payload.reminderKey,
      'de63b2818705663f033f5df87509c3bdc8d3c8cb89f5c669f90bdb0be3597e58',
    );
    expect(restored.identity, payload.identity);
    expect(
      restored.triggerUtcMicros,
      reminder.triggerTime!.microsecondsSinceEpoch,
    );
    expect(restored.matches(reminder, currentDatasetEpoch: epoch), isTrue);
    expect(
      restored.matches(
        reminder.copyWith(triggerTime: reminder.triggerTime!.toLocal()),
        currentDatasetEpoch: epoch,
      ),
      isTrue,
    );
  });

  test('legacy, missing, oversized and malformed payloads are rejected', () {
    for (final invalid in <String?>[
      null,
      '',
      'isolated-task-id',
      '{',
      '[]',
      'null',
      jsonEncode({'id': task().id}),
      'x' * (NotificationPayload.maxEncodedLength + 1),
    ]) {
      expect(NotificationPayload.tryParse(invalid), isNull, reason: '$invalid');
    }
  });

  test(
    'unknown versions, keys, wrong types and invalid identities fail closed',
    () {
      final valid =
          jsonDecode(
                NotificationPayload.forReminder(
                  task(),
                  datasetEpoch: epoch,
                ).encode(),
              )
              as Map<String, dynamic>;
      final changes = <Map<String, Object?>>[
        {'version': 0},
        {'version': 2},
        {'version': 1.0},
        {'kind': 'complete'},
        {'datasetEpoch': 'legacy'},
        {'datasetEpoch': otherEpoch.toUpperCase()},
        {'datasetEpoch': null},
        {'reminderKey': ''},
        {'reminderKey': 'a' * 63},
        {'reminderKey': 'a' * 65},
        {'reminderKey': 'A' * 64},
        {'reminderKey': 'g' * 64},
        {'reminderKey': null},
        {'reminderId': 'old-unreleased-format'},
        {'noticeRevision': -1},
        {'noticeRevision': 3.0},
        {'noticeRevision': '3'},
        {'triggerUtcMicros': null},
        {'triggerUtcMicros': '2026-10-21'},
        {'triggerUtcMicros': 8640000000000000001},
        {'extra': true},
      ];
      for (final change in changes) {
        expect(
          NotificationPayload.tryParse(jsonEncode({...valid, ...change})),
          isNull,
          reason: '$change',
        );
      }
      for (final key in valid.keys) {
        expect(
          NotificationPayload.tryParse(jsonEncode({...valid}..remove(key))),
          isNull,
          reason: key,
        );
      }
    },
  );

  test(
    'long and NUL database IDs remain routable with bounded opaque keys',
    () {
      for (final id in ['x' * 100000, 'synthetic\u0000legacy-id', '合成提醒🧪']) {
        final reminder = task(id);
        final payload = NotificationPayload.forReminder(
          reminder,
          datasetEpoch: epoch,
        );
        final encoded = payload.encode();
        final restored = NotificationPayload.tryParse(encoded)!;
        expect(payload.reminderKey, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(encoded.length, lessThan(400));
        expect(jsonDecode(encoded), isNot(contains('reminderId')));
        expect(encoded, isNot(contains(id)));
        expect(restored.matches(reminder, currentDatasetEpoch: epoch), isTrue);
        expect(
          restored.matches(task('$id-different'), currentDatasetEpoch: epoch),
          isFalse,
        );
        expect(
          NotificationPayload.forReminder(
            task(id),
            datasetEpoch: epoch,
          ).reminderKey,
          restored.reminderKey,
        );
      }
    },
  );

  test('fingerprints distinguish control characters and unpaired UTF-16', () {
    final ids = ['a\u0000b', 'a\\u0000b', '\ud800', '\ud801', '\ufffd'];
    final keys = [
      for (final id in ids)
        NotificationPayload.forReminder(
          task(id),
          datasetEpoch: epoch,
        ).reminderKey,
    ];
    expect(keys.toSet(), hasLength(ids.length));
    for (var index = 0; index < ids.length; index++) {
      final payload = NotificationPayload.tryParse(
        NotificationPayload.forReminder(
          task(ids[index]),
          datasetEpoch: epoch,
        ).encode(),
      )!;
      expect(
        payload.matches(task(ids[index]), currentDatasetEpoch: epoch),
        isTrue,
      );
    }
  });

  test(
    'changed, deleted-instance, acknowledged and completed occurrences mismatch',
    () {
      final original = task();
      final payload = NotificationPayload.forReminder(
        original,
        datasetEpoch: epoch,
      );
      for (final changed in [
        task('different'),
        original.copyWith(triggerTime: null),
        original.copyWith(
          triggerTime: original.triggerTime!.add(
            const Duration(microseconds: 1),
          ),
        ),
        original.copyWith(noticeRevision: original.noticeRevision + 1),
        original.copyWith(isCompleted: true),
        original.copyWith(noticeAcknowledgedAt: DateTime.utc(2026)),
      ]) {
        expect(payload.matches(changed, currentDatasetEpoch: epoch), isFalse);
      }
      expect(
        payload.matches(original, currentDatasetEpoch: otherEpoch),
        isFalse,
      );
      // Upcoming dismissal is not acknowledgement of a later due occurrence.
      expect(
        payload.matches(
          original.copyWith(upcomingDismissedAt: DateTime.utc(2026)),
          currentDatasetEpoch: epoch,
        ),
        isTrue,
      );
    },
  );

  test(
    'creating a native payload requires an active occurrence and local epoch',
    () {
      for (final invalid in [
        task().copyWith(triggerTime: null),
        task().copyWith(isCompleted: true),
        task().copyWith(noticeAcknowledgedAt: DateTime.utc(2026)),
        task(''),
      ]) {
        expect(
          () => NotificationPayload.forReminder(invalid, datasetEpoch: epoch),
          throwsArgumentError,
        );
      }
      expect(
        () => NotificationPayload.forReminder(task(), datasetEpoch: 'old'),
        throwsArgumentError,
      );
    },
  );
}
