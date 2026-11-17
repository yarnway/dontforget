@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/services/content/content_cleanup_service.dart';
import 'package:dont_forget/services/content/owned_material_activity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'support/offline_management_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  late Directory root, documents;
  late ContentCleanupService service;
  final aliases = <String>[];
  final outcomes = <Map<String, Object?>>[];
  final now = DateTime(2032, 2, 10), old = DateTime(2032, 2, 1);

  Future<void> removeAlias(String path) async {
    expect(p.isWithin(root.path, path), isTrue);
    final result = await Process.run('py', [
      '-3',
      '-c',
      'import os,sys,ctypes; r=os.path.abspath(sys.argv[1]); q=os.path.abspath(sys.argv[2]); '
          'assert os.path.commonpath([r,q])==r and q!=r; '
          'k=ctypes.WinDLL("kernel32",use_last_error=True); '
          'k.GetFileAttributesW.argtypes=[ctypes.c_wchar_p]; k.GetFileAttributesW.restype=ctypes.c_uint32; '
          'k.RemoveDirectoryW.argtypes=[ctypes.c_wchar_p]; k.RemoveDirectoryW.restype=ctypes.c_int; '
          'a=k.GetFileAttributesW(q); '
          'assert a!=0xffffffff and a&0x400 and a&0x10; '
          'assert k.RemoveDirectoryW(q),ctypes.get_last_error()',
      root.path,
      path,
    ]);
    expect(
      result.exitCode,
      0,
      reason: 'Remove only the owned NTFS junction, never its target',
    );
    aliases.remove(path);
  }

  Future<String> junction(Directory alias, Directory target) async {
    expect(p.isWithin(root.path, alias.path), isTrue);
    expect(p.isWithin(root.path, target.path), isTrue);
    expect(
      await FileSystemEntity.type(alias.path, followLinks: false),
      FileSystemEntityType.notFound,
    );
    expect(await target.exists(), isTrue);
    expect(
      RegExp(r'[&|<>^%!"\r\n]').hasMatch('${alias.path}${target.path}'),
      isFalse,
    );
    final result = await Process.run('cmd.exe', [
      '/d',
      '/c',
      'mklink',
      '/J',
      alias.path,
      target.path,
    ]);
    expect(
      result.exitCode,
      0,
      reason:
          'A real unprivileged NTFS junction must be created; no mock fallback',
    );
    aliases.add(alias.path);
    expect(
      p.equals(
        await alias.resolveSymbolicLinks(),
        await target.resolveSymbolicLinks(),
      ),
      isTrue,
    );
    return (await FileSystemEntity.type(
      alias.path,
      followLinks: false,
    )).toString();
  }

  Future<File> original() async {
    final dir = await Directory(
      p.join(documents.path, 'media', 'import-native'),
    ).create(recursive: true);
    final file = await File(
      p.join(dir.path, 'original.bin'),
    ).writeAsString('Synthetic original: preserve every byte.', flush: true);
    await OwnedMaterialActivity.mark(dir, 'original');
    for (final item in await dir.list().toList()) {
      if (item is File) await item.setLastModified(old);
    }
    await h.database.writeTransaction(
      h.database.captureGeneration(),
      (db) => db.insert(
        'MediaRecords',
        MediaRecord(
          id: 'native-junction-original',
          type: 'file',
          contentOrPath: file.path,
          createdAt: old,
        ).toJson(),
      ),
    );
    return file;
  }

  Future<void> copyFlat(Directory from, Directory to) async {
    await to.create(recursive: true);
    for (final entry in await from.list(followLinks: false).toList()) {
      expect(entry, isA<File>());
      final source = entry as File;
      final target = await source.copy(
        p.join(to.path, p.basename(source.path)),
      );
      await target.setLastModified(await source.lastModified());
    }
  }

  Future<Map<String, String>> hashes(Directory dir) async => {
    for (final f
        in (await dir.list(followLinks: false).toList()).whereType<File>())
      p.basename(f.path): sha256.convert(await f.readAsBytes()).toString(),
  };
  Future<String> rows() => h.database.read(
    h.database.captureGeneration(),
    (db) async => jsonEncode({
      for (final table in ['Reminders', 'MediaRecords', 'Settings'])
        table: await db.query(table, orderBy: 'id'),
    }),
  );
  Future<ContentCleanupPlan> preview() async => service.prepare(
    await service.inspect(h.database.captureGeneration()),
    {'record:native-junction-original'},
    h.database.captureGeneration(),
    isCurrent: () => true,
  );
  Future<void> reject(Future<dynamic> Function() action) async {
    Object? error;
    try {
      await action();
    } catch (e) {
      error = e;
    }
    expect(
      error,
      anyOf(isA<StateError>(), isA<FormatException>()),
      reason: 'Changed directory ownership must reject cleanup',
    );
  }

  Future<void> cleanPositive(ContentCleanupPlan plan, File file) async {
    await service.clean(
      plan,
      h.database.captureGeneration(),
      isCurrent: () => true,
    );
    expect(await file.exists(), isFalse);
    expect(await (await h.database.database).query('MediaRecords'), isEmpty);
    expect(
      (await service.inspect(h.database.captureGeneration())).pendingJobs,
      isEmpty,
    );
  }

  setUp(() async {
    expect(Platform.isWindows, isTrue);
    h = OfflineManagementHarness();
    await h.create();
    root = await Directory.systemTemp.createTemp('dontforget-native-junction-');
    documents = await Directory(p.join(root.path, 'Documents')).create();
    service = ContentCleanupService(h.database, documents, clock: () => now);
  });
  tearDown(() async {
    for (final path in aliases.toList().reversed) {
      await removeAlias(path);
    }
    OwnedMaterialActivity.activeDirectories.removeWhere(
      (v) => p.isWithin(root.path, v),
    );
    await h.dispose();
    await root.delete(recursive: true);
    expect(await root.exists(), isFalse);
  });
  tearDownAll(() async {
    if (const bool.fromEnvironment('WRITE_NATIVE_EVIDENCE')) {
      final path = File('build/windows-content-junction-result.json');
      await path.parent.create(recursive: true);
      final version = RegExp(
        r'^version:\s*(.+)$',
        multiLine: true,
      ).firstMatch(await File('pubspec.yaml').readAsString())!.group(1);
      final report = {
        'platform': 'Windows NTFS',
        'version': version,
        'checked_at_utc': DateTime.now().toUtc().toIso8601String(),
        'only_fresh_owned_temporary_directories_modified': true,
        'normal_application_data_or_credentials_accessed': false,
        'system_directory_acl_or_security_settings_modified': false,
        'native_junction_creation': 'cmd mklink /J',
        'junction_removal':
            'kernel32 RemoveDirectoryW after reparse-point and scope checks',
        'cases': outcomes,
      };
      await path.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
    }
  });

  test(
    'native import-directory takeover rejects a stale cleanup plan without changing files or rows',
    () async {
      final file = await original(),
          plan = await preview(),
          before = await rows();
      final parent = file.parent,
          held = Directory(p.join(root.path, 'held-import'));
      await parent.rename(held.path);
      final outside = Directory(p.join(root.path, 'outside-import'));
      await copyFlat(held, outside);
      final kept = await hashes(outside), originalKept = await hashes(held);
      final type = await junction(parent, outside);
      await reject(
        () => service.clean(
          plan,
          h.database.captureGeneration(),
          isCurrent: () => true,
        ),
      );
      expect(await rows(), before);
      expect(await hashes(outside), kept);
      expect(await hashes(held), originalKept);
      await removeAlias(parent.path);
      await held.rename(parent.path);
      await cleanPositive(plan, file);
      expect(await hashes(outside), kept);
      outcomes.add({
        'case': 'import_directory_replaced_after_preview',
        'junction_type': type,
        'stale_delete_rejected': true,
        'all_business_fields_preserved_on_rejection': true,
        'outside_files_preserved': true,
        'original_files_preserved_on_rejection': true,
        'original_directory_restored_and_explicit_cleanup_succeeds': true,
      });
    },
  );

  test(
    'native media-root takeover cannot redirect cleanup outside the previewed root',
    () async {
      final file = await original(),
          plan = await preview(),
          before = await rows();
      final media = file.parent.parent,
          held = Directory(p.join(root.path, 'held-media'));
      await media.rename(held.path);
      final outside = await Directory(
        p.join(root.path, 'outside-media'),
      ).create();
      await copyFlat(
        Directory(p.join(held.path, 'import-native')),
        Directory(p.join(outside.path, 'import-native')),
      );
      final target = Directory(p.join(outside.path, 'import-native')),
          kept = await hashes(target);
      final type = await junction(media, outside);
      await reject(
        () => service.clean(
          plan,
          h.database.captureGeneration(),
          isCurrent: () => true,
        ),
      );
      expect(await rows(), before);
      expect(await hashes(target), kept);
      expect(
        await File(
          p.join(held.path, 'import-native', 'original.bin'),
        ).readAsString(),
        'Synthetic original: preserve every byte.',
      );
      await removeAlias(media.path);
      await held.rename(media.path);
      await cleanPositive(plan, file);
      expect(await hashes(target), kept);
      outcomes.add({
        'case': 'media_root_replaced_after_preview',
        'junction_type': type,
        'stale_delete_rejected': true,
        'all_business_fields_preserved_on_rejection': true,
        'outside_files_preserved': true,
        'original_root_restored_and_explicit_cleanup_succeeds': true,
      });
    },
  );

  test(
    'native interrupted-cleanup junction is rejected and the original job remains repairable',
    () async {
      await original();
      final plan = await preview();
      final interrupted = ContentCleanupService(
        h.database,
        documents,
        clock: () => now,
        beforePurge: () async => throw StateError('Synthetic interruption'),
      );
      final result = await interrupted.clean(
        plan,
        h.database.captureGeneration(),
        isCurrent: () => true,
      );
      expect(result.pending, isTrue);
      final job = (await service.inspect(
        h.database.captureGeneration(),
      )).pendingJobs.single;
      final quarantine = Directory(p.join(documents.path, 'media', job)),
          held = Directory(p.join(root.path, 'held-job'));
      final before = await rows();
      await quarantine.rename(held.path);
      final outside = Directory(p.join(root.path, 'outside-job'));
      await copyFlat(held, outside);
      final kept = await hashes(outside);
      final type = await junction(quarantine, outside);
      await reject(
        () => service.repair(
          job,
          h.database.captureGeneration(),
          isCurrent: () => true,
        ),
      );
      expect(await rows(), before);
      expect(await hashes(outside), kept);
      expect(await File(p.join(held.path, 'file-0')).exists(), isTrue);
      await removeAlias(quarantine.path);
      await held.rename(quarantine.path);
      expect(
        await service.repair(
          job,
          h.database.captureGeneration(),
          isCurrent: () => true,
        ),
        1,
      );
      expect(
        (await service.inspect(h.database.captureGeneration())).pendingJobs,
        isEmpty,
      );
      expect(await hashes(outside), kept);
      outcomes.add({
        'case': 'interrupted_cleanup_directory_replaced_by_junction',
        'junction_type': type,
        'repair_alias_rejected': true,
        'all_business_fields_preserved_on_rejection': true,
        'outside_files_preserved': true,
        'original_staged_file_preserved_on_rejection': true,
        'original_job_restored_and_repair_succeeds': true,
      });
    },
  );
}
