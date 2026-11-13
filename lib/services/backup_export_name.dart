import 'dart:convert';
import 'package:path/path.dart' as p;

/// One portable file name, never a path or a native device name.
class BackupExportName {
  static const extension = '.dfbackup';
  static const maxCharacters = 80;
  // Leave room for the directory exporter's UUID suffix on byte-limited FSs.
  static const maxUtf8Bytes = 200;

  static String resolve(String input, {DateTime? at}) {
    var stem = input.trim();
    if (stem.isEmpty) {
      final time = (at ?? DateTime.now()).toLocal();
      String pad(int value, [int length = 2]) => '$value'.padLeft(length, '0');
      stem =
          'dontforget-${pad(time.year, 4)}-${pad(time.month)}-${pad(time.day)}-'
          '${pad(time.hour)}${pad(time.minute)}${pad(time.second)}${pad(time.millisecond, 3)}';
    } else if (stem.toLowerCase().endsWith(extension)) {
      stem = stem.substring(0, stem.length - extension.length);
    }
    if (stem.runes.length > maxCharacters ||
        utf8.encode(stem).length > maxUtf8Bytes) {
      throw const FormatException('name_too_long');
    }
    if (stem.isEmpty ||
        stem.startsWith('.') ||
        stem.endsWith('.') ||
        stem.endsWith(' ') ||
        stem.toLowerCase().endsWith(extension) ||
        RegExp(r'[\x00-\x1f\x7f-\x9f<>:"/\\|?*\u2028\u2029]').hasMatch(stem)) {
      throw const FormatException('invalid_name');
    }
    final device = stem.split('.').first.trimRight();
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$',
      caseSensitive: false,
    ).hasMatch(device)) {
      throw const FormatException('invalid_name');
    }
    return '$stem$extension';
  }

  static String? fromLocation(String location) {
    if (location.length > 8192) {
      return null;
    }
    final windows =
        RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(location) ||
        location.startsWith(r'\\');
    final uri = Uri.tryParse(location);
    // A document provider's opaque identifier is not a display name.
    if (!windows && uri != null && uri.hasScheme && uri.scheme != 'file') {
      return null;
    }
    final name = windows
        ? p.windows.basename(location)
        : uri?.scheme == 'file'
        ? uri!.pathSegments.lastOrNull
        : p.posix.basename(location);
    if (name == null || !name.toLowerCase().endsWith(extension)) return null;
    return display(name);
  }

  static String? display(Object? value) {
    if (value is! String ||
        value.length > maxCharacters * 2 + extension.length ||
        value.trim().isEmpty) {
      return null;
    }
    try {
      return resolve(value);
    } on FormatException {
      return null;
    }
  }
}
