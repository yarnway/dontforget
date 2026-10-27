import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/planning_strings.dart';
import '../../models/notification_schedule_status.dart';
import '../../providers/providers.dart';
import '../../services/notification_window.dart';
import '../formatters/local_date_time.dart';
import '../screens/notification_repair_screen.dart';

class RoutineCoveragePanel extends ConsumerStatefulWidget {
  const RoutineCoveragePanel({super.key, required this.planId});
  final String planId;
  @override
  ConsumerState<RoutineCoveragePanel> createState() =>
      _RoutineCoveragePanelState();
}

class _RoutineCoveragePanelState extends ConsumerState<RoutineCoveragePanel> {
  late Future<NotificationScheduleStatus> _snapshot;
  Future<NotificationScheduleStatus> _read() =>
      ref.read(routineScheduleStatusReaderProvider)(widget.planId);
  @override
  void initState() {
    super.initState();
    _snapshot = _read();
  }

  @override
  void didUpdateWidget(covariant RoutineCoveragePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.planId != widget.planId) _snapshot = _read();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(remindersProvider, (_, _) {
      if (mounted) setState(() => _snapshot = _read());
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
            return Text(
              l10n
                  .get('notificationScheduleWindow')
                  .replaceAll(
                    '{through}',
                    status.scheduledThrough == null
                        ? '—'
                        : formatLocalDateTime(status.scheduledThrough!),
                  )
                  .replaceAll('{deferred}', '${status.deferred}')
                  .replaceAll('{capacity}', '${status.capacity}'),
            );
          },
        ),
        TextButton.icon(
          onPressed: notificationRepairAction(context).onPressed,
          icon: const Icon(Icons.notifications_outlined),
          label: Text(planningText(context, 'checkCoverage')),
        ),
      ],
    );
  }
}
