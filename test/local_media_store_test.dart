import 'dart:io';
import 'package:dont_forget/services/local_media_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory directory;
  late Directory documents;
  late LocalMediaStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('media-import-test-');
    documents = Directory(path.join(directory.path, 'documents'));
    store = LocalMediaStore(documentsDirectory: () async => documents);
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'concurrent same-name imports preserve both attachments and sources',
    () async {
      final sources = <File>[];
      for (var i = 0; i < 2; i++) {
        final folder = await Directory(
          path.join(directory.path, '$i'),
        ).create();
        sources.add(
          await File(
            path.join(folder.path, 'meeting.m4a'),
          ).writeAsString('audio-$i'),
        );
      }
      final paths = await Future.wait(
        sources.map((file) => store.importFile(file.path)),
      );
      expect(paths.toSet(), hasLength(2));
      for (var i = 0; i < paths.length; i++) {
        expect(path.basename(paths[i]), 'meeting.m4a');
        expect(await File(paths[i]).readAsString(), 'audio-$i');
        expect(await sources[i].readAsString(), 'audio-$i');
      }
      final reimported = await store.importFile(paths.first);
      expect(reimported, isNot(paths.first));
      expect(await File(reimported).readAsString(), 'audio-0');
      expect(await File(paths.first).readAsString(), 'audio-0');
    },
  );

  test('failed copy removes only its new staging directory', () async {
    final source = await File(
      path.join(directory.path, 'note.txt'),
    ).writeAsString('keep');
    final saved = await store.importFile(source.path);
    await expectLater(
      store.importFile(path.join(directory.path, 'missing.txt')),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File(saved).readAsString(), 'keep');
    expect(await source.readAsString(), 'keep');
    expect(
      await Directory(path.join(documents.path, 'media')).list().length,
      1,
    );
  });

  test(
    'relocated Documents retains import identity without changing paths',
    () async {
      final oldDocuments = await Directory(
        path.join(directory.path, 'old-container', 'Documents'),
      ).create(recursive: true);
      final importer = LocalMediaStore(
        documentsDirectory: () async => oldDocuments,
      );
      final source = await File(
        path.join(directory.path, 'meeting.m4a'),
      ).writeAsString('first recording');
      final first = await importer.importFile(source.path);
      await source.writeAsString('second recording');
      final second = await importer.importFile(source.path);
      final newParent = await Directory(
        path.join(directory.path, 'new-container'),
      ).create();
      final relocated = await oldDocuments.rename(
        path.join(newParent.path, 'Documents'),
      );
      var lookups = 0;
      final reader = LocalMediaStore(
        documentsDirectory: () async {
          lookups++;
          return relocated;
        },
      );
      for (final entry in {
        first: 'first recording',
        second: 'second recording',
      }.entries) {
        final resolved = await reader.resolvePath(entry.key);
        expect(resolved, isNot(entry.key));
        expect(await File(resolved).readAsString(), entry.value);
        expect(await File(entry.key).exists(), isFalse);
      }
      expect(lookups, 1);
      expect(await reader.resolvePath(source.path), source.path);
      expect(await source.readAsString(), 'second recording');
    },
    skip: Platform.isWindows ? 'iOS container relocation is POSIX-only' : false,
  );

  test('unowned and unsafe paths do not request the app directory', () async {
    var lookups = 0;
    final reader = LocalMediaStore(
      documentsDirectory: () async {
        lookups++;
        return documents;
      },
    );
    for (final value in [
      'media/import-one/file.m4a',
      'file:///old/Documents/media/import-one/file.m4a',
      '//host/Documents/media/import-one/file.m4a',
      r'\\host\Documents\media\import-one\file.m4a',
      '/old/Documents/media/import-one/../file.m4a',
      '/old/../Documents/media/import-one/file.m4a',
      '/old/Documents/media/import-one/./file.m4a',
      '/old/Documents/media/import-one//file.m4a',
      '/old/Documents/media/import-one/file\u0000.m4a',
      '/old/Documents/media/other/file.m4a',
      '/old/downloads/import-one/file.m4a',
    ]) {
      expect(await reader.resolvePath(value), value);
    }
    expect(lookups, 0);
  });

  test(
    'existing paths and unavailable directory preserve legacy behavior',
    () async {
      final original = await File(
        path.join(
          directory.path,
          'old',
          'Documents',
          'media',
          'import-original',
          'audio.m4a',
        ),
      ).create(recursive: true);
      final reader = LocalMediaStore(
        documentsDirectory: () async => throw StateError('unavailable'),
      );
      expect(await reader.resolvePath(original.path), original.path);
      final missing = path.join(
        directory.path,
        'old',
        'Documents',
        'media',
        'import-missing',
        'audio.m4a',
      );
      expect(await reader.resolvePath(missing), missing);
    },
  );

  test(
    'rebasing never follows a symlink inside the owned media tree',
    () async {
      final outside = await Directory(
        path.join(directory.path, 'outside'),
      ).create();
      final file = await File(
        path.join(outside.path, 'audio.m4a'),
      ).writeAsString('external');
      await documents.create();
      const old = '/old-container/Documents/media/import-one/audio.m4a';
      final media = path.join(documents.path, 'media');
      await Link(media).create(outside.path);
      expect(await store.resolvePath(old), old);
      await Link(media).delete();
      await Directory(media).create();
      final imported = path.join(media, 'import-one');
      await Link(imported).create(outside.path);
      expect(await store.resolvePath(old), old);
      await Link(imported).delete();
      await Directory(imported).create();
      await Link(path.join(imported, 'audio.m4a')).create(file.path);
      expect(await store.resolvePath(old), old);
      expect(await file.readAsString(), 'external');
    },
    skip: Platform.isWindows
        ? 'Creating symlinks requires Windows privileges'
        : false,
  );
}
