// Explicit opt-in acceptance; kept outside test/ to avoid multi-GiB CI jobs.
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
  const mib = 1024 * 1024;
  const unitMiB = int.fromEnvironment(
    'DF_BACKUP_CAPACITY_MIB',
    defaultValue: 512,
  );
  const password = 'Public synthetic capacity fixture 2030';
  const service = StreamingBackupService();

  test('streaming backup capacity, cancellation and database reopen', () async {
    expect(unitMiB, inInclusiveRange(1, 512));
    final h = OfflineManagementHarness();
    await h.create();
    final report = <String, Object?>{
      'format': 1,
      'platform': Platform.operatingSystem,
      'dart': Platform.version.split(' ').first,
      'attachment_bytes': unitMiB * mib,
      'total_attachment_bytes': 4 * unitMiB * mib,
      'full_capacity_boundary': unitMiB == 512,
      'baseline_rss_bytes': ProcessInfo.currentRss,
      'cases': <Map<String, Object?>>[],
    };
    final hashes = <String, String>{};
    final sources = <String, File>{};
    final stages = report['cases'] as List<Map<String, Object?>>;
    Future<T> timed<T>(String stage, Future<T> Function() body) async {
      final watch = Stopwatch()..start();
      stdout.writeln('CAPACITY_START $stage');
      final value = await body();
      stages.add({
        'stage': stage,
        'elapsed_ms': watch.elapsedMilliseconds,
        'rss_bytes': ProcessInfo.currentRss,
        'max_rss_bytes': ProcessInfo.maxRss,
      });
      stdout.writeln('CAPACITY_PASS $stage ${watch.elapsedMilliseconds}ms');
      return value;
    }

    Future<void> insertMedia(String id, File file) =>
        h.database.writeTransaction(h.database.captureGeneration(), (db) async {
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

    Future<BackupFile> export(String name, {String? key}) => service.createFile(
      h.database,
      h.database.captureGeneration(),
      Directory('${h.directory.path}/$name'),
      password: key,
    );

    try {
      // Reject an actual oversize file before scanning its contents. The file
      // belongs only to this randomly named temporary fixture directory.
      await timed('single_attachment_limit_plus_one', () async {
        final file = File('${h.directory.path}/oversized.bin');
        final output = await file.open(mode: FileMode.write);
        try {
          await output.truncate(StreamingBackupService.maxAttachmentBytes + 1);
        } finally {
          await output.close();
        }
        await insertMedia('oversized', file);
        await expectLater(export('oversize-cache'), throwsFormatException);
        expect(
          await Directory('${h.directory.path}/oversize-cache').exists(),
          false,
        );
        await h.database.writeTransaction(h.database.captureGeneration(), (
          db,
        ) async {
          await db.delete(
            'MediaRecords',
            where: 'id = ?',
            whereArgs: ['oversized'],
          );
        });
        await file.delete();
      });

      await timed('seed_and_hash_four_attachments', () async {
        for (var index = 0; index < 4; index++) {
          final id = 'capacity-$index';
          final file = File('${h.directory.path}/$id.bin');
          final chunk = Uint8List(mib);
          for (var n = 0; n < chunk.length; n++) {
            chunk[n] = (n * 17 + index * 29) % 251;
          }
          final out = await file.open(mode: FileMode.write);
          try {
            for (var n = 0; n < unitMiB; n++) {
              await out.writeFrom(chunk);
            }
            await out.flush();
          } finally {
            await out.close();
          }
          expect(await file.length(), unitMiB * mib);
          sources[id] = file;
          hashes[id] = (await sha256.bind(file.openRead()).first).toString();
          await insertMedia(id, file);
          await h.seed(
            Reminder(
              id: id,
              recordId: id,
              taskTitle: 'Synthetic capacity attachment $index',
              quadrantLevel: 2,
              createdAt: DateTime.utc(2030),
            ),
          );
        }
      });

      if (unitMiB == 512) {
        await timed('total_attachment_limit_plus_one', () async {
          final extra = await File(
            '${h.directory.path}/extra.bin',
          ).writeAsBytes([1]);
          await insertMedia('extra', extra);
          await expectLater(export('total-limit-cache'), throwsFormatException);
          expect(
            await Directory('${h.directory.path}/total-limit-cache').exists(),
            false,
          );
          await h.database.writeTransaction(h.database.captureGeneration(), (
            db,
          ) async {
            await db.delete(
              'MediaRecords',
              where: 'id = ?',
              whereArgs: ['extra'],
            );
          });
          await extra.delete();
        });
      }

      final plain = await timed('plain_export', () => export('plain-cache'));
      expect(plain.mediaCount, 4);
      expect(plain.missingMedia, isEmpty);
      report['plain_backup_bytes'] = await plain.file.length();
      final preview = await timed(
        'plain_inspect',
        () => service.inspect(plain.file),
      );
      expect(preview.mediaCount, 4);
      expect(preview.encrypted, false);

      await timed('cancel_after_first_attachment', () async {
        final control = BackupControl();
        final root = Directory('${h.directory.path}/cancelled');
        await expectLater(
          service.prepareRestore(
            plain.file,
            root,
            expectedDigest: preview.digest,
            control: control,
            isCurrent: () => true,
            onProgress: (value) {
              if (value.stage == 'read' &&
                  value.completed >
                      unitMiB * mib + StreamingBackupService.chunkBytes) {
                control.cancel();
              }
            },
          ),
          throwsA(isA<BackupCancelled>()),
        );
        expect(control.cancelled, true);
        if (await root.exists()) expect(await root.list().toList(), isEmpty);
      });

      final prepared = await timed(
        'plain_prepare_restore',
        () => service.prepareRestore(
          plain.file,
          Directory('${h.directory.path}/restored'),
          expectedDigest: preview.digest,
          isCurrent: () => true,
        ),
      );
      final snapshot = jsonDecode(await prepared.readAsString()) as Map;
      await timed('verify_all_restored_and_original_hashes', () async {
        final records = snapshot['media_records'] as List;
        expect(records.length, 4);
        for (final row in records) {
          final file = File(row['content_or_path'] as String);
          expect(await file.length(), unitMiB * mib);
          expect(
            (await sha256.bind(file.openRead()).first).toString(),
            hashes[row['id']],
          );
        }
        for (final entry in sources.entries) {
          expect(
            (await sha256.bind(entry.value.openRead()).first).toString(),
            hashes[entry.key],
          );
        }
      });

      await timed('restore_database_and_reopen', () async {
        final inspector = BackupInspector(databaseFactoryFfi);
        final summary = await inspector.inspect(prepared);
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
          // This explicit acceptance test lives outside automatic test discovery.
          // ignore: invalid_use_of_visible_for_testing_member
          notifications: NotificationService.forTesting(
            FlutterLocalNotificationsPlugin(),
            usesNativeNotifications: false,
          ),
        ).restore(prepared, expectedDigest: summary.digest);
        await h.close();
        await h.open();
        expect(
          (await h.rows()).map((row) => row.id).toSet(),
          sources.keys.toSet(),
        );
      });

      // The protected boundary is one real 512 MiB attachment. The 2 GiB total
      // case above is plaintext; report those independently, never interchange.
      await h.database.writeTransaction(h.database.captureGeneration(), (
        db,
      ) async {
        await db.delete(
          'Reminders',
          where: 'id != ?',
          whereArgs: ['capacity-0'],
        );
        await db.delete(
          'MediaRecords',
          where: 'id != ?',
          whereArgs: ['capacity-0'],
        );
      });
      final encrypted = await timed(
        'protected_single_export',
        () => export('protected-cache', key: password),
      );
      final encryptedPreview = await timed(
        'protected_single_inspect',
        () => service.inspect(encrypted.file, password: password),
      );
      expect(encryptedPreview.encrypted, true);
      expect(encryptedPreview.mediaCount, 1);
      final protectedSnapshot = await timed(
        'protected_single_prepare_restore',
        () => service.prepareRestore(
          encrypted.file,
          Directory('${h.directory.path}/protected-restored'),
          expectedDigest: encryptedPreview.digest,
          password: password,
          isCurrent: () => true,
        ),
      );
      final protectedRows =
          jsonDecode(await protectedSnapshot.readAsString())['media_records']
              as List;
      expect(protectedRows.length, 1);
      final protectedFile = File(
        protectedRows.single['content_or_path'] as String,
      );
      expect(await protectedFile.length(), unitMiB * mib);
      expect(
        (await sha256.bind(protectedFile.openRead()).first).toString(),
        hashes['capacity-0'],
      );
      await const BackupCacheService().release(plain.file);
      await const BackupCacheService().release(encrypted.file);
      report['outcome'] = 'PASS';
      report['max_rss_bytes'] = ProcessInfo.maxRss;
      const reportPath = String.fromEnvironment('DF_BACKUP_CAPACITY_REPORT');
      if (reportPath.isNotEmpty) {
        final destination = File(reportPath);
        await destination.parent.create(recursive: true);
        await destination.writeAsString('${jsonEncode(report)}\n', flush: true);
      }
      stdout.writeln('CAPACITY_RESULT ${jsonEncode(report)}');
    } finally {
      await h.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
