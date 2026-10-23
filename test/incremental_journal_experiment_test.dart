import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:flutter_test/flutter_test.dart';
import '../benchmark/incremental_journal_experiment.dart';

void main() {
  const epoch = '00000000-0000-4000-8000-000000000001';
  const next = '00000000-0000-4000-8000-000000000002';
  late Directory dir;
  late IncrementalJournalEngine log;
  late String dartExecutable;
  setUpAll(() async {
    // Use the SDK that supplied package:flutter, even when Flutter was invoked
    // by absolute path and no dart command is available in the caller's PATH.
    final config = File('.dart_tool/package_config.json').absolute;
    final packages =
        (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
    final flutter = packages.singleWhere((p) => p['name'] == 'flutter') as Map;
    final sdk = Directory.fromUri(
      config.uri.resolve(flutter['rootUri'] as String),
    ).parent.parent;
    final executable = File(
      '${sdk.path}/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
    );
    if (!await executable.exists()) {
      throw StateError(
        'The current Flutter SDK has no bundled Dart executable',
      );
    }
    dartExecutable = executable.path;
  });
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
    log = IncrementalJournalEngine(dir);
    await log.checkpoint(NotificationJournalSnapshot(epoch, {}));
  });
  tearDown(() => dir.delete(recursive: true));

  test('oversized checkpoint preserves the selected generation', () async {
    final manifest = File('${dir.path}/current.json');
    final before = await manifest.readAsBytes();
    final limited = IncrementalJournalEngine(dir, maxCheckpointBytes: 120);
    await limited.open();
    await expectLater(
      limited.checkpoint(
        NotificationJournalSnapshot(epoch, {'x': entry('pending')}),
      ),
      throwsStateError,
    );
    expect(await manifest.readAsBytes(), before);
    expect(limited.snapshot!.entries, isEmpty);
    await expectLater(
      limited.append(epoch, [entry('pending')]),
      throwsStateError,
    );
    expect(await limited.delta.length(), 0);
    expect((await IncrementalJournalEngine(dir).open()).entries, isEmpty);
    // A failed oversized mutation has not poisoned a larger valid writer.
    final normal = IncrementalJournalEngine(dir);
    await normal.open();
    await normal.append(epoch, [entry('pending')]);
    expect(
      (await IncrementalJournalEngine(
        dir,
      ).open()).entries.values.single.nativeId,
      17,
    );
  });

  test(
    'oversized append is rejected before log or in-memory changes',
    () async {
      final limited = IncrementalJournalEngine(dir, maxFrameBytes: 1024);
      await limited.open();
      final huge = NotificationJournalEntry.decode({
        ...entry('pending').toJson(),
        'reminderId': 'x' * 3000,
      });
      await expectLater(limited.append(epoch, [huge]), throwsStateError);
      expect(await limited.delta.length(), 0);
      expect(limited.snapshot!.entries, isEmpty);
      await limited.append(epoch, [entry('pending')]);
      expect(
        (await IncrementalJournalEngine(
          dir,
        ).open()).entries.values.single.nativeId,
        17,
      );
    },
  );

  test(
    'segment byte capacity requires a checkpoint and preserves ID',
    () async {
      final limited = IncrementalJournalEngine(dir, maxLogBytes: 1024);
      await limited.open();
      var reachedLimit = false;
      for (var n = 0; n < 20; n++) {
        final before = await limited.delta.readAsBytes();
        final state = limited.snapshot!.toJson();
        try {
          await limited.append(epoch, [entry('pending')]);
        } on StateError {
          reachedLimit = true;
          expect(await limited.delta.readAsBytes(), before);
          expect(limited.snapshot!.toJson(), state);
          break;
        }
      }
      expect(reachedLimit, isTrue);
      await limited.checkpoint(limited.snapshot!);
      await limited.append(epoch, [entry('submitted')]);
      final recovered = await IncrementalJournalEngine(dir).open();
      expect(recovered.entries.values.single.nativeId, 17);
      expect(recovered.entries.values.single.status, 'submitted');
    },
  );

  test('manifest, checkpoint and log reads enforce byte limits', () async {
    final manifest = File('${dir.path}/current.json');
    final manifestBytes = await manifest.readAsBytes();
    final selected = jsonDecode(utf8.decode(manifestBytes)) as Map;
    for (final kind in ['manifest', 'checkpoint', 'log']) {
      if (kind == 'manifest') await manifest.writeAsString(' ' * 4097);
      if (kind == 'log') await log.delta.writeAsString(' ' * 101);
      final reader = IncrementalJournalEngine(
        dir,
        maxCheckpointBytes: kind == 'checkpoint' ? 10 : 16 * 1024 * 1024,
        maxLogBytes: kind == 'log' ? 100 : 64 * 1024 * 1024,
      );
      await expectLater(
        reader.open(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'limit',
            contains('exceeds limit'),
          ),
        ),
      );
      expect(reader.snapshot, isNull);
      await manifest.writeAsBytes(manifestBytes);
      await log.delta.writeAsBytes([]);
    }
    selected['generation'] = 'f' * 36;
    await manifest.writeAsString(jsonEncode(selected));
    await expectLater(
      IncrementalJournalEngine(dir).open(),
      throwsFormatException,
    );
  });

  test('oversized unterminated tail is not silently ignored', () async {
    await log.delta.writeAsString('x' * 1025);
    final reader = IncrementalJournalEngine(dir, maxFrameBytes: 1024);
    await expectLater(reader.open(), throwsFormatException);
    expect(reader.snapshot, isNull);
  });

  test(
    'linked manifest cannot redirect reads or checkpoint publication',
    () async {
      final manifest = File('${dir.path}/current.json');
      final bytes = await manifest.readAsBytes();
      final target = File('${dir.path}/sentinel.json');
      await target.writeAsBytes(bytes);
      await manifest.delete();
      await Link(manifest.path).create(target.path);
      await expectLater(
        IncrementalJournalEngine(dir).open(),
        throwsFormatException,
      );
      await expectLater(
        log.checkpoint(NotificationJournalSnapshot(epoch, {})),
        throwsFormatException,
      );
      expect(await target.readAsBytes(), bytes);
      expect(
        await FileSystemEntity.type(manifest.path, followLinks: false),
        FileSystemEntityType.link,
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'linked delta cannot redirect append and poisons the writer',
    () async {
      final target = File('${dir.path}/sentinel.log');
      await target.writeAsString('unchanged');
      final delta = log.delta;
      await delta.delete();
      await Link(delta.path).create(target.path);
      await expectLater(
        log.append(epoch, [entry('pending')]),
        throwsFormatException,
      );
      expect(await target.readAsString(), 'unchanged');
      expect(log.snapshot, isNull);
    },
    skip: Platform.isWindows,
  );

  test(
    'linked root is not treated as an exclusively owned directory',
    () async {
      final alias = Link('${dir.path}/alias');
      await alias.create(dir.path);
      final before = await File('${dir.path}/current.json').readAsBytes();
      await expectLater(
        IncrementalJournalEngine(
          Directory(alias.path),
        ).checkpoint(NotificationJournalSnapshot(epoch, {})),
        throwsFormatException,
      );
      expect(await File('${dir.path}/current.json').readAsBytes(), before);
    },
    skip: Platform.isWindows,
  );

  test('replay and checkpoint retain pending intent and native ID', () async {
    await log.append(epoch, [entry('pending')]);
    final pending = await IncrementalJournalEngine(dir).open();
    expect(pending.entries.values.single.nativeId, 17);
    expect(pending.entries.values.single.unfinished, isTrue);
    await log.append(epoch, [entry('submitted')]);
    final state = await IncrementalJournalEngine(dir).open();
    await log.checkpoint(state);
    expect(
      (await IncrementalJournalEngine(dir).open()).toJson(),
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
        final reopened = IncrementalJournalEngine(dir);
        expect(
          (await reopened.open()).entries.values.single.status,
          'pending',
          reason: 'cut=$n',
        );
        expect(reopened.ignoredTailBytes, n - prefix.length);
      }
      final reopened = IncrementalJournalEngine(dir);
      final recovered = await reopened.open();
      await expectLater(
        reopened.append(epoch, [entry('submitted')]),
        throwsStateError,
      );
      await reopened.checkpoint(recovered);
      await reopened.append(epoch, [entry('submitted')]);
      expect(
        (await IncrementalJournalEngine(
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
          IncrementalJournalEngine(dir).open(),
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
        IncrementalJournalEngine(dir).open(),
        throwsFormatException,
      );
      await file.delete();
      await expectLater(
        IncrementalJournalEngine(dir).open(),
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
      expect((await IncrementalJournalEngine(dir).open()).entries.keys, [
        '合成任务',
        'new',
      ]);
    },
  );

  test(
    'periodic checkpoints bound replay while preserving all reserved IDs',
    () async {
      log = IncrementalJournalEngine(dir, checkpointEveryFrames: 3);
      await log.open();
      for (var i = 0; i < 7; i++) {
        await log.append(epoch, [
          NotificationJournalEntry.decode({
            ...entry('pending').toJson(),
            'reminderId': 'task-$i',
            'nativeId': 100 + i,
          }),
        ]);
        final reopened = IncrementalJournalEngine(dir);
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
          (await IncrementalJournalEngine(
            dir,
          ).open()).entries.values.single.status,
          'submitted',
        );
      },
    );
  }

  Future<void> crash(String mode) async {
    final child = await Process.start(dartExecutable, [
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
        final reopened = IncrementalJournalEngine(dir);
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
        final reopened = IncrementalJournalEngine(dir);
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
        final state = await IncrementalJournalEngine(dir).open();
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
