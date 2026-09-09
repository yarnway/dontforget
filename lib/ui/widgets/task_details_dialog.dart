import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../services/notification_service.dart';
import '../../l10n/app_localizations.dart';

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
    final l10n = AppLocalizations.of(context);
    String? recurrenceDesc;
    switch (_selectedRecurrenceRule) {
      case 'daily':
        recurrenceDesc = l10n.get('repeatDaily');
        break;
      case 'workday':
        recurrenceDesc = l10n.get('repeatWorkday');
        break;
      case 'weekly':
        recurrenceDesc = l10n.get('repeatWeekly');
        break;
      case 'monthly':
        recurrenceDesc = l10n.get('repeatMonthly');
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
    final l10n = AppLocalizations.of(context);
    final notifier = ref.read(remindersProvider.notifier);
    notifier.deleteReminder(widget.task.id);
    NotificationService().cancelReminder(widget.task.id);

    Navigator.of(context).pop();

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
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
      ),
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.get('editTask'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _titleController,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  labelText: l10n.get('taskTitleLabel'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                maxLines: 3,
                minLines: 1,
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<int>(
                initialValue: _selectedQuadrant,
                decoration: InputDecoration(
                  labelText: l10n.get('quadrantLabel'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                items: [
                  DropdownMenuItem(
                    value: 1,
                    child: Row(
                      children: [
                        Icon(Icons.local_fire_department_rounded, color: Colors.red.shade400, size: 18),
                        const SizedBox(width: 8),
                        Text(l10n.get('q1Short'), style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  DropdownMenuItem(
                    value: 2,
                    child: Row(
                      children: [
                        Icon(Icons.star_rounded, color: Colors.orange.shade400, size: 18),
                        const SizedBox(width: 8),
                        Text(l10n.get('q2Short'), style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  DropdownMenuItem(
                    value: 3,
                    child: Row(
                      children: [
                        Icon(Icons.bolt_rounded, color: Colors.blue.shade400, size: 18),
                        const SizedBox(width: 8),
                        Text(l10n.get('q3Short'), style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  DropdownMenuItem(
                    value: 4,
                    child: Row(
                      children: [
                        Icon(Icons.coffee_rounded, color: Colors.green.shade400, size: 18),
                        const SizedBox(width: 8),
                        Text(l10n.get('q4Short'), style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) setState(() => _selectedQuadrant = val);
                },
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _selectedRecurrenceRule,
                decoration: InputDecoration(
                  labelText: l10n.get('recurrenceLabel'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                items: [
                  DropdownMenuItem(value: 'none', child: Text(l10n.get('repeatNone'), style: const TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 'daily', child: Text(l10n.get('repeatDaily'), style: const TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 'workday', child: Text(l10n.get('repeatWorkday'), style: const TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 'weekly', child: Text(l10n.get('repeatWeekly'), style: const TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 'monthly', child: Text(l10n.get('repeatMonthly'), style: const TextStyle(fontSize: 13))),
                ],
                onChanged: (val) {
                  if (val != null) setState(() => _selectedRecurrenceRule = val);
                },
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l10n.get('triggerTimeLabel'), style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                          const SizedBox(height: 2),
                          Text(
                            _selectedTime?.toString().substring(0, 16) ?? l10n.get('notSet'),
                            style: TextStyle(
                              fontSize: 13,
                              color: _selectedTime == null ? Colors.grey : Theme.of(context).colorScheme.primary,
                              fontWeight: _selectedTime == null ? FontWeight.normal : FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_selectedTime != null)
                      IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        tooltip: l10n.get('clearTime'),
                        splashRadius: 16,
                        onPressed: () => setState(() => _selectedTime = null),
                      ),
                    IconButton(
                      icon: const Icon(Icons.access_time, size: 18),
                      tooltip: l10n.get('triggerTimeLabel'),
                      splashRadius: 16,
                      onPressed: _pickTime,
                    ),
                  ],
                ),
              ),
              if (widget.task.taskSummary != null && widget.task.taskSummary!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  widget.task.taskSummary!,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 16),
                    label: Text(l10n.get('deleteTask'), style: const TextStyle(color: Colors.red, fontSize: 13)),
                    onPressed: _delete,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.get('cancel'), style: const TextStyle(fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    onPressed: _save,
                    child: Text(l10n.get('save'), style: const TextStyle(fontSize: 13)),
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
