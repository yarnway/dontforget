import 'dart:convert';
import 'dart:io';

import 'package:dont_forget/services/notification_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const epoch = '00000000-0000-4000-8000-000000000001';
  const nextEpoch = '00000000-0000-4000-8000-000000000002';
  late Directory directory;
  late NotificationJournal journal;
  setUp(() async {
    final temporary = await Directory.systemTemp.createTemp(
      'notification-journal-',
    );
    directory = Directory(await temporary.resolveSymbolicLinks());
    journal = NotificationJournal(directory);
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'stable ID has a pinned cross-process vector and distinguishes escaped IDs',
    () {
      expect(stableNotificationId('qa-ack-due'), 1967836952);
      expect(
        stableNotificationId('\ud800'),
        isNot(stableNotificationId('\ufffd')),
      );
      expect(
        stableNotificationId('a\u0000b'),
        isNot(stableNotificationId('ab')),
      );
    },
  );

  test(
    'concurrent allocation survives reopening and never reuses a deleted ID',
    () async {
      await journal.reset(epoch);
      final allocated = await Future.wait(
        List.generate(20, (i) => journal.reserve(epoch, 'task-${i % 10}')),
      );
      expect(allocated.map((e) => e.nativeId).toSet(), hasLength(10));
      await journal.record(
        epoch,
        'task-0',
        action: 'cancel',
        status: 'submitted',
      );
      final reopened = NotificationJournal(directory);
      expect(
        (await reopened.reserve(epoch, 'task-0')).nativeId,
        allocated.first.nativeId,
      );
      expect((await reopened.read())!.entries, hasLength(10));
    },
  );

  test(
    'a collision reserves a different ID and reopening preserves it',
    () async {
      final id = stableNotificationId('collision-target');
      final state = NotificationJournalSnapshot(epoch, {
        'occupied': NotificationJournalEntry(
          reminderId: 'occupied',
          nativeId: id,
          action: 'cancel',
          status: 'submitted',
          attempts: 1,
        ),
      });
      await File(
        '${directory.path}/${NotificationJournal.fileName}',
      ).writeAsString(jsonEncode(state.toJson()));
      final reserved = await journal.reserve(epoch, 'collision-target');
      expect(reserved.nativeId, id == 0x7fffffff ? 1 : id + 1);
      expect(
        (await NotificationJournal(
          directory,
        ).reserve(epoch, 'collision-target')).nativeId,
        reserved.nativeId,
      );
    },
  );

  test(
    'pending and failed intent persists without task content or errors',
    () async {
      await journal.reset(epoch);
      await journal.reserve(epoch, 'task');
      await journal.record(
        epoch,
        'task',
        action: 'schedule',
        status: 'pending',
        triggerUtcMicros: 123,
        noticeRevision: 7,
        attemptedAt: DateTime.utc(2030),
      );
      var saved = (await NotificationJournal(
        directory,
      ).read())!.entries['task']!;
      expect(saved.unfinished, isTrue);
      expect(saved.attempts, 1);
      expect(saved.triggerUtcMicros, 123);
      await journal.record(
        epoch,
        'task',
        action: 'schedule',
        status: 'failed',
        triggerUtcMicros: 123,
        noticeRevision: 7,
      );
      saved = (await NotificationJournal(directory).read())!.entries['task']!;
      expect(saved.status, 'failed');
      expect(saved.attempts, 1);
      expect(saved.toJson().keys, isNot(contains('title')));
      expect(saved.toJson().keys, isNot(contains('error')));
    },
  );

  test(
    'restored epoch rejects stale writes and starts a new local registry',
    () async {
      await journal.reset(epoch);
      await journal.reserve(epoch, 'old');
      await journal.reset(nextEpoch);
      await expectLater(
        journal.record(epoch, 'old', action: 'cancel', status: 'submitted'),
        throwsStateError,
      );
      expect((await journal.read())!.epoch, nextEpoch);
      expect((await journal.read())!.entries, isEmpty);
    },
  );

  test('corrupt state is preserved rather than overwritten or reset', () async {
    final file = File('${directory.path}/${NotificationJournal.fileName}');
    await file.writeAsString('{broken');
    await expectLater(journal.read(), throwsFormatException);
    await expectLater(journal.reset(epoch), throwsFormatException);
    expect(await file.readAsString(), '{broken');
  });

  test('duplicate native IDs fail closed', () async {
    final state = NotificationJournalSnapshot(epoch, {
      for (final name in ['a', 'b'])
        name: NotificationJournalEntry(
          reminderId: name,
          nativeId: 1,
          action: 'cancel',
          status: 'submitted',
          attempts: 1,
        ),
    });
    await File(
      '${directory.path}/${NotificationJournal.fileName}',
    ).writeAsString(jsonEncode(state.toJson()));
    await expectLater(journal.read(), throwsFormatException);
  });

  test(
    'a symlink is never followed or replaced',
    () async {
      final target = File('${directory.path}/unrelated')
        ..writeAsStringSync('preserved');
      await Link(
        '${directory.path}/${NotificationJournal.fileName}',
      ).create(target.path);
      await expectLater(journal.reset(epoch), throwsFormatException);
      expect(await target.readAsString(), 'preserved');
    },
    skip: Platform.isWindows
        ? 'Creating symlinks needs host permission.'
        : false,
  );
}
