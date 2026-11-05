import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'storage_directory_lease.dart';

/// Local geometry only. The owning helper serializes all access through [run]
/// while holding the directory lease. Business recovery never replaces this
/// file, and business backups never include it.
final class DeviceWindowPreferencesStore {
  DeviceWindowPreferencesStore(this._lease);

  static const fileName = 'device-window-preferences.json';
  static const maxFileBytes = 4096;
  static const shortcutFileName = 'device-capture-shortcut.json';
  final StorageDirectoryLease _lease;
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function(DeviceWindowPreferencesStore) operation) {
    final result = _tail.then((_) {
      _lease.checkHeld();
      return operation(this);
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  File get _file => File(p.join(_lease.directory.path, fileName));

  Future<bool> readCaptureShortcut() async {
    _lease.checkHeld();
    final file = File(p.join(_lease.directory.path, shortcutFileName));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file ||
        await file.length() > maxFileBytes) {
      throw const FileSystemException('Unsafe capture shortcut preferences');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map ||
        value['version'] != 1 ||
        value['version'] is! int ||
        value.length != 2 ||
        value['enabled'] is! bool) {
      throw const FormatException('Unsupported capture shortcut preferences');
    }
    return value['enabled'] as bool;
  }

  Future<void> writeCaptureShortcut(bool enabled) async {
    // Do not overwrite corrupt or future files, or touch window geometry.
    await readCaptureShortcut();
    final file = File(p.join(_lease.directory.path, shortcutFileName));
    final temporary = File('${file.path}.${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'enabled': enabled}),
        flush: true,
      );
      _lease.checkHeld();
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<Map<String, dynamic>?> _readDocument() async {
    _lease.checkHeld();
    final type = await FileSystemEntity.type(_file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('Unsafe window preferences file');
    }
    if (await _file.length() > maxFileBytes) {
      throw const FileSystemException('Window preferences too large');
    }
    final decoded = jsonDecode(await _file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid window preferences');
    }
    return decoded;
  }

  void _checkVersion(Map<String, dynamic> document) {
    final version = document['version'];
    if (version is int && version > 1) {
      // Downgrading must not overwrite a newer app's local format.
      throw UnsupportedError('Newer window preferences version');
    }
    if (version != 1 || version is! int) {
      throw const FormatException('Invalid window preferences version');
    }
  }

  Future<Map<String, dynamic>?> read() async {
    final document = await _readDocument();
    if (document == null) return null;
    _checkVersion(document);
    final preferences = document['preferences'];
    if (preferences is! Map<String, dynamic>) {
      throw const FormatException('Invalid window geometry');
    }
    return preferences;
  }

  Future<void> write(Map<String, dynamic> preferences) async {
    // Refuse unknown future formats and unsafe paths. Malformed regular files
    // may be replaced by the next real window event after default fallback.
    try {
      final document = await _readDocument();
      if (document != null) _checkVersion(document);
    } on FormatException {
      // No business draft is read or modified during corruption repair.
    }
    final encoded = jsonEncode({'version': 1, 'preferences': preferences});
    if (utf8.encode(encoded).length > maxFileBytes) {
      throw const FormatException('Window preferences too large');
    }
    final temporary = File('${_file.path}.${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsString(encoded, flush: true);
      _lease.checkHeld();
      // Atomic replacement retains the previous target if rename fails.
      // Never delete the target as a Windows replacement workaround.
      await temporary.rename(_file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
