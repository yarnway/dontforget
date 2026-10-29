import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:dont_forget/data/database_location_migrator.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dontforget_migrator_test_');
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('DatabaseLocationMigrator', () {
    test('scenario 1: legacy does not exist -> returns target directory', () async {
      final targetDir = Directory(join(tempDir.path, 'new_app_data', 'databases'))..createSync(recursive: true);
      final legacyDir = Directory(join(tempDir.path, 'legacy_app_data', 'databases'));

      final result = await DatabaseLocationMigrator.resolveAndMigrate(
        targetDir: targetDir.path,
        candidateLegacyDirs: [legacyDir.path],
      );

      expect(result, targetDir.path);
      expect(File(join(targetDir.path, DatabaseLocationMigrator.databaseFileName)).existsSync(), isFalse);
      expect(File(join(targetDir.path, 'migration.log')).existsSync(), isFalse);
    });

    test('scenario 2: legacy exists and target is empty -> migrates atomically and returns target', () async {
      final targetDir = Directory(join(tempDir.path, 'new_app_data', 'databases'))..createSync(recursive: true);
      final legacyDir = Directory(join(tempDir.path, 'legacy_app_data', 'databases'))..createSync(recursive: true);

      // Populate legacy directory with database and sidecar files
      final legacyDb = File(join(legacyDir.path, DatabaseLocationMigrator.databaseFileName))
        ..writeAsStringSync('SQLITE-DATA-LEGACY-V3');
      final legacyEpoch = File(join(legacyDir.path, 'notification-epoch.json'))
        ..writeAsStringSync('{"epoch": "epoch-123"}');
      final legacyJournal = File(join(legacyDir.path, 'notification-journal.json'))
        ..writeAsStringSync('{"journal": []}');

      final result = await DatabaseLocationMigrator.resolveAndMigrate(
        targetDir: targetDir.path,
        candidateLegacyDirs: [legacyDir.path],
      );

      expect(result, targetDir.path);

      // Verify target directory has all migrated files
      final targetDb = File(join(targetDir.path, DatabaseLocationMigrator.databaseFileName));
      final targetEpoch = File(join(targetDir.path, 'notification-epoch.json'));
      final targetJournal = File(join(targetDir.path, 'notification-journal.json'));
      final targetReceipt = File(join(targetDir.path, 'migration.log'));

      expect(targetDb.existsSync(), isTrue);
      expect(targetDb.readAsStringSync(), 'SQLITE-DATA-LEGACY-V3');
      expect(targetEpoch.existsSync(), isTrue);
      expect(targetEpoch.readAsStringSync(), '{"epoch": "epoch-123"}');
      expect(targetJournal.existsSync(), isTrue);
      expect(targetJournal.readAsStringSync(), '{"journal": []}');
      expect(targetReceipt.existsSync(), isTrue);

      // Verify legacy files remain intact (no deletion of original data)
      expect(legacyDb.existsSync(), isTrue);
      expect(legacyDb.readAsStringSync(), 'SQLITE-DATA-LEGACY-V3');
      expect(legacyEpoch.existsSync(), isTrue);
      expect(legacyJournal.existsSync(), isTrue);
    });

    test('scenario 3: both target and legacy exist -> target wins (new data preferred)', () async {
      final targetDir = Directory(join(tempDir.path, 'new_app_data', 'databases'))..createSync(recursive: true);
      final legacyDir = Directory(join(tempDir.path, 'legacy_app_data', 'databases'))..createSync(recursive: true);

      final targetDb = File(join(targetDir.path, DatabaseLocationMigrator.databaseFileName))
        ..writeAsStringSync('NEWER-DATA-ALREADY-EXISTS');
      final legacyDb = File(join(legacyDir.path, DatabaseLocationMigrator.databaseFileName))
        ..writeAsStringSync('OLDER-LEGACY-DATA');

      final result = await DatabaseLocationMigrator.resolveAndMigrate(
        targetDir: targetDir.path,
        candidateLegacyDirs: [legacyDir.path],
      );

      expect(result, targetDir.path);
      expect(targetDb.readAsStringSync(), 'NEWER-DATA-ALREADY-EXISTS');
      expect(legacyDb.readAsStringSync(), 'OLDER-LEGACY-DATA');
      expect(File(join(targetDir.path, 'migration.log')).existsSync(), isFalse);
    });

    test('scenario 4: interrupted migration with leftover .tmp files cleans up and succeeds', () async {
      final targetDir = Directory(join(tempDir.path, 'new_app_data', 'databases'))..createSync(recursive: true);
      final legacyDir = Directory(join(tempDir.path, 'legacy_app_data', 'databases'))..createSync(recursive: true);

      // Leftover .tmp file in target directory from a previously interrupted attempt
      File(join(targetDir.path, 'dont_forget_v3.db.tmp')).writeAsStringSync('half-written');

      File(join(legacyDir.path, DatabaseLocationMigrator.databaseFileName))
        .writeAsStringSync('COMPLETE-LEGACY-DATA');

      final result = await DatabaseLocationMigrator.resolveAndMigrate(
        targetDir: targetDir.path,
        candidateLegacyDirs: [legacyDir.path],
      );

      expect(result, targetDir.path);
      final targetDb = File(join(targetDir.path, DatabaseLocationMigrator.databaseFileName));
      expect(targetDb.existsSync(), isTrue);
      expect(targetDb.readAsStringSync(), 'COMPLETE-LEGACY-DATA');
      expect(File(join(targetDir.path, 'dont_forget_v3.db.tmp')).existsSync(), isFalse);
    });

    test('scenario 5: failure during migration falls back to legacy directory without data loss', () async {
      // Use a target file instead of directory to simulate uncreatable target directory
      final fakeTargetFile = File(join(tempDir.path, 'not_a_directory'))..writeAsStringSync('blocker');
      final targetDir = join(fakeTargetFile.path, 'databases'); // Trying to create subdirectories inside a file fails

      final legacyDir = Directory(join(tempDir.path, 'legacy_app_data', 'databases'))..createSync(recursive: true);
      final legacyDb = File(join(legacyDir.path, DatabaseLocationMigrator.databaseFileName))
        ..writeAsStringSync('SAFE-LEGACY-DATA');

      final result = await DatabaseLocationMigrator.resolveAndMigrate(
        targetDir: targetDir,
        candidateLegacyDirs: [legacyDir.path],
      );

      // Must safely fall back to legacy directory so user data is retained!
      expect(result, legacyDir.path);
      expect(legacyDb.existsSync(), isTrue);
      expect(legacyDb.readAsStringSync(), 'SAFE-LEGACY-DATA');
    });

    test('getLegacyCandidates returns populated list on Windows', () {
      final candidates = DatabaseLocationMigrator.getLegacyCandidates();
      if (Platform.isWindows) {
        expect(candidates, isNotEmpty);
        expect(candidates.any((c) => c.contains('com.example')), isTrue);
      } else {
        expect(candidates, isEmpty);
      }
    });
  });
}
