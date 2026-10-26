import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Owns copies of imported media; source files are never moved or removed.
class LocalMediaStore {
  LocalMediaStore({Future<Directory> Function()? documentsDirectory})
    : _documentsDirectory =
          documentsDirectory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDirectory;
  Future<Directory>? _resolvedDocuments;
  static final _importDirectoryName = RegExp(r'^import-[A-Za-z0-9_-]+$');

  /// iOS may relocate Documents during an application update. Keep persisted
  /// paths intact for older versions, and locate owned imports only on demand.
  Future<String> resolvePath(String storedPath) async {
    // Only the layout created by importFile is eligible for rebasing. Never
    // infer ownership from a basename, URI, relative path or traversal.
    if (!storedPath.startsWith('/') ||
        storedPath.startsWith('//') ||
        storedPath.contains('\\') ||
        storedPath.contains('\u0000')) {
      return storedPath;
    }
    final parts = storedPath.split('/');
    if (parts.length < 6 ||
        parts
            .skip(1)
            .any((part) => part.isEmpty || part == '.' || part == '..') ||
        parts[parts.length - 4] != 'Documents' ||
        parts[parts.length - 3] != 'media' ||
        !_importDirectoryName.hasMatch(parts[parts.length - 2])) {
      return storedPath;
    }
    try {
      if (await FileSystemEntity.type(storedPath, followLinks: false) ==
          FileSystemEntityType.file) {
        return storedPath;
      }
      final documents = await (_resolvedDocuments ??= _documentsDirectory());
      final media = path.join(documents.path, 'media');
      final imported = path.join(media, parts[parts.length - 2]);
      final candidate = path.join(imported, parts.last);
      // Allow platform aliases above Documents, but never follow links inside
      // our media tree to an unrelated file or another import directory.
      for (final directory in [media, imported]) {
        if (await FileSystemEntity.type(directory, followLinks: false) !=
            FileSystemEntityType.directory) {
          return storedPath;
        }
      }
      if (await FileSystemEntity.type(candidate, followLinks: false) ==
          FileSystemEntityType.file) {
        return candidate;
      }
    } catch (_) {
      // A missing directory or unavailable platform channel must not break
      // legacy/external paths. The caller retains its normal unavailable UI.
      _resolvedDocuments = null;
    }
    return storedPath;
  }

  Future<String> importFile(String sourcePath) async {
    final documents = await _documentsDirectory();
    final media = Directory(path.join(documents.path, 'media'));
    await media.create(recursive: true);
    // A unique directory also preserves the original display name/extension.
    // Two imports with the same basename cannot overwrite an older attachment.
    final destination = await media.createTemp('import-');
    try {
      final copied = await File(
        sourcePath,
      ).copy(path.join(destination.path, path.basename(sourcePath)));
      return copied.path;
    } catch (_) {
      try {
        await destination.delete(recursive: true);
      } catch (_) {
        // Preserve the original copy failure if cleanup also fails.
      }
      rethrow;
    }
  }
}
