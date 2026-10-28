import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/portable_backup_service.dart';
import 'package:dont_forget/services/streaming_backup_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/offline_management_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  const service = StreamingBackupService(),
      password = 'Synthetic backup password 2030';
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
  });
  tearDown(() => h.dispose());
  Future<void> seed({int size = 5}) async {
    final file = File('${h.directory.path}/attachment.bin');
    final out = await file.open(mode: FileMode.write);
    final chunk = Uint8List(64 * 1024);
    for (var i = 0; i < chunk.length; i++) {
      chunk[i] = i % 251;
    }
    var left = size;
    while (left > 0) {
      final n = left < chunk.length ? left : chunk.length;
      await out.writeFrom(chunk, 0, n);
      left -= n;
    }
    await out.close();
    await h.database.writeTransaction(h.database.captureGeneration(), (
      db,
    ) async {
      await db.insert(
        'MediaRecords',
        MediaRecord(
          id: 'media',
          type: 'image',
          contentOrPath: file.path,
          createdAt: DateTime(2030),
        ).toJson(),
      );
      await db.insert(
        'MediaRecords',
        MediaRecord(
          id: 'missing',
          type: 'audio',
          contentOrPath: '${h.directory.path}/absent',
          createdAt: DateTime(2030),
        ).toJson(),
      );
      await db.insert(
        'Reminders',
        Reminder(
          id: 'task',
          recordId: 'media',
          taskTitle: 'Synthetic private record',
          quadrantLevel: 2,
          createdAt: DateTime(2030),
        ).toJson(),
      );
    });
  }

  Future<BackupFile> export({String? key, int size = 5}) async {
    await seed(size: size);
    return service.createFile(
      h.database,
      h.database.captureGeneration(),
      Directory('${h.directory.path}/cache'),
      password: key,
    );
  }

  int bodyOffset(Uint8List bytes) =>
      12 + ByteData.sublistView(bytes, 8, 12).getUint32(0);
  test(
    'Python-generated AES-GCM fixture decrypts with the documented framing and KDF',
    () async {
      final fixture = File(
        'test/fixtures/protected_backup/python-aesgcm-v2.dfbackup',
      );
      final preview = await service.inspect(
        fixture,
        password: 'Public synthetic fixture password 2030',
      );
      expect(preview.encrypted, isTrue);
      expect(preview.mediaCount, 0);
      expect(preview.missingMedia, isEmpty);
    },
  );
  test(
    'new file streams raw attachments and preserves metadata and missing media',
    () async {
      await h.container
          .read(settingsProvider.notifier)
          .updateSettings(
            h.container
                .read(settingsProvider)
                .copyWith(apiKey: 'private-ai-key'),
          );
      final backup = await export();
      expect(backup.mediaCount, 1);
      expect(backup.missingMedia, ['missing']);
      final raw = await backup.file.readAsBytes();
      expect(
        utf8.decode(raw, allowMalformed: true),
        isNot(contains('private-ai-key')),
      );
      expect(await service.needsPassword(backup.file), isFalse);
      final preview = await service.inspect(backup.file);
      expect(preview.mediaCount, 1);
      expect(preview.missingMedia, ['missing']);
      final prepared = await service.prepareRestore(
        backup.file,
        Directory('${h.directory.path}/restored'),
        expectedDigest: preview.digest,
        isCurrent: () => true,
      );
      final snapshot = jsonDecode(await prepared.readAsString());
      final record = (snapshot['media_records'] as List).firstWhere(
        (r) => r['id'] == 'media',
      );
      expect(await File(record['content_or_path']).readAsBytes(), [
        0,
        1,
        2,
        3,
        4,
      ]);
      expect(
        (await BackupInspector(
          databaseFactoryFfi,
        ).inspect(prepared)).counts['reminders'],
        1,
      );
    },
  );
  test(
    'encrypted round trip hides content, rejects wrong password and creates no restore directory',
    () async {
      final backup = await export(key: password);
      final raw = await backup.file.readAsBytes();
      expect(
        utf8.decode(raw, allowMalformed: true),
        isNot(contains('Synthetic private record')),
      );
      expect(utf8.decode(raw, allowMalformed: true), isNot(contains(password)));
      expect(await service.needsPassword(backup.file), isTrue);
      await expectLater(
        service.inspect(backup.file),
        throwsA(isA<BackupPasswordException>()),
      );
      await expectLater(
        service.prepareRestore(
          backup.file,
          Directory('${h.directory.path}/wrong'),
          expectedDigest: '0' * 64,
          password: 'Wrong synthetic password',
          isCurrent: () => true,
        ),
        throwsA(isA<BackupPasswordException>()),
      );
      expect(await Directory('${h.directory.path}/wrong').exists(), isFalse);
      final preview = await service.inspect(backup.file, password: password);
      final prepared = await service.prepareRestore(
        backup.file,
        Directory('${h.directory.path}/right'),
        expectedDigest: preview.digest,
        password: password,
        isCurrent: () => true,
      );
      expect(
        (await BackupInspector(databaseFactoryFfi).inspect(prepared)).version,
        16,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    '40 MiB attachment exceeds old JSON limit but new stream restores exact bytes',
    () async {
      final progress = <BackupProgress>[];
      await seed(size: 40 * 1024 * 1024);
      await expectLater(
        const PortableBackupService().create(
          h.database,
          h.database.captureGeneration(),
        ),
        throwsFormatException,
      );
      final backup = await service.createFile(
        h.database,
        h.database.captureGeneration(),
        Directory('${h.directory.path}/cache'),
        onProgress: progress.add,
      );
      expect(await backup.file.length(), lessThan(41 * 1024 * 1024));
      expect(progress.where((p) => p.stage == 'write').length, greaterThan(39));
      final preview = await service.inspect(backup.file);
      final prepared = await service.prepareRestore(
        backup.file,
        Directory('${h.directory.path}/large'),
        expectedDigest: preview.digest,
        isCurrent: () => true,
      );
      final snapshot = jsonDecode(await prepared.readAsString());
      final record = (snapshot['media_records'] as List).firstWhere(
        (r) => r['id'] == 'media',
      );
      final restored = File(record['content_or_path']);
      expect(await restored.length(), 40 * 1024 * 1024);
      expect(
        await sha256.bind(restored.openRead()).first,
        await sha256
            .bind(File('${h.directory.path}/attachment.bin').openRead())
            .first,
      );
    },
  );
  test(
    'ciphertext tampering, truncation and trailing bytes are rejected',
    () async {
      final backup = await export(key: password, size: 1024 * 1024 + 9);
      final original = await backup.file.readAsBytes();
      for (final mode in ['tamper', 'truncate', 'append']) {
        final bytes = Uint8List.fromList(
          mode == 'truncate'
              ? original.sublist(0, original.length - 1)
              : mode == 'append'
              ? [...original, 0]
              : original,
        );
        if (mode == 'tamper') bytes[bodyOffset(bytes) + 4 + 20] ^= 1;
        final file = await File(
          '${h.directory.path}/$mode',
        ).writeAsBytes(bytes);
        await expectLater(
          service.inspect(file, password: password),
          throwsA(
            anyOf(isA<FormatException>(), isA<BackupPasswordException>()),
          ),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'authenticated frames cannot be reordered and fresh exports use different salts and nonces',
    () async {
      final backup = await export(key: password, size: 3 * 1024 * 1024 + 9);
      final original = await backup.file.readAsBytes();
      final offset = bodyOffset(original);
      final header = jsonDecode(utf8.decode(original.sublist(12, offset)));
      const frameSize = 4 + StreamingBackupService.chunkBytes + 16;
      final swapped = Uint8List.fromList(original);
      swapped.setRange(
        offset,
        offset + frameSize,
        original,
        offset + frameSize,
      );
      swapped.setRange(
        offset + frameSize,
        offset + 2 * frameSize,
        original,
        offset,
      );
      final bad = await File(
        '${h.directory.path}/reordered',
      ).writeAsBytes(swapped);
      await expectLater(
        service.inspect(bad, password: password),
        throwsA(isA<BackupPasswordException>()),
      );
      final second = await service.createFile(
        h.database,
        h.database.captureGeneration(),
        Directory('${h.directory.path}/cache'),
        password: password,
      );
      final bytes = await second.file.open();
      final prefix = await bytes.read(4096);
      await bytes.close();
      final nextHeader = jsonDecode(
        utf8.decode(prefix.sublist(12, bodyOffset(prefix))),
      );
      expect(nextHeader['salt'], isNot(header['salt']));
      expect(nextHeader['nonce'], isNot(header['nonce']));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'cancel during restore removes provisional files without changing original media',
    () async {
      final backup = await export(size: 2 * 1024 * 1024 + 9);
      final preview = await service.inspect(backup.file);
      final control = BackupControl(),
          root = Directory('${h.directory.path}/cancelled-restore');
      await expectLater(
        service.prepareRestore(
          backup.file,
          root,
          expectedDigest: preview.digest,
          isCurrent: () => true,
          control: control,
          onProgress: (p) {
            if (p.stage == 'read' && p.completed >= 2 * 1024 * 1024) {
              control.cancel();
            }
          },
        ),
        throwsA(isA<BackupCancelled>()),
      );
      if (await root.exists()) expect(await root.list().toList(), isEmpty);
      expect(
        await File('${h.directory.path}/attachment.bin').length(),
        2 * 1024 * 1024 + 9,
      );
    },
  );
  test(
    'late authentication failure removes all provisional restored files',
    () async {
      final backup = await export(key: password, size: 2 * 1024 * 1024 + 9);
      final bytes = await backup.file.readAsBytes();
      bytes[bytes.length - 18] ^= 1;
      final bad = await File('${h.directory.path}/bad').writeAsBytes(bytes);
      final root = Directory('${h.directory.path}/staged');
      await expectLater(
        service.prepareRestore(
          bad,
          root,
          expectedDigest: '0' * 64,
          password: password,
          isCurrent: () => true,
        ),
        throwsA(isA<BackupPasswordException>()),
      );
      expect(await root.list().toList(), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'header downgrade and expensive KDF parameters are rejected before derivation',
    () async {
      final backup = await export(key: password);
      final bytes = await backup.file.readAsBytes();
      final offset = bodyOffset(bytes);
      final header = jsonDecode(utf8.decode(bytes.sublist(12, offset)));
      header['iterations'] = 1;
      final changed = utf8.encode(jsonEncode(header));
      final bad = await File('${h.directory.path}/header').writeAsBytes([
        ...bytes.sublist(0, 8),
        ...(ByteData(4)..setUint32(0, changed.length)).buffer.asUint8List(),
        ...changed,
        ...bytes.sublist(offset),
      ]);
      await expectLater(
        service.inspect(bad, password: password),
        throwsFormatException,
      );
    },
  );
  test('changed preview digest cannot publish a restored snapshot', () async {
    final backup = await export();
    final preview = await service.inspect(backup.file);
    final bytes = await backup.file.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await backup.file.writeAsBytes(bytes);
    final root = Directory('${h.directory.path}/changed');
    await expectLater(
      service.prepareRestore(
        backup.file,
        root,
        expectedDigest: preview.digest,
        isCurrent: () => true,
      ),
      throwsFormatException,
    );
    if (await root.exists()) expect(await root.list().toList(), isEmpty);
  });
  test(
    'cancelled export and stale generation leave no partial backup files',
    () async {
      await seed(size: 2 * 1024 * 1024);
      final control = BackupControl();
      final root = Directory('${h.directory.path}/cancel');
      await expectLater(
        service.createFile(
          h.database,
          h.database.captureGeneration(),
          root,
          control: control,
          onProgress: (p) {
            if (p.stage == 'write') control.cancel();
          },
        ),
        throwsA(isA<BackupCancelled>()),
      );
      expect(await root.list().toList(), isEmpty);
      final gen = h.database.captureGeneration(),
          lease = await h.database.beginMaintenance();
      await lease.resume();
      await expectLater(
        () => service.createFile(h.database, gen, root),
        throwsA(isA<DatabaseAccessException>()),
      );
    },
  );
  test(
    'source mutation during scan never produces a completed export',
    () async {
      await seed(size: 8);
      final source = File('${h.directory.path}/attachment.bin'),
          root = Directory('${h.directory.path}/mutation');
      await expectLater(
        service.createFile(
          h.database,
          h.database.captureGeneration(),
          root,
          onProgress: (p) {
            if (p.stage == 'scan') {
              source.writeAsBytesSync([9, 9, 9, 9, 9, 9, 9, 9]);
            }
          },
        ),
        throwsFormatException,
      );
      expect(await root.list().toList(), isEmpty);
    },
  );
  test(
    'oversized attachment is rejected without reading its contents',
    () async {
      await seed();
      final file = await File(
        '${h.directory.path}/attachment.bin',
      ).open(mode: FileMode.write);
      await file.truncate(StreamingBackupService.maxAttachmentBytes + 1);
      await file.close();
      await expectLater(
        service.createFile(
          h.database,
          h.database.captureGeneration(),
          Directory('${h.directory.path}/limit'),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'multiple attachment streams preserve zero-byte files and missing IDs cannot link to another device file',
    () async {
      await seed(size: 1024 * 1024 + 9);
      await File(
        '${h.directory.path}/absent',
      ).writeAsString('Unrelated file created after backup scan');
      // Keep the missing marker by using the path that does not yet exist at export.
      await File('${h.directory.path}/absent').delete();
      final zero = await File('${h.directory.path}/zero.bin').writeAsBytes([]),
          second = await File(
            '${h.directory.path}/second.jpg',
          ).writeAsBytes([9, 8, 7]);
      await h.database.writeTransaction(h.database.captureGeneration(), (
        db,
      ) async {
        for (final item in [('zero', zero), ('second', second)]) {
          await db.insert(
            'MediaRecords',
            MediaRecord(
              id: item.$1,
              type: 'image',
              contentOrPath: item.$2.path,
              createdAt: DateTime(2030),
            ).toJson(),
          );
        }
      });
      final backup = await service.createFile(
        h.database,
        h.database.captureGeneration(),
        Directory('${h.directory.path}/cache'),
        password: password,
      );
      await File(
        '${h.directory.path}/absent',
      ).writeAsString('Unrelated file on this device');
      final preview = await service.inspect(backup.file, password: password);
      final prepared = await service.prepareRestore(
        backup.file,
        Directory('${h.directory.path}/multi'),
        expectedDigest: preview.digest,
        password: password,
        isCurrent: () => true,
      );
      final rows =
          jsonDecode(await prepared.readAsString())['media_records'] as List;
      expect(preview.mediaCount, 3);
      expect(
        await File(
          rows.singleWhere((r) => r['id'] == 'zero')['content_or_path'],
        ).length(),
        0,
      );
      expect(
        await File(
          rows.singleWhere((r) => r['id'] == 'second')['content_or_path'],
        ).readAsBytes(),
        [9, 8, 7],
      );
      final missing = File(
        rows.singleWhere((r) => r['id'] == 'missing')['content_or_path'],
      );
      expect(await missing.exists(), isFalse);
      expect(
        await File('${h.directory.path}/absent').readAsString(),
        'Unrelated file on this device',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'legacy bundles remain readable and remappable through the new entry point',
    () async {
      await seed();
      final backup = await const PortableBackupService().create(
        h.database,
        h.database.captureGeneration(),
      );
      final file = await File(
        '${h.directory.path}/legacy.json',
      ).writeAsBytes(backup.bytes);
      expect(await service.needsPassword(file), isFalse);
      final preview = await service.inspect(file);
      final result = await service.prepareRestore(
        file,
        Directory('${h.directory.path}/legacy'),
        expectedDigest: preview.digest,
        isCurrent: () => true,
      );
      expect(
        (await BackupInspector(
          databaseFactoryFfi,
        ).inspect(result)).counts['reminders'],
        1,
      );
    },
  );
  for (final encrypted in [false, true]) {
    test(
      '${encrypted ? 'encrypted' : 'plain'} backup restores through actual recovery and a fresh provider container',
      () async {
        final backup = await export(key: encrypted ? password : null);
        final preview = await service.inspect(
          backup.file,
          password: encrypted ? password : null,
        );
        final prepared = await service.prepareRestore(
          backup.file,
          Directory('${h.directory.path}/restore-media'),
          expectedDigest: preview.digest,
          password: encrypted ? password : null,
          isCurrent: () => true,
        );
        final inspector = BackupInspector(databaseFactoryFfi),
            summary = await inspector.inspect(prepared);
        await h.seed(
          Reminder(
            id: 'later',
            taskTitle: 'Later',
            quadrantLevel: 2,
            createdAt: DateTime(2030),
          ),
        );
        await DatabaseRecovery(
          h.database,
          inspector: inspector,
          notifications: NotificationService.forTesting(
            FlutterLocalNotificationsPlugin(),
            usesNativeNotifications: false,
          ),
        ).restore(prepared, expectedDigest: summary.digest);
        await h.close();
        await h.open();
        expect((await h.rows()).map((r) => r.id), ['task']);
        expect(h.container.read(settingsProvider).apiKey, isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
