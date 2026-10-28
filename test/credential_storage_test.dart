import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/ai_profile.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/security/credential_repository.dart';
import 'package:dont_forget/services/security/credential_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Vault implements CredentialStore {
  final values = <String, String>{};
  bool failRead = false,
      failWrite = false,
      failDelete = false,
      wrongReadback = false;
  Completer<void>? writeBarrier;
  int writes = 0;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('Synthetic read failure');
    return wrongReadback && values.containsKey(key) ? 'corrupt' : values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    await writeBarrier?.future;
    if (failWrite) throw StateError('Synthetic write failure');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('Synthetic delete failure');
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late DatabaseHelper db;
  late _Vault vault;
  late SettingsNotifier settings;
  setUp(() async {
    sqfliteFfiInit();
    temp = await Directory.systemTemp.createTemp('dontforget-secret-test-');
    vault = _Vault();
    db = DatabaseHelper.forTesting(
      temp.path,
      databaseFactoryFfi,
      credentialStore: vault,
    );
    settings = SettingsNotifier(db);
    await settings.ready;
  });
  tearDown(() async {
    settings.dispose();
    await db.close(createBackup: false);
    await temp.delete(recursive: true);
  });
  Future<Map<String, dynamic>> row() async => Map<String, dynamic>.from(
    (await db.read(
      db.captureGeneration(),
      (sql) => sql.query('Settings'),
    )).single,
  );
  AppSettings keyed(String key) => settings.state.copyWith(apiKey: key);
  Future<void> reload() async {
    settings.dispose();
    settings = SettingsNotifier(db);
    await settings.ready;
  }

  test(
    'secrets live only in vault; runtime state hydrates after restart',
    () async {
      await settings.updateSettings(keyed('synthetic-private-one'));
      final stored = await row();
      expect(CredentialRepository.isReference(stored['api_key']), isTrue);
      expect(jsonEncode(stored), isNot(contains('synthetic-private-one')));
      expect(vault.values.values.single, contains('synthetic-private-one'));
      expect(
        settings.state.primaryModelSettings.apiKey,
        'synthetic-private-one',
      );
      await reload();
      expect(settings.state.apiKey, 'synthetic-private-one');
      expect(settings.credentialStatus, CredentialStatus.secured);
    },
  );
  test(
    'multiple profiles keep independent keys and credential-free metadata',
    () async {
      await settings.updateSettings(
        settings.state.copyWith(
          apiKey: 'legacy-secret',
          aiProfiles: [
            AiProfile(
              id: 'a',
              label: 'A',
              settings: AppSettings.defaults().copyWith(apiKey: 'secret-a'),
            ),
            AiProfile(
              id: 'b',
              label: 'B',
              enabled: false,
              settings: AppSettings.defaults().copyWith(
                apiKey: 'secret-b',
                baseUrl: 'https://fixture.invalid',
              ),
            ),
          ],
        ),
      );
      expect(jsonEncode(await row()), isNot(contains('secret-a')));
      expect(jsonEncode(await row()), isNot(contains('secret-b')));
      await reload();
      expect(settings.state.apiKey, 'legacy-secret');
      expect(settings.state.aiProfiles.map((p) => p.settings.apiKey), [
        'secret-a',
        'secret-b',
      ]);
    },
  );
  test(
    'language and appearance changes reuse a verified credential entry',
    () async {
      await settings.updateSettings(keyed('secret'));
      final reference = (await row())['api_key'];
      final count = vault.writes;
      await settings.updateSettings(
        settings.state.copyWith(language: 'ja', appearance: AppAppearance.dark),
      );
      expect(vault.writes, count);
      expect((await row())['api_key'], reference);
      await reload();
      expect(settings.state.language, 'ja');
      expect(settings.state.apiKey, 'secret');
    },
  );
  test(
    'legacy credentials migrate only after successful write and readback',
    () async {
      final sql = await db.database;
      await sql.update(
        'Settings',
        AppSettings.defaults().copyWith(apiKey: 'legacy-key').toJson(),
      );
      await reload();
      expect(settings.state.apiKey, 'legacy-key');
      expect(settings.credentialStatus, CredentialStatus.secured);
      expect(jsonEncode(await row()), isNot(contains('legacy-key')));
    },
  );
  for (final kind in ['write', 'readback']) {
    test(
      'legacy $kind failure preserves original row and withholds unprotected runtime keys',
      () async {
        final sql = await db.database;
        await sql.update(
          'Settings',
          AppSettings.defaults().copyWith(apiKey: 'legacy-key').toJson(),
        );
        final before = await row();
        vault.failWrite = kind == 'write';
        vault.wrongReadback = kind == 'readback';
        await reload();
        expect(await row(), before);
        expect(settings.state.apiKey, isEmpty);
        expect(settings.state.hasConfiguredExtraction, isFalse);
        expect(settings.credentialStatus, CredentialStatus.migrationPending);
        vault.failWrite = false;
        vault.wrongReadback = false;
        await settings.reloadCredentials();
        expect(settings.state.apiKey, 'legacy-key');
      },
    );
  }
  test(
    'locked secure storage never falls back to storing a new plaintext key',
    () async {
      await settings.updateSettings(keyed('old'));
      final before = await row();
      vault.failWrite = true;
      await expectLater(
        settings.updateSettings(keyed('new')),
        throwsA(isA<CredentialStorageException>()),
      );
      expect(await row(), before);
      expect(settings.state.apiKey, 'old');
    },
  );
  test(
    'settings from a locked read cannot erase credentials after the vault recovers',
    () async {
      await settings.updateSettings(keyed('preserved-secret'));
      final before = await row(), secrets = Map.of(vault.values);
      vault.failRead = true;
      await reload();
      expect(settings.state.apiKey, isEmpty);
      expect(settings.credentialStatus, CredentialStatus.unavailable);
      vault.failRead = false;
      await expectLater(
        settings.updateSettings(settings.state.copyWith(language: 'ja')),
        throwsA(isA<CredentialStorageException>()),
      );
      expect(await row(), before);
      expect(vault.values, secrets);
      await settings.reloadCredentials();
      await settings.updateSettings(settings.state.copyWith(language: 'ja'));
      expect(settings.state.apiKey, 'preserved-secret');
      expect(settings.state.language, 'ja');
      expect(vault.values, secrets);
    },
  );
  test(
    'settings from failed legacy migration cannot overwrite unhydrated keys',
    () async {
      final sql = await db.database;
      await sql.update(
        'Settings',
        AppSettings.defaults().copyWith(apiKey: 'legacy-preserved').toJson(),
      );
      vault.failWrite = true;
      await reload();
      final before = await row();
      expect(settings.credentialStatus, CredentialStatus.migrationPending);
      vault.failWrite = false;
      await expectLater(
        settings.updateSettings(settings.state.copyWith(language: 'ja')),
        throwsA(isA<CredentialStorageException>()),
      );
      expect(await row(), before);
      expect(vault.values, isEmpty);
      await settings.reloadCredentials();
      expect(settings.state.apiKey, 'legacy-preserved');
      expect(settings.credentialStatus, CredentialStatus.secured);
    },
  );
  test(
    'clearing the last stored credential requires explicit removal',
    () async {
      await settings.updateSettings(keyed('preserved-secret'));
      final before = await row(), secrets = Map.of(vault.values);
      final cleared = settings.state.copyWith(apiKey: '', aiProfiles: []);
      await expectLater(
        settings.updateSettings(cleared),
        throwsA(isA<CredentialStorageException>()),
      );
      expect(await row(), before);
      expect(vault.values, secrets);
      await settings.updateSettings(cleared, clearCredentials: true);
      expect((await row())['api_key'], isEmpty);
      expect(vault.values, isEmpty);
    },
  );
  test(
    'missing or inaccessible vault reference never becomes an API credential',
    () async {
      await settings.updateSettings(keyed('old'));
      final before = await row();
      vault.failRead = true;
      await reload();
      expect(settings.state.apiKey, isEmpty);
      expect(settings.state.hasConfiguredExtraction, isFalse);
      expect(settings.credentialStatus, CredentialStatus.unavailable);
      await expectLater(
        settings.updateSettings(settings.state.copyWith(language: 'en')),
        throwsA(isA<CredentialStorageException>()),
      );
      expect(await row(), before);
      vault.failRead = false;
      vault.values.clear();
      await settings.reloadCredentials();
      expect(settings.credentialStatus, CredentialStatus.missing);
      await settings.updateSettings(
        settings.state.copyWith(apiKey: '', aiProfiles: []),
        clearCredentials: true,
      );
      expect((await row())['api_key'], '');
    },
  );
  test('SQL cannot silently enable additional credential fallback', () async {
    await settings.updateSettings(keyed('private'));
    final sql = await db.database;
    await sql.update('Settings', {'ai_fallback_enabled': 1});
    await reload();
    expect(settings.state.apiKey, isEmpty);
    expect(settings.state.hasConfiguredExtraction, isFalse);
    expect(settings.credentialStatus, CredentialStatus.unavailable);
  });
  test(
    'endpoint metadata tampering cannot reuse another credential binding',
    () async {
      await settings.updateSettings(keyed('private'));
      final sql = await db.database;
      await sql.update('Settings', {'base_url': 'https://attacker.invalid'});
      await reload();
      expect(settings.state.apiKey, isEmpty);
      expect(settings.state.hasConfiguredExtraction, isFalse);
      expect(settings.credentialStatus, CredentialStatus.unavailable);
    },
  );
  test(
    'SQL failure rolls back reference, preserves previous key and removes provisional entry',
    () async {
      await settings.updateSettings(keyed('old'));
      final before = await row(), old = Map.of(vault.values);
      final sql = await db.database;
      await sql.execute(
        "CREATE TRIGGER reject_settings BEFORE INSERT ON Settings BEGIN SELECT RAISE(ABORT,'Synthetic failure'); END",
      );
      await expectLater(
        settings.updateSettings(keyed('new')),
        throwsA(isA<DatabaseException>()),
      );
      expect(await row(), before);
      expect(vault.values, old);
      expect(settings.state.apiKey, 'old');
      await sql.execute('DROP TRIGGER reject_settings');
    },
  );
  test(
    'old references are deleted only after commit; failed cleanup persists and survives draft edits',
    () async {
      await settings.updateSettings(keyed('old'));
      final old = (await row())['api_key'];
      vault.failDelete = true;
      final drafts = WorkspaceDrafts(db);
      await drafts.ready;
      await settings.updateSettings(keyed('new'));
      expect(settings.credentialStatus, CredentialStatus.cleanupPending);
      expect(vault.values, contains(old));
      await drafts.put('unrelated', {'keep': true});
      expect(
        (jsonDecode(
              (await row())['workspace_drafts_json'],
            )[CredentialRepository.cleanupKey]
            as List),
        hasLength(1),
      );
      drafts.dispose();
      settings.dispose();
      await db.close(createBackup: false);
      db = DatabaseHelper.forTesting(
        temp.path,
        databaseFactoryFfi,
        credentialStore: vault,
      );
      vault.failDelete = false;
      settings = SettingsNotifier(db);
      await settings.ready;
      expect(settings.state.apiKey, 'new');
      expect(vault.values, hasLength(1));
      expect(jsonDecode((await row())['workspace_drafts_json'])['unrelated'], {
        'keep': true,
      });
    },
  );
  test(
    'untrusted backup cleanup IDs cannot delete arbitrary vault credentials',
    () async {
      await settings.updateSettings(keyed('kept'));
      final reference = (await row())['api_key'];
      final before = Map.of(vault.values);
      final sql = await db.database;
      await sql.update('Settings', {
        'api_key': '',
        'ai_profiles_json': '[]',
        'workspace_drafts_json': jsonEncode({
          CredentialRepository.cleanupKey: [reference],
        }),
      });
      await reload();
      expect(vault.values, before);
      expect(settings.state.apiKey, isEmpty);
    },
  );
  test('new mirrors contain references and never secret values', () async {
    await settings.updateSettings(keyed('private-key-value'));
    await db.createMirrorBackup();
    expect(
      await File('${temp.path}/ha_snapshot.json').readAsString(),
      isNot(contains('private-key-value')),
    );
    final mirror = await databaseFactoryFfi.openDatabase(
      '${temp.path}/dont_forget_v3.mirror.db',
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      expect(
        jsonEncode(await mirror.query('Settings')),
        isNot(contains('private-key-value')),
      );
    } finally {
      await mirror.close();
    }
  });
  test(
    'settings save admitted before recovery cannot write into a new generation',
    () async {
      vault.writeBarrier = Completer<void>();
      final pending = settings.updateSettings(keyed('private'));
      await Future<void>.delayed(Duration.zero);
      final maintenance = db.beginMaintenance();
      vault.writeBarrier!.complete();
      await expectLater(pending, throwsA(isA<DatabaseAccessException>()));
      final lease = await maintenance;
      await lease.resume();
      expect((await row())['api_key'], '');
      expect(vault.values, isEmpty);
    },
  );
}
