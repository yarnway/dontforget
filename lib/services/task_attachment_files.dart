import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../models/media_record.dart';
import 'local_media_store.dart';

/// Copies user-selected files; originals and shared media are never removed.
class TaskAttachmentFiles {
  TaskAttachmentFiles({LocalMediaStore? store})
    : _store = store ?? LocalMediaStore();

  static const maxBytes = 32 * 1024 * 1024;
  final LocalMediaStore _store;
  final _uncommitted = <String>{};

  Future<MediaRecord> import(String source) async {
    final size = await File(source).length();
    if (size > maxBytes) throw const AttachmentTooLarge();
    final copied = await _store.importFile(source);
    _uncommitted.add(copied);
    try {
      // A selected file may have changed while the copy was in flight.
      if (await File(copied).length() > maxBytes) {
        throw const AttachmentTooLarge();
      }
      final image = const {
        '.png',
        '.jpg',
        '.jpeg',
        '.gif',
        '.webp',
        '.bmp',
        '.heic',
        '.heif',
      }.contains(path.extension(source).toLowerCase());
      return MediaRecord(
        id: const Uuid().v4(),
        type: image ? 'image' : 'file',
        contentOrPath: copied,
        createdAt: DateTime.now(),
      );
    } catch (_) {
      await _discard(copied);
      rethrow;
    }
  }

  void committed(MediaRecord record) =>
      _uncommitted.remove(record.contentOrPath);

  Future<void> discard(MediaRecord record) => _discard(record.contentOrPath);

  Future<void> _discard(String copied) async {
    if (!_uncommitted.remove(copied)) return;
    // Only the fresh, uniquely named import returned to this instance qualifies.
    try {
      final file = File(copied);
      if (await file.exists()) await file.delete();
      if (await file.parent.exists() && await file.parent.list().isEmpty) {
        await file.parent.delete();
      }
    } catch (_) {
      // Preserve the original failure. A leftover private copy can be recovered.
    }
  }
}

class AttachmentTooLarge implements Exception {
  const AttachmentTooLarge();
}
