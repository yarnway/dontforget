import '../../l10n/app_localizations.dart';
import '../../models/notification_schedule_status.dart';
import 'local_date_time.dart';

String formatNotificationCoverage(
  AppLocalizations l10n,
  NotificationScheduleStatus status,
) {
  final key = status.upcoming == 0
      ? 'notificationScheduleWindowEmpty'
      : status.scheduledThrough == null
      ? 'notificationScheduleWindowUnconfirmed'
      : 'notificationScheduleWindow';
  return l10n
      .get(key)
      .replaceAll(
        '{through}',
        status.scheduledThrough == null
            ? ''
            : formatLocalDateTime(status.scheduledThrough!),
      )
      .replaceAll('{deferred}', '${status.deferred}')
      .replaceAll('{capacity}', '${status.capacity}');
}
