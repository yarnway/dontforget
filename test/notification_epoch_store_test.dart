import 'dart:convert';
import 'dart:io';

import 'package:dont_forget/services/notification_epoch_store.dart';
import 'package:flutter_test/flutter_test.dart';

const firstEpoch = '9c2361cc-ea7b-46bd-ab59-5e2873508ff1';
const secondEpoch = '1d43159f-2c14-4283-a921-8ea5d67ff1c9';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'notification-epoch-test-',
    );
    // macOS systemTemp may use an alias such as /var -> /private/var.
    directory = Directory(await directory.resolveSymbolicLinks());
    file = File('${directory.path}/${NotificationEpochStore.fileName}');
  });

  tearDown(() async => directory.delete(recursive: true));

  test(
    'identity survives restart and rotates without changing business data',
    () async {
      final business = File('${directory.path}/dont_forget_v3.db');
      await business.writeAsString('synthetic business bytes');
      final store = NotificationEpochStore(
        directory,
        newEpoch: () => firstEpoch,
      );
      expect(await store.readOrCreate(), firstEpoch);
      final restarted = NotificationEpochStore(
        directory,
        newEpoch: () => secondEpoch,
      );
      expect(await restarted.readOrCreate(), firstEpoch);
      expect(await restarted.rotate(), secondEpoch);
      expect(await store.readOrCreate(), secondEpoch);
      expect(await business.readAsString(), 'synthetic business bytes');
    },
  );

  test(
    'concurrent reads and rotation are serialized with no stale cached epoch',
    () async {
      var generation = 0;
      final store = NotificationEpochStore(
        directory,
        newEpoch: () => generation++ == 0 ? firstEpoch : secondEpoch,
      );
      final results = await Future.wait([
        store.readOrCreate(),
        store.readOrCreate(),
        store.rotate(),
        store.readOrCreate(),
      ]);
      expect(results, [firstEpoch, firstEpoch, secondEpoch, secondEpoch]);
      expect(generation, 2);
    },
  );

  test('invalid or reused next identity preserves the current file', () async {
    final valid = NotificationEpochStore(directory, newEpoch: () => firstEpoch);
    await valid.readOrCreate();
    final original = await file.readAsString();
    for (final invalid in ['', 'wrong', firstEpoch]) {
      final store = NotificationEpochStore(directory, newEpoch: () => invalid);
      await expectLater(store.rotate(), throwsFormatException);
      expect(await file.readAsString(), original);
      expect(await store.readOrCreate(), firstEpoch);
    }
  });

  test(
    'in-flight reads coalesce but completed reads revalidate bytes',
    () async {
      final store = NotificationEpochStore(
        directory,
        newEpoch: () => firstEpoch,
      );
      final first = store.readOrCreate();
      expect(identical(first, store.readOrCreate()), isTrue);
      expect(await first, firstEpoch);
      await file.writeAsString(
        jsonEncode({'version': 1, 'epoch': secondEpoch}),
      );
      final second = store.readOrCreate();
      expect(identical(first, second), isFalse);
      expect(await second, secondEpoch);
      await file.writeAsString('corrupt');
      final failed = store.readOrCreate();
      expect(identical(failed, store.readOrCreate()), isTrue);
      await expectLater(failed, throwsFormatException);
      await file.writeAsString(jsonEncode({'version': 1, 'epoch': firstEpoch}));
      expect(await store.readOrCreate(), firstEpoch);
    },
  );

  test(
    'corrupt, future, oversized and unknown-file formats never regenerate',
    () async {
      for (final invalid in [
        '{',
        'null',
        '[]',
        jsonEncode({'version': 2, 'epoch': firstEpoch}),
        jsonEncode({'version': 1.0, 'epoch': firstEpoch}),
        jsonEncode({'version': 1, 'epoch': 'invalid'}),
        jsonEncode({'version': 1, 'epoch': firstEpoch, 'extra': true}),
        'x' * 257,
      ]) {
        await file.writeAsString(invalid);
        final store = NotificationEpochStore(
          directory,
          newEpoch: () => secondEpoch,
        );
        await expectLater(store.readOrCreate(), throwsFormatException);
        await expectLater(store.rotate(), throwsFormatException);
        expect(await file.readAsString(), invalid);
      }
    },
  );

  test('a failed operation does not poison later serialized reads', () async {
    var next = 'invalid';
    final store = NotificationEpochStore(directory, newEpoch: () => next);
    await expectLater(store.readOrCreate(), throwsFormatException);
    next = firstEpoch;
    expect(await store.readOrCreate(), firstEpoch);
  });

  test(
    'directory and file symlinks are rejected without changing the target',
    () async {
      final actual = File('${directory.path}/other.json');
      await actual.writeAsString(
        jsonEncode({'version': 1, 'epoch': firstEpoch}),
      );
      await Link(file.path).create(actual.path);
      final store = NotificationEpochStore(
        directory,
        newEpoch: () => secondEpoch,
      );
      await expectLater(store.readOrCreate(), throwsFormatException);
      await expectLater(store.rotate(), throwsFormatException);
      expect(jsonDecode(await actual.readAsString())['epoch'], firstEpoch);
      await Link(file.path).delete();
      final alias = Link('${directory.path}/alias');
      await alias.create(directory.path);
      final throughAlias = NotificationEpochStore(
        Directory(alias.path),
        newEpoch: () => firstEpoch,
      );
      await expectLater(throughAlias.readOrCreate(), throwsFormatException);
    },
    skip: Platform.isWindows
        ? 'Symlink creation requires host privileges.'
        : false,
  );

  test(
    'a dangling identity link and a directory in place of the file fail closed',
    () async {
      if (!Platform.isWindows) {
        await Link(file.path).create('${directory.path}/missing.json');
        final store = NotificationEpochStore(
          directory,
          newEpoch: () => firstEpoch,
        );
        await expectLater(store.rotate(), throwsFormatException);
        expect(
          await FileSystemEntity.type(file.path, followLinks: false),
          FileSystemEntityType.link,
        );
        await Link(file.path).delete();
      }
      await Directory(file.path).create();
      final store = NotificationEpochStore(
        directory,
        newEpoch: () => firstEpoch,
      );
      await expectLater(store.readOrCreate(), throwsFormatException);
    },
  );
}
