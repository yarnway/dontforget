// Opt-in device round trip; excluded from the normal test/ discovery.
import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/services/backup_cache_service.dart';
import 'package:dont_forget/services/streaming_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../test/support/offline_management_harness.dart';
import 'support/attachment_round_trip_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const directory = String.fromEnvironment('DF_ATTACHMENT_EXCHANGE');
  for (final encrypted in [false, true]) {
    final format = encrypted ? 'encrypted' : 'plain';
    test('device attachments restore on Windows and return: $format', () async {
      requireFixture(
        Platform.isWindows && directory.isNotEmpty,
        'Explicit Windows exchange directory required',
      );
      final root = Directory(directory),
          source = File(p.join(directory, 'android-$format.dfbackup'));
      final output = File(p.join(directory, 'windows-$format.dfbackup'));
      requireFixture(
        await root.exists() && await source.exists() && !await output.exists(),
        'Missing source or output already exists',
      );
      final harness = OfflineManagementHarness();
      await harness.create();
      try {
        final mediaRoot = Directory(
          p.join(harness.directory.path, 'restored-media'),
        );
        await harness.database.withDeviceWindowPreferences(
          (store) => store.writeCaptureShortcut(true),
        );
        await restoreAttachmentFixture(
          harness.database,
          databaseFactoryFfi,
          source,
          mediaRoot,
          encrypted: encrypted,
          mediaCount: 3,
        );
        await harness.close();
        await harness.open();
        final restored = await verifyAttachmentFixture(
          harness.database,
          desktop: false,
          restoredRoot: mediaRoot,
        );
        expect(
          await harness.database.withDeviceWindowPreferences(
            (store) => store.readCaptureShortcut(),
          ),
          isTrue,
        );
        if (encrypted) {
          final destination = Directory(
            p.join(harness.directory.path, 'wrong-password'),
          );
          await expectLater(
            const StreamingBackupService().prepareRestore(
              source,
              destination,
              expectedDigest: await fixtureHash(source),
              isCurrent: () => true,
              password: 'Wrong synthetic password',
            ),
            throwsA(isA<BackupPasswordException>()),
          );
          expect(
            !await destination.exists() || await destination.list().isEmpty,
            isTrue,
          );
        }
        await seedAttachmentFixture(
          harness.database,
          Directory(p.join(harness.directory.path, 'desktop-original')),
          desktopOnly: true,
        );
        final appended = await verifyAttachmentFixture(
          harness.database,
          desktop: true,
        );
        final exported = await const StreamingBackupService().createFile(
          harness.database,
          harness.database.captureGeneration(),
          Directory(p.join(harness.directory.path, 'export')),
          password: encrypted ? attachmentFixturePassword : null,
        );
        requireFixture(
          exported.mediaCount == 4 && exported.missingMedia.isEmpty,
          'Return export lost attachments',
        );
        await exported.file.copy(output.path);
        await const BackupCacheService().release(exported.file);
        await File('${output.path}.report.json').writeAsString(
          '${jsonEncode({'fixture': attachmentFixtureMarker, 'platform': Platform.operatingSystem, 'format': format, 'source_sha256': await fixtureHash(source), 'return_sha256': await fixtureHash(output), 'restored': restored, 'appended': appended, 'database_close_reopen_passed': true, 'device_preference_preserved': true, 'wrong_password_no_output': encrypted ? true : null, 'desktop_gui_tested': false, 'notification_transport': 'substitute', 'outcome': 'PASS'})}\n',
          flush: true,
        );
      } finally {
        await harness.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 4)));
  }
}
