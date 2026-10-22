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

  test(
    'cached snapshots are immutable and stay unchanged after later writes',
    () async {
      await journal.reset(epoch);
      await journal.reserve(epoch, 'task');
      final first = (await journal.read())!;
      expect(() => first.entries.clear(), throwsUnsupportedError);
      await journal.record(
        epoch,
        'task',
        action: 'schedule',
        status: 'pending',
      );
      expect(first.entries['task']!.status, 'reserved');
      expect((await journal.read())!.entries['task']!.status, 'pending');
      final original = Map<String, NotificationJournalEntry>.of(first.entries);
      final snapshot = NotificationJournalSnapshot(epoch, original);
      original.clear();
      expect(snapshot.entries, hasLength(1));
    },
  );

  test(
    'same-size external edits with unchanged mtime invalidate the cache',
    () async {
      await journal.reset(epoch);
      await journal.reserve(epoch, 'task');
      final file = File('${directory.path}/${NotificationJournal.fileName}');
      final modified = await file.lastModified();
      final original = await file.readAsString();
      await journal.read();
      final edited = original.replaceFirst('"attempts":0', '"attempts":7');
      expect(edited.length, original.length);
      await file.writeAsString(edited, flush: true);
      await file.setLastModified(modified);
      expect((await journal.read())!.entries['task']!.attempts, 7);
      await journal.record(epoch, 'task', action: 'cancel', status: 'pending');
      expect(
        (await NotificationJournal(
          directory,
        ).read())!.entries['task']!.attempts,
        8,
      );
    },
  );

  test(
    'a warm cache cannot hide corruption or restore a removed file',
    () async {
      await journal.reset(epoch);
      await journal.reserve(epoch, 'task');
      await journal.read();
      final file = File('${directory.path}/${NotificationJournal.fileName}');
      final original = await file.readAsString();
      final corrupted = '!${original.substring(1)}';
      await file.writeAsString(corrupted);
      await expectLater(journal.read(), throwsFormatException);
      await expectLater(journal.reset(epoch), throwsFormatException);
      await expectLater(
        journal.record(epoch, 'task', action: 'cancel', status: 'pending'),
        throwsFormatException,
      );
      expect(await file.readAsString(), corrupted);
      await file.delete();
      expect(await journal.read(), isNull);
      await expectLater(journal.reserve(epoch, 'new'), throwsStateError);
      await journal.reset(nextEpoch);
      expect((await journal.read())!.entries, isEmpty);
    },
  );

  test('invalid updates cannot poison cached or persisted state', () async {
    await journal.reset(epoch);
    await journal.reserve(epoch, 'task');
    final file = File('${directory.path}/${NotificationJournal.fileName}');
    final before = await file.readAsString();
    await expectLater(
      journal.record(epoch, 'task', action: 'cancel', status: 'invalid'),
      throwsFormatException,
    );
    await expectLater(
      journal.record(
        epoch,
        'task',
        action: 'schedule',
        status: 'pending',
        noticeRevision: -1,
      ),
      throwsFormatException,
    );
    await expectLater(journal.reserve(epoch, ''), throwsFormatException);
    await expectLater(journal.reset('invalid-epoch'), throwsFormatException);
    expect(await file.readAsString(), before);
    expect((await journal.read())!.entries['task']!.status, 'reserved');
    await journal.record(epoch, 'task', action: 'cancel', status: 'submitted');
    expect(
      (await NotificationJournal(directory).read())!.entries['task']!.status,
      'submitted',
    );
  });

  test(
    'a staged write refuses valid intervening changes and cleans its own temporary file',
    () async {
      await journal.reset(epoch);
      await journal.reserve(epoch, 'task');
      final file = File('${directory.path}/${NotificationJournal.fileName}');
      final original = await file.readAsString();
      final edited = original.replaceFirst('"attempts":0', '"attempts":9');
      var intervene = true;
      final writer = NotificationJournal.forTesting(directory, () async {
        if (intervene) {
          intervene = false;
          await file.writeAsString(edited, flush: true);
        }
      });
      await expectLater(
        writer.record(epoch, 'task', action: 'cancel', status: 'pending'),
        throwsFormatException,
      );
      expect(await file.readAsString(), edited);
      expect(
        await directory.list().where((f) => f.path.endsWith('.tmp')).toList(),
        isEmpty,
      );
      await writer.record(epoch, 'task', action: 'cancel', status: 'pending');
      expect(
        (await NotificationJournal(
          directory,
        ).read())!.entries['task']!.attempts,
        10,
      );
    },
  );

  test(
    'a failure after staging never promotes the uncommitted cache',
    () async {
      await journal.reset(epoch);
      await journal.reserve(epoch, 'task');
      final file = File('${directory.path}/${NotificationJournal.fileName}');
      final original = await file.readAsString();
      var fail = true;
      final writer = NotificationJournal.forTesting(directory, () async {
        if (fail) {
          throw const FileSystemException('synthetic replacement failure');
        }
      });
      await expectLater(
        writer.record(epoch, 'task', action: 'cancel', status: 'pending'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), original);
      expect((await writer.read())!.entries['task']!.attempts, 0);
      fail = false;
      await writer.record(epoch, 'task', action: 'cancel', status: 'pending');
      expect(
        (await NotificationJournal(
          directory,
        ).read())!.entries['task']!.attempts,
        1,
      );
    },
  );

  test(
    'warm-cache reads reject a replacement symlink',
    () async {
      await journal.reset(epoch);
      await journal.reserve(epoch, 'task');
      final file = File('${directory.path}/${NotificationJournal.fileName}');
      final target = File('${directory.path}/unrelated')
        ..writeAsStringSync('preserved');
      await file.delete();
      await Link(file.path).create(target.path);
      await expectLater(journal.read(), throwsFormatException);
      await expectLater(
        journal.record(epoch, 'task', action: 'cancel', status: 'pending'),
        throwsFormatException,
      );
      expect(await target.readAsString(), 'preserved');
    },
    skip: Platform.isWindows
        ? 'Creating symlinks needs host permission.'
        : false,
  );

  test('cached content does not bypass the file size limit', () async {
    await journal.reset(epoch);
    await journal.reserve(epoch, 'task');
    final file = File('${directory.path}/${NotificationJournal.fileName}');
    final before = await file.readAsBytes();
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(NotificationJournal.maxBytes + 1);
    await handle.close();
    await expectLater(journal.read(), throwsFormatException);
    await expectLater(
      journal.record(epoch, 'task', action: 'cancel', status: 'pending'),
      throwsFormatException,
    );
    expect(await file.length(), NotificationJournal.maxBytes + 1);
    await file.writeAsBytes(before);
    await journal.record(epoch, 'task', action: 'cancel', status: 'pending');
    expect(
      (await NotificationJournal(directory).read())!.entries['task']!.attempts,
      1,
    );
  });
}
