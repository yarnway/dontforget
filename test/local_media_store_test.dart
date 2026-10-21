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
}
