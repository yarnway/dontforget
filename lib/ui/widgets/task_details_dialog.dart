import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../services/notification_service.dart';

class TaskDetailsDialog extends ConsumerStatefulWidget {
  final Reminder task;

  const TaskDetailsDialog({super.key, required this.task});

  @override
  ConsumerState<TaskDetailsDialog> createState() => _TaskDetailsDialogState();
}

class _TaskDetailsDialogState extends ConsumerState<TaskDetailsDialog> {
  late TextEditingController _titleController;
  late int _selectedQuadrant;
  late DateTime? _selectedTime;
  late String _selectedRecurrenceRule;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.task.taskTitle);
    _selectedQuadrant = widget.task.quadrantLevel;
    _selectedTime = widget.task.triggerTime;
    _selectedRecurrenceRule = widget.task.isRecurring && widget.task.recurrenceRule != null
        ? widget.task.recurrenceRule!
        : 'none';
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  void _save() {
    String? recurrenceDesc;
    switch (_selectedRecurrenceRule) {
      case 'daily':
        recurrenceDesc = '每天';
        break;
      case 'workday':
        recurrenceDesc = '工作日';
        break;
      case 'weekly':
        recurrenceDesc = '每周';
        break;
      case 'monthly':
        recurrenceDesc = '每月';
        break;
      default:
        recurrenceDesc = null;
    }

    final updatedTask = widget.task.copyWith(
      taskTitle: _titleController.text.trim(),
      quadrantLevel: _selectedQuadrant,
      triggerTime: _selectedTime,
      isRecurring: _selectedRecurrenceRule != 'none',
      recurrenceRule: _selectedRecurrenceRule,
      recurrenceDescription: recurrenceDesc,
    );

    ref.read(remindersProvider.notifier).updateReminder(updatedTask);

    final notifService = NotificationService();
    notifService.cancelReminder(widget.task.id);
    if (!updatedTask.isCompleted &&
        updatedTask.triggerTime != null &&
        updatedTask.triggerTime!.isAfter(DateTime.now())) {
      notifService.scheduleReminder(updatedTask);
    }

    Navigator.of(context).pop();
  }

  void _delete() {
    final notifier = ref.read(remindersProvider.notifier);
    notifier.deleteReminder(widget.task.id);
    NotificationService().cancelReminder(widget.task.id);

    Navigator.of(context).pop();

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Text('已删除事项: ${widget.task.taskTitle}'),
        action: SnackBarAction(
          label: '撤销',
          textColor: Colors.amberAccent,
          onPressed: () {
            notifier.addReminder(widget.task);
            if (widget.task.triggerTime != null &&
                widget.task.triggerTime!.isAfter(DateTime.now())) {
              NotificationService().scheduleReminder(widget.task);
            }
          },
        ),
      ),
    );
  }

  Future<void> _pickTime() async {
    final initialDate = _selectedTime ?? DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
    );

    if (pickedDate != null && mounted) {
      final pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(initialDate),
      );

      if (pickedTime != null) {
        setState(() {
          _selectedTime = DateTime(
            pickedDate.year,
            pickedDate.month,
            pickedDate.day,
            pickedTime.hour,
            pickedTime.minute,
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('编辑事项',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              TextField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: '事项标题',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                maxLines: 3,
                minLines: 1,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: _selectedQuadrant,
                decoration: InputDecoration(
                  labelText: '象限分类',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                items: [
                  DropdownMenuItem(
                    value: 1,
                    child: Row(
                      children: [
                        Icon(Icons.local_fire_department_rounded, color: Colors.red.shade400, size: 20),
                        const SizedBox(width: 8),
                        const Text('象限 1 (火急重要)'),
                      ],
                    ),
                  ),
                  DropdownMenuItem(
                    value: 2,
                    child: Row(
                      children: [
                        Icon(Icons.star_rounded, color: Colors.orange.shade400, size: 20),
                        const SizedBox(width: 8),
                        const Text('象限 2 (长期重要)'),
                      ],
                    ),
                  ),
                  DropdownMenuItem(
                    value: 3,
                    child: Row(
                      children: [
                        Icon(Icons.bolt_rounded, color: Colors.blue.shade400, size: 20),
                        const SizedBox(width: 8),
                        const Text('象限 3 (突发琐事)'),
                      ],
                    ),
                  ),
                  DropdownMenuItem(
                    value: 4,
                    child: Row(
                      children: [
                        Icon(Icons.coffee_rounded, color: Colors.green.shade400, size: 20),
                        const SizedBox(width: 8),
                        const Text('象限 4 (低优闲事)'),
                      ],
                    ),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) setState(() => _selectedQuadrant = val);
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _selectedRecurrenceRule,
                decoration: InputDecoration(
                  labelText: '提醒周期',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('单次提醒 (不重复)')),
                  DropdownMenuItem(value: 'daily', child: Text('每天重复')),
                  DropdownMenuItem(value: 'workday', child: Text('工作日重复 (周一至周五)')),
                  DropdownMenuItem(value: 'weekly', child: Text('每周重复')),
                  DropdownMenuItem(value: 'monthly', child: Text('每月重复')),
                ],
                onChanged: (val) {
                  if (val != null) setState(() => _selectedRecurrenceRule = val);
                },
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('提醒时间'),
                subtitle: Text(
                  _selectedTime?.toString().substring(0, 16) ?? '未设置提醒',
                  style: TextStyle(
                    color: _selectedTime == null ? Colors.grey : Theme.of(context).colorScheme.primary,
                    fontWeight: _selectedTime == null ? FontWeight.normal : FontWeight.w600,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_selectedTime != null)
                      IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        tooltip: '清除提醒时间',
                        onPressed: () => setState(() => _selectedTime = null),
                      ),
                    IconButton(
                      icon: const Icon(Icons.access_time, size: 20),
                      tooltip: '选择提醒时间',
                      onPressed: _pickTime,
                    ),
                  ],
                ),
              ),
              if (widget.task.taskSummary != null && widget.task.taskSummary!.isNotEmpty) ...[
                const Divider(),
                const Text('AI提炼摘要',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 4),
                Text(
                  widget.task.taskSummary!,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                    label: const Text('删除', style: TextStyle(color: Colors.red)),
                    onPressed: _delete,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _save,
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
