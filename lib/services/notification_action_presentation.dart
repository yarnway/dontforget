import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../l10n/app_localizations.dart';

/// Platform categories share action IDs, while recurrence and language remain
/// explicit so a one-off notification never exposes a skip action.
abstract final class NotificationActionPresentation {
  static List<String> ids(bool recurring) => [
    'complete',
    'snooze_15',
    'snooze_60',
    if (recurring) 'skip_occurrence',
  ];

  static String title(String id, String language) =>
      AppLocalizations(Locale(language)).get(switch (id) {
        'complete' => 'notificationActionComplete',
        'snooze_15' => 'snooze15',
        'snooze_60' => 'snooze60',
        _ => 'skipOccurrence',
      });

  static String category(String platform, bool recurring, String language) =>
      'dontforget_${platform}_${recurring ? 'recurring' : 'once'}_$language';

  static List<DarwinNotificationCategory> categories(
    String platform,
    String language,
  ) => [
    for (final recurring in [false, true])
      DarwinNotificationCategory(
        category(platform, recurring, language),
        actions: [
          for (final id in ids(recurring))
            DarwinNotificationAction.plain(id, title(id, language)),
        ],
      ),
  ];

  static List<AndroidNotificationAction> android(
    bool recurring,
    String language,
  ) => [
        // Android's standard template can display at most three actions.
        // Recurring tasks keep skip; the one-hour option remains in the app.
        for (final id in recurring
            ? ['complete', 'snooze_15', 'skip_occurrence']
            : ids(false))
      AndroidNotificationAction(id, title(id, language)),
  ];
}
