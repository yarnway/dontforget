import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';
import '../../services/quick_reminder_parser.dart';

String reminderOccurrenceKey(Reminder reminder) => reminder.occurrenceIdentity;

/// One compact, non-modal place for upcoming and due items. Never takes focus.
class ReminderNoticePanel extends StatelessWidget {
  const ReminderNoticePanel({
    super.key,
    required this.reminders,
    required this.now,
    required this.onDismiss,
    required this.onSnooze,
    required this.onComplete,
    this.onReview,
    this.onSnoozeUntil,
    this.onSkip,
    this.busyIds = const {},
  });
  final List<Reminder> reminders;
  final Set<String> busyIds;
  final DateTime now;
  final ValueChanged<Reminder> onDismiss;
  final ValueChanged<Reminder> onSnooze;
  final ValueChanged<Reminder> onComplete;
  final ValueChanged<Reminder>? onReview;
  final void Function(Reminder, DateTime)? onSnoozeUntil;
  final ValueChanged<Reminder>? onSkip;

  Future<void> _chooseSnooze(
    BuildContext context,
    String choice,
    Reminder task,
  ) async {
    final current = DateTime.now();
    DateTime? until = switch (choice) {
      '15' => current.add(const Duration(minutes: 15)),
      '60' => current.add(const Duration(hours: 1)),
      'evening' => QuickReminderParser.tonight(current),
      'morning' => QuickReminderParser.tomorrowMorning(current),
      _ => null,
    };
    if (choice == 'custom') {
      final date = await showDatePicker(
        context: context,
        initialDate: current,
        firstDate: DateTime(current.year, current.month, current.day),
        lastDate: DateTime(current.year + 10),
      );
      if (!context.mounted || date == null) return;
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(current),
      );
      if (!context.mounted || time == null) return;
      until = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    }
    if (context.mounted && until != null && until.isAfter(DateTime.now())) {
      onSnoozeUntil?.call(task, until);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (reminders.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final reminder = reminders.first;
    final busy = busyIds.contains(reminder.id);
    final upcoming = reminder.triggerTime?.isAfter(now) ?? false;
    final canReview =
        reminder.reviewNotificationsEnabled &&
        reminder.spacedRepetitionLevel > 0 &&
        !reminder.isCompleted &&
        onReview != null;
    final categoryCount = reminders
        .where((item) => (item.triggerTime?.isAfter(now) ?? false) == upcoming)
        .length;
    return Container(
      key: const ValueKey('reminder-notice-panel'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.notifications_none_rounded,
                size: 18,
                color: colors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${l10n.get(upcoming ? 'upcomingReminder' : 'dueReminder')} · $categoryCount',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              IconButton(
                tooltip: l10n.get('dismissReminderHint'),
                onPressed: busy ? null : () => onDismiss(reminder),
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Text(
            reminder.taskTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (upcoming)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                l10n.get('upcomingReminderHint'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else
            Wrap(
              spacing: 4,
              children: [
                if (canReview)
                  FilledButton.tonalIcon(
                    key: const ValueKey('notice-start-review'),
                    onPressed: busy ? null : () => onReview!(reminder),
                    icon: const Icon(Icons.school_outlined, size: 18),
                    label: Text(l10n.get('startReview')),
                  ),
                TextButton(
                  onPressed: busy ? null : () => onSnooze(reminder),
                  child: Text(l10n.get('snooze5Min')),
                ),
                if (onSnoozeUntil != null)
                  PopupMenuButton<String>(
                    key: const ValueKey('snooze-options'),
                    tooltip: l10n.get('snoozeMore'),
                    enabled: !busy,
                    onSelected: (choice) =>
                        _chooseSnooze(context, choice, reminder),
                    itemBuilder: (_) => [
                      for (final entry in const {
                        '15': 'snooze15',
                        '60': 'snooze60',
                        'evening': 'quickEvening',
                        'morning': 'quickMorning',
                        'custom': 'quickChoose',
                      }.entries)
                        PopupMenuItem(
                          value: entry.key,
                          child: Text(l10n.get(entry.value)),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(l10n.get('snoozeMore')),
                    ),
                  ),
                if (reminder.isRecurring && onSkip != null)
                  TextButton(
                    onPressed: busy ? null : () => onSkip!(reminder),
                    child: Text(l10n.get('skipOccurrence')),
                  ),
                TextButton(
                  onPressed: busy ? null : () => onComplete(reminder),
                  child: Text(l10n.get('markDone')),
                ),
                TextButton(
                  onPressed: busy ? null : () => onDismiss(reminder),
                  child: Text(l10n.get('iKnow')),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
