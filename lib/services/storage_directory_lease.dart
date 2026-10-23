import 'dart:io';

/// Cooperative process ownership shared by SQL and local notification stores.
/// Never unlink the lock file: a replacement inode would bypass live locks.
/// POSIX locks are process-scoped, so reject another owner in this isolate before
/// opening any second handle (closing it could release the first owner's lock).
/// As with DatabaseHelper, callers must route storage work to one owner isolate.
class StorageDirectoryLease {
  StorageDirectoryLease._(this.directory, this._handle);
  static final _owners = <String, Object>{};
  static const lockName = '.dontforget.owner.lock';
  final Directory directory;
  RandomAccessFile? _handle;
  Future<void>? _closing;

  static Future<StorageDirectoryLease> acquire(Directory directory) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await directory.resolveSymbolicLinks() != directory.path) {
      throw const FileSystemException(
        'A canonical storage directory is required',
      );
    }
    final token = Object();
    if (_owners.containsKey(directory.path)) {
      throw const FileSystemException('Storage directory is already owned');
    }
    _owners[directory.path] = token;
    RandomAccessFile? handle;
    try {
      final file = File('${directory.path}/$lockName');
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw const FileSystemException('Unsafe storage lock');
      }
      handle = await file.open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive);
      final lease = StorageDirectoryLease._(directory, handle);
      _owners[directory.path] = lease;
      return lease;
    } catch (_) {
      await handle?.close();
      if (identical(_owners[directory.path], token)) {
        _owners.remove(directory.path);
      }
      rethrow;
    }
  }

  void checkHeld() {
    if (_handle == null ||
        _closing != null ||
        !identical(_owners[directory.path], this)) {
      throw StateError('Storage lease is no longer active');
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    final handle = _handle;
    if (handle == null) return;
    await handle.close();
    _handle = null;
    if (identical(_owners[directory.path], this)) {
      _owners.remove(directory.path);
    }
  }
}
