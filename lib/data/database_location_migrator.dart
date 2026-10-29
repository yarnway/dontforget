import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';

/// Handles detection, migration, and fallback of user databases from legacy
/// application directories (e.g. `com.example\DontForget`) to production directories
/// (`com.yarnway.dontforget\DontForget`).
class DatabaseLocationMigrator {
  static const databaseFileName = 'dont_forget_v3.db';

  /// Operational files that must migrate together to preserve state and leases.
  static const sidecarFiles = [
    'dont_forget_v3.db',
    'dont_forget_v3.db-wal',
    'dont_forget_v3.db-shm',
    'notification-epoch.json',
    'notification-journal.json',
    'notification-journal.log',
  ];

  /// Resolves the database directory to use, performing an atomic one-time migration
  /// from legacy storage locations if [targetDir] does not yet contain a database.
  ///
  /// - If [targetDir] already contains `dont_forget_v3.db`, returns [targetDir] directly.
  /// - If [targetDir] is empty but an older candidate directory has data, copies files
  ///   atomically.
  /// - If migration succeeds, returns [targetDir].
  /// - If migration fails (e.g. target disk error), safely falls back to the legacy
  ///   directory without data loss.
  static Future<String> resolveAndMigrate({
    required String targetDir,
    List<String>? candidateLegacyDirs,
  }) async {
    final targetDbFile = File(join(targetDir, databaseFileName));
    // 1. If target database already exists, no migration needed
    if (targetDbFile.existsSync()) {
      return targetDir;
    }

    // 2. Discover legacy candidates if not explicitly provided
    final candidates = candidateLegacyDirs ?? getLegacyCandidates();

    for (final legacyDir in candidates) {
      final legacyDbFile = File(join(legacyDir, databaseFileName));
      if (!legacyDbFile.existsSync()) continue;

      debugPrint('Found legacy database at $legacyDir. Initiating migration to $targetDir...');
      final success = await migrateDirectory(
        sourceDir: legacyDir,
        destinationDir: targetDir,
      );

      if (success) {
        debugPrint('Database migration succeeded: $legacyDir -> $targetDir');
        return targetDir;
      } else {
        debugPrint('Database migration failed or was partial. Falling back to legacy directory: $legacyDir');
        return legacyDir;
      }
    }

    // No legacy database found, use target directory
    return targetDir;
  }

  /// Returns candidate legacy database directories on Windows in priority order.
  static List<String> getLegacyCandidates() {
    if (!Platform.isWindows) return const [];
    final appData = Platform.environment['APPDATA'];
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final candidates = <String>[];

    if (appData != null && appData.isNotEmpty) {
      candidates.add(join(appData, 'com.example', 'DontForget', 'databases'));
      candidates.add(join(appData, 'com.example', 'dont_forget', 'databases'));
    }
    if (localAppData != null && localAppData.isNotEmpty) {
      candidates.add(join(localAppData, 'DontForget', 'databases'));
    }
    return candidates;
  }

  /// Copies database and sidecar files from [sourceDir] to [destinationDir] atomically.
  ///
  /// Retains the original legacy directory intact for safety and rollback.
  /// Returns `true` if migration succeeded, `false` otherwise.
  static Future<bool> migrateDirectory({
    required String sourceDir,
    required String destinationDir,
  }) async {
    try {
      final destDir = Directory(destinationDir);
      if (!destDir.existsSync()) {
        destDir.createSync(recursive: true);
      }

      final copiedFiles = <File>[];

      for (final fileName in sidecarFiles) {
        final src = File(join(sourceDir, fileName));
        if (!src.existsSync()) continue;

        final dstTmp = File(join(destinationDir, '$fileName.tmp'));
        final dstFinal = File(join(destinationDir, fileName));

        // Copy to temporary file first
        src.copySync(dstTmp.path);
        // Rename temporary to final
        if (dstFinal.existsSync()) {
          dstFinal.deleteSync();
        }
        dstTmp.renameSync(dstFinal.path);
        copiedFiles.add(dstFinal);
      }

      // Verify destination database file integrity
      final destDb = File(join(destinationDir, databaseFileName));
      final srcDb = File(join(sourceDir, databaseFileName));
      if (!destDb.existsSync() || destDb.lengthSync() != srcDb.lengthSync()) {
        throw StateError('Migrated database size mismatch or missing target file');
      }

      // Record migration receipt
      final receipt = File(join(destinationDir, 'migration.log'));
      receipt.writeAsStringSync(
        'Migration completed from $sourceDir to $destinationDir at ${DateTime.now().toUtc().toIso8601String()}\n'
        'Files: ${copiedFiles.map((f) => basename(f.path)).join(', ')}\n',
      );

      return true;
    } catch (e, stack) {
      debugPrint('Error during database migration: $e\n$stack');
      // Clean up any lingering .tmp files in destination
      try {
        final destDir = Directory(destinationDir);
        if (destDir.existsSync()) {
          for (final entity in destDir.listSync()) {
            if (entity is File && entity.path.endsWith('.tmp')) {
              entity.deleteSync();
            }
          }
        }
      } catch (_) {}
      return false;
    }
  }
}
