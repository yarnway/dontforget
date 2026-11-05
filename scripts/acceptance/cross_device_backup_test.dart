// Explicit acceptance against a supplied, synthetic device export, outside test/.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dont_forget/models/reminder.dart';
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
  const sourcePath = String.fromEnvironment('DF_DEVICE_BACKUP');
  const outputPath = String.fromEnvironment('DF_DEVICE_RETURN');
  // Public fixture password. Never use this acceptance with personal exports.
  const password = 'Stage61Backup-2026';
  test(
    'synthetic Android export restores and reopens on desktop before return export',
    () async {
      expect(sourcePath, isNotEmpty);
      expect(outputPath, isNotEmpty);
      final source = File(sourcePath);
      final output = File(outputPath);
      expect(
        await output.exists(),
        isFalse,
        reason: 'Never overwrite an existing export',
      );
      const service = StreamingBackupService();
      final h = OfflineManagementHarness();
      await h.create();
      try {
        final preview = await service.inspect(source, password: password);
        expect(preview.encrypted, isTrue);
        expect(preview.mediaCount, 0);
        final snapshot = await service.prepareRestore(
          source,
          Directory('${h.directory.path}/restored'),
          password: password,
          expectedDigest: preview.digest,
          isCurrent: () => true,
        );
        final data = jsonDecode(await snapshot.readAsString()) as Map;
        final original = data['reminders'] as List;
        expect(original, hasLength(1));
        expect(original.single['task_title'], '测试');
        await h.database.withDeviceWindowPreferences(
          (store) => store.writeCaptureShortcut(true),
        );
        final inspector = BackupInspector(databaseFactoryFfi);
        final inspected = await inspector.inspect(snapshot);
        await DatabaseRecovery(
          h.database,
          inspector: inspector,
          // ignore: invalid_use_of_visible_for_testing_member
          notifications: NotificationService.forTesting(
            FlutterLocalNotificationsPlugin(),
            usesNativeNotifications: false,
          ),
        ).restore(snapshot, expectedDigest: inspected.digest);
        await h.close();
        await h.open();
        expect((await h.rows()).single.toJson(), original.single);
        expect(
          await h.database.withDeviceWindowPreferences(
            (store) => store.readCaptureShortcut(),
          ),
          isTrue,
        );
        await h.seed(
          Reminder(
            id: 'stage61-desktop-return',
            taskTitle: 'CrossDeviceStage61',
            quadrantLevel: 3,
            createdAt: DateTime.utc(2026, 11, 6),
          ),
        );
        final returned = await service.createFile(
          h.database,
          h.database.captureGeneration(),
          Directory('${h.directory.path}/export'),
          password: password,
        );
        await output.parent.create(recursive: true);
        await returned.file.copy(output.path);
        final report = {
          'format': 1,
          'scope':
              'synthetic-android-export-desktop-backend-restore-reopen-return',
          'platform': Platform.operatingSystem,
          'source_sha256': (await sha256.bind(source.openRead()).first)
              .toString(),
          'source_reminders': 1,
          'source_media': 0,
          'restored_row_all_fields_equal': true,
          'device_shortcut_preserved': true,
          'return_reminders': 2,
          'return_sha256': (await sha256.bind(output.openRead()).first)
              .toString(),
          'desktop_gui_tested': false,
          'android_return_import_tested': false,
          'outcome': 'PASS',
        };
        await File(
          '$outputPath.report.json',
        ).writeAsString('${jsonEncode(report)}\n');
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
