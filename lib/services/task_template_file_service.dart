import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/task_template.dart';
import '../models/task_template_transfer.dart';
import 'backup_file_exporter.dart';

class TaskTemplateFileService {
  const TaskTemplateFileService({
    this.pickPath,
    this.temporaryDirectory,
    this.exporter = const BackupFileExporter(),
  });
  final Future<String?> Function()? pickPath;
  final Future<Directory> Function()? temporaryDirectory;
  final BackupFileExporter exporter;
  Future<List<TaskTemplate>?> pick() async {
    final path = await (pickPath?.call() ?? _pick());
    if (path == null) return null;
    final file = File(path);
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > TaskTemplateTransfer.maxBytes) {
      throw const FormatException('Invalid template file');
    }
    final chunks = <int>[];
    await for (final chunk in file.openRead()) {
      if (chunks.length + chunk.length > TaskTemplateTransfer.maxBytes) {
        throw const FormatException('Template file too large');
      }
      chunks.addAll(chunk);
    }
    return TaskTemplateTransfer.decode(utf8.decode(chunks));
  }

  Future<String?> _pick() async => (await FilePicker.pickFile(
    dialogTitle: 'Templates',
    type: FileType.custom,
    allowedExtensions: ['json'],
  ))?.path;
  Future<bool> save(List<TaskTemplate> items) async {
    final data = TaskTemplateTransfer.encode(items);
    final root = await (temporaryDirectory?.call() ?? getTemporaryDirectory());
    final directory = await root.createTemp('dontforget-template-export-');
    try {
      final file = await File(
        p.join(directory.path, 'templates.json'),
      ).writeAsString(data, flush: true);
      return await exporter.saveWithExtension(
            file,
            'dontforget-templates.json',
            extension: 'json',
          ) !=
          null;
    } finally {
      await directory.delete(recursive: true);
    }
  }
}
