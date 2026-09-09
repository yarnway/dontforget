import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../services/notification_service.dart';
import '../../l10n/app_localizations.dart';
import 'task_details_dialog.dart';

class TaskCard extends ConsumerWidget {
  final Reminder task;
  final VoidCallback onPlayMedia;

  const TaskCard({
    super.key,
    required this.task,
    required this.onPlayMedia,
  });

  void _deleteTask(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final notifier = ref.read(remindersProvider.notifier);
    notifier.deleteReminder(task.id);
    NotificationService().cancelReminder(task.id);

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        content: Text('${l10n.get('deletedTask')}: ${task.taskTitle}'),
        action: SnackBarAction(
          label: l10n.get('undo'),
          textColor: Colors.amberAccent,
          onPressed: () {
            notifier.addReminder(task);
            if (task.triggerTime != null && task.triggerTime!.isAfter(DateTime.now())) {
              NotificationService().scheduleReminder(task);
            }
          },
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, WidgetRef ref, Offset globalPosition) async {
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
                task.isCompleted ? Icons.radio_button_unchecked : Icons.check_circle_outline,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(task.isCompleted ? l10n.get('markUndone') : l10n.get('markDone')),
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
      showDialog(
        context: context,
        builder: (context) => TaskDetailsDialog(task: task),
      );
    } else if (value == 'toggle') {
      final updated = task.copyWith(isCompleted: !task.isCompleted);
      ref.read(remindersProvider.notifier).updateReminder(updated);
      if (updated.isCompleted) {
        NotificationService().cancelReminder(task.id);
      } else if (updated.triggerTime != null && updated.triggerTime!.isAfter(DateTime.now())) {
        NotificationService().scheduleReminder(updated);
      }
    } else if (value == 'delete') {
      _deleteTask(context, ref);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
      onDismissed: (_) => _deleteTask(context, ref),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.black.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: task.isCompleted
                ? Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5)
                : priorityColor.withValues(alpha: 0.35),
            width: 1.0,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            showDialog(
              context: context,
              builder: (context) => TaskDetailsDialog(task: task),
            );
          },
          onSecondaryTapUp: (details) {
            _showContextMenu(context, ref, details.globalPosition);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
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
                    onTap: onPlayMedia,
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
                      Text(
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
                      if (task.triggerTime != null || task.isRecurring)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 2,
                            children: [
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
          ),
        ),
      ),
    );
  }
}
