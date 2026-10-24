import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/notification_schedule_status.dart';
import '../../services/notification_permission_service.dart';
import '../../services/system_notification_reader.dart';

/// Permission checks never display an operating-system prompt. Requests are
/// explicit buttons, and returning from system settings refreshes this panel.
class NotificationPermissionPanel extends StatefulWidget {
  const NotificationPermissionPanel({
    super.key,
    this.service,
    this.onRetryReminders,
    this.onReadScheduleStatus,
    this.onReadSystemNotifications,
  });

  final NotificationPermissionService? service;
  final Future<NotificationScheduleStatus> Function()? onReadScheduleStatus;
  final Future<SystemNotificationSnapshot> Function()?
  onReadSystemNotifications;
  final Future<({int attempted, int failed})> Function()? onRetryReminders;

  @override
  State<NotificationPermissionPanel> createState() =>
      _NotificationPermissionPanelState();
}

class _NotificationPermissionPanelState
    extends State<NotificationPermissionPanel>
    with WidgetsBindingObserver {
  static const _observationTimeout = Duration(seconds: 3);
  late NotificationPermissionService _service;
  NotificationPermissionSnapshot? _snapshot;
  bool _busy = false;
  bool _refreshQueued = false;
  int _generation = 0;
  ({int attempted, int failed})? _retryResult;
  bool _retryFailed = false;
  NotificationScheduleStatus? _schedule;
  bool _scheduleFailed = false;
  SystemNotificationSnapshot? _system;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? NotificationPermissionService();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run(_service.refresh));
  }

  @override
  void didUpdateWidget(NotificationPermissionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service ||
        oldWidget.onReadSystemNotifications !=
            widget.onReadSystemNotifications) {
      _generation++;
      _busy = false;
      _refreshQueued = false;
      _snapshot = null;
      _schedule = null;
      _scheduleFailed = false;
      _system = null;
      _retryResult = null;
      _retryFailed = false;
      _service = widget.service ?? NotificationPermissionService();
      unawaited(_run(_service.refresh));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_busy) {
      _refreshQueued = true;
    } else {
      unawaited(_run(_service.refresh));
    }
  }

  Future<void> _run(
    Future<NotificationPermissionSnapshot> Function() operation,
  ) async {
    if (_busy) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      // Manual retry feedback describes that attempt, not the current queue.
      // A later refresh may follow a successful automatic retry.
      _retryResult = null;
      _retryFailed = false;
    });
    final result = await operation();
    if (!mounted || generation != _generation) return;
    await _readObservations(generation, result.canRequestNotifications);
    if (!mounted || generation != _generation) return;
    setState(() {
      _snapshot = result;
      _busy = false;
    });
    if (_refreshQueued) {
      _refreshQueued = false;
      unawaited(_run(_service.refresh));
    }
  }

  Future<void> _retryReminders() async {
    final retry = widget.onRetryReminders;
    if (_busy || retry == null) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _retryResult = null;
      _retryFailed = false;
    });
    ({int attempted, int failed})? result;
    var failed = false;
    try {
      result = await retry();
    } catch (_) {
      failed = true;
    }
    if (!mounted || generation != _generation) return;
    await _readObservations(
      generation,
      _snapshot?.canRequestNotifications ?? false,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _retryResult = result;
      _retryFailed = failed;
      _busy = false;
    });
    if (_refreshQueued) {
      _refreshQueued = false;
      unawaited(_run(_service.refresh));
    }
  }

  Future<void> _readSchedule(int generation, {required bool supported}) async {
    final read = widget.onReadScheduleStatus;
    if (read == null || !supported) return;
    NotificationScheduleStatus? value;
    var failed = false;
    try {
      value = await read().timeout(_observationTimeout);
    } catch (_) {
      failed = true;
    }
    if (!mounted || generation != _generation) return;
    _schedule = value;
    _scheduleFailed = failed;
  }

  Future<void> _readObservations(int generation, bool supported) =>
      Future.wait([
        _readSchedule(generation, supported: supported),
        _readSystem(generation, supported: supported),
      ]);

  Future<void> _readSystem(int generation, {required bool supported}) async {
    final read = widget.onReadSystemNotifications;
    if (read == null || !supported) return;
    SystemNotificationSnapshot value;
    try {
      value = await read().timeout(_observationTimeout);
    } catch (_) {
      value = SystemNotificationSnapshot(supported: true);
    }
    if (!mounted || generation != _generation) return;
    _system = value;
  }

  String _statusKey(NotificationPermissionStatus status) => switch (status) {
    NotificationPermissionStatus.granted => 'notificationPermissionGranted',
    NotificationPermissionStatus.provisional =>
      'notificationPermissionProvisional',
    NotificationPermissionStatus.notEnabled =>
      'notificationPermissionNotEnabled',
    NotificationPermissionStatus.unknown => 'notificationPermissionUnknown',
    NotificationPermissionStatus.unsupported =>
      'notificationPermissionUnsupported',
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final snapshot = _snapshot;
    final status = snapshot?.authorization.status;
    final canRequest = snapshot?.canRequestNotifications ?? false;
    final retryResult = _retryResult;
    final retryMessage = _retryFailed
        ? l10n.get('notificationRetryFailed')
        : retryResult == null
        ? null
        : l10n
              .get(
                retryResult.failed > 0
                    ? 'notificationRetryPartial'
                    : retryResult.attempted == 0
                    ? 'notificationRetryEmpty'
                    : 'notificationRetryFinished',
              )
              .replaceAll('{failed}', '${retryResult.failed}')
              .replaceAll('{total}', '${retryResult.attempted}');
    return Card(
      key: const ValueKey('notification-permission-panel'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.notifications_outlined, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.get('notificationPermissionTitle'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Semantics(
              liveRegion: true,
              child: Text(
                l10n.get(
                  status == null
                      ? 'notificationPermissionChecking'
                      : _statusKey(status),
                ),
                key: const ValueKey('notification-permission-status'),
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.get(
                snapshot == null || canRequest
                    ? 'notificationPermissionHint'
                    : 'notificationPermissionUnsupportedHint',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (snapshot?.authorization.alertsEnabled == false ||
                snapshot?.authorization.soundsEnabled == false)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(l10n.get('notificationPermissionPresentationHint')),
              ),
            if (snapshot?.supportsExactAlarms ?? false) ...[
              const Divider(height: 24),
              Text(
                '${l10n.get('notificationExactAlarmTitle')}: '
                '${l10n.get(_statusKey(snapshot!.exactAlarms))}',
                key: const ValueKey('notification-exact-alarm-status'),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.get('notificationExactAlarmHint'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (canRequest && widget.onReadScheduleStatus != null) ...[
              const Divider(height: 24),
              Text(
                l10n.get('notificationScheduleTitle'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Semantics(
                liveRegion: true,
                child: Text(
                  _scheduleFailed
                      ? l10n.get('notificationScheduleUnavailable')
                      : _schedule == null
                      ? l10n.get('notificationScheduleChecking')
                      : l10n
                            .get('notificationScheduleSummary')
                            .replaceAll('{upcoming}', '${_schedule!.upcoming}')
                            .replaceAll(
                              '{submitted}',
                              '${_schedule!.submitted}',
                            )
                            .replaceAll(
                              '{attention}',
                              '${_schedule!.needsAttention}',
                            )
                            .replaceAll(
                              '{cancellations}',
                              '${_schedule!.cancellations}',
                            ),
                  key: const ValueKey('notification-schedule-status'),
                ),
              ),
              if ((_schedule?.overdueUnconfirmed ?? 0) > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    l10n
                        .get('notificationScheduleOverdue')
                        .replaceAll(
                          '{count}',
                          '${_schedule!.overdueUnconfirmed}',
                        ),
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                l10n.get('notificationScheduleHint'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (canRequest && widget.onReadSystemNotifications != null) ...[
              const Divider(height: 24),
              Text(
                l10n.get('notificationSystemTitle'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(
                _busy || _system == null
                    ? l10n.get('notificationSystemChecking')
                    : l10n
                          .get('notificationSystemSummary')
                          .replaceAll(
                            '{pending}',
                            '${_system!.pending?.length ?? '—'}',
                          )
                          .replaceAll(
                            '{retained}',
                            '${_system!.retained?.length ?? '—'}',
                          ),
                key: const ValueKey('notification-system-status'),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.get('notificationSystemHint'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (!_busy && (_system?.retained?.isNotEmpty ?? false))
                Semantics(
                  container: true,
                  explicitChildNodes: true,
                  child: ExpansionTile(
                    key: const ValueKey('notification-system-retained'),
                    internalAddSemanticForOnTap: true,
                    tilePadding: EdgeInsets.zero,
                    title: Text(l10n.get('notificationSystemRetainedTitles')),
                    children: [
                      for (final entry in _system!.retained!.take(3))
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            entry.title?.trim().isNotEmpty == true
                                ? entry.title!
                                : l10n.get('notificationSystemUntitled'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
            if (snapshot?.requestFailed ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.get('notificationPermissionRequestFailed'),
                  style: TextStyle(color: colors.error),
                ),
              ),
            if (retryMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    retryMessage,
                    key: const ValueKey('notification-retry-result'),
                    style: TextStyle(
                      color: _retryFailed || (retryResult?.failed ?? 0) > 0
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (canRequest &&
                    status != NotificationPermissionStatus.granted)
                  FilledButton.tonal(
                    key: const ValueKey('notification-permission-request'),
                    onPressed: _busy
                        ? null
                        : () => _run(_service.requestNotifications),
                    child: Text(l10n.get('notificationPermissionRequest')),
                  ),
                if ((snapshot?.supportsExactAlarms ?? false) &&
                    snapshot!.exactAlarms !=
                        NotificationPermissionStatus.granted)
                  OutlinedButton(
                    key: const ValueKey('notification-exact-alarm-request'),
                    onPressed: _busy
                        ? null
                        : () => _run(_service.requestExactAlarms),
                    child: Text(l10n.get('notificationExactAlarmRequest')),
                  ),
                TextButton.icon(
                  key: const ValueKey('notification-permission-refresh'),
                  onPressed: _busy ? null : () => _run(_service.refresh),
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(l10n.get('notificationPermissionRefresh')),
                ),
                if (canRequest && widget.onRetryReminders != null)
                  OutlinedButton(
                    key: const ValueKey('notification-reminders-retry'),
                    onPressed: _busy ? null : _retryReminders,
                    child: Text(l10n.get('notificationRetryReminders')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
