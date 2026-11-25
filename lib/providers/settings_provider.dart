part of 'providers.dart';

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((
  ref,
) {
  return SettingsNotifier(ref.read(databaseHelperProvider));
});

class SettingsNotifier extends StateNotifier<AppSettings> {
  final DatabaseHelper _dbHelper;
  late final Future<void> ready;
  DataGeneration? _stateGeneration;
  Future<void> _writes = Future<void>.value();

  SettingsNotifier(this._dbHelper) : super(AppSettings.defaults()) {
    ready = _loadSettings();
    // A consumer may await ready later; still observe an early startup failure.
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  CredentialStatus credentialStatus = CredentialStatus.notConfigured;
  Future<void> _loadSettings() async {
    final generation = _dbHelper.captureGeneration();
    final loaded = await CredentialRepository(_dbHelper).load(generation);
    _dbHelper.checkGeneration(generation);
    _stateGeneration = generation;
    credentialStatus = loaded.status;
    if (mounted) state = loaded.settings;
    StartupTrace.mark('settings_loaded');
  }

  Future<void> reloadCredentials() => _write(() async {
    await ready;
    if (_stateGeneration != null) _dbHelper.checkGeneration(_stateGeneration!);
    await _loadSettings();
  });

  Future<T> _write<T>(Future<T> Function() action) {
    final operation = _writes.then((_) => action());
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<void> updateSettings(
    AppSettings newSettings, {
    bool clearCredentials = false,
  }) async {
    final generation = _dbHelper.captureGeneration();
    if (_stateGeneration != null) _dbHelper.checkGeneration(_stateGeneration!);
    return _write(() async {
      await ready;
      _dbHelper.checkGeneration(generation);
      _dbHelper.checkGeneration(_stateGeneration!);
      final loaded = await CredentialRepository(
        _dbHelper,
      ).save(newSettings, generation, clear: clearCredentials);
      _dbHelper.checkGeneration(generation);
      credentialStatus = loaded.status;
      if (mounted) state = loaded.settings;
    });
  }

  Future<void> updatePreferences({
    required AppPreferences expected,
    required AppPreferences value,
  }) async {
    final generation = _dbHelper.captureGeneration();
    return _write(() async {
      await ready;
      _dbHelper.checkGeneration(generation);
      _dbHelper.checkGeneration(_stateGeneration!);
      await CredentialRepository(
        _dbHelper,
      ).savePreferences(expected, value, generation);
      _dbHelper.checkGeneration(generation);
      if (mounted) {
        state = state.copyWith(
          language: value.language,
          appearance: value.appearance,
          inputSendMode: value.send,
        );
      }
    });
  }
}
