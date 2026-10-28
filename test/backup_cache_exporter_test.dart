import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/services/backup_cache_service.dart';
import 'package:dont_forget/services/backup_file_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dontforget-backup-cache-');
  });
  tearDown(() async {
    BackupCacheService.activeDirectories.clear();
    await temp.delete(recursive: true);
  });
  Future<File> cached(String name, {String data = 'synthetic'}) async {
    final d = await Directory(
      '${temp.path}/cache/export-$name',
    ).create(recursive: true);
    return File('${d.path}/backup.dfbackup').writeAsString(data);
  }

  test(
    'cleanup selects only owned exports and preserves active jobs, originals and restored media',
    () async {
      final one = await cached('one'), active = await cached('active');
      BackupCacheService.activeDirectories.add(active.parent.path);
      final original = await File(
        '${temp.path}/original.bin',
      ).writeAsString('original');
      final imported = await Directory(
        '${temp.path}/cache/import-owned',
      ).create(recursive: true);
      await File('${imported.path}/attachment.bin').writeAsString('restored');
      const service = BackupCacheService();
      final entries = await service.inspect(Directory('${temp.path}/cache'));
      expect(entries, hasLength(1));
      expect(entries.single.path, one.path);
      expect(
        await service.clearSelected(
          Directory('${temp.path}/cache'),
          entries,
          isCurrent: () => true,
        ),
        1,
      );
      expect(await active.exists(), isTrue);
      expect(await original.readAsString(), 'original');
      expect(
        await File('${imported.path}/attachment.bin').readAsString(),
        'restored',
      );
    },
  );
  test(
    'changed cache confirmation and expired session delete nothing',
    () async {
      final file = await cached('one');
      const service = BackupCacheService();
      final entries = await service.inspect(file.parent.parent);
      await file.writeAsString('changed content');
      await expectLater(
        service.clearSelected(
          file.parent.parent,
          entries,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      expect(await file.exists(), isTrue);
      final updated = await service.inspect(file.parent.parent);
      await expectLater(
        service.clearSelected(
          file.parent.parent,
          updated,
          isCurrent: () => false,
        ),
        throwsStateError,
      );
      expect(await file.exists(), isTrue);
    },
  );
  test('cache symlinks never authorize deleting their targets', () async {
    final original = await File(
      '${temp.path}/original.bin',
    ).writeAsString('original');
    final d = await Directory(
      '${temp.path}/cache/export-link',
    ).create(recursive: true);
    await Link('${d.path}/backup.dfbackup').create(original.path);
    expect(await const BackupCacheService().inspect(d.parent), isEmpty);
    expect(await original.readAsString(), 'original');
  });
  test(
    'native export receives a file path with an empty byte buffer',
    () async {
      MethodCall? request;
      const channel = MethodChannel('file_saver');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            request = call;
            return '${temp.path}/destination.dfbackup';
          });
      try {
        final source = await File(
          '${temp.path}/source',
        ).writeAsString('synthetic');
        final result = await const BackupFileExporter().save(
          source,
          'backup.dfbackup',
        );
        expect(result, '${temp.path}/destination.dfbackup');
        expect(request!.method, 'saveAs');
        expect(request!.arguments['sourcePath'], source.path);
        expect(request!.arguments['bytes'], isEmpty);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );
  test(
    'directory export copies source into a new file and cancellation creates nothing',
    () async {
      final source = await File(
        '${temp.path}/source',
      ).writeAsString('synthetic');
      final d = await Directory('${temp.path}/destination').create();
      final exporter = BackupFileExporter(
        useDirectoryPicker: true,
        pickDirectory: () async => d.path,
      );
      final path = await exporter.save(source, 'backup.dfbackup');
      expect(await File(path!).readAsString(), 'synthetic');
      expect(await source.readAsString(), 'synthetic');
      expect(await d.list().length, 1);
      expect(
        await BackupFileExporter(
          useDirectoryPicker: true,
          pickDirectory: () async => null,
        ).save(source, 'cancel.dfbackup'),
        isNull,
      );
      expect(await d.list().length, 1);
    },
  );
}
