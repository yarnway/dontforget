import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../services/notification_service.dart';
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
    final notifier = ref.read(remindersProvider.notifier);
    notifier.deleteReminder(task.id);
    NotificationService().cancelReminder(task.id);

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Text('已删除事项: ${task.taskTitle}'),
        action: SnackBarAction(
          label: '撤销',
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
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx + 1,
        globalPosition.dy + 1,
      ),
      items: [
        const PopupMenuItem(
          value: 'edit',
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 18),
              SizedBox(width: 8),
              Text('编辑事项'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'toggle',
          child: Row(
            children: [
              Icon(
                task.isCompleted ? Icons.radio_button_unchecked : Icons.check_circle_outline,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(task.isCompleted ? '标为未完成' : '标为已完成'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('删除事项', style: TextStyle(color: Colors.red)),
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
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => _deleteTask(context, ref),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 0,
        color: Theme.of(context).cardColor.withOpacity(0.9),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
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
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
              leading: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 4,
                    height: 24,
                    decoration: BoxDecoration(
                      color: priorityColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  if (mediaIcon != null) ...[
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: onPlayMedia,
                      child: Icon(mediaIcon, size: 20, color: Theme.of(context).colorScheme.primary),
                    ),
                  ],
                ],
              ),
              minLeadingWidth: 10,
              title: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withOpacity(task.isCompleted ? 0.4 : 1.0),
                  decoration: task.isCompleted ? TextDecoration.lineThrough : null,
                ),
                child: Text(
                  task.taskTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (task.taskSummary != null && task.taskSummary!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 2),
                      child: Text(
                        task.taskSummary!,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.color
                              ?.withOpacity(task.isCompleted ? 0.4 : 0.7),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (task.triggerTime != null || task.isRecurring)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          if (task.isRecurring) ...[
                            Icon(
                              Icons.autorenew_rounded,
                              size: 13,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              task.recurrenceDescription ?? '周期提醒',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          if (task.triggerTime != null) ...[
                            if (!task.isRecurring)
                              Icon(Icons.access_time, size: 12, color: Colors.grey.shade600),
                            const SizedBox(width: 4),
                            Text(
                              task.triggerTime.toString().substring(0, 16),
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    )
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(Icons.delete_outline, size: 19, color: Colors.grey.shade500),
                    tooltip: '删除事项',
                    splashRadius: 18,
                    onPressed: () => _deleteTask(context, ref),
                  ),
                  Checkbox(
                    shape: const CircleBorder(),
                    activeColor: Theme.of(context).colorScheme.primary,
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
                              duration: const Duration(seconds: 4),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              content: Text('已完成本次周期任务，下一次已自动排期至: ${nextTime.toString().substring(0, 16)}'),
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
