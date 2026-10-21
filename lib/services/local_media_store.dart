import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Owns copies of imported media; source files are never moved or removed.
class LocalMediaStore {
  LocalMediaStore({Future<Directory> Function()? documentsDirectory})
    : _documentsDirectory =
          documentsDirectory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDirectory;

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
