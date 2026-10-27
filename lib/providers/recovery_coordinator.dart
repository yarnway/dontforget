import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/reminder.dart';
import '../services/recovery/backup_inspector.dart';
import '../services/recovery/database_recovery.dart';
import '../services/recovery/runtime_gate.dart';
import 'home_controller.dart';
import 'workspace_drafts_provider.dart';
import 'providers.dart';

enum RecoveryPhase {
  idle,
  quiescing,
  restoring,
  reloading,
  succeeded,
  rolledBack,
  notApplied,
  blocked,
}

class RecoveryFlowState {
  const RecoveryFlowState(this.phase, {this.rollbackDirectory});
  final RecoveryPhase phase;
  final String? rollbackDirectory;
  bool get working => const {
    RecoveryPhase.quiescing,
    RecoveryPhase.restoring,
    RecoveryPhase.reloading,
  }.contains(phase);
  bool get terminal => const {
    RecoveryPhase.succeeded,
    RecoveryPhase.rolledBack,
    RecoveryPhase.notApplied,
    RecoveryPhase.blocked,
  }.contains(phase);
}

final databaseRecoveryProvider = Provider<DatabaseRecovery>((ref) {
  return DatabaseRecovery(
    ref.read(databaseHelperProvider),
    notifications: ref.read(notificationServiceProvider),
  );
});

final recoveryCoordinatorProvider = ChangeNotifierProvider<RecoveryCoordinator>(
  (ref) => RecoveryCoordinator(ref),
);

/// Coordinates one confirmed replacement. The engine owns durable file and
/// notification decisions; this layer owns live producers and the UI session.
class RecoveryCoordinator extends ChangeNotifier {
  RecoveryCoordinator(this._ref);
  final Ref _ref;
  RecoveryFlowState _state = const RecoveryFlowState(RecoveryPhase.idle);
  RecoveryFlowState get state => _state;
  int _navigationEpoch = 0;
  int get navigationEpoch => _navigationEpoch;
  bool _preparing = false;
  bool _disposed = false;

  Future<RecoveryPlan> prepare(File source, BackupPreview preview) async {
    if (_preparing || _state.phase != RecoveryPhase.idle) {
      throw StateError('Recovery is already active.');
    }
    _preparing = true;
    try {
      return await _ref
          .read(databaseRecoveryProvider)
          .prepare(source, expectedDigest: preview.digest);
    } finally {
      _preparing = false;
    }
  }

  void _publish(
    RecoveryPhase phase, {
    String? rollbackDirectory,
    bool reset = false,
  }) {
    if (_disposed) return;
    _state = RecoveryFlowState(phase, rollbackDirectory: rollbackDirectory);
    if (reset) _navigationEpoch++;
    notifyListeners();
  }

  Future<void> restore(RecoveryPlan plan) async {
    if (_preparing || _state.phase != RecoveryPhase.idle) {
      throw StateError('Recovery is already active.');
    }
    _publish(RecoveryPhase.quiescing);
    final gate = _ref.read(runtimeRecoveryGateProvider);
    final lan = _ref.read(lanSyncServiceProvider);
    final notifications = _ref.read(notificationServiceProvider);
    RuntimeRecoveryToken? pauseToken;
    var phase = RecoveryPhase.succeeded;
    String? rollbackDirectory;
    try {
      // Freeze reminder delivery before waiting for any native producer cleanup.
      // All three pauses start synchronously and every failure is observed.
      final pausedNotifications = Future<void>.sync(
        notifications.pauseForMaintenance,
      );
      final pausing = Future<RuntimeRecoveryToken>.sync(gate.pause);
      // Invalidate transport now so old AI chains cannot keep sending.
      _ref.invalidate(multiAgentServiceProvider);
      _ref.invalidate(llmServiceProvider);
      _ref.invalidate(studyPlanServiceProvider);
      final stopped = Future<void>.sync(lan.pauseForRecovery);
      // Observe every failure even if one fails first. No replacement can start
      // until all registered producers and LAN handlers have stopped.
      final waits = await Future.wait<Object?>([
        pausing,
        stopped,
        pausedNotifications,
      ]);
      pauseToken = waits.first as RuntimeRecoveryToken;
      _ref.read(contextTriggerServiceProvider).resetForRecovery();
      _publish(RecoveryPhase.restoring);
      try {
        final result = await _ref
            .read(databaseRecoveryProvider)
            .restorePlan(plan);
        rollbackDirectory = result.rollbackDirectory;
      } on DatabaseRecoveryException catch (error) {
        rollbackDirectory = error.rollbackDirectory;
        if (!error.canContinue) rethrow;
        phase = error.outcome == RecoveryFailureOutcome.rolledBack
            ? RecoveryPhase.rolledBack
            : RecoveryPhase.notApplied;
      }
      // A stale/consumed plan can be rejected before the engine takes its own
      // lease. In that case our early pause still needs a safe current rebuild.
      // Normal engine success/rollback has already resumed notifications once.
      await _resumeNotificationsIfNeeded();
      _publish(RecoveryPhase.reloading);
      await _reloadProviders();
      // LAN remains stopped; only permit a new explicit start with a new PIN.
      lan.resumeAfterRecovery();
      gate.resume(pauseToken);
      _publish(phase, rollbackDirectory: rollbackDirectory, reset: true);
      // Old controller work stays tied to its invalid runtime epoch. A fresh
      // controller is created when the user enters the rebuilt workspace.
      _ref.invalidate(homeControllerProvider);
    } catch (_) {
      // Some data decisions may already be committed. Do not invent rollback,
      // resume producers, or let stale state remain usable on a partial reload.
      try {
        await _ref.read(notificationServiceProvider).pauseForMaintenance();
      } catch (_) {}
      _publish(
        RecoveryPhase.blocked,
        rollbackDirectory: rollbackDirectory ?? plan.rollbackDirectory,
        reset: true,
      );
    }
  }

  Future<void> _resumeNotificationsIfNeeded() async {
    final notifications = _ref.read(notificationServiceProvider);
    if (!notifications.isPausedForMaintenance) return;
    final database = _ref.read(databaseHelperProvider);
    // Drain any last admitted UI write and expire queued work before taking the
    // snapshot. This path never replaces files or creates mirror backups.
    final lease = await database.beginMaintenance();
    try {
      await lease.validateAndOpen();
      final rows = await lease.read((db) => db.query('Reminders'));
      await notifications.resumeFromReminders(rows.map(Reminder.fromJson));
      await lease.resume();
    } catch (_) {
      lease.fail();
      rethrow;
    }
  }

  Future<void> _reloadProviders() async {
    _ref.invalidate(workspaceDraftsProvider);
    _ref.invalidate(settingsProvider);
    await _ref.read(settingsProvider.notifier).ready;
    _ref.invalidate(mediaRecordsProvider);
    await _ref.read(mediaRecordsProvider.notifier).ready;
    _ref.invalidate(remindersProvider);
    await _ref.read(remindersProvider.notifier).ready;
    // Context policy is session-local; keep it, but discard old task digests.
    _ref.invalidate(contextProfileProvider);
  }

  void acknowledge() {
    if (!_state.terminal || _state.phase == RecoveryPhase.blocked) return;
    _publish(RecoveryPhase.idle, reset: true);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
