import 'dart:io';
import 'package:path/path.dart' as p;

class BackupCacheEntry {
  const BackupCacheEntry(this.path, this.bytes, this.modified);
  final String path;
  final int bytes;
  final DateTime modified;
}

class BackupCacheService {
  const BackupCacheService();
  static final activeDirectories = <String>{};
  Future<List<BackupCacheEntry>> inspect(Directory root) async {
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return [];
    }
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('Unsafe backup cache');
    }
    final result = <BackupCacheEntry>[];
    await for (final directory in root.list(followLinks: false)) {
      if (directory is! Directory ||
          !p.basename(directory.path).startsWith('export-') ||
          activeDirectories.any((d) => p.equals(d, directory.path))) {
        continue;
      }
      final files = await directory.list(followLinks: false).toList();
      if (files.isEmpty ||
          files.length > 2 ||
          files.any(
            (f) =>
                f is! File ||
                !const {
                  'backup.partial',
                  'backup.dfbackup',
                }.contains(p.basename(f.path)),
          )) {
        continue;
      }
      for (final file in files) {
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.file) {
          result.add(BackupCacheEntry(file.path, stat.size, stat.modified));
        }
      }
    }
    return List.unmodifiable(result);
  }

  Future<int> clearSelected(
    Directory root,
    List<BackupCacheEntry> entries, {
    required bool Function() isCurrent,
  }) async {
    final current = await inspect(root);
    final known = {for (final e in current) e.path: e};
    // Validate the whole selection before deleting any file.
    for (final e in entries) {
      final found = known[e.path];
      if (found == null ||
          found.bytes != e.bytes ||
          found.modified != e.modified ||
          !isCurrent()) {
        throw StateError('Backup cache changed');
      }
    }
    var count = 0;
    for (final e in entries) {
      if (!isCurrent()) throw StateError('Backup session changed');
      await File(e.path).delete();
      count++;
      final parent = Directory(p.dirname(e.path));
      if (await parent.exists() && (await parent.list().toList()).isEmpty) {
        await parent.delete();
      }
    }
    return count;
  }

  Future<void> release(File exported) async {
    final directory = Directory(p.dirname(exported.path));
    final matching =
        activeDirectories.where((d) => p.equals(d, directory.path)).toList();
    if (matching.isEmpty) return;
    for (final d in matching) {
      activeDirectories.remove(d);
    }
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final files = await directory.list(followLinks: false).toList();
    if (files.any(
      (f) =>
          f is! File ||
          !const {
            'backup.partial',
            'backup.dfbackup',
          }.contains(p.basename(f.path)),
    )) {
      return;
    }
    for (final f in files) {
      await f.delete();
    }
    await directory.delete();
  }
}
