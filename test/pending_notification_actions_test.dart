import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/pending_notification_actions.dart';
import 'package:flutter_test/flutter_test.dart';

const _epoch = '10000000-0000-4000-8000-000000000001';

NotificationActionRequest _request(
  int index, {
  String action = 'snooze_15',
  DateTime? at,
}) => NotificationActionRequest(
  payload: NotificationPayload.forReminder(
    Reminder(
      id: 'synthetic-$index',
      taskTitle: 'Synthetic task',
      triggerTime: DateTime.utc(2030, 1, 1, 9),
      quadrantLevel: 2,
      noticeRevision: index,
    ),
    datasetEpoch: _epoch,
  ),
  actionId: action,
  occurredAt: at ?? DateTime.utc(2030, 1, 1, 9, 1),
);

void main() {
  late Directory directory;
  late PendingNotificationActions queue;
  File queueFile() =>
      File('${directory.path}/${PendingNotificationActions.fileName}');

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pending-actions-test-');
    queue = PendingNotificationActions.forDirectory(directory);
  });

  tearDown(() async => directory.delete(recursive: true));

  test('request preserves exact payload, action and action time', () {
    for (final action in [
      'complete',
      'snooze_15',
      'snooze_60',
      'skip_occurrence',
    ]) {
      final request = _request(1, action: action);
      final restored = NotificationActionRequest.tryParse(request.encode())!;
      expect(restored.identity, request.identity);
      expect(restored.payload.encode(), request.payload.encode());
      expect(restored.actionId, action);
      expect(restored.occurredAt, request.occurredAt);
    }
    expect(
      _request(1, action: 'complete').identity,
      isNot(_request(1, action: 'snooze_15').identity),
    );
  });

  test('request rejects unknown versions, fields, action and bad payload', () {
    final valid = _request(1).toJson();
    for (final invalid in [
      {...valid, 'version': 2},
      {...valid, 'version': 1.0},
      {...valid, 'actionId': 'open'},
      {...valid, 'payload': '{}'},
      {...valid, 'occurredAt': '2030-01-01'},
      {...valid, 'extra': true},
      {...valid}..remove('occurredAt'),
    ]) {
      expect(NotificationActionRequest.tryParse(jsonEncode(invalid)), isNull);
    }
    expect(NotificationActionRequest.tryParse('['), isNull);
    expect(NotificationActionRequest.tryParse('a' * 3000), isNull);
  });

  test(
    'restart retains action time and removes individually after handling',
    () async {
      final first = _request(1);
      final second = _request(2);
      await queue.enqueue(first);
      await queue.enqueue(second);
      queue = PendingNotificationActions.forDirectory(directory);
      expect((await queue.read()).map((item) => item.identity), [
        first.identity,
        second.identity,
      ]);
      expect((await queue.read()).first.occurredAt, first.occurredAt);
      await queue.remove(first.identity);
      expect((await queue.read()).single.identity, second.identity);
      await queue.remove(second.identity);
      expect(await queue.read(), isEmpty);
      expect(await queueFile().exists(), isTrue);
    },
  );

  test(
    'duplicate keeps first action time while distinct actions remain',
    () async {
      await queue.enqueue(_request(1));
      await queue.enqueue(_request(1, at: DateTime.utc(2030, 1, 1, 9, 3)));
      await queue.enqueue(_request(1, action: 'complete'));
      final actions = await queue.read();
      expect(actions, hasLength(2));
      expect(actions.first.occurredAt, DateTime.utc(2030, 1, 1, 9, 1));
    },
  );

  test('queue retains newest 32 entries and has a bounded file', () async {
    for (var index = 0; index < 40; index++) {
      await queue.enqueue(_request(index));
    }
    final actions = await queue.read();
    expect(actions, hasLength(32));
    expect(actions.first.identity, _request(8).identity);
    expect(actions.last.identity, _request(39).identity);
    expect(
      await queueFile().length(),
      lessThan(PendingNotificationActions.maxFileBytes),
    );
    expect(
      directory.listSync().where((file) => file.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test(
    'malformed and oversized files fail closed and can accept new actions',
    () async {
      for (final invalid in [
        '[',
        jsonEncode({'version': 2, 'actions': []}),
        jsonEncode({'version': 1, 'actions': [], 'extra': true}),
        'x' * (PendingNotificationActions.maxFileBytes + 1),
      ]) {
        await queueFile().writeAsString(invalid);
        expect(await queue.read(), isEmpty);
        expect(await queueFile().length(), lessThan(100));
        await queue.enqueue(_request(1));
        expect((await queue.read()).single.identity, _request(1).identity);
      }
    },
  );

  test(
    'invalid and duplicated records are purged without losing valid actions',
    () async {
      final valid = _request(1);
      await queueFile().writeAsString(
        jsonEncode({
          'version': 1,
          'actions': [
            valid.toJson(),
            {'unsafe': true},
            valid.toJson(),
          ],
        }),
      );
      expect((await queue.read()).single.identity, valid.identity);
      expect(
        (jsonDecode(await queueFile().readAsString())['actions'] as List),
        hasLength(1),
      );
    },
  );

  test('multiple instances serialize independent writes', () async {
    await Future.wait([
      for (var index = 0; index < 32; index++)
        PendingNotificationActions.forDirectory(
          directory,
        ).enqueue(_request(index)),
    ]);
    final actions = await queue.read();
    expect(actions, hasLength(32));
    expect(actions.map((item) => item.identity).toSet(), {
      for (var index = 0; index < 32; index++) _request(index).identity,
    });
  });

  test('separate isolates cannot overwrite each other on POSIX', () async {
    final path = directory.path;
    await Future.wait([
      for (var worker = 0; worker < 4; worker++)
        Isolate.run(() async {
          final queue = PendingNotificationActions.forDirectory(
            Directory(path),
          );
          for (var index = 0; index < 8; index++) {
            await queue.enqueue(_request(worker * 8 + index));
          }
        }),
    ]);
    final actions = await queue.read();
    expect(actions, hasLength(32));
    expect(actions.map((item) => item.identity).toSet(), {
      for (var index = 0; index < 32; index++) _request(index).identity,
    });
  });

  test('queue and lock symlinks are rejected', () async {
    if (Platform.isWindows) return;
    final unrelated = File('${directory.path}/unrelated');
    await unrelated.writeAsString('retained');
    await Link(queueFile().path).create(unrelated.path);
    await expectLater(queue.read(), throwsA(isA<FileSystemException>()));
    expect(await unrelated.readAsString(), 'retained');
    await Link(queueFile().path).delete();
    final lock = File('${directory.path}/.pending-notification-actions.lock');
    await lock.delete();
    await Link(lock.path).create(unrelated.path);
    await expectLater(
      queue.enqueue(_request(1)),
      throwsA(isA<FileSystemException>()),
    );
    expect(await unrelated.readAsString(), 'retained');
  });
}
