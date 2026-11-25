import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';
import '../../services/quick_reminder_parser.dart';
import '../formatters/local_date_time.dart';
import '../theme/app_theme.dart';

Future<String?> showTaskPostponeDialog(BuildContext context, Reminder task) {
  final l10n = AppLocalizations.of(context);
  final colors = Theme.of(context).colorScheme;
  final previewNow = DateTime.now();
  final previewTrigger = task.triggerTime!;
  final previewBase = previewTrigger.isAfter(previewNow)
      ? previewTrigger
      : previewNow;
  final options = <(String key, String labelKey, IconData icon, DateTime? preview)>[
    (
      '15',
      'snooze15',
      Icons.timer_outlined,
      previewBase.add(const Duration(minutes: 15)),
    ),
    (
      '60',
      'snooze60',
      Icons.hourglass_bottom_rounded,
      previewBase.add(const Duration(hours: 1)),
    ),
    (
      'evening',
      'quickEvening',
      Icons.nightlight_outlined,
      QuickReminderParser.tonight(previewNow),
    ),
    (
      'morning',
      'quickMorning',
      Icons.wb_sunny_outlined,
      QuickReminderParser.tomorrowMorning(previewNow),
    ),
    ('custom', 'quickChoose', Icons.edit_calendar_outlined, null),
  ];
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      key: const ValueKey('task-postpone-dialog'),
      title: Text(l10n.get('quickPostpone')),
      children: [
        for (final opt in options)
          SimpleDialogOption(
            key: ValueKey('task-postpone-${opt.$1}'),
            onPressed: () => Navigator.pop(dialogContext, opt.$1),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(opt.$3, size: 18, color: colors.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l10n.get(opt.$2))),
                  if (opt.$4 != null) ...[
                    const SizedBox(width: 10),
                    Text(
                      formatLocalDateTime(opt.$4!),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                        fontFeatures: AppTheme.tabularFigures,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
