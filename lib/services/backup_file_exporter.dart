import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class BackupFileExporter {
  const BackupFileExporter({this.useDirectoryPicker, this.pickDirectory});
  final bool? useDirectoryPicker;
  final Future<String?> Function()? pickDirectory;
  Future<String?> save(File source, String filename) =>
      saveWithExtension(source, filename, extension: 'dfbackup');
  Future<String?> saveWithExtension(
    File source,
    String filename, {
    required String extension,
  }) async {
    if (!RegExp(r'^[a-z0-9]{1,16}$').hasMatch(extension)) {
      throw const FormatException('Invalid export extension');
    }
    if (useDirectoryPicker ?? Platform.isLinux) {
      final directory =
          await (pickDirectory?.call() ??
              FilePicker.getDirectoryPath(dialogTitle: filename));
      if (directory == null) return null;
      final destination = File(
        p.join(
          directory,
          '${p.basenameWithoutExtension(filename)}-${const Uuid().v4()}.$extension',
        ),
      );
      if (await destination.exists()) {
        throw const FileSystemException('Destination already exists');
      }
      final partial = File('${destination.path}.partial');
      try {
        await source.copy(partial.path);
        if (await partial.length() != await source.length() ||
            await destination.exists()) {
          throw const FileSystemException('Incomplete backup export');
        }
        await partial.rename(destination.path);
      } catch (_) {
        if (await partial.exists()) await partial.delete();
        rethrow;
      }
      return destination.path;
    }
    // FileSaver receives a file path, never attachment bytes. Native document
    // exporters perform the final copy without a multi-GiB method-channel blob.
    return FileSaver.instance.saveAs(
      name: p.basenameWithoutExtension(filename),
      filePath: source.path,
      fileExtension: extension,
      mimeType: MimeType.other,
    );
  }
}
