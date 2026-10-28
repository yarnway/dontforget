import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../services/notification_diagnostics_service.dart';
import '../../services/notification_permission_service.dart';

class NotificationDiagnosticsPanel extends StatefulWidget {
  const NotificationDiagnosticsPanel({super.key, required this.service});
  final NotificationDiagnosticsService service;

  @override
  State<NotificationDiagnosticsPanel> createState() =>
      _NotificationDiagnosticsPanelState();
}

class _NotificationDiagnosticsPanelState
    extends State<NotificationDiagnosticsPanel>
    with WidgetsBindingObserver {
  NotificationDiagnosticsSnapshot? _snapshot;
  TestNotificationResult? _result;
  bool _refreshing = false, _sending = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(NotificationDiagnosticsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service == widget.service) return;
    oldWidget.service.cancelReads();
    _generation++;
    _snapshot = null;
    _result = null;
    _refreshing = false;
    _sending = false;
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _generation++;
    widget.service.cancelReads();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    final generation = _generation;
    setState(() => _refreshing = true);
    final observed = await widget.service.refresh();
    if (!mounted || generation != _generation) return;
    setState(() {
      _snapshot = observed;
      _refreshing = false;
    });
  }

  Future<void> _send() async {
    if (_sending) return;
    final generation = _generation;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _sending = true;
      _result = null;
    });
    final result = await widget.service.sendTest(
      title: l10n.get('notificationDiagnosticsTestTitle'),
      body: l10n.get('notificationDiagnosticsTestBody'),
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _result = result;
      _sending = false;
    });
    unawaited(_refresh());
  }

  String _permission(AppLocalizations l10n) =>
      l10n.get(switch (_snapshot?.permission.authorization.status) {
        NotificationPermissionStatus.granted => 'notificationPermissionGranted',
        NotificationPermissionStatus.provisional =>
          'notificationPermissionProvisional',
        NotificationPermissionStatus.notEnabled =>
          'notificationPermissionNotEnabled',
        _ => 'notificationDiagnosticsUnavailable',
      });

  String _resultKey(TestNotificationResult result) => switch (result) {
    TestNotificationResult.submitted => 'notificationDiagnosticsSubmitted',
    TestNotificationResult.permissionDenied => 'notificationDiagnosticsDenied',
    TestNotificationResult.unsupported => 'notificationDiagnosticsRuntimeHint',
    TestNotificationResult.failed => 'notificationDiagnosticsFailed',
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final unavailable = l10n.get('notificationDiagnosticsUnavailable');
    final schedule = _snapshot?.schedule;
    final pendingRepair = schedule == null
        ? unavailable
        : '${schedule.needsAttention + schedule.cancellations + schedule.overdueUnconfirmed}';
    final history = _snapshot?.failureHistory;
    final lastFailure = history?.latestFailure;
    final failureText = history?.available != true
        ? l10n
              .get('notificationDiagnosticsFailure')
              .replaceAll('{time}', unavailable)
        : lastFailure == null
        ? l10n.get('notificationDiagnosticsNoFailure')
        : l10n
              .get('notificationDiagnosticsFailure')
              .replaceAll(
                '{time}',
                DateFormat.yMd(
                  l10n.locale.languageCode,
                ).add_Hm().format(lastFailure.toLocal()),
              );
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.fact_check_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.get('notificationDiagnosticsTitle'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  key: const ValueKey('notification-diagnostics-refresh'),
                  tooltip: l10n.get('notificationPermissionRefresh'),
                  onPressed: _refreshing ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            Text(
              l10n
                  .get('notificationDiagnosticsPermission')
                  .replaceAll('{status}', _permission(l10n)),
            ),
            const SizedBox(height: 4),
            Text(
              l10n
                  .get('notificationDiagnosticsPending')
                  .replaceAll(
                    '{count}',
                    '${_snapshot?.pendingCount ?? unavailable}',
                  ),
              key: const ValueKey('notification-diagnostics-pending'),
            ),
            const SizedBox(height: 4),
            Text(
              l10n
                  .get('notificationDiagnosticsRepair')
                  .replaceAll('{count}', pendingRepair),
            ),
            const SizedBox(height: 4),
            Text(failureText),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              key: const ValueKey('notification-diagnostics-send'),
              onPressed: _sending || !widget.service.supportsNativeScheduling
                  ? null
                  : _send,
              icon: const Icon(Icons.notifications_active_outlined),
              label: Text(l10n.get('notificationDiagnosticsTest')),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.get(
                widget.service.supportsNativeScheduling
                    ? 'notificationDiagnosticsDeliveryHint'
                    : 'notificationDiagnosticsRuntimeHint',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_result != null) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  l10n.get(_resultKey(_result!)),
                  key: const ValueKey('notification-diagnostics-result'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
