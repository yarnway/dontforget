import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/planning_strings.dart';
import '../../models/notification_schedule_status.dart';
import '../../providers/providers.dart';
import '../../services/notification_window.dart';
import '../formatters/notification_coverage.dart';
import '../screens/notification_repair_screen.dart';

class RoutineCoveragePanel extends ConsumerStatefulWidget {
  const RoutineCoveragePanel({super.key, required this.planId});
  final String planId;
  @override
  ConsumerState<RoutineCoveragePanel> createState() =>
      _RoutineCoveragePanelState();
}

class _RoutineCoveragePanelState extends ConsumerState<RoutineCoveragePanel>
    with WidgetsBindingObserver {
  late Future<NotificationScheduleStatus> _snapshot;
  Future<NotificationScheduleStatus> _read() =>
      ref.read(routineScheduleStatusReaderProvider)(widget.planId);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _snapshot = _read();
  }

  @override
  void didUpdateWidget(covariant RoutineCoveragePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _snapshot = _read();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _refresh() {
    final snapshot = _read();
    setState(() {
      _snapshot = snapshot;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _repair() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const NotificationRepairScreen()),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(remindersProvider, (_, _) {
      if (mounted) _refresh();
    });
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FutureBuilder<NotificationScheduleStatus>(
          future: _snapshot,
          builder: (context, result) {
            final status = result.data;
            if (result.hasError) {
              return Text(l10n.get('notificationScheduleUnavailable'));
            }
            if (status == null) {
              return Text(l10n.get('notificationScheduleChecking'));
            }
            if (NotificationWindow.platformLimit == null) {
              return Text(planningText(context, 'inAppOnly'));
            }
            return Text(formatNotificationCoverage(l10n, status));
          },
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: _repair,
              icon: const Icon(Icons.notifications_outlined),
              label: Text(planningText(context, 'checkCoverage')),
            ),
            IconButton(
              onPressed: _refresh,
              tooltip: l10n.get('reminderStatusRefresh'),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ],
    );
  }
}
