import 'dart:math' as math;
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
    final actionTextStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      fontSize: 14,
      height: 1.25,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final baseActionStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(
        Size(
          0,
          math.max(44, MediaQuery.textScalerOf(context).scale(14) * 1.25 + 20),
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      textStyle: WidgetStatePropertyAll(actionTextStyle),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      alignment: Alignment.center,
    );
    final upcoming = reminder.triggerTime?.isAfter(now) ?? false;
    final canReview =
        reminder.reviewNotificationsEnabled &&
        reminder.spacedRepetitionLevel > 0 &&
        !reminder.isCompleted &&
        onReview != null;
    final categoryCount = reminders
        .where((item) => (item.triggerTime?.isAfter(now) ?? false) == upcoming)
        .length;
    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: Container(
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
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  reminder.taskTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (!upcoming)
                LayoutBuilder(
                  builder: (context, constraints) {
                    var actionHeight = 44.0;
                    for (final entry in [
                      (l10n.get('snooze5Min'), 0.0),
                      if (onSnoozeUntil != null) (l10n.get('snoozeMore'), 26.0),
                      if (canReview) (l10n.get('startReview'), 26.0),
                      if (reminder.canSkipOccurrence && onSkip != null)
                        (l10n.get('skipOccurrence'), 0.0),
                      (l10n.get('markDone'), 0.0),
                      (l10n.get('iKnow'), 0.0),
                    ]) {
                      final painter =
                          TextPainter(
                            text: TextSpan(
                              text: entry.$1,
                              style: actionTextStyle,
                            ),
                            textDirection: Directionality.of(context),
                            textScaler: MediaQuery.textScalerOf(context),
                          )..layout(
                            maxWidth: math.max(
                              1,
                              constraints.maxWidth - 24 - entry.$2,
                            ),
                          );
                      actionHeight = math.max(
                        actionHeight,
                        painter.height + 20,
                      );
                      painter.dispose();
                    }
                    final actionStyle = baseActionStyle.copyWith(
                      minimumSize: WidgetStatePropertyAll(
                        Size(0, actionHeight),
                      ),
                    );
                    return Wrap(
                      key: const ValueKey('notice-actions'),
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (canReview)
                          FilledButton.tonalIcon(
                            key: const ValueKey('notice-start-review'),
                            style: actionStyle,
                            onPressed: busy ? null : () => onReview!(reminder),
                            icon: const Icon(Icons.school_outlined, size: 18),
                            label: Text(l10n.get('startReview')),
                          ),
                        TextButton(
                          key: const ValueKey('notice-snooze-five'),
                          style: actionStyle,
                          onPressed: busy ? null : () => onSnooze(reminder),
                          child: Text(l10n.get('snooze5Min')),
                        ),
                        if (onSnoozeUntil != null)
                          MenuAnchor(
                            menuChildren: [
                              for (final entry in const {
                                '15': 'snooze15',
                                '60': 'snooze60',
                                'evening': 'quickEvening',
                                'morning': 'quickMorning',
                                'custom': 'quickChoose',
                              }.entries)
                                MenuItemButton(
                                  onPressed: busy
                                      ? null
                                      : () => _chooseSnooze(
                                          context,
                                          entry.key,
                                          reminder,
                                        ),
                                  child: Text(l10n.get(entry.value)),
                                ),
                            ],
                            builder: (context, controller, child) =>
                                TextButton.icon(
                                  key: const ValueKey('snooze-options'),
                                  style: actionStyle,
                                  onPressed: busy
                                      ? null
                                      : () => controller.isOpen
                                            ? controller.close()
                                            : controller.open(),
                                  icon: const Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    size: 18,
                                  ),
                                  iconAlignment: IconAlignment.end,
                                  label: Text(l10n.get('snoozeMore')),
                                ),
                          ),
                        if (reminder.canSkipOccurrence && onSkip != null)
                          TextButton(
                            key: const ValueKey('notice-skip'),
                            style: actionStyle,
                            onPressed: busy ? null : () => onSkip!(reminder),
                            child: Text(l10n.get('skipOccurrence')),
                          ),
                        TextButton(
                          key: const ValueKey('notice-complete'),
                          style: actionStyle,
                          onPressed: busy ? null : () => onComplete(reminder),
                          child: Text(l10n.get('markDone')),
                        ),
                        TextButton(
                          key: const ValueKey('notice-dismiss'),
                          style: actionStyle,
                          onPressed: busy ? null : () => onDismiss(reminder),
                          child: Text(l10n.get('iKnow')),
                        ),
                      ],
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
