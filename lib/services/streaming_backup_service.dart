import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import '../data/database_helper.dart';
import '../models/stored_json.dart';
import 'local_media_store.dart';
import 'backup_cache_service.dart';
import 'portable_backup_service.dart';
import 'recovery/backup_inspector.dart';
import 'security/credential_repository.dart';

class BackupCancelled implements Exception {}

class BackupPasswordException implements Exception {
  const BackupPasswordException();
  @override
  String toString() => 'BackupPasswordException';
}

class BackupControl {
  bool cancelled = false;
  void cancel() => cancelled = true;
  void check() {
    if (cancelled) throw BackupCancelled();
  }
}

class BackupProgress {
  const BackupProgress(this.stage, this.completed, this.total);
  final String stage;
  final int completed, total;
  double? get fraction => total == 0 ? null : (completed / total).clamp(0, 1);
}

class BackupFile {
  const BackupFile(
    this.file,
    this.mediaCount,
    this.missingMedia,
    this.createdAt,
    this.encrypted,
  );
  final File file;
  final int mediaCount;
  final List<String> missingMedia;
  final DateTime createdAt;
  final bool encrypted;
}

class BackupFilePreview {
  const BackupFilePreview(
    this.digest,
    this.mediaCount,
    this.missingMedia,
    this.encrypted,
    this.payloadBytes,
  );
  final String digest;
  final int mediaCount, payloadBytes;
  final List<String> missingMedia;
  final bool encrypted;
}

typedef BackupProgressCallback = void Function(BackupProgress value);

/// Version 2: bounded authenticated frames over a manifest and raw attachment
/// streams. No attachment is base64 encoded or loaded as one byte array.
class StreamingBackupService {
  const StreamingBackupService();
  static const magic = [68, 70, 66, 75, 50, 13, 10, 0]; // DFBK2 CR LF NUL
  static const chunkBytes = 1024 * 1024;
  static const maxAttachmentBytes = 512 * 1024 * 1024;
  static const maxAttachmentsBytes = 2 * 1024 * 1024 * 1024;
  static const maxSnapshotBytes = 32 * 1024 * 1024;
  static const maxManifestBytes = 64 * 1024 * 1024;
  static const maxFileBytes =
      maxAttachmentsBytes + maxManifestBytes + 256 * 1024;
  static const kdfIterations = 600000;
  static void validatePassword(String value, {bool creating = true}) {
    if ((creating && value.runes.length < 12) ||
        value.isEmpty ||
        utf8.encode(value).length > 1024) {
      throw const BackupPasswordException();
    }
  }

  static Map<String, dynamic> redactedSnapshot(Map<String, dynamic> data) {
    final copy = Map<String, dynamic>.from(jsonDecode(jsonEncode(data)));
    for (final row in copy['settings'] as List) {
      row['api_key'] = '';
      if (row['ai_profiles_json'] != null) {
        final profiles = jsonDecode(row['ai_profiles_json'] as String) as List;
        for (final profile in profiles) {
          profile['api_key'] = '';
        }
        row['ai_profiles_json'] = jsonEncode(profiles);
      }
      final drafts = row['workspace_drafts_json'];
      if (drafts is String) {
        final value = jsonDecode(drafts) as Map<String, dynamic>;
        value.remove(CredentialRepository.cleanupKey);
        row['workspace_drafts_json'] = jsonEncode(value);
      }
    }
    return copy;
  }

  Future<BackupFile> createFile(
    DatabaseHelper database,
    DataGeneration generation,
    Directory cacheRoot, {
    String? password,
    BackupControl? control,
    bool Function()? isCurrent,
    BackupProgressCallback? onProgress,
    DateTime? now,
  }) => database.runOperation(generation, () async {
    final job = control ?? BackupControl();
    void check() {
      job.check();
      database.checkGeneration(generation);
      if (isCurrent?.call() == false) throw BackupCancelled();
    }

    check();
    if (password != null) validatePassword(password);
    final at = now ?? DateTime.now();
    final raw = await database.writeTransaction(generation, (db) async {
      final data = <String, dynamic>{
        'version': DatabaseHelper.schemaVersion,
        'timestamp': at.toIso8601String(),
      };
      for (final entry in {
        'settings': 'Settings',
        'media_records': 'MediaRecords',
        'reminders': 'Reminders',
      }.entries) {
        final rows = await db.query(entry.value, limit: 100001);
        if (rows.length > 100000) {
          throw const FormatException('Too many backup rows');
        }
        data[entry.key] = rows;
      }
      return data;
    });
    check();
    final snapshot = redactedSnapshot(raw);
    if (utf8.encode(jsonEncode(snapshot)).length > maxSnapshotBytes) {
      throw const FormatException('Backup metadata too large');
    }
    final files = <Map<String, dynamic>>[],
        paths = <String>[],
        missing = <String>[];
    var total = 0;
    final records = snapshot['media_records'] as List;
    for (var i = 0; i < records.length; i++) {
      check();
      final record = records[i] as Map;
      if (record['type'] == 'text') continue;
      final path = await LocalMediaStore().resolvePath(
        record['content_or_path'] as String,
      );
      check();
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        missing.add(record['id'] as String);
        continue;
      }
      final file = File(path), length = await File(path).length();
      if (length > maxAttachmentBytes || total + length > maxAttachmentsBytes) {
        throw const FormatException('Backup attachment limit exceeded');
      }
      total += length;
      final digest = await _hashFile(file, maxAttachmentBytes, check);
      check();
      if (await file.length() != length) {
        throw const FormatException('Attachment changed during backup');
      }
      files.add({
        'id': record['id'],
        'name': p.basename(path),
        'size': length,
        'sha256': digest,
      });
      paths.add(path);
      onProgress?.call(BackupProgress('scan', i + 1, records.length));
    }
    final manifest = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'dontforget.bundle',
          'bundle_version': 2,
          'snapshot': snapshot,
          'attachments': files,
          'missing_media': missing,
        }),
      ),
    );
    if (manifest.length > maxManifestBytes) {
      throw const FormatException('Backup manifest too large');
    }
    final payloadBytes = 4 + manifest.length + total;
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final noncePrefix = List<int>.generate(8, (_) => random.nextInt(256));
    final header = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'dontforget.file',
          'version': 2,
          'cipher': password == null ? 'none' : 'AES-256-GCM',
          'kdf': password == null ? 'none' : 'PBKDF2-HMAC-SHA256',
          'iterations': password == null ? 0 : kdfIterations,
          'salt': password == null ? '' : base64Encode(salt),
          'nonce': password == null ? '' : base64Encode(noncePrefix),
          'chunk_bytes': chunkBytes,
          'payload_bytes': payloadBytes,
        }),
      ),
    );
    onProgress?.call(const BackupProgress('key', 0, 0));
    final key = password == null ? null : await _derive(password, salt);
    check();
    await _safeDirectory(cacheRoot);
    final directory = await cacheRoot.createTemp('export-');
    BackupCacheService.activeDirectories.add(directory.path);
    final partial = File(p.join(directory.path, 'backup.partial'));
    RandomAccessFile? output;
    try {
      output = await partial.open(mode: FileMode.write);
      await output.writeFrom(magic);
      await output.writeFrom(_u32(header.length));
      await output.writeFrom(header);
      final writer = _FrameWriter(
        output,
        header,
        noncePrefix,
        key,
        check,
        payloadBytes,
        onProgress,
      );
      await writer.add(_u32(manifest.length));
      await writer.add(manifest);
      for (var i = 0; i < files.length; i++) {
        check();
        final digest = _HashSink();
        var count = 0;
        await for (final chunk in File(paths[i]).openRead()) {
          check();
          count += chunk.length;
          if (count > files[i]['size']) {
            throw const FormatException('Attachment grew during backup');
          }
          digest.add(chunk);
          await writer.add(chunk);
        }
        if (count != files[i]['size'] ||
            digest.finish() != files[i]['sha256']) {
          throw const FormatException('Attachment changed during backup');
        }
      }
      await writer.finish();
      check();
      await output.flush();
      await output.close();
      output = null;
      final result = await partial.rename(
        p.join(directory.path, 'backup.dfbackup'),
      );
      return BackupFile(
        result,
        files.length,
        List.unmodifiable(missing),
        at,
        password != null,
      );
    } catch (_) {
      BackupCacheService.activeDirectories.remove(directory.path);
      await output?.close();
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    } finally {
      key?.fillRange(0, key.length, 0);
    }
  });

  Future<bool> needsPassword(File source) async {
    final header = await _header(source);
    return header?['cipher'] != null && header!['cipher'] != 'none';
  }

  Future<BackupFilePreview> inspect(
    File source, {
    String? password,
    BackupControl? control,
    bool Function()? isCurrent,
    BackupProgressCallback? onProgress,
  }) async {
    control?.check();
    if (isCurrent?.call() == false) throw BackupCancelled();
    if (await _header(source) == null) {
      final old = await const PortableBackupService().inspect(source);
      control?.check();
      if (isCurrent?.call() == false) throw BackupCancelled();
      return BackupFilePreview(
        old.digest,
        old.mediaCount,
        old.missing,
        false,
        await source.length(),
      );
    }
    final read = await _read(
      source,
      password: password,
      control: control,
      isCurrent: isCurrent,
      onProgress: onProgress,
    );
    return BackupFilePreview(
      read.digest,
      read.files,
      read.missing,
      read.encrypted,
      read.bytes,
    );
  }

  Future<File> prepareRestore(
    File source,
    Directory ownedMediaRoot, {
    required String expectedDigest,
    required bool Function() isCurrent,
    String? password,
    BackupControl? control,
    BackupProgressCallback? onProgress,
  }) async {
    control?.check();
    if (await _header(source) == null) {
      return const PortableBackupService().prepareRestore(
        source,
        ownedMediaRoot,
        expectedDigest: expectedDigest,
        isCurrent: () => control?.cancelled != true && isCurrent(),
      );
    }
    final read = await _read(
      source,
      password: password,
      destination: ownedMediaRoot,
      expectedDigest: expectedDigest,
      control: control,
      isCurrent: isCurrent,
      onProgress: onProgress,
    );
    return read.snapshot!;
  }

  Future<Map<String, dynamic>?> _header(File source) async {
    await _validSource(source);
    final input = await source.open();
    try {
      final prefix = await input.read(magic.length);
      if (!_equal(prefix, magic)) return null;
      final size = await input.read(4);
      if (size.length != 4) {
        throw const FormatException('Truncated backup header');
      }
      final length = ByteData.sublistView(size).getUint32(0);
      if (length < 2 || length > 4096) {
        throw const FormatException('Invalid backup header');
      }
      final data = await input.read(length);
      if (data.length != length) {
        throw const FormatException('Truncated backup header');
      }
      final header = _parseHeader(data);
      await _checkFileLength(source, header, length);
      return header;
    } finally {
      await input.close();
    }
  }

  Future<
    ({
      String digest,
      int files,
      List<String> missing,
      bool encrypted,
      int bytes,
      File? snapshot,
    })
  >
  _read(
    File source, {
    String? password,
    Directory? destination,
    String? expectedDigest,
    BackupControl? control,
    bool Function()? isCurrent,
    BackupProgressCallback? onProgress,
  }) async {
    final job = control ?? BackupControl();
    void check() {
      job.check();
      if (isCurrent?.call() == false) throw BackupCancelled();
    }

    check();
    await _validSource(source);
    Directory? created, validation;
    Uint8List? key;
    final input = await source.open();
    try {
      final reader = _FileReader(input, check);
      if (!_equal(await reader.take(magic.length), magic)) {
        throw const FormatException('Invalid backup magic');
      }
      final headerSize = _int(await reader.take(4));
      if (headerSize < 2 || headerSize > 4096) {
        throw const FormatException('Invalid backup header');
      }
      final headerBytes = await reader.take(headerSize),
          header = _parseHeader(headerBytes);
      await _checkFileLength(source, header, headerSize);
      final encrypted = header['cipher'] != 'none';
      if (encrypted) {
        if (password == null) throw const BackupPasswordException();
        validatePassword(password, creating: false);
        onProgress?.call(const BackupProgress('key', 0, 0));
        key = await _derive(password, base64Decode(header['salt']));
        check();
      }
      final payload = _PayloadReader(
        reader,
        headerBytes,
        header,
        key,
        check,
        onProgress,
      );
      final length = _int(await payload.take(4));
      if (length < 2 || length > maxManifestBytes) {
        throw const FormatException('Invalid backup manifest');
      }
      final manifest = _parseManifest(await payload.take(length));
      final snapshot = Map<String, dynamic>.from(manifest['snapshot']);
      if (utf8.encode(jsonEncode(snapshot)).length > maxSnapshotBytes) {
        throw const FormatException('Backup metadata too large');
      }
      final files = manifest['attachments'] as List;
      final total = files.fold<int>(
        4 + length,
        (n, f) => n + (f['size'] as int),
      );
      if (total != header['payload_bytes']) {
        throw const FormatException('Invalid backup payload length');
      }
      // Structural inspection uses a private metadata copy only, before any
      // restored media directory or application database is touched.
      validation = await Directory.systemTemp.createTemp(
        'dontforget-backup-inspection-',
      );
      final probe = await File(
        p.join(validation.path, 'snapshot.json'),
      ).writeAsString(jsonEncode(snapshot), flush: true);
      await BackupInspector.platform().inspect(probe);
      check();
      if (destination != null) {
        await _safeDirectory(destination);
        check();
        created = await destination.createTemp('import-');
      }
      for (var index = 0; index < files.length; index++) {
        final meta = files[index] as Map, digest = _HashSink();
        RandomAccessFile? out;
        try {
          File? file;
          if (created != null) {
            var extension = p.extension(meta['name'] as String).toLowerCase();
            if (!RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(extension)) {
              extension = '.bin';
            }
            file = File(p.join(created.path, 'attachment-$index$extension'));
            out = await file.open(mode: FileMode.write);
          }
          var left = meta['size'] as int;
          while (left > 0) {
            check();
            final data = await payload.take(min(left, chunkBytes));
            digest.add(data);
            if (out != null) await out.writeFrom(data);
            left -= data.length;
          }
          if (digest.finish() != meta['sha256']) {
            throw const FormatException('Attachment digest mismatch');
          }
          await out?.flush();
          if (file != null) {
            (snapshot['media_records'] as List).firstWhere(
              (r) => r['id'] == meta['id'],
            )['content_or_path'] = file.path;
          }
        } finally {
          await out?.close();
        }
      }
      await payload.finish();
      check();
      final digest = await reader.finish();
      if (expectedDigest != null && digest != expectedDigest) {
        throw const FormatException('Backup changed after preview');
      }
      File? result;
      if (created != null) {
        final missing = (manifest['missing_media'] as List).toSet();
        final rows = snapshot['media_records'] as List;
        for (var i = 0; i < rows.length; i++) {
          if (missing.contains(rows[i]['id'])) {
            // A missing attachment must not accidentally resolve to an
            // unrelated existing file on the destination device.
            rows[i]['content_or_path'] = p.join(created.path, 'missing-$i.bin');
          }
        }
        result = await File(
          p.join(created.path, 'snapshot.json'),
        ).writeAsString(jsonEncode(snapshot), flush: true);
        check();
      }
      return (
        digest: digest,
        files: files.length,
        missing: List<String>.unmodifiable(manifest['missing_media']),
        encrypted: encrypted,
        bytes: header['payload_bytes'] as int,
        snapshot: result,
      );
    } catch (_) {
      if (created != null && await created.exists()) {
        await created.delete(recursive: true);
      }
      rethrow;
    } finally {
      await input.close();
      key?.fillRange(0, key.length, 0);
      if (validation != null && await validation.exists()) {
        await validation.delete(recursive: true);
      }
    }
  }

  static Map<String, dynamic> _parseHeader(Uint8List bytes) {
    final h = decodeStoredJson(utf8.decode(bytes));
    const keys = {
      'format',
      'version',
      'cipher',
      'kdf',
      'iterations',
      'salt',
      'nonce',
      'chunk_bytes',
      'payload_bytes',
    };
    if (h is! Map<String, dynamic> ||
        h.keys.toSet().difference(keys).isNotEmpty ||
        h.length != keys.length ||
        h['format'] != 'dontforget.file' ||
        h['version'] != 2 ||
        h['version'] is! int ||
        h['chunk_bytes'] != chunkBytes ||
        h['chunk_bytes'] is! int ||
        h['payload_bytes'] is! int ||
        h['payload_bytes'] < 4 ||
        h['payload_bytes'] > maxAttachmentsBytes + maxManifestBytes + 4) {
      throw const FormatException('Invalid backup header');
    }
    if (h['cipher'] == 'none') {
      if (h['kdf'] != 'none' ||
          h['iterations'] != 0 ||
          h['salt'] != '' ||
          h['nonce'] != '') {
        throw const FormatException('Invalid plaintext backup');
      }
    } else if (h['cipher'] == 'AES-256-GCM') {
      if (h['kdf'] != 'PBKDF2-HMAC-SHA256' ||
          h['iterations'] is! int ||
          h['iterations'] != kdfIterations ||
          h['salt'] is! String ||
          h['nonce'] is! String ||
          (h['salt'] as String).length > 32 ||
          (h['nonce'] as String).length > 16 ||
          base64Decode(h['salt']).length != 16 ||
          base64Decode(h['nonce']).length != 8) {
        throw const FormatException('Invalid encrypted backup');
      }
    } else {
      throw const FormatException('Unsupported backup cipher');
    }
    return h;
  }

  static Future<void> _checkFileLength(
    File source,
    Map<String, dynamic> header,
    int headerBytes,
  ) async {
    final bytes = header['payload_bytes'] as int;
    final frames = (bytes + chunkBytes - 1) ~/ chunkBytes;
    final expected =
        magic.length +
        4 +
        headerBytes +
        bytes +
        frames * (header['cipher'] == 'none' ? 4 : 20);
    if (await source.length() != expected) {
      throw const FormatException('Truncated or extended backup');
    }
  }

  static Map<String, dynamic> _parseManifest(Uint8List bytes) {
    final m = decodeStoredJson(utf8.decode(bytes));
    if (m is! Map<String, dynamic> ||
        m.length != 5 ||
        m['format'] != 'dontforget.bundle' ||
        m['bundle_version'] is! int ||
        m['bundle_version'] != 2 ||
        m['snapshot'] is! Map ||
        m['attachments'] is! List ||
        m['missing_media'] is! List) {
      throw const FormatException('Invalid backup manifest');
    }
    final records = m['snapshot']['media_records'];
    if (m['snapshot']['settings'] is! List ||
        m['snapshot']['reminders'] is! List) {
      throw const FormatException('Invalid backup tables');
    }
    if (records is! List ||
        records.length > 100000 ||
        (m['attachments'] as List).length > 100000 ||
        (m['missing_media'] as List).length > 100000) {
      throw const FormatException('Invalid backup records');
    }
    final recordIds = <String>{};
    for (final r in records) {
      if (r is! Map || r['id'] is! String || !recordIds.add(r['id'])) {
        throw const FormatException('Duplicate backup record');
      }
    }
    final media = {
      for (final r in records)
        if (r['type'] != 'text') r['id'] as String,
    };
    final ids = <String>{};
    var total = 0;
    for (final f in m['attachments']) {
      if (f is! Map ||
          f.length != 4 ||
          f['id'] is! String ||
          !media.contains(f['id']) ||
          !ids.add(f['id']) ||
          f['name'] is! String ||
          (f['name'] as String).length > 255 ||
          f['size'] is! int ||
          f['size'] < 0 ||
          f['size'] > maxAttachmentBytes ||
          f['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(f['sha256'])) {
        throw const FormatException('Invalid backup attachment');
      }
      total += f['size'] as int;
    }
    if (total > maxAttachmentsBytes) {
      throw const FormatException('Backup attachment limit exceeded');
    }
    for (final id in m['missing_media']) {
      if (id is! String || !media.contains(id) || !ids.add(id)) {
        throw const FormatException('Invalid missing attachment');
      }
    }
    if (ids.length != media.length) {
      throw const FormatException('Incomplete attachment manifest');
    }
    // New files never carry credentials, even when encrypted.
    for (final row in m['snapshot']['settings'] as List) {
      if ((row['api_key'] as String? ?? '').isNotEmpty) {
        throw const FormatException('Backup contains credentials');
      }
      if (row['ai_profiles_json'] is String) {
        for (final p in jsonDecode(row['ai_profiles_json']) as List) {
          if ((p['api_key'] as String? ?? '').isNotEmpty) {
            throw const FormatException('Backup contains credentials');
          }
        }
      }
    }
    return m;
  }
}

Future<void> _safeDirectory(Directory directory) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.directory) {
    throw const FormatException('Unsafe backup directory');
  }
  await directory.create(recursive: true);
}

Future<void> _validSource(File file) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await file.length() > StreamingBackupService.maxFileBytes) {
    throw const FormatException('Invalid backup source');
  }
}

Future<String> _hashFile(File file, int limit, void Function() check) async {
  final digest = _HashSink();
  var size = 0;
  await for (final data in file.openRead()) {
    check();
    size += data.length;
    if (size > limit) throw const FormatException('Attachment too large');
    digest.add(data);
  }
  return digest.finish();
}

class _DigestOutput implements Sink<hashes.Digest> {
  String? value;
  @override
  void add(hashes.Digest event) => value = event.toString();
  @override
  void close() {}
}

class _HashSink {
  final output = _DigestOutput();
  late final sink = hashes.sha256.startChunkedConversion(output);
  void add(List<int> data) => sink.add(data);
  String finish() {
    sink.close();
    return output.value!;
  }
}

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
int _int(Uint8List data) => ByteData.sublistView(data).getUint32(0);
bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<Uint8List> _derive(String password, List<int> salt) =>
    Isolate.run(() async {
      final key = await Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: StreamingBackupService.kdfIterations,
        bits: 256,
      ).deriveKeyFromPassword(password: password, nonce: salt);
      return Uint8List.fromList(await key.extractBytes());
    });
Future<Uint8List> _crypt(
  Uint8List input,
  Uint8List key,
  List<int> nonce,
  List<int> aad,
  bool encrypt,
) => Isolate.run(() async {
  final cipher = AesGcm.with256bits();
  if (encrypt) {
    final box = await cipher.encrypt(
      input,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }
  try {
    return Uint8List.fromList(
      await cipher.decrypt(
        SecretBox(
          input.sublist(0, input.length - 16),
          nonce: nonce,
          mac: Mac(input.sublist(input.length - 16)),
        ),
        secretKey: SecretKey(key),
        aad: aad,
      ),
    );
  } on SecretBoxAuthenticationError {
    throw const BackupPasswordException();
  }
});

class _FrameWriter {
  _FrameWriter(
    this.output,
    this.header,
    this.noncePrefix,
    this.key,
    this.check,
    this.total,
    this.progress,
  );
  final RandomAccessFile output;
  final Uint8List header;
  final List<int> noncePrefix;
  final Uint8List? key;
  final void Function() check;
  final int total;
  final BackupProgressCallback? progress;
  final buffer = Uint8List(StreamingBackupService.chunkBytes);
  int used = 0, sequence = 0, completed = 0;
  Future<void> add(List<int> data) async {
    var offset = 0;
    while (offset < data.length) {
      check();
      final count = min(buffer.length - used, data.length - offset);
      buffer.setRange(used, used + count, data, offset);
      used += count;
      offset += count;
      if (used == buffer.length) await _flush();
    }
  }

  Future<void> _flush() async {
    if (used == 0) return;
    check();
    final size = _u32(used), seq = _u32(sequence++);
    final bytes = key == null
        ? Uint8List.fromList(buffer.sublist(0, used))
        : await _crypt(
            Uint8List.fromList(buffer.sublist(0, used)),
            key!,
            [...noncePrefix, ...seq],
            [...header, ...seq, ...size],
            true,
          );
    check();
    await output.writeFrom(size);
    await output.writeFrom(bytes);
    completed += used;
    used = 0;
    progress?.call(BackupProgress('write', completed, total));
  }

  Future<void> finish() async {
    await _flush();
    if (completed != total) {
      throw const FormatException('Backup payload changed');
    }
  }
}

class _FileReader {
  _FileReader(this.input, this.check);
  final RandomAccessFile input;
  final void Function() check;
  final digest = _HashSink();
  int read = 0;
  Future<Uint8List> take(int count) async {
    check();
    if (count < 0 || count > StreamingBackupService.maxManifestBytes) {
      throw const FormatException('Invalid backup read');
    }
    final result = Uint8List(count);
    var offset = 0;
    while (offset < count) {
      check();
      final data = await input.read(
        min(count - offset, StreamingBackupService.chunkBytes + 16),
      );
      if (data.isEmpty) throw const FormatException('Truncated backup');
      read += data.length;
      if (read > StreamingBackupService.maxFileBytes) {
        throw const FormatException('Backup too large');
      }
      digest.add(data);
      result.setRange(offset, offset + data.length, data);
      offset += data.length;
    }
    return result;
  }

  Future<String> finish() async {
    check();
    if ((await input.read(1)).isNotEmpty) {
      throw const FormatException('Trailing backup bytes');
    }
    return digest.finish();
  }
}

class _PayloadReader {
  _PayloadReader(
    this.file,
    this.headerBytes,
    this.header,
    this.key,
    this.check,
    this.progress,
  );
  final _FileReader file;
  final Uint8List headerBytes;
  final Map<String, dynamic> header;
  final Uint8List? key;
  final void Function() check;
  final BackupProgressCallback? progress;
  Uint8List buffer = Uint8List(0);
  int offset = 0, read = 0, sequence = 0, decoded = 0;
  Future<Uint8List> take(int count) async {
    if (count < 0 ||
        count > StreamingBackupService.maxManifestBytes ||
        read + count > header['payload_bytes']) {
      throw const FormatException('Invalid backup payload');
    }
    final result = Uint8List(count);
    var copied = 0;
    while (copied < count) {
      check();
      if (offset == buffer.length) {
        final sizeBytes = await file.take(4), size = _int(sizeBytes);
        final expected = min(
          StreamingBackupService.chunkBytes,
          (header['payload_bytes'] as int) - decoded,
        );
        if (size <= 0 || size != expected) {
          throw const FormatException('Invalid backup frame');
        }
        final bytes = await file.take(size + (key == null ? 0 : 16)),
            seq = _u32(sequence++);
        buffer = key == null
            ? bytes
            : await _crypt(
                bytes,
                key!,
                [...base64Decode(header['nonce']), ...seq],
                [...headerBytes, ...seq, ...sizeBytes],
                false,
              );
        decoded += size;
        offset = 0;
        progress?.call(
          BackupProgress('read', decoded, header['payload_bytes'] as int),
        );
      }
      final n = min(count - copied, buffer.length - offset);
      result.setRange(copied, copied + n, buffer, offset);
      offset += n;
      copied += n;
    }
    read += count;
    return result;
  }

  Future<void> finish() async {
    check();
    if (read != header['payload_bytes'] || offset != buffer.length) {
      throw const FormatException('Incomplete backup payload');
    }
  }
}
