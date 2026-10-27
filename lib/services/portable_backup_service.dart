import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../data/database_helper.dart';
import 'local_media_store.dart';

class PortableBackup {
  const PortableBackup(
    this.bytes,
    this.missingMedia,
    this.mediaCount,
    this.createdAt,
  );
  final Uint8List bytes;
  final List<String> missingMedia;
  final int mediaCount;
  final DateTime createdAt;
}

/// A self-contained JSON bundle; credentials are always excluded. Bounded
/// decoding and content hashes are checked before creating any restore files.
class PortableBackupService {
  const PortableBackupService();
  static const maxMediaBytes = 32 * 1024 * 1024;
  static const maxBundleBytes = 64 * 1024 * 1024;
  Future<PortableBackup> create(
    DatabaseHelper database,
    DataGeneration generation, {
    DateTime? now,
  }) => database.runOperation(generation, () async {
    final at = now ?? DateTime.now();
    final snapshot = await database.writeTransaction(
      generation,
      (db) async => <String, dynamic>{
        'version': DatabaseHelper.schemaVersion,
        'timestamp': at.toIso8601String(),
        'settings': await db.query('Settings'),
        'media_records': await db.query('MediaRecords'),
        'reminders': await db.query('Reminders'),
      },
    );
    // Copy rows before redacting: the live database is never rewritten.
    final safe = Map<String, dynamic>.from(jsonDecode(jsonEncode(snapshot)));
    for (final row in safe['settings'] as List) {
      row['api_key'] = '';
      final profiles = jsonDecode(row['ai_profiles_json'] as String);
      for (final profile in profiles as List) {
        profile['api_key'] = '';
      }
      row['ai_profiles_json'] = jsonEncode(profiles);
    }
    final attachments = <Map<String, dynamic>>[], missing = <String>[];
    var total = 0;
    for (final record in safe['media_records'] as List) {
      if (record['type'] == 'text') continue;
      database.checkGeneration(generation);
      final original = record['content_or_path'] as String;
      final path = await LocalMediaStore().resolvePath(original);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        missing.add(record['id'] as String);
        continue;
      }
      final length = await File(path).length();
      if (length > maxMediaBytes || total + length > maxMediaBytes) {
        throw const FormatException('Attachments exceed portable backup limit');
      }
      final bytes = await File(path).readAsBytes();
      total += bytes.length;
      if (total > maxMediaBytes) {
        throw const FormatException('Attachments grew during backup');
      }
      attachments.add({
        'id': record['id'],
        'name': p.basename(path),
        'sha256': sha256.convert(bytes).toString(),
        'bytes': base64Encode(bytes),
      });
    }
    database.checkGeneration(generation);
    final body = jsonEncode({
      'format': 'dontforget.bundle',
      'bundle_version': 1,
      'snapshot': safe,
      'attachments': attachments,
      'missing_media': missing,
    });
    final bytes = Uint8List.fromList(utf8.encode(body));
    if (bytes.length > maxBundleBytes) {
      throw const FormatException('Backup too large');
    }
    return PortableBackup(
      bytes,
      List.unmodifiable(missing),
      attachments.length,
      at,
    );
  });

  Future<
    ({
      Map<String, dynamic> snapshot,
      int mediaCount,
      List<String> missing,
      String digest,
    })
  >
  inspect(File source) async {
    final bundle = await _read(source);
    return (
      snapshot: Map<String, dynamic>.unmodifiable(bundle['snapshot']),
      mediaCount: (bundle['attachments'] as List).length,
      missing: List<String>.unmodifiable(bundle['missing_media']),
      digest: bundle['_source_digest'] as String,
    );
  }

  /// Explicit restore preparation only. Unique directories never replace live
  /// media; retained files remain valid if database recovery is interrupted.
  Future<File> prepareRestore(
    File source,
    Directory ownedMediaRoot, {
    required String expectedDigest,
    required bool Function() isCurrent,
  }) async {
    final bundle = await _read(source);
    if (bundle['_source_digest'] != expectedDigest) {
      throw const FormatException('Backup changed after preview');
    }
    if (!isCurrent()) throw StateError('Backup session expired');
    final rootType = await FileSystemEntity.type(
      ownedMediaRoot.path,
      followLinks: false,
    );
    if (rootType == FileSystemEntityType.link) {
      throw const FormatException('Unsafe media root');
    }
    await ownedMediaRoot.create(recursive: true);
    final destination = await ownedMediaRoot.createTemp('restored-bundle-');
    try {
      final records = (bundle['snapshot']['media_records'] as List);
      for (final attachment in bundle['attachments'] as List) {
        if (!isCurrent()) throw StateError('Backup session expired');
        final record = records.firstWhere((r) => r['id'] == attachment['id']);
        // The on-disk filename is a local ordinal, never an untrusted path.
        final index = records.indexOf(record);
        var extension = p.extension(attachment['name'] as String).toLowerCase();
        if (!RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(extension)) {
          extension = '.bin';
        }
        final file = File(
          p.join(destination.path, 'attachment-$index$extension'),
        );
        await file.writeAsBytes(
          base64Decode(attachment['bytes'] as String),
          flush: true,
        );
        record['content_or_path'] = file.path;
      }
      if (!isCurrent()) throw StateError('Backup session expired');
      final snapshot = File(p.join(destination.path, 'snapshot.json'));
      await snapshot.writeAsString(jsonEncode(bundle['snapshot']), flush: true);
      return snapshot;
    } catch (_) {
      await destination.delete(recursive: true);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _read(File source) async {
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await source.length() > maxBundleBytes) {
      throw const FormatException('Invalid bundle source');
    }
    final bytes = await source.readAsBytes();
    if (bytes.length > maxBundleBytes) {
      throw const FormatException('Backup too large');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> ||
        value['format'] != 'dontforget.bundle' ||
        value['bundle_version'] != 1 ||
        value['snapshot'] is! Map ||
        value['attachments'] is! List ||
        value['missing_media'] is! List) {
      throw const FormatException('Invalid bundle');
    }
    final snapshot = value['snapshot'] as Map;
    if (snapshot['version'] is! int ||
        snapshot['version'] < 7 ||
        snapshot['version'] > DatabaseHelper.schemaVersion ||
        snapshot['media_records'] is! List ||
        snapshot['reminders'] is! List ||
        snapshot['settings'] is! List) {
      throw const FormatException('Unsupported bundle schema');
    }
    final records = snapshot['media_records'] as List;
    if (records.length > 100000) {
      throw const FormatException('Too many media records');
    }
    final ids = <String>{};
    var total = 0;
    for (final attachment in value['attachments'] as List) {
      if (attachment is! Map ||
          attachment['id'] is! String ||
          !ids.add(attachment['id']) ||
          attachment['name'] is! String ||
          attachment['bytes'] is! String ||
          attachment['sha256'] is! String) {
        throw const FormatException('Invalid bundle attachment');
      }
      if (!records.any(
        (r) => r is Map && r['id'] == attachment['id'] && r['type'] != 'text',
      )) {
        throw const FormatException('Orphan bundle attachment');
      }
      final encoded = attachment['bytes'] as String;
      if (encoded.length > maxMediaBytes * 4 ~/ 3 + 8) {
        throw const FormatException('Attachment too large');
      }
      final data = base64Decode(encoded);
      total += data.length;
      if (total > maxMediaBytes ||
          sha256.convert(data).toString() != attachment['sha256']) {
        throw const FormatException('Attachment digest mismatch');
      }
    }
    if ((value['missing_media'] as List).any(
      (id) =>
          id is! String ||
          !records.any(
            (r) => r is Map && r['id'] == id && r['type'] != 'text',
          ) ||
          ids.contains(id),
    )) {
      throw const FormatException('Invalid missing media');
    }
    final covered = {...ids, ...value['missing_media'] as List};
    if (records.any(
      (r) =>
          r is! Map ||
          r['id'] is! String ||
          r['type'] != 'text' && !covered.contains(r['id']),
    )) {
      throw const FormatException('Incomplete media manifest');
    }
    value['_source_digest'] = sha256.convert(bytes).toString();
    return value;
  }
}
