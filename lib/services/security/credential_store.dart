import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class CredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// No plaintext fallback and no automatic reset of inaccessible credentials.
class SystemCredentialStore implements CredentialStore {
  const SystemCredentialStore();
  static const operationTimeout = Duration(seconds: 8);
  static const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: false,
      storageNamespace: 'dontforget.ai.v1',
    ),
    iOptions: IOSOptions(
      accountName: 'dontforget.ai.v1',
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
    mOptions: MacOsOptions(
      accountName: 'dontforget.ai.v1',
      synchronizable: false,
      // Current desktop builds are ad hoc signed. Use the OS login Keychain;
      // Data Protection Keychain requires a provisioned signing identity.
      // The locked darwin 0.4.3 includes the classic-query fixes from #1241.
      usesDataProtectionKeychain: false,
    ),
  );
  @override
  Future<String?> read(String key) =>
      storage.read(key: key).timeout(operationTimeout);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value).timeout(operationTimeout);
  @override
  Future<void> delete(String key) =>
      storage.delete(key: key).timeout(operationTimeout);
}

/// An isolated OS-store substitute. Never selected by a production helper.
class MemoryCredentialStore implements CredentialStore {
  MemoryCredentialStore();
  static final _testNamespaces = <String, MemoryCredentialStore>{};
  factory MemoryCredentialStore.forTesting(String directory) {
    String canonical;
    try {
      canonical = Directory(directory).resolveSymbolicLinksSync();
    } catch (_) {
      canonical = Directory(directory).absolute.path;
    }
    return _testNamespaces.putIfAbsent(canonical, MemoryCredentialStore.new);
  }
  final values = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read(String key) async {
    if (fail) throw StateError('Synthetic secure storage failure');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (fail) throw StateError('Synthetic secure storage failure');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (fail) throw StateError('Synthetic secure storage failure');
    values.remove(key);
  }
}
