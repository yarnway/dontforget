part of 'providers.dart';

final llmServiceProvider = Provider<LLMService>((ref) {
  final service = LLMService();
  ref.onDispose(service.dispose);
  return service;
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService.forDatabase(ref.read(databaseHelperProvider));
});

final lanSyncServiceProvider = Provider<LanSyncService>((ref) {
  return LanSyncService.instance;
});

final dpSchedulerServiceProvider = Provider<DPSchedulerService>((ref) {
  return const DPSchedulerService();
});

final multiAgentServiceProvider = Provider<MultiAgentService>((ref) {
  final service = MultiAgentService(
    llmService: ref.read(llmServiceProvider),
    dpScheduler: ref.read(dpSchedulerServiceProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final spacedRepetitionServiceProvider = Provider<SpacedRepetitionService>((
  ref,
) {
  return const SpacedRepetitionService();
});

final dataExportServiceProvider = Provider<DataExportService>((ref) {
  return const DataExportService();
});

class ImmersiveModeNotifier extends StateNotifier<bool> {
  final NotificationService _notificationService;
  ImmersiveModeNotifier(this._notificationService) : super(false);

  void toggle() {
    state = !state;
    _notificationService.isImmersiveModeActive = state;
  }

  void setMode(bool enabled) {
    state = enabled;
    _notificationService.isImmersiveModeActive = enabled;
  }

  Future<({int attempted, int failed})> apply(bool enabled) {
    final operation = _notificationService.applyFocusMode(enabled);
    state = enabled;
    return operation;
  }
}

final immersiveModeProvider =
    StateNotifierProvider<ImmersiveModeNotifier, bool>((ref) {
      return ImmersiveModeNotifier(ref.read(notificationServiceProvider));
    });

final dynamicUrgencyServiceProvider = Provider<DynamicUrgencyService>((ref) {
  return const DynamicUrgencyService();
});

final biDirectionalLinkServiceProvider = Provider<BiDirectionalLinkService>((
  ref,
) {
  return const BiDirectionalLinkService();
});

final contextTriggerServiceProvider = Provider<ContextTriggerService>((ref) {
  return ContextTriggerService();
});

class ContextProfileNotifier extends StateNotifier<ContextProfile> {
  final ContextTriggerService _service;
  final DatabaseHelper _database;
  final NotificationService _notifications;
  ContextProfileNotifier(this._service, this._database, this._notifications)
    : super(_service.currentProfile);

  Future<void> setProfile(ContextProfile profile) async {
    final generation = _database.captureGeneration();
    final previous = _service.currentProfile;
    try {
      await _database.runOperation(generation, () async {
        _database.checkGeneration(generation);
        _service.switchProfile(profile);
        await _notifications.reconcileNotificationPolicy();
      });
      _database.checkGeneration(generation);
      if (mounted) {
        state = profile;
      } else {
        _service.switchProfile(previous);
      }
    } catch (_) {
      _service.switchProfile(previous);
      rethrow;
    }
  }
}

final contextProfileProvider =
    StateNotifierProvider<ContextProfileNotifier, ContextProfile>((ref) {
      return ContextProfileNotifier(
        ref.read(contextTriggerServiceProvider),
        ref.read(databaseHelperProvider),
        ref.read(notificationServiceProvider),
      );
    });
