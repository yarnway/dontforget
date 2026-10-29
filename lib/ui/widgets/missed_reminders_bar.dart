import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';

/// Aggregated, non-modal entry for reminders that became due while the app was closed or offline.
/// Shows up to 72 hours of unacknowledged overdue items without firing noisy toasts.
class MissedRemindersBar extends StatelessWidget {
  const MissedRemindersBar({
    super.key,
    required this.reminders,
    required this.onOpenMissed,
    required this.onAcknowledgeAll,
    this.busy = false,
  });

  final List<Reminder> reminders;
  final VoidCallback onOpenMissed;
  final VoidCallback onAcknowledgeAll;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (reminders.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);

    final titleText = '${l10n.get('missedReminders')} · ${reminders.length}';
    final buttonText = l10n.get('allAcknowledged');

    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Material(
            key: const ValueKey('missed-reminders-bar'),
            color: colors.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: LayoutBuilder(
            builder: (context, constraints) {
              final buttonStyle = ButtonStyle(
                minimumSize: WidgetStatePropertyAll(
                  Size(0, math.max(44, scaler.scale(14) * 1.25 + 20)),
                ),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                textStyle: WidgetStatePropertyAll(
                  textTheme.labelLarge?.copyWith(
                    fontSize: 14,
                    height: 1.25,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                ),
                visualDensity: VisualDensity.standard,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              );

              final isNarrow = constraints.maxWidth < 420;

              final titleWidget = InkWell(
                key: const ValueKey('missed-reminders-title'),
                borderRadius: BorderRadius.circular(8),
                onTap: onOpenMissed,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.history_toggle_off_rounded,
                        size: 20,
                        color: colors.error,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          titleText,
                          style: textTheme.titleSmall?.copyWith(
                            color: colors.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              );

              final actionButton = TextButton(
                key: const ValueKey('missed-reminders-acknowledge-all'),
                style: buttonStyle,
                onPressed: busy ? null : onAcknowledgeAll,
                child: Text(buttonText),
              );

              if (isNarrow) {
                return Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    titleWidget,
                    actionButton,
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: titleWidget),
                  const SizedBox(width: 8),
                  actionButton,
                ],
              );
            },
          ),
        ),
      ),
    ),
  ),
);
  }
}
