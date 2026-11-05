// Explicit opt-in: real four-attachment encrypted capacity, outside test/.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/backup_cache_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/streaming_backup_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../test/support/offline_management_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const unit = 1024 * 1024;
  const mib = int.fromEnvironment('DF_BACKUP_CAPACITY_MIB', defaultValue: 512);
  const password = 'Public synthetic encrypted total fixture 2030';
  const service = StreamingBackupService();
  test(
    'four encrypted attachments restore with exact bytes and database reopen',
    () async {
      expect(mib, inInclusiveRange(1, 512));
      final h = OfflineManagementHarness();
      await h.create();
      final report = <String, Object?>{
        'format': 1,
        'scope': 'encrypted-total',
        'platform': Platform.operatingSystem,
        'dart': Platform.version.split(' ').first,
        'attachment_bytes': mib * unit,
        'total_attachment_bytes': 4 * mib * unit,
        'full_capacity_boundary': mib == 512,
        'baseline_rss_bytes': ProcessInfo.currentRss,
        'cases': <Map<String, Object?>>[],
      };
      final cases = report['cases'] as List<Map<String, Object?>>;
      Future<T> timed<T>(String name, Future<T> Function() run) async {
        final watch = Stopwatch()..start();
        stdout.writeln('CAPACITY_START $name');
        final result = await run();
        cases.add({
          'stage': name,
          'elapsed_ms': watch.elapsedMilliseconds,
          'rss_bytes': ProcessInfo.currentRss,
          'max_rss_bytes': ProcessInfo.maxRss,
        });
        stdout.writeln('CAPACITY_PASS $name ${watch.elapsedMilliseconds}ms');
        return result;
      }

      final sources = <String, File>{};
      final hashes = <String, String>{};
      Future<String> hash(File file) async =>
          (await sha256.bind(file.openRead()).first).toString();
      try {
        await timed('seed_and_hash_four_attachments', () async {
          for (var index = 0; index < 4; index++) {
            final id = 'protected-total-$index';
            final file = File('${h.directory.path}/$id.bin');
            final chunk = Uint8List(unit);
            for (var n = 0; n < chunk.length; n++) {
              chunk[n] = (n * 23 + index * 31) % 251;
            }
            final out = await file.open(mode: FileMode.write);
            try {
              for (var n = 0; n < mib; n++) {
                await out.writeFrom(chunk);
              }
              await out.flush();
            } finally {
              await out.close();
            }
            expect(await file.length(), mib * unit);
            sources[id] = file;
            hashes[id] = await hash(file);
            await h.database.writeTransaction(h.database.captureGeneration(), (
              db,
            ) async {
              await db.insert(
                'MediaRecords',
                MediaRecord(
                  id: id,
                  type: 'audio',
                  contentOrPath: file.path,
                  createdAt: DateTime.utc(2030),
                ).toJson(),
              );
            });
            await h.seed(
              Reminder(
                id: id,
                recordId: id,
                taskTitle: 'Synthetic encrypted attachment $index',
                quadrantLevel: 2,
                createdAt: DateTime.utc(2030),
              ),
            );
          }
        });
        final backup = await timed(
          'encrypted_total_export',
          () => service.createFile(
            h.database,
            h.database.captureGeneration(),
            Directory('${h.directory.path}/encrypted-cache'),
            password: password,
          ),
        );
        expect(backup.mediaCount, 4);
        expect(backup.missingMedia, isEmpty);
        report['encrypted_backup_bytes'] = await backup.file.length();
        final preview = await timed(
          'encrypted_total_inspect',
          () => service.inspect(backup.file, password: password),
        );
        expect(preview.encrypted, true);
        expect(preview.mediaCount, 4);
        await timed('wrong_password_leaves_no_restore_output', () async {
          final destination = Directory('${h.directory.path}/wrong-password');
          await expectLater(
            service.prepareRestore(
              backup.file,
              destination,
              password: 'Incorrect public synthetic password',
              expectedDigest: preview.digest,
              isCurrent: () => true,
            ),
            throwsA(isA<BackupPasswordException>()),
          );
          if (await destination.exists()) {
            expect(await destination.list().toList(), isEmpty);
          }
        });
        await timed('encrypted_cancel_cleans_partial_files', () async {
          final control = BackupControl();
          final destination = Directory('${h.directory.path}/cancelled');
          await expectLater(
            service.prepareRestore(
              backup.file,
              destination,
              password: password,
              expectedDigest: preview.digest,
              control: control,
              isCurrent: () => true,
              onProgress: (progress) {
                if (progress.stage == 'read' &&
                    progress.completed >
                        mib * unit + StreamingBackupService.chunkBytes) {
                  control.cancel();
                }
              },
            ),
            throwsA(isA<BackupCancelled>()),
          );
          expect(control.cancelled, true);
          if (await destination.exists()) {
            expect(await destination.list().toList(), isEmpty);
          }
        });
        final snapshot = await timed(
          'encrypted_total_prepare_restore',
          () => service.prepareRestore(
            backup.file,
            Directory('${h.directory.path}/restored'),
            password: password,
            expectedDigest: preview.digest,
            isCurrent: () => true,
          ),
        );
        await timed('verify_all_restored_and_original_hashes', () async {
          final rows =
              jsonDecode(await snapshot.readAsString())['media_records']
                  as List;
          expect(rows.length, 4);
          for (final row in rows) {
            final file = File(row['content_or_path'] as String);
            expect(await file.length(), mib * unit);
            expect(await hash(file), hashes[row['id']]);
          }
          for (final entry in sources.entries) {
            expect(await hash(entry.value), hashes[entry.key]);
          }
        });
        await timed('restore_database_close_reopen_and_hash', () async {
          final inspector = BackupInspector(databaseFactoryFfi);
          final inspected = await inspector.inspect(snapshot);
          await h.seed(
            Reminder(
              id: 'later-only',
              taskTitle: 'Synthetic later row',
              quadrantLevel: 2,
              createdAt: DateTime.utc(2030),
            ),
          );
          await DatabaseRecovery(
            h.database,
            inspector: inspector,
            // This explicit acceptance is deliberately outside automatic test/.
            // ignore: invalid_use_of_visible_for_testing_member
            notifications: NotificationService.forTesting(
              FlutterLocalNotificationsPlugin(),
              usesNativeNotifications: false,
            ),
          ).restore(snapshot, expectedDigest: inspected.digest);
          await h.close();
          await h.open();
          expect(
            (await h.rows()).map((r) => r.id).toSet(),
            sources.keys.toSet(),
          );
          final rows = await h.database.read(
            h.database.captureGeneration(),
            (db) => db.query('MediaRecords'),
          );
          expect(rows.length, 4);
          for (final row in rows) {
            expect(
              await hash(File(row['content_or_path'] as String)),
              hashes[row['id']],
            );
          }
        });
        await const BackupCacheService().release(backup.file);
        report['outcome'] = 'PASS';
        report['max_rss_bytes'] = ProcessInfo.maxRss;
        const destination = String.fromEnvironment('DF_BACKUP_CAPACITY_REPORT');
        if (destination.isNotEmpty) {
          final file = File(destination);
          await file.parent.create(recursive: true);
          await file.writeAsString('${jsonEncode(report)}\n', flush: true);
        }
        stdout.writeln('CAPACITY_RESULT ${jsonEncode(report)}');
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 45)),
  );
}
