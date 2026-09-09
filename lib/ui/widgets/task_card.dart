import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../services/notification_service.dart';
import '../../l10n/app_localizations.dart';
import '../screens/task_detail_screen.dart';

class TaskCard extends ConsumerStatefulWidget {
  final Reminder task;
  final VoidCallback onPlayMedia;

  const TaskCard({
    super.key,
    required this.task,
    required this.onPlayMedia,
  });

  @override
  ConsumerState<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends ConsumerState<TaskCard> {
  bool _isDecomposing = false;
  bool _showSubtasks = true;

  Future<void> _decomposeToMicroHabits() async {
    if (_isDecomposing) return;
    setState(() => _isDecomposing = true);

    try {
      final settings = ref.read(settingsProvider);
      final llmService = ref.read(llmServiceProvider);
      final habits = await llmService.decomposeTaskToMicroHabits(
        widget.task,
        settings,
        language: settings.language,
      );

      final updated = widget.task.copyWith(
        subTasks: jsonEncode(habits),
      );
      await ref.read(remindersProvider.notifier).updateReminder(updated);

      if (mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            content: Text(l10n.get('addMicroHabitsAsSubtasks')),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('拆解失败: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isDecomposing = false);
      }
    }
  }

  void _deleteTask(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final notifier = ref.read(remindersProvider.notifier);
    notifier.deleteReminder(widget.task.id);
    NotificationService().cancelReminder(widget.task.id);

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        content: Text('${l10n.get('deletedTask')}: ${widget.task.taskTitle}'),
        action: SnackBarAction(
          label: l10n.get('undo'),
          textColor: Colors.amberAccent,
          onPressed: () {
            notifier.addReminder(widget.task);
            if (widget.task.triggerTime != null && widget.task.triggerTime!.isAfter(DateTime.now())) {
              NotificationService().scheduleReminder(widget.task);
            }
          },
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, Offset globalPosition) async {
    final l10n = AppLocalizations.of(context);
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx + 1,
        globalPosition.dy + 1,
      ),
      items: [
        PopupMenuItem(
          value: 'edit',
          child: Row(
            children: [
              const Icon(Icons.edit_outlined, size: 16),
              const SizedBox(width: 8),
              Text(l10n.get('editTask')),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'toggle',
          child: Row(
            children: [
              Icon(
                widget.task.isCompleted ? Icons.radio_button_unchecked : Icons.check_circle_outline,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(widget.task.isCompleted ? l10n.get('markUndone') : l10n.get('markDone')),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'decompose',
          child: Row(
            children: [
              const Icon(Icons.psychology_outlined, size: 16, color: Colors.indigoAccent),
              const SizedBox(width: 8),
              Text(l10n.get('breakdownHabits')),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'toggle_review',
          child: Row(
            children: [
              Icon(
                widget.task.spacedRepetitionLevel > 0 ? Icons.school : Icons.school_outlined,
                size: 16,
                color: Colors.amber,
              ),
              const SizedBox(width: 8),
              Text(
                widget.task.spacedRepetitionLevel > 0
                    ? '移出复习卡片'
                    : l10n.get('convertCard'),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              const Icon(Icons.delete_outline, size: 16, color: Colors.red),
              const SizedBox(width: 8),
              Text(l10n.get('deleteTask'), style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    );

    if (!context.mounted) return;

    if (value == 'edit') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TaskDetailScreen(task: widget.task, onPlayMedia: widget.onPlayMedia),
        ),
      );
    } else if (value == 'toggle') {
      HapticFeedback.selectionClick();
      final updated = widget.task.copyWith(isCompleted: !widget.task.isCompleted);
      ref.read(remindersProvider.notifier).updateReminder(updated);
      if (updated.isCompleted) {
        NotificationService().cancelReminder(widget.task.id);
      } else if (updated.triggerTime != null && updated.triggerTime!.isAfter(DateTime.now())) {
        NotificationService().scheduleReminder(updated);
      }
    } else if (value == 'decompose') {
      _decomposeToMicroHabits();
    } else if (value == 'toggle_review') {
      final spacedService = ref.read(spacedRepetitionServiceProvider);
      final updated = widget.task.spacedRepetitionLevel > 0
          ? spacedService.disableCard(widget.task)
          : spacedService.enableCard(widget.task);
      ref.read(remindersProvider.notifier).updateReminder(updated);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(updated.spacedRepetitionLevel > 0
              ? '已转为艾宾浩斯复习卡片！将按记忆遗忘曲线安排深度复盘。'
              : '已从复习卡片移出。'),
          duration: const Duration(seconds: 2),
        ),
      );
    } else if (value == 'delete') {
      _deleteTask(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final task = widget.task;

    IconData? mediaIcon;
    if (task.recordId != null) {
      final records = ref.read(mediaRecordsProvider);
      final media = records.where((m) => m.id == task.recordId).firstOrNull;
      if (media?.type == 'audio') {
        mediaIcon = Icons.mic_none;
      } else if (media?.type == 'image') {
        mediaIcon = Icons.image_outlined;
      } else if (media?.type == 'video') {
        mediaIcon = Icons.videocam_outlined;
      } else if (media?.type == 'file') {
        mediaIcon = Icons.description_outlined;
      }
    }

    Color priorityColor;
    switch (task.quadrantLevel) {
      case 1:
        priorityColor = Colors.red.shade400;
        break;
      case 2:
        priorityColor = Colors.orange.shade400;
        break;
      case 3:
        priorityColor = Colors.blue.shade400;
        break;
      case 4:
      default:
        priorityColor = Colors.green.shade400;
        break;
    }

    final subTasksList = task.getSubTasksList();
    final isStagnant = task.isStagnant(hours: 24);

    return Dismissible(
      key: Key(task.id),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: Colors.red.shade400.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete_outline, color: Colors.white, size: 20),
      ),
      onDismissed: (_) => _deleteTask(context),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: task.isCompleted
              ? (isDark ? Colors.black26 : Colors.grey.shade100.withValues(alpha: 0.6))
              : (isDark ? Colors.black.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.75)),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: task.isCompleted
                ? Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.35)
                : priorityColor.withValues(alpha: 0.35),
            width: 1.0,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TaskDetailScreen(task: task, onPlayMedia: widget.onPlayMedia),
              ),
            );
          },
          onSecondaryTapUp: (details) {
            _showContextMenu(context, details.globalPosition);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Micro Status Indicator Light on the edge
                    Padding(
                      padding: const EdgeInsets.only(top: 5, right: 6),
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: task.isCompleted ? Colors.grey.shade400 : priorityColor,
                          boxShadow: task.isCompleted
                              ? []
                              : [
                                  BoxShadow(
                                    color: priorityColor.withValues(alpha: 0.6),
                                    blurRadius: 4,
                                    spreadRadius: 0.5,
                                  ),
                                ],
                        ),
                      ),
                    ),

                    // Media attachment icon if any
                    if (mediaIcon != null) ...[
                      InkWell(
                        onTap: widget.onPlayMedia,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 1, right: 6),
                          child: Icon(mediaIcon, size: 16, color: Theme.of(context).colorScheme.primary),
                        ),
                      ),
                    ],

                    // Main Info Stream (Title, Summary, Recurrence/Time wireframe tags)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  task.taskTitle,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.color
                                        ?.withValues(alpha: task.isCompleted ? 0.38 : 1.0),
                                    decoration: task.isCompleted ? TextDecoration.lineThrough : null,
                                    height: 1.25,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              // Empty Boat Purified Badge
                              if (task.isEmotionFiltered)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: Colors.teal.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(3),
                                      border: Border.all(
                                        color: Colors.teal.withValues(alpha: 0.35),
                                        width: 0.7,
                                      ),
                                    ),
                                    child: Text(
                                      l10n.get('emotionFilteredBadge'),
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w600,
                                        color: isDark ? Colors.tealAccent : Colors.teal.shade700,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (task.taskSummary != null && task.taskSummary!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                task.taskSummary!,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.color
                                      ?.withValues(alpha: task.isCompleted ? 0.35 : 0.65),
                                  height: 1.2,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (task.triggerTime != null || task.isRecurring || task.spacedRepetitionLevel > 0 || (isStagnant && subTasksList.isEmpty))
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Wrap(
                                spacing: 4,
                                runSpacing: 2,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (task.spacedRepetitionLevel > 0)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: Colors.amber.withValues(alpha: 0.15),
                                        border: Border.all(
                                          color: Colors.amber.withValues(alpha: 0.5),
                                          width: 0.8,
                                        ),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.school, size: 10, color: Colors.amber),
                                          const SizedBox(width: 2),
                                          Text(
                                            'Lv.${task.spacedRepetitionLevel}',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.amber,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (task.isRecurring)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                                          width: 0.8,
                                        ),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.autorenew_rounded, size: 10, color: Theme.of(context).colorScheme.primary),
                                          const SizedBox(width: 2),
                                          Text(
                                            task.recurrenceDescription ?? l10n.get('recurrencePeriodic'),
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: Theme.of(context).colorScheme.primary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (task.triggerTime != null)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Colors.grey.withValues(alpha: 0.3),
                                          width: 0.8,
                                        ),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.access_time, size: 10, color: Colors.grey.shade600),
                                          const SizedBox(width: 2),
                                          Text(
                                            task.triggerTime.toString().substring(0, 16),
                                            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                                          ),
                                        ],
                                      ),
                                    ),
                                  // Stagnant Task Warning Hint
                                  if (isStagnant && subTasksList.isEmpty)
                                    InkWell(
                                      onTap: _decomposeToMicroHabits,
                                      borderRadius: BorderRadius.circular(3),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.amber.withValues(alpha: 0.15),
                                          border: Border.all(
                                            color: Colors.amber.shade700.withValues(alpha: 0.4),
                                            width: 0.8,
                                          ),
                                          borderRadius: BorderRadius.circular(3),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.bolt, size: 10, color: Colors.amber),
                                            const SizedBox(width: 2),
                                            Text(
                                              l10n.get('stagnantHint'),
                                              style: TextStyle(
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.w600,
                                                color: isDark ? Colors.amberAccent : Colors.amber.shade900,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),

                    // Trailing: Compact Checkbox
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: Checkbox(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
                          activeColor: Theme.of(context).colorScheme.primary,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          value: task.isCompleted,
                          onChanged: (val) {
                            HapticFeedback.selectionClick();
                            if (val == true && task.isRecurring) {
                              final nextTime = task.getNextOccurrence();
                              if (nextTime != null) {
                                final nextTask = task.copyWith(triggerTime: nextTime, isCompleted: false);
                                ref.read(remindersProvider.notifier).updateReminder(nextTask);
                                NotificationService().scheduleReminder(nextTask);

                                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    duration: const Duration(seconds: 3),
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    content: Text('${l10n.get('periodicNext')}${nextTime.toString().substring(0, 16)}'),
                                  ),
                                );
                                return;
                              }
                            }

                            final updatedTask = task.copyWith(isCompleted: val);
                            ref.read(remindersProvider.notifier).updateReminder(updatedTask);
                            if (val == true) {
                              NotificationService().cancelReminder(task.id);
                            } else if (updatedTask.triggerTime != null &&
                                updatedTask.triggerTime!.isAfter(DateTime.now())) {
                              NotificationService().scheduleReminder(updatedTask);
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),

                // Micro-Habits Subtasks Section
                if (subTasksList.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.indigo.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Colors.indigoAccent.withValues(alpha: 0.2),
                        width: 0.6,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.psychology, size: 12, color: Colors.indigoAccent),
                            const SizedBox(width: 4),
                            Text(
                              l10n.get('subTasksTitle'),
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.indigoAccent),
                            ),
                            const Spacer(),
                            InkWell(
                              onTap: () => setState(() => _showSubtasks = !_showSubtasks),
                              child: Icon(
                                _showSubtasks ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                size: 14,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                        if (_showSubtasks) ...[
                          const SizedBox(height: 2),
                          for (final habit in subTasksList)
                            Padding(
                              padding: const EdgeInsets.only(top: 2, left: 2),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4, right: 4),
                                    child: Container(
                                      width: 4,
                                      height: 4,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.indigoAccent,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      habit,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.85),
                                        height: 1.25,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ] else if (task.quadrantLevel == 2 && !task.isCompleted) ...[
                  // Decompose button for Q2 tasks without micro habits
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 12),
                    child: _isDecomposing
                        ? Row(
                            children: [
                              const SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(strokeWidth: 1.5),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                l10n.get('breakdownLoading'),
                                style: const TextStyle(fontSize: 10, color: Colors.indigoAccent),
                              ),
                            ],
                          )
                        : InkWell(
                            onTap: _decomposeToMicroHabits,
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.auto_awesome, size: 11, color: Colors.indigoAccent),
                                  const SizedBox(width: 3),
                                  Text(
                                    l10n.get('breakdownHabits'),
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.indigoAccent,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
