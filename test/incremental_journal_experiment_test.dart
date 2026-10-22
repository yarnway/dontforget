import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:flutter_test/flutter_test.dart';
import '../benchmark/incremental_journal_experiment.dart';

void main() {
  const epoch = '00000000-0000-4000-8000-000000000001';
  const next = '00000000-0000-4000-8000-000000000002';
  late Directory dir;
  late IncrementalJournalExperiment log;
  NotificationJournalEntry entry(String status) => NotificationJournalEntry(
    reminderId: '合成任务',
    nativeId: 17,
    action: 'schedule',
    status: status,
    attempts: 1,
  );
  setUp(() async {
    dir = Directory(
      await (await Directory.systemTemp.createTemp(
        'incremental-test-',
      )).resolveSymbolicLinks(),
    );
    log = IncrementalJournalExperiment(dir);
    await log.checkpoint(NotificationJournalSnapshot(epoch, {}));
  });
  tearDown(() => dir.delete(recursive: true));

  test('replay and checkpoint retain pending intent and native ID', () async {
    await log.append(epoch, [entry('pending')]);
    final pending = await IncrementalJournalExperiment(dir).open();
    expect(pending.entries.values.single.nativeId, 17);
    expect(pending.entries.values.single.unfinished, isTrue);
    await log.append(epoch, [entry('submitted')]);
    final state = await IncrementalJournalExperiment(dir).open();
    await log.checkpoint(state);
    expect(
      (await IncrementalJournalExperiment(dir).open()).toJson(),
      state.toJson(),
    );
  });

  test(
    'all partial final-frame offsets recover the preceding commit',
    () async {
      await log.append(epoch, [entry('pending')]);
      final prefix = await log.delta.readAsBytes();
      await log.append(epoch, [entry('submitted')]);
      final complete = await log.delta.readAsBytes();
      for (var n = prefix.length; n < complete.length; n++) {
        await log.delta.writeAsBytes(complete.sublist(0, n));
        final reopened = IncrementalJournalExperiment(dir);
        expect(
          (await reopened.open()).entries.values.single.status,
          'pending',
          reason: 'cut=$n',
        );
        expect(reopened.ignoredTailBytes, n - prefix.length);
      }
      final reopened = IncrementalJournalExperiment(dir);
      final recovered = await reopened.open();
      await expectLater(
        reopened.append(epoch, [entry('submitted')]),
        throwsStateError,
      );
      await reopened.checkpoint(recovered);
      await reopened.append(epoch, [entry('submitted')]);
      expect(
        (await IncrementalJournalExperiment(
          dir,
        ).open()).entries.values.single.status,
        'submitted',
      );
    },
  );

  test(
    'complete corrupt, duplicated and reordered frames fail closed',
    () async {
      await log.append(epoch, [entry('pending')]);
      final first = await log.delta.readAsBytes();
      await log.append(epoch, [entry('submitted')]);
      final all = await log.delta.readAsBytes();
      final corrupt = [...all];
      corrupt[10] ^= 1;
      for (final bytes in [
        corrupt,
        [...all, ...first],
        [...all.sublist(first.length), ...first],
      ]) {
        await log.delta.writeAsBytes(bytes);
        await expectLater(
          IncrementalJournalExperiment(dir).open(),
          throwsA(anything),
        );
      }
    },
  );

  test(
    'old epoch, native ID change and duplicate allocation leave log intact',
    () async {
      await log.append(epoch, [entry('pending')]);
      final before = await log.delta.readAsBytes();
      await expectLater(
        log.append(next, [entry('submitted')]),
        throwsStateError,
      );
      for (final row in [
        {...entry('pending').toJson(), 'nativeId': 18},
        {...entry('pending').toJson(), 'reminderId': 'collision'},
      ]) {
        await expectLater(
          log.append(epoch, [NotificationJournalEntry.decode(row)]),
          throwsFormatException,
        );
      }
      expect(await log.delta.readAsBytes(), before);
    },
  );

  test(
    'checkpoint checksum failure and missing generation fail closed',
    () async {
      final manifest =
          jsonDecode(await File('${dir.path}/current.json').readAsString())
              as Map;
      final file = File('${dir.path}/${manifest['generation']}.json');
      await file.writeAsString('{}');
      await expectLater(
        IncrementalJournalExperiment(dir).open(),
        throwsFormatException,
      );
      await file.delete();
      await expectLater(
        IncrementalJournalExperiment(dir).open(),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'incremental validation rejects a whole batch without reserving IDs',
    () async {
      await log.append(epoch, [entry('pending')]);
      final before = await log.delta.readAsBytes();
      final good = NotificationJournalEntry.decode({
        ...entry('pending').toJson(),
        'reminderId': 'new',
        'nativeId': 18,
      });
      final bad = NotificationJournalEntry.decode({
        ...entry('pending').toJson(),
        'reminderId': 'collision',
      });
      await expectLater(log.append(epoch, [good, bad]), throwsFormatException);
      expect(log.snapshot!.entries.keys, ['合成任务']);
      expect(await log.delta.readAsBytes(), before);
      await log.append(epoch, [good]);
      expect((await IncrementalJournalExperiment(dir).open()).entries.keys, [
        '合成任务',
        'new',
      ]);
    },
  );

  test(
    'periodic checkpoints bound replay while preserving all reserved IDs',
    () async {
      log = IncrementalJournalExperiment(dir, checkpointEveryFrames: 3);
      await log.open();
      for (var i = 0; i < 7; i++) {
        await log.append(epoch, [
          NotificationJournalEntry.decode({
            ...entry('pending').toJson(),
            'reminderId': 'task-$i',
            'nativeId': 100 + i,
          }),
        ]);
        final reopened = IncrementalJournalExperiment(dir);
        final state = await reopened.open();
        expect(reopened.replayedFrames, (i + 1) % 3);
        expect(state.entries.length, i + 1);
      }
      expect(log.checkpoints, 2);
      final before = await log.delta.readAsBytes();
      await expectLater(
        log.append(epoch, [
          NotificationJournalEntry.decode({
            ...entry('pending').toJson(),
            'reminderId': 'late-collision',
            'nativeId': 100,
          }),
        ]),
        throwsFormatException,
      );
      expect(await log.delta.readAsBytes(), before);
      await expectLater(
        log.checkpoint(NotificationJournalSnapshot(epoch, {})),
        throwsFormatException,
      );
    },
  );

  for (final point in ['before_publish', 'after_publish']) {
    test(
      'checkpoint error at $point requires reopen before further writes',
      () async {
        await log.append(epoch, [entry('pending')]);
        log.checkpointHook = (at) async {
          if (at == point) throw const FileSystemException('checkpoint fault');
        };
        await expectLater(
          log.checkpoint(log.snapshot!),
          throwsA(isA<FileSystemException>()),
        );
        expect(log.snapshot, isNull);
        await expectLater(
          log.append(epoch, [entry('submitted')]),
          throwsStateError,
        );
        log.checkpointHook = null;
        await log.open();
        await log.append(epoch, [entry('submitted')]);
        expect(
          (await IncrementalJournalExperiment(
            dir,
          ).open()).entries.values.single.status,
          'submitted',
        );
      },
    );
  }

  Future<void> crash(String mode) async {
    final child = await Process.start('dart', [
      '--packages=.dart_tool/package_config.json',
      'test/fixtures/journal_crash_worker.dart',
      dir.path,
      mode,
    ]);
    final errors = child.stderr.transform(utf8.decoder).join();
    try {
      final ready = await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 20));
      expect(ready, 'DURABLE_BOUNDARY');
      expect(child.kill(ProcessSignal.sigkill), isTrue);
      expect(
        await child.exitCode.timeout(const Duration(seconds: 10)),
        isNot(0),
      );
      expect(await errors, isEmpty);
    } finally {
      child.kill(ProcessSignal.sigkill);
    }
  }

  for (final point in [
    'half_frame_written',
    'frame_flushed',
    'snapshot_flushed',
    'before_publish',
    'after_publish',
  ]) {
    test(
      'process kill at segmented $point recovers a complete prefix',
      () async {
        await log.append(epoch, [entry('pending')]);
        await crash('segment:$point');
        final reopened = IncrementalJournalExperiment(dir);
        final state = await reopened.open();
        expect(state.epoch, epoch);
        expect(state.entries.values.single.nativeId, 17);
        expect(
          state.entries.values.single.status,
          point == 'half_frame_written' ? 'pending' : 'submitted',
        );
        expect(reopened.ignoredTailBytes > 0, point == 'half_frame_written');
        expect(
          reopened.replayedFrames,
          point == 'after_publish'
              ? 0
              : (point == 'half_frame_written' ? 1 : 2),
        );
      },
    );
  }
  for (final point in [
    'half_frame_written',
    'frame_flushed',
    'snapshot_flushed',
    'before_publish',
    'after_publish',
  ]) {
    test(
      '10000 fixture identities survive segmented process kill at $point',
      () async {
        final entries = <String, NotificationJournalEntry>{};
        final used = <int>{};
        // Same ordered synthetic IDs, trigger and collision allocation as the
        // 10000-row journal benchmark; business task content is never in a log.
        for (var i = 0; i < 10000; i++) {
          final id = 'synthetic-$i';
          var nativeId = stableNotificationId(id);
          while (!used.add(nativeId)) {
            nativeId = nativeId == 0x7fffffff ? 1 : nativeId + 1;
          }
          entries[id] = NotificationJournalEntry(
            reminderId: id,
            nativeId: nativeId,
            action: 'schedule',
            status: 'submitted',
            attempts: 2,
            triggerUtcMicros: DateTime.utc(2099).microsecondsSinceEpoch,
            noticeRevision: 0,
            attemptedAt: DateTime.utc(2026, 10, 22).toIso8601String(),
          );
        }
        final before = NotificationJournalSnapshot(epoch, entries);
        await log.checkpoint(before);
        await crash('segment_bulk:$point');
        final reopened = IncrementalJournalExperiment(dir);
        final state = await reopened.open();
        final expected = {...entries};
        if (point != 'half_frame_written') {
          expected['synthetic-0'] = NotificationJournalEntry.decode({
            ...entries['synthetic-0']!.toJson(),
            'status': 'pending',
            'attempts': 3,
          });
        }
        expect(
          state.toJson(),
          NotificationJournalSnapshot(epoch, expected).toJson(),
        );
        expect(state.entries.length, 10000);
        expect(
          {for (final e in state.entries.values) e.reminderId: e.nativeId},
          {for (final e in before.entries.values) e.reminderId: e.nativeId},
        );
      },
    );
  }
  for (final point in ['snapshot_flushed', 'before_publish', 'after_publish']) {
    test(
      'process kill at checkpoint $point selects a whole generation',
      () async {
        await log.append(epoch, [entry('pending')]);
        await crash('checkpoint:$point');
        final state = await IncrementalJournalExperiment(dir).open();
        expect(state.epoch, point == 'after_publish' ? next : epoch);
        expect(state.entries.values.single.status, 'pending');
        expect(state.entries.values.single.nativeId, 17);
      },
    );
  }
  for (final point in ['staged', 'pending', 'effect', 'submitted']) {
    test(
      'production v1 survives process kill at $point without losing ID',
      () async {
        final current = NotificationJournal(dir);
        await current.reset(epoch);
        await crash(point);
        final state = (await NotificationJournal(dir).read())!;
        if (point == 'staged') {
          expect(state.entries, isEmpty);
          expect(
            await dir.list().where((e) => e.path.endsWith('.tmp')).length,
            1,
          );
        } else {
          final saved = state.entries['task']!;
          expect(saved.status, point == 'submitted' ? 'submitted' : 'pending');
          if (point != 'pending') {
            expect(
              await File('${dir.path}/effect.json').readAsString(),
              '${saved.nativeId}',
            );
          }
          final retry = await NotificationJournal(dir).begin(
            epoch,
            'task',
            action: 'schedule',
            attemptedAt: DateTime.utc(2026),
          );
          expect(retry.nativeId, saved.nativeId);
        }
      },
    );
  }
}
