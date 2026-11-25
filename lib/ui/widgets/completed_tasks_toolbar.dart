import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../screens/notification_repair_screen.dart';
import '../theme/app_theme.dart';
import 'inline_feedback.dart';

const Duration kTransientNotificationDuration = Duration(seconds: 5);

/// Sorts completed tasks with most recently completed items first.
int compareCompletedTasksNewestFirst(Reminder a, Reminder b) {
  final aTime =
      a.details.completedAt ?? a.eventTime ?? a.triggerTime ?? a.createdAt;
  final bTime =
      b.details.completedAt ?? b.eventTime ?? b.triggerTime ?? b.createdAt;
  if (aTime == null) return bTime == null ? a.id.compareTo(b.id) : 1;
  if (bTime == null) return -1;
  final cmp = bTime.compareTo(aTime);
  return cmp != 0 ? cmp : a.id.compareTo(b.id);
}

/// Moves one or more workspace tasks to Trash atomically and shows a 5-second
/// auto-closing Undo notification.
Future<bool> trashTasksWithUndo(
  BuildContext context,
  WidgetRef ref,
  List<Reminder> targets,
) async {
  if (targets.isEmpty) return false;
  final l10n = AppLocalizations.of(context);
  final feedback = InlineFeedback.of(context);
  final database = ref.read(databaseHelperProvider);
  final notifier = ref.read(remindersProvider.notifier);
  try {
    final generation = database.captureGeneration();
    final result = await notifier.trashWorkspaceTasks(targets, generation);
    database.checkGeneration(generation);
    if (result.trashed.isEmpty) return false;
    if (!feedback.mounted) return true;
    final trashed = result.trashed;
    final nativeFailed = result.nativeSyncFailures > 0;
    final label = nativeFailed
        ? l10n.get('reminderNativeDeleteFailed')
        : trashed.length == 1
        ? '${l10n.get('deletedTask')}: ${trashed.single.taskTitle}'
        : l10n
              .get('batchDeletedTasks')
              .replaceAll('{count}', '${trashed.length}');
    feedback.showSnackBar(
      SnackBar(
        content: Text(label),
        action: SnackBarAction(
          label: l10n.get('undo'),
          onPressed: () async {
            try {
              final restored = await notifier.restoreTrashedWorkspaceTasks(
                trashed,
                generation,
              );
              if (restored.nativeSyncFailures > 0 && feedback.mounted) {
                feedback.showSnackBar(
                  SnackBar(content: Text(l10n.get('reminderNativeSyncFailed'))),
                  tone: FeedbackTone.warning,
                );
              }
            } catch (_) {
              if (feedback.mounted) {
                feedback.showSnackBar(
                  SnackBar(content: Text(l10n.get('reminderUpdateFailed'))),
                  tone: FeedbackTone.error,
                );
              }
            }
          },
        ),
      ),
      tone: nativeFailed ? FeedbackTone.warning : FeedbackTone.info,
      dismissAfter: nativeFailed ? null : kTransientNotificationDuration,
    );
    return true;
  } catch (_) {
    if (feedback.mounted) {
      feedback.showSnackBar(
        SnackBar(content: Text(l10n.get('taskDeleteFailed'))),
        tone: FeedbackTone.error,
      );
    }
    return false;
  }
}

/// Prompts to clear completed tasks into Trash with 5-second Undo support.
Future<bool> confirmAndClearCompletedTasks(
  BuildContext context,
  WidgetRef ref,
  List<Reminder> completedTasks,
) async {
  final eligible = completedTasks
      .where(
        (r) =>
            r.isCompleted &&
            r.details.deletedAt == null &&
            r.details.data['learning_archive'] != true,
      )
      .toList();
  final l10n = AppLocalizations.of(context);
  if (eligible.isEmpty) {
    final feedback = InlineFeedback.maybeOf(context);
    feedback?.hideCurrentSnackBar();
    feedback?.showSnackBar(
      SnackBar(content: Text(l10n.get('noCompletedToClear'))),
      tone: FeedbackTone.info,
      dismissAfter: kTransientNotificationDuration,
    );
    return false;
  }
  final colors = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.delete_sweep_outlined,
            color: colors.error,
            size: 22,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${l10n.get('clearCompletedTitle')} (${eligible.length})',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
          ),
        ],
      ),
      content: Text(
        l10n.get('clearCompletedConfirm'),
        style: const TextStyle(fontSize: 14),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.get('cancel')),
        ),
        FilledButton(
          key: const ValueKey('confirm-clear-completed'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l10n.get('confirm')),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  return trashTasksWithUndo(context, ref, eligible);
}

/// Batch-marks selected completed tasks as undone with a 5-second notification.
Future<bool> reopenTasksBatch(
  BuildContext context,
  WidgetRef ref,
  List<Reminder> targets,
) async {
  if (targets.isEmpty) return false;
  final l10n = AppLocalizations.of(context);
  final feedback = InlineFeedback.of(context);
  final repair = notificationRepairAction(context);
  try {
    final database = ref.read(databaseHelperProvider);
    final generation = database.captureGeneration();
    final result = await ref
        .read(remindersProvider.notifier)
        .reopenCompletedTasks(targets, generation);
    database.checkGeneration(generation);
    if (!feedback.mounted || result.changed == 0) return result.changed > 0;
    if (result.nativeSyncFailures > 0) {
      feedback.showSnackBar(
        SnackBar(
          content: Text(l10n.get('reminderNativeSyncFailed')),
          action: repair,
        ),
        tone: FeedbackTone.warning,
      );
    } else {
      feedback.showSnackBar(
        SnackBar(
          content: Text(
            l10n
                .get('batchReopenedTasks')
                .replaceAll('{count}', '${result.changed}'),
          ),
        ),
        tone: FeedbackTone.success,
        dismissAfter: kTransientNotificationDuration,
      );
    }
    return true;
  } catch (_) {
    if (feedback.mounted) {
      feedback.showSnackBar(
        SnackBar(content: Text(l10n.get('reminderUpdateFailed'))),
        tone: FeedbackTone.error,
      );
    }
    return false;
  }
}

/// Responsive toolbar for completed-task views supporting both 1-tap Clear All
/// and multi-select Batch Delete / Batch Reopen.
class CompletedTasksToolbar extends ConsumerWidget {
  const CompletedTasksToolbar({
    super.key,
    required this.scopeKey,
    required this.tasks,
    required this.selectionMode,
    required this.selectedIds,
    required this.busy,
    required this.onEnterSelection,
    required this.onExitSelection,
    required this.onToggleSelectAll,
    required this.onDeleteSelected,
    required this.onReopenSelected,
    required this.onClearAll,
    this.leading,
  });

  final String scopeKey;
  final List<Reminder> tasks;
  final bool selectionMode;
  final Set<String> selectedIds;
  final bool busy;
  final VoidCallback onEnterSelection;
  final VoidCallback onExitSelection;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onDeleteSelected;
  final VoidCallback onReopenSelected;
  final VoidCallback onClearAll;
  final Widget? leading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (tasks.isEmpty) return leading ?? const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final selectedCount = tasks.where((t) => selectedIds.contains(t.id)).length;
    final allSelected = selectedCount == tasks.length && tasks.isNotEmpty;

    Widget iconLabel(
      IconData icon,
      String text, {
      TextStyle? style,
    }) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );

    if (!selectionMode) {
      return Wrap(
        spacing: 6,
        runSpacing: 4,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (leading != null) leading!,
          Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                key: ValueKey('$scopeKey-select-toggle'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                onPressed: busy ? null : onEnterSelection,
                child: iconLabel(
                  Icons.checklist_rtl_rounded,
                  l10n.get('batchSelect'),
                ),
              ),
              TextButton(
                key: ValueKey('$scopeKey-clear-completed'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 44),
                  foregroundColor: colors.error,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                onPressed: busy ? null : onClearAll,
                child: iconLabel(
                  Icons.delete_sweep_outlined,
                  l10n.get('clearCompletedShort'),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): onExitSelection,
      },
      child: Container(
        key: ValueKey('$scopeKey-selection-bar'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.primary.withValues(alpha: 0.35)),
        ),
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  key: ValueKey('$scopeKey-select-all'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: busy ? null : onToggleSelectAll,
                  child: iconLabel(
                    allSelected
                        ? Icons.deselect_outlined
                        : Icons.select_all_rounded,
                    l10n.get(allSelected ? 'deselectAll' : 'selectAll'),
                  ),
                ),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    l10n
                        .get('selectedCount')
                        .replaceAll('{count}', '$selectedCount'),
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: AppTheme.tabularFigures,
                    ),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  key: ValueKey('$scopeKey-reopen-selected'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: busy || selectedCount == 0
                      ? null
                      : onReopenSelected,
                  child: iconLabel(
                    Icons.undo_rounded,
                    l10n
                        .get('reopenSelectedCount')
                        .replaceAll('{count}', '$selectedCount'),
                    style: const TextStyle(
                      fontFeatures: AppTheme.tabularFigures,
                    ),
                  ),
                ),
                FilledButton(
                  key: ValueKey('$scopeKey-delete-selected'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 44),
                    backgroundColor: colors.error,
                    foregroundColor: colors.onError,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: busy || selectedCount == 0
                      ? null
                      : onDeleteSelected,
                  child: iconLabel(
                    Icons.delete_outline_rounded,
                    l10n
                        .get('deleteSelectedCount')
                        .replaceAll('{count}', '$selectedCount'),
                    style: const TextStyle(
                      fontFeatures: AppTheme.tabularFigures,
                    ),
                  ),
                ),
                TextButton(
                  key: ValueKey('$scopeKey-exit-select'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: busy ? null : onExitSelection,
                  child: Text(
                    l10n.get('doneSelecting'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
