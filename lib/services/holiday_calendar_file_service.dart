import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/holiday_calendar.dart';
import 'backup_file_exporter.dart';

class HolidayCalendarFileService {
  const HolidayCalendarFileService({
    this.pickPath,
    this.temporaryDirectory,
    this.exporter = const BackupFileExporter(),
  });
  final Future<String?> Function()? pickPath;
  final Future<Directory> Function()? temporaryDirectory;
  final BackupFileExporter exporter;
  Future<HolidayCalendar?> pick() async {
    final path = await (pickPath?.call() ?? _pick());
    if (path == null) return null;
    final file = File(path);
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > HolidayCalendar.maxBytes) {
      throw const FormatException('Invalid calendar file');
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > HolidayCalendar.maxBytes) {
        throw const FormatException('Calendar file too large');
      }
      bytes.addAll(chunk);
    }
    return HolidayCalendar.decode(utf8.decode(bytes));
  }

  Future<String?> _pick() async => (await FilePicker.pickFile(
    dialogTitle: 'Calendar',
    type: FileType.custom,
    allowedExtensions: ['json'],
  ))?.path;
  Future<bool> save(HolidayCalendar calendar) async {
    final checked = HolidayCalendar.fromJson(calendar.toJson());
    final temporary =
        await (temporaryDirectory?.call() ?? getTemporaryDirectory());
    final directory = await temporary.createTemp('dontforget-calendar-export-');
    try {
      final file = await File(
        '${directory.path}/calendar.json',
      ).writeAsString(jsonEncode(checked.toJson()), flush: true);
      return await exporter.saveWithExtension(
            file,
            'dontforget-calendar.json',
            extension: 'json',
          ) !=
          null;
    } finally {
      await directory.delete(recursive: true);
    }
  }
}
