import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/database_helper.dart';
import '../../../l10n/app_localizations.dart';
import '../../../models/reminder.dart';
import '../../../providers/providers.dart';
import '../../../services/lan_sync_service.dart';
import '../../../services/recovery/runtime_gate.dart';
import '../../screens/task_detail_screen.dart';
import '../../theme/app_theme.dart';
import '../editable_text_menu.dart';
import '../inline_feedback.dart';
import '../lan_sync_conflicts_dialog.dart';

/// Self-contained LAN peer-to-peer sync card with server toggle, PIN display,
/// peer sync trigger, and non-blocking conflict resolution.
class LanSyncSection extends ConsumerStatefulWidget {
  const LanSyncSection({
    super.key,
    required this.generation,
    required this.birth,
    this.onBusyChanged,
  });

  final DataGeneration generation;
  final RuntimeRecoveryToken birth;
  final ValueChanged<bool>? onBusyChanged;

  @override
  ConsumerState<LanSyncSection> createState() => _LanSyncSectionState();
}

class _LanSyncSectionState extends ConsumerState<LanSyncSection> {
  bool _isLanServerRunning = false;
  bool _lanServerChanging = false;
  String _lanIp = '';
  String _lanPin = '';
  int _lanPort = LanSyncService.defaultPort;
  final _targetIpController = TextEditingController();
  final _targetPinController = TextEditingController();
  bool _isSyncing = false;
  bool _applyingLanConflict = false;
  List<LanSyncConflict> _lanConflicts = const [];

  bool get _syncCurrent =>
      mounted &&
      ref.read(databaseHelperProvider).isCurrent(widget.generation) &&
      ref.read(runtimeRecoveryGateProvider).isCurrent(widget.birth);

  bool get _isBusy => _isSyncing || _applyingLanConflict || _lanServerChanging;

  void _notifyBusy() => widget.onBusyChanged?.call(_isBusy);

  @override
  void initState() {
    super.initState();
    final lanSync = ref.read(lanSyncServiceProvider);
    _isLanServerRunning = lanSync.isRunning;
    _lanIp = lanSync.localIp;
    _lanPin = lanSync.pin;
    _lanPort = lanSync.port;
  }

  @override
  void dispose() {
    _targetIpController.dispose();
    _targetPinController.dispose();
    super.dispose();
  }

  Future<void> _toggleLanServer() async {
    if (!_syncCurrent || _lanServerChanging) return;
    final lanSync = ref.read(lanSyncServiceProvider);
    final dbHelper = ref.read(databaseHelperProvider);
    final container = ProviderScope.containerOf(context, listen: false);
    final wasRunning = _isLanServerRunning;
    setState(() => _lanServerChanging = true);
    _notifyBusy();
    try {
      if (wasRunning) {
        await lanSync.stopServer();
        if (!_syncCurrent) return;
        setState(() {
          _isLanServerRunning = false;
          _lanPin = '';
        });
      } else {
        final reminders = ref.read(remindersProvider.notifier);
        final info = await lanSync.startServer(
          dbHelper: dbHelper,
          onDataChanged: () {
            if (reminders.mounted) {
              reminders.refreshReminders().catchError((Object _) {});
            }
            try {
              if (container.exists(mediaRecordsProvider)) {
                final media = container.read(mediaRecordsProvider.notifier);
                if (media.mounted) {
                  media.refreshMediaRecords().catchError((Object _) {});
                }
              }
            } catch (_) {}
          },
        );
        if (!_syncCurrent) return;
        setState(() {
          _isLanServerRunning = info.isRunning;
          _lanIp = info.ip;
          _lanPin = info.pin;
          _lanPort = info.port;
        });
      }
    } catch (_) {
      if (mounted && _syncCurrent) {
        setState(() => _isLanServerRunning = lanSync.isRunning);
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(
                context,
              ).get(wasRunning ? 'syncServerStopFailed' : 'syncServerFailed'),
            ),
          ),
          tone: FeedbackTone.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _lanServerChanging = false);
        _notifyBusy();
      }
    }
  }

  Future<void> _syncWithTarget() async {
    if (!_syncCurrent || _isSyncing || _applyingLanConflict) return;
    final l10n = AppLocalizations.of(context);
    final address = LanSyncService.parsePeerAddress(_targetIpController.text);
    final pin = _targetPinController.text.trim();
    if (address == null || pin.isEmpty) {
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.get(address == null ? 'syncInvalidAddress' : 'enterPin'),
          ),
        ),
        tone: FeedbackTone.error,
      );
      return;
    }

    setState(() {
      _isSyncing = true;
      _lanConflicts = const [];
    });
    _notifyBusy();
    final lanSync = ref.read(lanSyncServiceProvider);
    final dbHelper = ref.read(databaseHelperProvider);
    final container = ProviderScope.containerOf(context, listen: false);

    final reminders = ref.read(remindersProvider.notifier);
    Future<void>? refresh;
    List<LanSyncConflict> conflicts = const [];
    LanSyncFailure? failure;
    final success = await lanSync.syncWithPeer(
      peerIp: address.host,
      port: address.port,
      pin: pin,
      dbHelper: dbHelper,
      onDataChanged: () {
        // The service verifies the storage generation before this callback.
        // A committed merge still needs a refresh if Settings has been closed.
        final futures = <Future<void>>[
          if (reminders.mounted)
            reminders.refreshReminders().catchError((Object _) {}),
        ];
        try {
          if (container.exists(mediaRecordsProvider)) {
            final media = container.read(mediaRecordsProvider.notifier);
            if (media.mounted) {
              futures.add(
                media.refreshMediaRecords().catchError((Object _) {}),
              );
            }
          }
        } catch (_) {}
        if (futures.isNotEmpty) refresh = Future.wait(futures);
      },
      onConflicts: (result) => conflicts = result,
      onFailure: (reason) => failure = reason,
    );
    try {
      await refresh;
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _isSyncing = false;
      if (success && _syncCurrent) _lanConflicts = conflicts;
    });
    _notifyBusy();
    if (!_syncCurrent) return;
    final feedback = InlineFeedback.of(context);
    feedback.hideCurrentSnackBar();
    if (_lanConflicts.isNotEmpty) {
      feedback.showSnackBar(
        SnackBar(
          content: Text(
            '${l10n.get('syncConflictTitle')} (${_lanConflicts.length})',
          ),
        ),
        tone: FeedbackTone.warning,
      );
      return;
    }
    final failureKey = switch (failure) {
      LanSyncFailure.invalidPin => 'syncFailedInvalidPin',
      LanSyncFailure.pinLocked => 'syncFailedPinLocked',
      LanSyncFailure.payloadTooLarge => 'syncFailedTooLarge',
      LanSyncFailure.timeout => 'syncFailedTimeout',
      LanSyncFailure.unreachable => 'syncFailedUnreachable',
      LanSyncFailure.storageUnavailable => 'lanSyncStorageUnavailable',
      LanSyncFailure.invalidResponse => 'lanSyncInvalidResponse',
      _ => 'syncFailed',
    };
    feedback.showSnackBar(
      SnackBar(
        content: Text(l10n.get(success ? 'syncSuccess' : failureKey)),
      ),
      tone: success ? FeedbackTone.success : FeedbackTone.error,
    );
  }

  Future<void> _copyLanValue(String text, String feedbackKey) async {
    if (text.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      InlineFeedback.of(context).showSnackBar(
        SnackBar(content: Text(l10n.get(feedbackKey))),
        tone: FeedbackTone.success,
      );
    } catch (_) {
      if (!mounted) return;
      InlineFeedback.of(context).showSnackBar(
        SnackBar(content: Text(l10n.get('linkCopyFailed'))),
        tone: FeedbackTone.error,
      );
    }
  }

  Future<void> _showLanConflicts() async {
    if (!_syncCurrent || _lanConflicts.isEmpty || _applyingLanConflict) return;
    final tasks = {
      for (final task in ref.read(remindersProvider)) task.id: task,
    };
    final openable = {
      for (final task in tasks.values)
        if (task.isVisible) task.id,
    };
    final adoptable = {
      for (final conflict in _lanConflicts)
        if (tasks[conflict.taskId] case final task?)
          if (conflict.canAdoptText(task)) task.id,
    };
    final rootsWithChildren = {
      for (final task in tasks.values)
        if (task.details.planId case final id?) id,
    };
    final trashActions = {
      for (final conflict in _lanConflicts)
        if (tasks[conflict.taskId] case final task?)
          if (!rootsWithChildren.contains(task.id) &&
              conflict.canAdoptTrash(task))
            task.id,
    };
    final choice =
        await showDialog<
          ({LanSyncConflict conflict, LanSyncConflictAction action})
        >(
          context: context,
          builder: (_) => LanSyncConflictsDialog(
            conflicts: _lanConflicts,
            openableTaskIds: openable,
            adoptableTaskIds: adoptable,
            trashActionTaskIds: trashActions,
          ),
        );
    if (!mounted || !_syncCurrent || choice == null) return;
    if (choice.action != LanSyncConflictAction.openLocal) {
      if (tasks[choice.conflict.taskId] case final expected?) {
        await _confirmLanConflict(choice.conflict, choice.action, expected);
      }
      return;
    }
    final task = ref
        .read(remindersProvider)
        .where((task) => task.id == choice.conflict.taskId && task.isVisible)
        .firstOrNull;
    if (task != null) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => TaskDetailScreen(task: task)),
      );
    }
  }

  Future<void> _confirmLanConflict(
    LanSyncConflict conflict,
    LanSyncConflictAction action,
    Reminder expected,
  ) async {
    final l10n = AppLocalizations.of(context);
    final text = action == LanSyncConflictAction.adoptPeerText;
    final toTrash = conflict.peer.inTrash;
    final title = text
        ? 'syncAdoptPeerText'
        : toTrash
        ? 'syncMoveLocalToTrash'
        : 'syncRestoreLocal';
    final message = text
        ? 'syncAdoptPeerTextConfirm'
        : toTrash
        ? 'syncMoveLocalToTrashConfirm'
        : 'syncRestoreLocalConfirm';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.get(title)),
        content: Text(l10n.get(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.get('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.get(text ? 'save' : title)),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        !_syncCurrent ||
        _applyingLanConflict ||
        !_lanConflicts.contains(conflict)) {
      return;
    }
    setState(() => _applyingLanConflict = true);
    _notifyBusy();
    final feedback = InlineFeedback.of(context);
    try {
      final notifier = ref.read(remindersProvider.notifier);
      final result = await (text
          ? notifier.adoptLanSyncText(conflict, widget.generation)
          : notifier.adoptLanSyncTrash(conflict, expected, widget.generation));
      if (!_syncCurrent) return;
      if (result.reminder case final saved?) {
        final local = LanSyncConflict.contentOf(saved);
        setState(() {
          _lanConflicts = [
            for (final item in _lanConflicts)
              if (item != conflict)
                item
              else if (local != item.peer)
                LanSyncConflict(
                  taskId: item.taskId,
                  local: local,
                  peer: item.peer,
                ),
          ];
        });
      }
      feedback.showSnackBar(
        SnackBar(
          content: Text(
            l10n.get(
              !result.accepted
                  ? 'syncConflictStale'
                  : result.nativeSyncFailed
                  ? 'reminderNativeSyncFailed'
                  : 'changesSaved',
            ),
          ),
        ),
        tone: !result.accepted || result.nativeSyncFailed
            ? FeedbackTone.warning
            : FeedbackTone.success,
      );
    } catch (_) {
      if (_syncCurrent) {
        feedback.showSnackBar(
          SnackBar(
            content: Text(
              l10n.get(
                text ? 'syncAdoptPeerTextFailed' : 'syncAdoptPeerTrashFailed',
              ),
            ),
          ),
          tone: FeedbackTone.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _applyingLanConflict = false);
        _notifyBusy();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.wifi_tethering_rounded,
                  size: 18,
                  color: colors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      l10n.get('lanSyncTitle'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                Semantics(
                  label: l10n.get('lanSyncTitle'),
                  child: Switch(
                    key: const ValueKey('lan-sync-server'),
                    value: _isLanServerRunning,
                    onChanged: _lanServerChanging
                        ? null
                        : (_) => _toggleLanServer(),
                  ),
                ),
              ],
            ),
            Text(
              l10n.get('lanSyncDesc'),
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            if (_isLanServerRunning) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceContainer,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colors.outlineVariant, width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.router_rounded,
                          size: 14,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: SelectableText(
                            '${l10n.get('lanServerRunning')}$_lanIp:$_lanPort',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              fontFeatures: AppTheme.tabularFigures,
                            ),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('lan-sync-copy-address'),
                          tooltip: l10n.get('syncCopyAddress'),
                          iconSize: 18,
                          onPressed: () => _copyLanValue(
                            '$_lanIp:$_lanPort',
                            'syncCopiedAddress',
                          ),
                          icon: const Icon(Icons.copy_outlined),
                        ),
                      ],
                    ),
                    if (_lanPort != LanSyncService.defaultPort)
                      Text(l10n.get('syncAlternativePort')),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.vpn_key_rounded,
                          size: 14,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: SelectableText(
                            '${l10n.get('syncPin')}$_lanPin',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.5,
                              fontFeatures: AppTheme.tabularFigures,
                              color: colors.primary,
                            ),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('lan-sync-copy-pin'),
                          tooltip: l10n.get('syncCopyPin'),
                          iconSize: 18,
                          onPressed: () =>
                              _copyLanValue(_lanPin, 'syncCopiedPin'),
                          icon: const Icon(Icons.copy_outlined),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const Divider(height: 20),
            Semantics(
              header: true,
              child: Text(
                l10n.get('connectToDevice'),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: const ValueKey('lan-sync-target-ip'),
                    controller: _targetIpController,
                    contextMenuBuilder: buildEditableTextMenu,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      labelText: l10n.get('enterTargetIp'),
                      hintText: '192.168.1.10:${LanSyncService.defaultPort}',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: const ValueKey('lan-sync-target-pin'),
                    controller: _targetPinController,
                    contextMenuBuilder: buildEditableTextMenu,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _syncWithTarget(),
                    style: const TextStyle(
                      fontSize: 12,
                      fontFeatures: AppTheme.tabularFigures,
                    ),
                    decoration: InputDecoration(
                      labelText: l10n.get('enterPin'),
                      hintText: '123456',
                      counterText: '',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const ValueKey('lan-sync-now'),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
                onPressed: _isSyncing || _applyingLanConflict
                    ? null
                    : _syncWithTarget,
                icon: _isSyncing
                    ? SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: colors.onSurface.withValues(alpha: 0.55),
                        ),
                      )
                    : const Icon(Icons.sync_rounded, size: 14),
                label: Text(
                  _isSyncing ? l10n.get('syncing') : l10n.get('syncNow'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            if (_lanConflicts.isNotEmpty)
              Semantics(
                container: true,
                liveRegion: true,
                child: TextButton.icon(
                  key: const ValueKey('lan-sync-conflicts'),
                  onPressed: _applyingLanConflict ? null : _showLanConflicts,
                  icon: const Icon(Icons.compare_arrows),
                  label: Text(
                    l10n
                        .get('syncConflictingTasks')
                        .replaceAll('{count}', '${_lanConflicts.length}'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
