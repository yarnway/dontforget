import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';

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
    this.busyIds = const {},
  });
  final List<Reminder> reminders;
  final Set<String> busyIds;
  final DateTime now;
  final ValueChanged<Reminder> onDismiss;
  final ValueChanged<Reminder> onSnooze;
  final ValueChanged<Reminder> onComplete;
  final ValueChanged<Reminder>? onReview;

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
                tooltip: l10n.get('iKnow'),
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
