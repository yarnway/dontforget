@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/backup_cache_service.dart';
import 'package:dont_forget/services/backup_file_exporter.dart';
import 'package:dont_forget/services/content/owned_material_activity.dart';
import 'package:dont_forget/services/streaming_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import '../../test/support/offline_management_harness.dart';

// Opt in only with the bounded, disposable mount prepared by the companion
// acceptance runner. Never fill an arbitrary disk or a normal application path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixturePath = Platform.environment['DONTFORGET_DISKFULL_ROOT'];
  test(
    'real full filesystem preserves backups and originals, then retries',
    () async {
      final root = Directory(fixturePath!);
      final token = Platform.environment['DONTFORGET_DISKFULL_TOKEN'];
      expect(root.path, startsWith(r'\\wsl.localhost\'));
      expect(p.basename(root.path), token);
      expect(token, matches(r'^dontforget-diskfull-[a-f0-9]{32}$'));
      final owner =
          jsonDecode(
                await File(
                  p.join(root.path, 'fixture-owner.json'),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(owner['format'], 'dontforget.diskfull.fixture');
      expect(owner['token'], token);
      expect(owner['capacity_bytes'], 16 * 1024 * 1024);
      expect(await root.list().length, 1);

      final h = OfflineManagementHarness();
      await h.create();
      final outcomes = <Map<String, Object?>>[];
      const service = StreamingBackupService();
      final filler = File(p.join(root.path, 'reserved-test-space.bin'));
      final chunk = Uint8List.fromList(
        List.generate(1024 * 1024, (i) => i % 251),
      );
      Future<void> writeChunks(File file, int count) async {
        final out = await file.open(mode: FileMode.write);
        try {
          for (var i = 0; i < count; i++) {
            await out.writeFrom(chunk);
          }
          await out.flush();
        } finally {
          await out.close();
        }
      }

      Future<String> digest(File file) async =>
          (await sha256.bind(file.openRead()).first).toString();
      Future<String> rows() => h.database.read(
        h.database.captureGeneration(),
        (db) async => jsonEncode({
          for (final table in ['Reminders', 'MediaRecords', 'Settings'])
            table: await db.query(table, orderBy: 'id'),
        }),
      );
      Future<List<String>> entries(Directory dir) async =>
          (await dir.list(followLinks: false).toList())
              .map((e) => p.basename(e.path))
              .toList()
            ..sort();

      try {
        final original = File(p.join(h.directory.path, 'original.bin'));
        await writeChunks(original, 8);
        final originalHash = await digest(original);
        await h.database.writeTransaction(h.database.captureGeneration(), (
          db,
        ) async {
          await db.insert(
            'MediaRecords',
            MediaRecord(
              id: 'diskfull-original',
              type: 'file',
              contentOrPath: original.path,
              createdAt: DateTime(2032),
            ).toJson(),
          );
          await db.insert(
            'Reminders',
            Reminder(
              id: 'diskfull-task',
              recordId: 'diskfull-original',
              taskTitle: 'Synthetic full-filesystem preservation control',
              quadrantLevel: 2,
            ).toJson(),
          );
        });
        final before = await rows();
        Future<void> preserved() async {
          expect(await rows(), before);
          expect(await digest(original), originalHash);
        }

        for (final encrypted in [false, true]) {
          final password = encrypted
              ? 'Synthetic disk full password 2032'
              : null;
          final healthy = await service.createFile(
            h.database,
            h.database.captureGeneration(),
            Directory(p.join(h.directory.path, 'healthy-cache')),
            password: password,
          );
          final backupHash = await digest(healthy.file);
          final preview = await service.inspect(
            healthy.file,
            password: password,
          );
          expect(preview.mediaCount, 1);
          expect(preview.encrypted, encrypted);

          for (final operation in ['create', 'export', 'restore']) {
            final target = await Directory(
              p.join(
                root.path,
                '${encrypted ? 'encrypted' : 'plain'}-$operation',
              ),
            ).create();
            final sentinel = File(p.join(target.path, 'previous-export.txt'));
            await sentinel.writeAsString(
              'Preserve previous files.',
              flush: true,
            );
            final priorEntries = await entries(target);
            final reservationsBefore = Set.of(
              BackupCacheService.activeDirectories,
            );
            final materialsBefore = Set.of(
              OwnedMaterialActivity.activeDirectories,
            );
            await writeChunks(filler, 12);
            final progress = <BackupProgress>[];
            Object? failure;
            try {
              switch (operation) {
                case 'create':
                  await service.createFile(
                    h.database,
                    h.database.captureGeneration(),
                    target,
                    password: password,
                    onProgress: progress.add,
                  );
                case 'export':
                  await BackupFileExporter(
                    useDirectoryPicker: true,
                    pickDirectory: () async => target.path,
                  ).save(healthy.file, 'synthetic.dfbackup');
                case 'restore':
                  await service.prepareRestore(
                    healthy.file,
                    target,
                    expectedDigest: preview.digest,
                    isCurrent: () => true,
                    password: password,
                    onProgress: progress.add,
                  );
              }
            } catch (error) {
              failure = error;
            }
            expect(failure, isA<FileSystemException>());
            final error = failure! as FileSystemException;
            expect(
              error.osError?.errorCode,
              anyOf(28, 39, 112),
              reason: 'Only a real filesystem space-exhaustion error qualifies',
            );
            if (operation == 'create') {
              expect(
                progress.any((v) => v.stage == 'write' && v.completed > 0),
                isTrue,
                reason: 'Space must run out after writing actual backup frames',
              );
            }
            expect(await entries(target), priorEntries);
            expect(await sentinel.readAsString(), 'Preserve previous files.');
            expect(BackupCacheService.activeDirectories, reservationsBefore);
            expect(OwnedMaterialActivity.activeDirectories, materialsBefore);
            expect(await digest(healthy.file), backupHash);
            await preserved();
            await filler.delete();

            switch (operation) {
              case 'create':
                final retried = await service.createFile(
                  h.database,
                  h.database.captureGeneration(),
                  target,
                  password: password,
                );
                final checked = await service.inspect(
                  retried.file,
                  password: password,
                );
                expect(checked.mediaCount, 1);
                expect(checked.encrypted, encrypted);
                await const BackupCacheService().release(retried.file);
              case 'export':
                final saved = await BackupFileExporter(
                  useDirectoryPicker: true,
                  pickDirectory: () async => target.path,
                ).save(healthy.file, 'synthetic.dfbackup');
                expect(await digest(File(saved!)), backupHash);
                expect(
                  (await service.inspect(
                    File(saved),
                    password: password,
                  )).digest,
                  preview.digest,
                );
                await File(saved).delete();
              case 'restore':
                final snapshot = await service.prepareRestore(
                  healthy.file,
                  target,
                  expectedDigest: preview.digest,
                  isCurrent: () => true,
                  password: password,
                );
                final restored =
                    jsonDecode(await snapshot.readAsString()) as Map;
                expect(restored['reminders'], hasLength(1));
                expect(restored['settings'], hasLength(1));
                final media = (restored['media_records'] as List).single as Map;
                expect(
                  await digest(File(media['content_or_path'] as String)),
                  originalHash,
                );
                OwnedMaterialActivity.release(snapshot);
                await snapshot.parent.delete(recursive: true);
            }
            await preserved();
            expect(await digest(healthy.file), backupHash);
            expect(await entries(target), priorEntries);
            expect(BackupCacheService.activeDirectories, reservationsBefore);
            expect(OwnedMaterialActivity.activeDirectories, materialsBefore);
            outcomes.add({
              'encrypted': encrypted,
              'operation': operation,
              'actual_os_error': error.osError!.errorCode,
              'completed_write_frames_before_failure': progress
                  .where((v) => v.stage == 'write' && v.completed > 0)
                  .length,
              'failure_leaves_only_preexisting_files': true,
              'source_backup_hash_unchanged': true,
              'original_attachment_hash_unchanged': true,
              'all_business_fields_unchanged': true,
              'process_local_reservations_unchanged': true,
              'retry_after_freeing_space_passed': true,
            });
            await target.delete(recursive: true);
          }
          await const BackupCacheService().release(healthy.file);
        }
        await h.close();
        await h.open();
        await preserved();
        expect(await root.list().length, 1);
        final reportPath = Platform.environment['DONTFORGET_DISKFULL_REPORT'];
        if (reportPath != null) {
          expect(
            p.isWithin(p.join(Directory.current.path, 'build'), reportPath),
            isTrue,
          );
          await File(reportPath).writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'runtime': 'native Windows Flutter test engine',
              'filesystem': 'bounded WSL tmpfs through Windows UNC',
              'capacity_bytes': 16 * 1024 * 1024,
              'filler_bytes': 12 * 1024 * 1024,
              'attachment_bytes': 8 * 1024 * 1024,
              'cases': outcomes,
              'isolated_database_reopen_all_fields_preserved': true,
              'native_file_picker_or_gui_tested': false,
              'normal_user_data_or_credentials_accessed': false,
              'physical_power_loss_tested': false,
              'ntfs_disk_full_tested': false,
            }),
            flush: true,
          );
        }
      } finally {
        if (await filler.exists()) await filler.delete();
        await h.dispose();
      }
    },
    skip: fixturePath == null
        ? 'Requires the explicit bounded real-disk-full acceptance runner.'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
