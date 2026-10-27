import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/providers.dart';
import '../widgets/notification_permission_panel.dart';

/// Opens the existing permission, queue and retry controls at the point of failure.
class NotificationRepairScreen extends ConsumerWidget {
  const NotificationRepairScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.get('repairNotifications'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(loc.get('notificationRepairHint')),
                NotificationPermissionPanel(
                  onReadSystemNotifications: ref
                      .read(notificationServiceProvider)
                      .readSystemNotifications,
                  onReadScheduleStatus: ref.read(
                    notificationScheduleStatusReaderProvider,
                  ),
                  onRetryReminders: () => ref
                      .read(remindersProvider.notifier)
                      .retryNotificationDelivery(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

SnackBarAction notificationRepairAction(BuildContext context) {
  final navigator = Navigator.of(context);
  return SnackBarAction(
    label: AppLocalizations.of(context).get('repairNotifications'),
    onPressed: () => navigator.push(
      MaterialPageRoute<void>(builder: (_) => const NotificationRepairScreen()),
    ),
  );
}
