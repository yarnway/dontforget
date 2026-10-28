import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../models/notification_payload.dart';

/// A native response contains no task data and can be persisted without opening
/// the database. The main isolate must validate [payload] again before acting.
final class NotificationActionRequest {
  NotificationActionRequest({
    required this.payload,
    required this.actionId,
    required this.occurredAt,
  }) {
    if (!isSupported(actionId)) {
      throw ArgumentError.value(actionId, 'actionId');
    }
  }

  static const _fields = {'version', 'payload', 'actionId', 'occurredAt'};
  static const maxEncodedLength = NotificationPayload.maxEncodedLength + 512;
  final NotificationPayload payload;
  final String actionId;
  final DateTime occurredAt;

  static bool isSupported(String actionId) => const {
    'complete',
    'snooze_15',
    'snooze_60',
    'skip_occurrence',
  }.contains(actionId);

  String get identity => jsonEncode([payload.identity, actionId]);

  Map<String, Object> toJson() => {
    'version': 1,
    'payload': payload.encode(),
    'actionId': actionId,
    'occurredAt': occurredAt.toUtc().microsecondsSinceEpoch,
  };

  String encode() => jsonEncode(toJson());

  static NotificationActionRequest? tryParse(String? encoded) {
    if (encoded == null || encoded.length > maxEncodedLength) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map ||
          value.length != _fields.length ||
          value.keys.any((key) => !_fields.contains(key)) ||
          value['version'] != 1 ||
          value['version'] is! int ||
          value['payload'] is! String ||
          value['actionId'] is! String ||
          !isSupported(value['actionId'] as String) ||
          value['occurredAt'] is! int) {
        return null;
      }
      final payload = NotificationPayload.tryParse(value['payload'] as String);
      if (payload == null) return null;
      return NotificationActionRequest(
        payload: payload,
        actionId: value['actionId'] as String,
        occurredAt: DateTime.fromMicrosecondsSinceEpoch(
          value['occurredAt'] as int,
          isUtc: true,
        ),
      );
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}

/// The native background callback's only persistence. Each update holds a
/// separate lock and replaces the bounded queue atomically. A consumer removes
/// one item after handling it, so a process exit cannot lose the whole batch.
final class PendingNotificationActions {
  PendingNotificationActions.forDirectory(this.directory);

  static const maxEntries = 32;
  static const maxFileBytes = 128 * 1024;
  static const fileName = 'pending-notification-actions.json';
  static const _lockName = '.pending-notification-actions.lock';
  static final _tails = <String, Future<void>>{};
  final Directory directory;

  static Future<PendingNotificationActions> open() async =>
      PendingNotificationActions.forDirectory(
        await getApplicationSupportDirectory(),
      );

  Future<void> enqueue(NotificationActionRequest request) =>
      _withLock((file) async {
        final actions = await _read(file);
        if (actions.any((item) => item.identity == request.identity)) return;
        actions.add(request);
        while (actions.length > maxEntries) {
          actions.removeAt(0);
        }
        await _write(file, actions);
      });

  Future<List<NotificationActionRequest>> read() => _withLock(_read);

  Future<void> remove(String identity) => _withLock((file) async {
    final actions = await _read(file);
    final length = actions.length;
    actions.removeWhere((item) => item.identity == identity);
    if (actions.length != length) await _write(file, actions);
  });

  Future<T> _withLock<T>(Future<T> Function(File) operation) async {
    await directory.create(recursive: true);
    final canonical = await directory.resolveSymbolicLinks();
    final previous = _tails[canonical] ?? Future<void>.value();
    final done = Completer<void>();
    final tail = done.future;
    _tails[canonical] = tail;
    await previous;
    try {
      final lockFile = File('$canonical/$_lockName');
      await _requireRegularFile(lockFile);
      // POSIX RandomAccessFile locks belong to a process, so two isolates can
      // both acquire them. flock belongs to the open file description instead.
      // Windows Dart locks already belong to the individual handle.
      if (!Platform.isWindows) {
        final descriptor = await _UnixQueueLock.acquire(lockFile.path);
        try {
          return await operation(File('$canonical/$fileName'));
        } finally {
          _UnixQueueLock.release(descriptor);
        }
      }
      final handle = await lockFile.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.blockingExclusive);
        return await operation(File('$canonical/$fileName'));
      } finally {
        await handle.close();
      }
    } finally {
      done.complete();
      if (identical(_tails[canonical], tail)) _tails.remove(canonical);
    }
  }

  static Future<void> _requireRegularFile(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FileSystemException('Unsafe notification action queue');
    }
  }

  Future<List<NotificationActionRequest>> _read(File file) async {
    await _requireRegularFile(file);
    if (!await file.exists()) return [];
    if (await file.length() > maxFileBytes) {
      await _write(file, []);
      return [];
    }
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map ||
          value.length != 2 ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['actions'] is! List ||
          (value['actions'] as List).length > maxEntries) {
        await _write(file, []);
        return [];
      }
      final actions = <NotificationActionRequest>[];
      final identities = <String>{};
      var invalid = false;
      for (final item in value['actions'] as List) {
        final request = NotificationActionRequest.tryParse(jsonEncode(item));
        if (request == null || !identities.add(request.identity)) {
          invalid = true;
        } else {
          actions.add(request);
        }
      }
      if (invalid) await _write(file, actions);
      return actions;
    } on FormatException {
      await _write(file, []);
      return [];
    }
  }

  Future<void> _write(
    File file,
    List<NotificationActionRequest> actions,
  ) async {
    final bytes = utf8.encode(
      jsonEncode({
        'version': 1,
        'actions': [for (final action in actions) action.toJson()],
      }),
    );
    if (bytes.length > maxFileBytes) {
      throw StateError('Notification action queue limit exceeded');
    }
    final nonce = Random.secure().nextInt(1 << 32);
    final temporary = File('${file.path}.$pid.$nonce.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (!Platform.isWindows) _UnixQueueLock.restrict(temporary.path);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

/// No database or platform plugin is needed by a background isolate. libc is
/// already present on Android, iOS, macOS and Linux; no extra FFI dependency or
/// native connection is created. Nonblocking attempts keep the isolate free.
final class _UnixQueueLock {
  static final _library = DynamicLibrary.process();
  static final _malloc = _library
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('malloc');
  static final _free = _library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');
  static final _open = _library
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Int32, VarArgs<(Int32,)>),
        int Function(Pointer<Uint8>, int, int)
      >('open');
  static final _close = _library
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _flock = _library
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
      );
  static final _chmod = _library
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Uint32),
        int Function(Pointer<Uint8>, int)
      >('chmod');

  static T _withPath<T>(String path, T Function(Pointer<Uint8>) action) {
    final bytes = utf8.encode(path);
    final pointer = _malloc(bytes.length + 1).cast<Uint8>();
    if (pointer.address == 0) {
      throw const FileSystemException('Notification queue lock unavailable');
    }
    try {
      pointer.asTypedList(bytes.length + 1)
        ..setRange(0, bytes.length, bytes)
        ..[bytes.length] = 0;
      return action(pointer);
    } finally {
      _free(pointer.cast());
    }
  }

  static Future<int> acquire(String path) async {
    final create = Platform.isMacOS || Platform.isIOS ? 0x200 : 0x40;
    final descriptor = _withPath(
      path,
      (pointer) => _open(pointer, 2 | create, 0x180),
    );
    if (descriptor < 0) {
      throw const FileSystemException('Notification queue lock unavailable');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    try {
      while (_flock(descriptor, 2 | 4) != 0) {
        if (!DateTime.now().isBefore(deadline)) {
          throw const FileSystemException('Notification queue is busy');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return descriptor;
    } catch (_) {
      _close(descriptor);
      rethrow;
    }
  }

  static void release(int descriptor) => _close(descriptor);

  static void restrict(String path) {
    if (_withPath(path, (pointer) => _chmod(pointer, 0x180)) != 0) {
      throw const FileSystemException(
        'Notification queue permissions unavailable',
      );
    }
  }
}
