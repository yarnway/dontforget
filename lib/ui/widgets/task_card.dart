import 'inline_feedback.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../l10n/app_localizations.dart';
import '../screens/task_detail_screen.dart';

class TaskCard extends ConsumerStatefulWidget {
  final Reminder task;
  final VoidCallback onPlayMedia;

  const TaskCard({super.key, required this.task, required this.onPlayMedia});

  @override
  ConsumerState<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends ConsumerState<TaskCard> {
  bool _isDecomposing = false;
  bool _isUpdating = false;
  bool _isDeleting = false;
  bool _showSubtasks = true;

  bool get _isBusy => _isUpdating || _isDeleting;

  void _showMessage(String message) {
    if (!mounted) return;
    InlineFeedback.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _decomposeToMicroHabits() async {
    if (_isDecomposing || _isBusy) return;
    setState(() => _isDecomposing = true);
    final l10n = AppLocalizations.of(context);
    try {
      final settings = ref.read(settingsProvider);
      final habits = await ref
          .read(llmServiceProvider)
          .decomposeTaskToMicroHabits(
            widget.task,
            settings,
            language: settings.language,
          );
      if (!mounted) return;
      // Preserve edits made while the request was running, and do not revive a deleted task.
      final current = ref
          .read(remindersProvider)
          .where((task) => task.id == widget.task.id)
          .firstOrNull;
      if (current == null) return;
      await ref
          .read(remindersProvider.notifier)
          .updateReminder(current.copyWith(subTasks: jsonEncode(habits)));
      _showMessage(l10n.get('addMicroHabitsAsSubtasks'));
    } catch (_) {
      _showMessage(l10n.get('taskBreakdownFailed'));
    } finally {
      if (mounted) setState(() => _isDecomposing = false);
    }
  }

  Future<void> _setCompleted(bool completed) async {
    if (_isBusy) return;
    setState(() => _isUpdating = true);
    final l10n = AppLocalizations.of(context);
    final task = widget.task;
    final notifications = ref.read(notificationServiceProvider);
    try {
      final next = completed && task.isRecurring
          ? task.getNextOccurrence()
          : null;
      final updated = next == null
          ? task.copyWith(isCompleted: completed)
          : task.copyWith(triggerTime: next, isCompleted: false);
      await ref.read(remindersProvider.notifier).updateReminder(updated);
      if (updated.isCompleted) {
        await notifications.cancelReminder(task.id);
      } else if (updated.triggerTime?.isAfter(DateTime.now()) ?? false) {
        await notifications.scheduleReminder(updated);
      }
      if (next != null) {
        _showMessage(
          '${l10n.get('periodicNext')}${next.toString().substring(0, 16)}',
        );
      }
    } catch (_) {
      _showMessage(l10n.get('reminderUpdateFailed'));
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  Future<void> _deleteTask() async {
    if (_isBusy) return;
    setState(() => _isDeleting = true);
    final task = widget.task;
    final l10n = AppLocalizations.of(context);
    final notifier = ref.read(remindersProvider.notifier);
    final notifications = ref.read(notificationServiceProvider);
    final feedback = InlineFeedback.of(context);
    try {
      await notifier.deleteReminder(task.id);
      await notifications.cancelReminder(task.id);
      if (!feedback.mounted) return;
      feedback.showSnackBar(
        SnackBar(
          content: Text('${l10n.get('deletedTask')}: ${task.taskTitle}'),
          action: SnackBarAction(
            label: l10n.get('undo'),
            onPressed: () async {
              try {
                await notifier.addReminder(task);
                if (!task.isCompleted &&
                    (task.triggerTime?.isAfter(DateTime.now()) ?? false)) {
                  await notifications.scheduleReminder(task);
                }
              } catch (_) {
                if (feedback.mounted) {
                  feedback.showSnackBar(
                    SnackBar(content: Text(l10n.get('reminderUpdateFailed'))),
                  );
                }
              }
            },
          ),
        ),
      );
    } catch (_) {
      if (feedback.mounted) {
        feedback.showSnackBar(
          SnackBar(content: Text(l10n.get('taskDeleteFailed'))),
        );
      }
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  void _openDetails() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TaskDetailScreen(
          task: widget.task,
          onPlayMedia: widget.onPlayMedia,
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    bool destructive = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final color = destructive ? colors.error : colors.onSurface;
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }

  List<PopupMenuEntry<String>> _menuItems(AppLocalizations l10n) => [
    _menuItem('edit', Icons.edit_outlined, l10n.get('editTask')),
    _menuItem(
      'toggle',
      widget.task.isCompleted
          ? Icons.radio_button_unchecked
          : Icons.check_circle_outline,
      l10n.get(widget.task.isCompleted ? 'markUndone' : 'markDone'),
    ),
    _menuItem(
      'decompose',
      Icons.psychology_outlined,
      l10n.get('breakdownHabits'),
    ),
    _menuItem(
      'toggle_review',
      Icons.school_outlined,
      widget.task.spacedRepetitionLevel > 0
          ? l10n.get('removeReviewCard')
          : l10n.get('convertCard'),
    ),
    const PopupMenuDivider(),
    _menuItem(
      'delete',
      Icons.delete_outline,
      l10n.get('deleteTask'),
      destructive: true,
    ),
  ];

  Future<void> _showContextMenu(Offset position) async {
    if (_isBusy) return;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      color: Theme.of(context).colorScheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      items: _menuItems(AppLocalizations.of(context)),
    );
    if (mounted && action != null) await _onAction(action);
  }

  Future<void> _onAction(String action) async {
    if (_isBusy) return;
    if (action == 'edit') {
      _openDetails();
    } else if (action == 'toggle') {
      HapticFeedback.selectionClick();
      await _setCompleted(!widget.task.isCompleted);
    } else if (action == 'decompose') {
      await _decomposeToMicroHabits();
    } else if (action == 'delete') {
      await _deleteTask();
    } else if (action == 'toggle_review') {
      setState(() => _isUpdating = true);
      final l10n = AppLocalizations.of(context);
      try {
        final service = ref.read(spacedRepetitionServiceProvider);
        final updated = widget.task.spacedRepetitionLevel > 0
            ? service.disableCard(widget.task)
            : service.enableCard(widget.task);
        await ref.read(remindersProvider.notifier).updateReminder(updated);
      } catch (_) {
        _showMessage(l10n.get('reminderUpdateFailed'));
      } finally {
        if (mounted) setState(() => _isUpdating = false);
      }
    }
  }

  Widget _badge(String label, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(label, style: TextStyle(fontSize: 11, color: color)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final task = widget.task;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subTasks = task.getSubTasksList();
    final priorityColor = switch (task.quadrantLevel) {
      1 => isDark ? Colors.red.shade300 : Colors.red.shade700,
      2 => isDark ? Colors.orange.shade300 : Colors.orange.shade800,
      3 => isDark ? Colors.blue.shade300 : Colors.blue.shade700,
      _ => isDark ? Colors.green.shade300 : Colors.green.shade700,
    };
    IconData? mediaIcon;
    if (task.recordId != null) {
      final media = ref.watch(
        mediaRecordsProvider.select(
          (records) =>
              records.where((record) => record.id == task.recordId).firstOrNull,
        ),
      );
      mediaIcon = switch (media?.type) {
        'audio' => Icons.mic_none,
        'image' => Icons.image_outlined,
        'video' => Icons.videocam_outlined,
        'file' => Icons.description_outlined,
        _ => null,
      };
    }
    final metadata = <Widget>[
      if (task.isEmotionFiltered)
        _badge(
          l10n.get('emotionFilteredBadge'),
          Icons.spa_outlined,
          colors.primary,
        ),
      if (task.isDynamicallyPromoted &&
          !task.isCompleted &&
          task.quadrantLevel == 1)
        _badge(
          l10n.get('promotedToQ1Badge'),
          Icons.bolt_outlined,
          colors.error,
        ),
      if (task.triggerTime != null)
        _badge(
          task.triggerTime.toString().substring(0, 16),
          Icons.access_time,
          colors.onSurfaceVariant,
        ),
      if (task.isRecurring)
        _badge(
          task.recurrenceDescription ?? l10n.get('recurrencePeriodic'),
          Icons.autorenew_rounded,
          colors.primary,
        ),
      if (task.spacedRepetitionLevel > 0)
        _badge(
          'Lv.${task.spacedRepetitionLevel}',
          Icons.school_outlined,
          colors.primary,
        ),
      if (task.linkedTaskIds.isNotEmpty)
        _badge('${task.linkedTaskIds.length}', Icons.link, colors.primary),
      if (task.contextTrigger?.isNotEmpty ?? false)
        _badge(
          l10n.get('contextTriggerTitle'),
          Icons.near_me_outlined,
          colors.primary,
        ),
    ];
    final showBreakdown =
        subTasks.isEmpty &&
        !task.isCompleted &&
        (task.quadrantLevel == 2 || task.isStagnant(hours: 24));

    return Dismissible(
      key: ValueKey(task.id),
      direction: _isBusy ? DismissDirection.none : DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: Icon(Icons.delete_outline, color: colors.onErrorContainer),
      ),
      // The provider removes a successfully deleted row. A failed write leaves it usable.
      confirmDismiss: (_) async {
        await _deleteTask();
        return false;
      },
      // Animate the inherited theme once. A second background-only animation
      // can leave a white card behind already-light dark-theme text.
      child: Container(
        key: ValueKey('task-surface-${task.id}'),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: task.isCompleted ? colors.surfaceContainerLow : colors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: task.isCompleted
                ? colors.outlineVariant
                : priorityColor.withValues(alpha: 0.3),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _openDetails,
          onSecondaryTapUp: (details) =>
              _showContextMenu(details.globalPosition),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 16, right: 8),
                      child: Icon(
                        Icons.circle,
                        size: 6,
                        color: task.isCompleted
                            ? colors.onSurfaceVariant
                            : priorityColor,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: Text(
                          task.taskTitle,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                            color: task.isCompleted
                                ? colors.onSurfaceVariant
                                : colors.onSurface,
                            decoration: task.isCompleted
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Checkbox(
                        key: ValueKey('complete-${task.id}'),
                        semanticLabel:
                            '${l10n.get(task.isCompleted ? 'markUndone' : 'markDone')}: ${task.taskTitle}',
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        value: task.isCompleted,
                        onChanged: _isBusy
                            ? null
                            : (value) {
                                HapticFeedback.selectionClick();
                                if (value != null) _setCompleted(value);
                              },
                      ),
                    ),
                    PopupMenuButton<String>(
                      key: ValueKey('actions-${task.id}'),
                      tooltip: l10n.get('taskActions'),
                      enabled: !_isBusy,
                      constraints: const BoxConstraints(
                        minWidth: 200,
                        maxWidth: 320,
                      ),
                      color: colors.surfaceContainer,
                      surfaceTintColor: Colors.transparent,
                      icon: Icon(
                        Icons.more_horiz_rounded,
                        size: 20,
                        color: colors.onSurfaceVariant,
                      ),
                      itemBuilder: (_) => _menuItems(l10n),
                      onSelected: _onAction,
                    ),
                  ],
                ),
                if (task.taskSummary?.isNotEmpty ?? false)
                  Padding(
                    padding: const EdgeInsets.only(left: 14, top: 2),
                    child: Text(
                      task.taskSummary!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ),
                if (metadata.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(spacing: 6, runSpacing: 6, children: metadata),
                  ),
                if (mediaIcon != null)
                  Row(
                    children: [
                      IconButton(
                        tooltip: l10n.get('playOrPreview'),
                        onPressed: widget.onPlayMedia,
                        color: colors.primary,
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        icon: Icon(mediaIcon, size: 20),
                      ),
                      Expanded(
                        child: Text(
                          l10n.get('playOrPreview'),
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                if (subTasks.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Semantics(
                    expanded: _showSubtasks,
                    child: TextButton(
                      key: ValueKey('subtasks-${task.id}'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        foregroundColor: colors.primary,
                        alignment: Alignment.centerLeft,
                      ),
                      onPressed: () =>
                          setState(() => _showSubtasks = !_showSubtasks),
                      child: Row(
                        children: [
                          const Icon(Icons.checklist_rounded, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${l10n.get('subTasksTitle')} (${subTasks.length})',
                            ),
                          ),
                          Tooltip(
                            message: l10n.get(
                              _showSubtasks
                                  ? 'collapseSubtasks'
                                  : 'expandSubtasks',
                            ),
                            child: Icon(
                              _showSubtasks
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_showSubtasks)
                    for (final subTask in subTasks)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 2, 8, 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '•  ',
                              style: TextStyle(color: colors.primary),
                            ),
                            Expanded(
                              child: Text(
                                subTask,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                ] else if (showBreakdown)
                  TextButton.icon(
                    onPressed: _isDecomposing || _isBusy
                        ? null
                        : _decomposeToMicroHabits,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: colors.primary,
                    ),
                    icon: _isDecomposing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_outlined, size: 18),
                    label: Text(
                      l10n.get(
                        _isDecomposing ? 'breakdownLoading' : 'breakdownHabits',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
