import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/notification_payload.dart';

/// Local notification identity, deliberately outside business backup data.
/// The caller must own the database directory's process lock for every call.
/// A shared instance serializes callers, including reads racing with rotation.
final class NotificationEpochStore {
  NotificationEpochStore(Directory directory, {String Function()? newEpoch})
    : directory = Directory(p.normalize(p.absolute(directory.path))),
      _newEpoch = newEpoch ?? const Uuid().v4;

  static const fileName = 'notification-epoch.json';
  static const _maxFileBytes = 256;
  final Directory directory;
  final String Function() _newEpoch;
  Future<void> _tail = Future<void>.value();
  Future<String>? _pendingRead;

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<String> readOrCreate() {
    // Share only an in-flight read. A later call still revalidates the actual
    // file; rotations are ordering barriers, not a long-lived epoch cache.
    if (_pendingRead != null) return _pendingRead!;
    late final Future<String> pending;
    pending =
        _serialize(() async {
          await _requireDirectory();
          final existing = await _readExisting();
          if (existing != null) return existing;
          return _writeNew(previous: null);
        }).whenComplete(() {
          if (identical(_pendingRead, pending)) _pendingRead = null;
        });
    return _pendingRead = pending;
  }

  Future<String> rotate() {
    _pendingRead = null;
    return _serialize(() async {
      await _requireDirectory();
      final existing = await _readExisting();
      return _writeNew(previous: existing);
    });
  }

  File get _file => File(p.join(directory.path, fileName));

  Future<void> _requireDirectory() async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await directory.resolveSymbolicLinks() != directory.path) {
      throw const FormatException('Notification epoch directory is unsafe.');
    }
  }

  Future<String?> _readExisting() async {
    final file = _file;
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file ||
        await file.length() > _maxFileBytes) {
      throw const FormatException('Invalid notification epoch file.');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        decoded.length != 2 ||
        decoded['version'] is! int ||
        decoded['version'] != 1 ||
        decoded['epoch'] is! String ||
        !NotificationPayload.isValidDatasetEpoch(decoded['epoch'] as String)) {
      throw const FormatException('Invalid notification epoch identity.');
    }
    return decoded['epoch'] as String;
  }

  Future<String> _writeNew({required String? previous}) async {
    final next = _newEpoch();
    if (!NotificationPayload.isValidDatasetEpoch(next) || next == previous) {
      throw const FormatException('Invalid new notification epoch.');
    }
    final temporary = File('${_file.path}.${const Uuid().v4()}.tmp');
    if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FormatException('Notification epoch staging file exists.');
    }
    await temporary.writeAsString(
      jsonEncode({'version': 1, 'epoch': next}),
      flush: true,
    );
    // Preserve the last valid identity on any failure. Never remove the target
    // to make a replacement succeed; an incomplete staging file is harmless.
    await _requireDirectory();
    if (await _readExisting() != previous) {
      throw StateError('Notification epoch changed outside its owner.');
    }
    await temporary.rename(_file.path);
    return next;
  }
}
