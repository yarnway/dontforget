import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../../data/database_helper.dart';
import '../../models/settings.dart';
import '../../models/credential_reference.dart';

enum CredentialStatus {
  notConfigured,
  secured,
  unavailable,
  missing,
  migrationPending,
  cleanupPending,
}

class CredentialLoad {
  const CredentialLoad(this.settings, this.status);
  final AppSettings settings;
  final CredentialStatus status;
}

class CredentialStorageException implements Exception {
  const CredentialStorageException();
  @override
  String toString() => 'CredentialStorageException';
}

/// Database rows contain only an opaque reference and credential-free metadata.
/// A new immutable vault entry is read back before its SQL reference commits.
class CredentialRepository {
  CredentialRepository._(this.database);
  static final _instances = Expando<CredentialRepository>();
  factory CredentialRepository(DatabaseHelper database) =>
      _instances[database] ??= CredentialRepository._(database);
  final DatabaseHelper database;
  Future<void> _queue = Future.value();
  static const prefix = credentialReferencePrefix;
  static const cleanupKey = '_credentialCleanupV1';
  static bool isReference(Object? value) => isCredentialReference(value);

  Future<T> _serial<T>(
    DataGeneration generation,
    Future<T> Function() action, {
    bool admitted = true,
  }) {
    final previous = _queue;
    final result = () async {
      await previous;
      database.checkGeneration(generation);
      return admitted ? database.runOperation(generation, action) : action();
    }();
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Map<String, dynamic>> _row(DataGeneration generation) async {
    final rows = await database.read(
      generation,
      (db) => db.query('Settings', where: 'id = ?', whereArgs: ['default']),
    );
    if (rows.isEmpty) return AppSettings.defaults().toJson();
    if (rows.length != 1) throw StateError('Settings unavailable');
    return Map<String, dynamic>.from(rows.single);
  }

  static Map<String, dynamic> redact(AppSettings settings) {
    final data = settings.toJson();
    data['id'] = 'default';
    data['api_key'] = '';
    final profiles = jsonDecode(data['ai_profiles_json'] as String) as List;
    for (final p in profiles) {
      p['api_key'] = '';
    }
    data['ai_profiles_json'] = jsonEncode(profiles);
    return data;
  }

  static String _binding(Map<String, dynamic> raw) {
    final settings = AppSettings.fromJson(raw);
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              settings.baseUrl,
              settings.modelName,
              settings.aiFallbackEnabled,
              for (final p in settings.effectiveProfiles)
                [p.id, p.settings.baseUrl, p.settings.modelName, p.enabled],
            ]),
          ),
        )
        .toString();
  }

  static bool _hasKeys(AppSettings settings) =>
      settings.apiKey.isNotEmpty ||
      settings.effectiveProfiles.any((p) => p.settings.apiKey.isNotEmpty);
  static Map<String, dynamic> _drafts(Map row) {
    final raw = row['workspace_drafts_json'];
    if (raw == null) return {};
    final data = jsonDecode(raw as String);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid workspace');
    }
    return data;
  }

  static List<String> _pending(Map row) {
    final value = _drafts(row)[cleanupKey] ?? [];
    if (value is! List ||
        value.length > 128 ||
        value.any((e) => !isReference(e))) {
      throw const FormatException('Invalid credential cleanup');
    }
    return List<String>.from(value);
  }

  Future<String?> _readSecret(String reference) async {
    try {
      return await database.credentialStore.read(reference);
    } catch (_) {
      throw const CredentialStorageException();
    }
  }

  Future<CredentialLoad> load(
    DataGeneration generation,
  ) => _serial(generation, () async {
    final row = await _row(generation);
    database.checkGeneration(generation);
    final raw = AppSettings.fromJson(row), reference = row['api_key'];
    if (isReference(reference)) {
      try {
        final stored = await _readSecret(reference as String);
        database.checkGeneration(generation);
        if (stored == null) {
          return CredentialLoad(
            AppSettings.fromJson(redact(raw)),
            CredentialStatus.missing,
          );
        }
        if (stored.length > 262144) throw const CredentialStorageException();
        final data = jsonDecode(stored);
        if (data is! Map ||
            data['version'] != 1 ||
            data['binding'] != _binding(row) ||
            data['api_key'] is! String ||
            (data['api_key'] as String).length > 8192 ||
            data['profiles'] is! Map) {
          throw const CredentialStorageException();
        }
        final profiles = raw.effectiveProfiles.map((p) {
          final key = data['profiles'][p.id];
          if (key is! String || key.length > 8192) {
            throw const CredentialStorageException();
          }
          return p.copyWith(settings: p.settings.copyWith(apiKey: key));
        }).toList();
        final settings = AppSettings.fromJson({
          ...row,
          'api_key': data['api_key'],
          'ai_profiles_json': jsonEncode(
            profiles.map((p) => p.toJson()).toList(),
          ),
        });
        final clean = await database.runOperation(
          generation,
          () => _cleanup(generation),
        );
        return CredentialLoad(
          settings,
          clean ? CredentialStatus.secured : CredentialStatus.cleanupPending,
        );
      } on DatabaseAccessException {
        rethrow;
      } catch (_) {
        return CredentialLoad(
          AppSettings.fromJson(redact(raw)),
          CredentialStatus.unavailable,
        );
      }
    }
    if (_hasKeys(raw)) {
      try {
        return await database.runOperation(
          generation,
          () => _save(raw, generation),
        );
      } on DatabaseAccessException {
        rethrow;
      } catch (_) {
        return CredentialLoad(
          AppSettings.fromJson(redact(raw)),
          CredentialStatus.migrationPending,
        );
      }
    }
    final clean = await database.runOperation(
      generation,
      () => _cleanup(generation),
    );
    return CredentialLoad(
      raw,
      clean ? CredentialStatus.notConfigured : CredentialStatus.cleanupPending,
    );
  }, admitted: false);

  Future<CredentialLoad> save(
    AppSettings settings,
    DataGeneration generation, {
    bool clear = false,
  }) => _serial(generation, () => _save(settings, generation, clear: clear));
  Future<CredentialLoad> _save(
    AppSettings settings,
    DataGeneration generation, {
    bool clear = false,
  }) async {
    final current = await _row(generation);
    final saved = AppSettings.fromJson({...settings.toJson(), 'id': 'default'});
    if (isReference(saved.apiKey)) throw const CredentialStorageException();
    final oldReference = isReference(current['api_key'])
        ? current['api_key'] as String
        : null;
    if (!_hasKeys(saved) &&
        !clear &&
        (oldReference != null || _hasKeys(AppSettings.fromJson(current)))) {
      // Failed reads and migrations expose a redacted runtime state. A later
      // preference save is not consent to remove the still-stored secrets,
      // even if the vault has recovered since that state was loaded.
      throw const CredentialStorageException();
    }
    final persisted = redact(saved);
    String? newReference;
    if (_hasKeys(saved)) {
      final entry = jsonEncode({
        'version': 1,
        'binding': _binding(persisted),
        'api_key': saved.apiKey,
        'profiles': {
          for (final p in saved.effectiveProfiles) p.id: p.settings.apiKey,
        },
      });
      if (entry.length > 262144) throw const CredentialStorageException();
      // Reuse unchanged secrets across language/appearance saves.
      if (oldReference != null && await _readSecret(oldReference) == entry) {
        newReference = oldReference;
      } else {
        newReference = '$prefix${const Uuid().v4()}';
        try {
          await database.credentialStore.write(newReference, entry);
          if (await database.credentialStore.read(newReference) != entry) {
            throw const CredentialStorageException();
          }
        } catch (_) {
          try {
            await database.credentialStore.delete(newReference);
          } catch (_) {}
          throw const CredentialStorageException();
        }
      }
      persisted['api_key'] = newReference;
    }
    String? cleanupJob;
    try {
      if (oldReference != null && oldReference != newReference) {
        cleanupJob = '$prefix${const Uuid().v4()}';
        final authorization = jsonEncode({
          'version': 1,
          'kind': 'cleanup',
          'old_ref': oldReference,
        });
        await database.credentialStore.write(cleanupJob, authorization);
        if (await database.credentialStore.read(cleanupJob) != authorization) {
          throw const CredentialStorageException();
        }
      }
      database.checkGeneration(generation);
      await database.writeTransaction(generation, (db) async {
        final rows = await db.query(
          'Settings',
          where: 'id = ?',
          whereArgs: ['default'],
        );
        if (rows.length > 1) throw StateError('Settings unavailable');
        final row = rows.isEmpty
            ? AppSettings.defaults().toJson()
            : rows.single;
        // Another SQL writer must not silently swap the credential binding.
        for (final field in [
          'api_key',
          'base_url',
          'model_name',
          'ai_profiles_json',
          'ai_fallback_enabled',
        ]) {
          if (rows.isNotEmpty && row[field] != current[field]) {
            throw const CredentialStorageException();
          }
        }
        final drafts = _drafts(row);
        final pending = _pending(row).toSet();
        if (cleanupJob != null) pending.add(cleanupJob);
        if (pending.length > 128) throw const CredentialStorageException();
        if (pending.isNotEmpty) drafts[cleanupKey] = pending.toList();
        final rawDrafts = drafts.isEmpty && row['workspace_drafts_json'] == null
            ? null
            : jsonEncode(drafts);
        if (rawDrafts != null && rawDrafts.length > 1048576) {
          throw const FormatException('Workspace too large');
        }
        await db.delete('Settings', where: 'id = ?', whereArgs: ['default']);
        await db.insert('Settings', {
          ...persisted,
          'workspace_drafts_json': rawDrafts,
        });
      });
    } catch (_) {
      if (cleanupJob != null) {
        try {
          await database.credentialStore.delete(cleanupJob);
        } catch (_) {}
      }
      if (newReference != null && newReference != oldReference) {
        try {
          await database.credentialStore.delete(newReference);
        } catch (_) {}
      }
      rethrow;
    }
    var clean = false;
    try {
      clean = await _cleanup(generation);
    } on DatabaseAccessException {
      rethrow;
    } catch (_) {}
    final row = await _row(generation);
    return CredentialLoad(
      AppSettings.fromJson({
        ...saved.toJson(),
        'workspace_drafts_json': row['workspace_drafts_json'],
      }),
      !clean
          ? CredentialStatus.cleanupPending
          : _hasKeys(saved)
          ? CredentialStatus.secured
          : CredentialStatus.notConfigured,
    );
  }

  Future<bool> _cleanup(DataGeneration generation) async {
    final row = await _row(generation);
    final pending = _pending(row);
    if (pending.isEmpty) return true;
    final removed = <String>{};
    for (final ref in pending.where((r) => r != row['api_key'])) {
      try {
        final raw = await database.credentialStore.read(ref);
        if (raw == null) {
          removed.add(ref);
          continue;
        }
        if (raw.length > 1024) {
          removed.add(ref);
          continue;
        }
        final job = jsonDecode(raw);
        // SQL/backup data cannot invent deletion authorizations. The cleanup
        // target must come from a job previously written to the OS vault.
        if (job is! Map ||
            job['version'] != 1 ||
            job['kind'] != 'cleanup' ||
            !isReference(job['old_ref']) ||
            job['old_ref'] == row['api_key']) {
          removed.add(ref);
          continue;
        }
        await database.credentialStore.delete(job['old_ref']);
        if (await database.credentialStore.read(job['old_ref']) != null) {
          continue;
        }
        await database.credentialStore.delete(ref);
        if (await database.credentialStore.read(ref) == null) removed.add(ref);
      } catch (_) {
        break;
      }
      database.checkGeneration(generation);
    }
    if (removed.isNotEmpty) {
      await database.writeTransaction(generation, (db) async {
        final current = (await db.query(
          'Settings',
          where: 'id = ?',
          whereArgs: ['default'],
        )).single;
        final drafts = _drafts(current),
            remaining = _pending(
              current,
            ).where((r) => !removed.contains(r)).toList();
        if (remaining.isEmpty) {
          drafts.remove(cleanupKey);
        } else {
          drafts[cleanupKey] = remaining;
        }
        await db.update(
          'Settings',
          {'workspace_drafts_json': jsonEncode(drafts)},
          where: 'id = ?',
          whereArgs: ['default'],
        );
      });
    }
    return pending.every(removed.contains);
  }
}
