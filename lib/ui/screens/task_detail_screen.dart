import '../widgets/inline_feedback.dart';
import '../widgets/editable_text_menu.dart';
import '../formatters/local_date_time.dart';
import '../../data/database_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../services/context_trigger_service.dart';
import '../../l10n/app_localizations.dart';
import 'knowledge_graph_screen.dart';

/// Dedicated Full-Page Task Detail & Editing Screen
class TaskDetailScreen extends ConsumerStatefulWidget {
  final Reminder task;
  final VoidCallback? onPlayMedia;

  const TaskDetailScreen({super.key, required this.task, this.onPlayMedia});

  @override
  ConsumerState<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends ConsumerState<TaskDetailScreen> {
  late TextEditingController _titleController;
  late TextEditingController _summaryController;
  late int _selectedQuadrant;
  late int _originalQuadrant;
  late bool _isDynamicallyPromoted;
  late DateTime? _selectedTime;
  late String _selectedRecurrenceRule;
  late bool _isCompleted;
  late List<String> _linkedTaskIds;
  List<Reminder>? _linkedSource;
  List<String>? _indexedLinkIds;
  Map<String, Reminder> _linkedTaskIndex = {};
  DataGeneration? _editorGeneration;
  bool _isSaving = false;
  bool _isDeleting = false;
  bool get _isMutating => _isSaving || _isDeleting;

  // Context Trigger state
  late String _contextTriggerType; // 'none', 'wifi', 'profile'
  late TextEditingController _wifiSsidController;
  late TextEditingController _contextPromptController;
  late String _contextProfileValue;
  late String? _initialContextFormValue;

  @override
  void initState() {
    super.initState();
    try {
      _editorGeneration = ref.read(databaseHelperProvider).captureGeneration();
    } on DatabaseAccessException {
      // Opening during maintenance leaves the form readable but unable to save.
    }
    _titleController = TextEditingController(text: widget.task.taskTitle);
    _summaryController = TextEditingController(
      text: widget.task.taskSummary ?? '',
    );
    _selectedQuadrant = widget.task.quadrantLevel;
    _originalQuadrant = widget.task.originalQuadrantLevel;
    _isDynamicallyPromoted = widget.task.isDynamicallyPromoted;
    _selectedTime = widget.task.triggerTime;
    _selectedRecurrenceRule =
        widget.task.isRecurring && widget.task.recurrenceRule != null
        ? widget.task.recurrenceRule!
        : 'none';
    _isCompleted = widget.task.isCompleted;
    _linkedTaskIds = List<String>.from(widget.task.linkedTaskIds);

    final rule = ContextTriggerRule.tryParse(widget.task.contextTrigger);
    if (rule != null) {
      _contextTriggerType = rule.type;
      if (rule.type == 'wifi') {
        _wifiSsidController = TextEditingController(text: rule.value);
        _contextProfileValue = 'office';
      } else {
        _wifiSsidController = TextEditingController();
        _contextProfileValue = rule.value.isNotEmpty ? rule.value : 'office';
      }
      _contextPromptController = TextEditingController(text: rule.prompt ?? '');
    } else {
      _contextTriggerType = 'none';
      _wifiSsidController = TextEditingController();
      _contextProfileValue = 'office';
      _contextPromptController = TextEditingController();
    }
    _initialContextFormValue = _contextFormValue();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _summaryController.dispose();
    _wifiSsidController.dispose();
    _contextPromptController.dispose();
    super.dispose();
  }

  String? _contextFormValue() {
    final prompt = _contextPromptController.text.trim();
    if (_contextTriggerType == 'wifi' &&
        _wifiSsidController.text.trim().isNotEmpty) {
      return ContextTriggerRule(
        type: 'wifi',
        value: _wifiSsidController.text.trim(),
        prompt: prompt.isEmpty ? null : prompt,
      ).toJsonString();
    }
    if (_contextTriggerType == 'profile') {
      return ContextTriggerRule(
        type: 'profile',
        value: _contextProfileValue,
        prompt: prompt.isEmpty ? null : prompt,
      ).toJsonString();
    }
    return null;
  }

  Future<void> _save() async {
    if (_isMutating) return;
    final l10n = AppLocalizations.of(context);
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(l10n.get('taskTitleLabel')),
        ),
      );
      return;
    }

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

    final summary = _summaryController.text.trim();

    final baseline = widget.task;
    final current = ref
        .read(remindersProvider)
        .where((task) => task.id == baseline.id)
        .firstOrNull;
    if (current == null) {
      InlineFeedback.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.get('reminderUpdateFailed'))));
      return;
    }
    final initialRule = baseline.isRecurring
        ? baseline.recurrenceRule ?? 'none'
        : 'none';
    final recurrenceChanged = _selectedRecurrenceRule != initialRule;
    final newContextTrigger = _contextFormValue();
    final removedLinks = baseline.linkedTaskIds
        .where((id) => !_linkedTaskIds.contains(id))
        .toSet();
    final addedLinks = _linkedTaskIds.where(
      (id) => !baseline.linkedTaskIds.contains(id),
    );
    final mergedLinks = <String>{
      ...current.linkedTaskIds.where((id) => !removedLinks.contains(id)),
      ...addedLinks,
    }.toList();
    // An editor can stay open while AI, synchronization or urgency promotion changes
    // the same task. Apply only fields changed from the form's opening baseline.
    final updatedTask = current.copyWith(
      taskTitle: _titleController.text != baseline.taskTitle
          ? title
          : current.taskTitle,
      taskSummary: _summaryController.text != (baseline.taskSummary ?? '')
          ? (summary.isEmpty ? null : summary)
          : current.taskSummary,
      quadrantLevel: _selectedQuadrant != baseline.quadrantLevel
          ? _selectedQuadrant
          : current.quadrantLevel,
      originalQuadrantLevel: _originalQuadrant != baseline.originalQuadrantLevel
          ? _originalQuadrant
          : current.originalQuadrantLevel,
      isDynamicallyPromoted:
          _isDynamicallyPromoted != baseline.isDynamicallyPromoted
          ? _isDynamicallyPromoted
          : current.isDynamicallyPromoted,
      triggerTime: _selectedTime != baseline.triggerTime
          ? _selectedTime
          : current.triggerTime,
      isCompleted: _isCompleted != baseline.isCompleted
          ? _isCompleted
          : current.isCompleted,
      isRecurring: recurrenceChanged
          ? _selectedRecurrenceRule != 'none'
          : current.isRecurring,
      recurrenceRule: recurrenceChanged
          ? _selectedRecurrenceRule
          : current.recurrenceRule,
      recurrenceDescription: recurrenceChanged
          ? recurrenceDesc
          : current.recurrenceDescription,
      linkedTaskIds: mergedLinks,
      contextTrigger: newContextTrigger != _initialContextFormValue
          ? newContextTrigger
          : current.contextTrigger,
    );

    final notifier = ref.read(remindersProvider.notifier);
    final feedback = InlineFeedback.of(context);
    setState(() => _isSaving = true);
    try {
      final database = ref.read(databaseHelperProvider);
      final generation = _editorGeneration;
      if (generation == null) throw StateError('Editor unavailable');
      final result = await database.runOperation(
        generation,
        () => notifier.updateReminder(updatedTask, baseline: current),
      );
      database.checkGeneration(generation);
      if (!mounted) return;
      if (result.nativeSyncFailed) {
        feedback.showSnackBar(
          SnackBar(content: Text(l10n.get('reminderNativeSyncFailed'))),
        );
        return;
      }
      feedback.showSnackBar(SnackBar(content: Text(l10n.get('save'))));
      setState(() => _isSaving = false);
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        feedback.showSnackBar(
          SnackBar(content: Text(l10n.get('reminderUpdateFailed'))),
        );
      }
    } finally {
      if (mounted && _isSaving) setState(() => _isSaving = false);
    }
  }

  Future<void> _delete() async {
    if (_isMutating) return;
    final l10n = AppLocalizations.of(context);
    final task = ref
        .read(remindersProvider)
        .where((item) => item.id == widget.task.id)
        .firstOrNull;
    if (task == null) {
      InlineFeedback.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.get('taskDeleteFailed'))));
      return;
    }
    final notifier = ref.read(remindersProvider.notifier);
    // The feedback host survives this route and owns Undo after the editor closes.
    final feedback = InlineFeedback.of(context);
    setState(() => _isDeleting = true);
    try {
      final database = ref.read(databaseHelperProvider);
      final generation = _editorGeneration;
      if (generation == null) throw StateError('Editor unavailable');
      final result = await database.runOperation(
        generation,
        () => notifier.deleteReminder(task.id),
      );
      final deleted = result.reminder ?? task;
      database.checkGeneration(generation);
      if (feedback.mounted) {
        feedback.showSnackBar(
          SnackBar(
            content: Text(
              result.nativeSyncFailed
                  ? l10n.get('reminderNativeDeleteFailed')
                  : '${l10n.get('deletedTask')}: ${deleted.taskTitle}',
            ),
            action: SnackBarAction(
              label: l10n.get('undo'),
              onPressed: () async {
                try {
                  final restored = await database.runOperation(
                    generation,
                    () => notifier.restoreDeletedReminder(deleted, generation),
                  );
                  if (restored.nativeSyncFailed && feedback.mounted) {
                    feedback.showSnackBar(
                      SnackBar(
                        content: Text(l10n.get('reminderNativeSyncFailed')),
                      ),
                    );
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
      }
      if (mounted) {
        setState(() => _isDeleting = false);
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) {
        feedback.showSnackBar(
          SnackBar(content: Text(l10n.get('taskDeleteFailed'))),
        );
      }
    } finally {
      if (mounted && _isDeleting) setState(() => _isDeleting = false);
    }
  }

  Future<void> _pickDateTime() async {
    final initialDate = _selectedTime?.toLocal() ?? DateTime.now();
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

      if (pickedTime != null && mounted) {
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

  void _applyQuickTime(Duration offset) {
    setState(() {
      _selectedTime = DateTime.now().add(offset);
    });
  }

  void _applyFixedHour(int hour, {bool tomorrow = false}) {
    final now = DateTime.now();
    DateTime target = DateTime(now.year, now.month, now.day, hour, 0);
    if (tomorrow || target.isBefore(now)) {
      target = target.add(const Duration(days: 1));
    }
    setState(() {
      _selectedTime = target;
    });
  }

  String _formatTimeRemaining(AppLocalizations l10n) {
    if (_selectedTime == null) return l10n.get('notSet');
    final now = DateTime.now();
    final diff = _selectedTime!.difference(now);

    if (diff.isNegative) {
      return l10n.get('overdue');
    }

    if (diff.inDays > 0) {
      return '${diff.inDays}天 ${diff.inHours % 24}小时';
    } else if (diff.inHours > 0) {
      return '${diff.inHours}小时 ${diff.inMinutes % 60}分钟';
    } else {
      return '${diff.inMinutes}分钟';
    }
  }

  Color _getCategoryColor(int level) {
    switch (level) {
      case 1:
        return Colors.red.shade400;
      case 2:
        return Colors.orange.shade400;
      case 3:
        return Colors.blue.shade400;
      case 4:
      default:
        return Colors.green.shade400;
    }
  }

  IconData _getCategoryIcon(int level) {
    switch (level) {
      case 1:
        return Icons.local_fire_department_rounded;
      case 2:
        return Icons.star_rounded;
      case 3:
        return Icons.bolt_rounded;
      case 4:
      default:
        return Icons.coffee_rounded;
    }
  }

  String _getCategoryName(AppLocalizations l10n, int level) {
    switch (level) {
      case 1:
        return l10n.get('cat1');
      case 2:
        return l10n.get('cat2');
      case 3:
        return l10n.get('cat3');
      case 4:
      default:
        return l10n.get('cat4');
    }
  }

  Widget _buildTriggerTypeRadio(String type, String label) {
    final isSelected = _contextTriggerType == type;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(() => _contextTriggerType = type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.teal.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? Colors.teal
                : Colors.grey.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 14,
              color: isSelected ? Colors.teal : Colors.grey,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? Colors.teal : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeLink(String otherId, {required bool remove}) async {
    if (_isMutating) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _isSaving = true);
    try {
      final database = ref.read(databaseHelperProvider);
      final generation = _editorGeneration;
      if (generation == null) throw StateError('Editor unavailable');
      final notifier = ref.read(remindersProvider.notifier);
      await database.runOperation(generation, () async {
        if (remove) {
          await notifier.unlinkTwoTasks(widget.task.id, otherId);
        } else {
          await notifier.linkTwoTasks(widget.task.id, otherId);
        }
      });
      database.checkGeneration(generation);
      if (!mounted) return;
      setState(() {
        if (remove) {
          _linkedTaskIds.remove(otherId);
        } else if (!_linkedTaskIds.contains(otherId)) {
          _linkedTaskIds.add(otherId);
        }
      });
    } catch (_) {
      if (mounted) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(l10n.get('reminderUpdateFailed'))),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildLinkedTaskChip(
    String linkedId,
    Map<String, Reminder> taskIndex,
    AppLocalizations l10n,
    bool isDark,
  ) {
    final target = taskIndex[linkedId];
    final title = target?.taskTitle ?? linkedId;
    final qLevel = target?.quadrantLevel ?? 4;
    final qColor = _getCategoryColor(qLevel);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: qColor.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: qColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              'Q$qLevel',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.bold,
                color: qColor,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: InkWell(
              onTap: () {
                if (target != null) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TaskDetailScreen(task: target),
                    ),
                  );
                }
              },
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => _changeLink(linkedId, remove: true),
            child: const Icon(Icons.close, size: 14, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  void _showAddLinkDialog(List<Reminder> allReminders, AppLocalizations l10n) {
    final available = allReminders
        .where((r) => r.id != widget.task.id && !_linkedTaskIds.contains(r.id))
        .toList();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.get('addLinkedTask')),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: available.isEmpty
                ? Center(child: Text(l10n.get('noAvailableTasksToLink')))
                : ListView.builder(
                    itemCount: available.length,
                    itemBuilder: (_, i) {
                      final item = available[i];
                      final qColor = _getCategoryColor(item.quadrantLevel);
                      return ListTile(
                        leading: CircleAvatar(
                          radius: 12,
                          backgroundColor: qColor.withValues(alpha: 0.2),
                          child: Text(
                            'Q${item.quadrantLevel}',
                            style: TextStyle(
                              fontSize: 10,
                              color: qColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          item.taskTitle,
                          style: const TextStyle(fontSize: 13),
                        ),
                        onTap: () async {
                          Navigator.pop(ctx);
                          await _changeLink(item.id, remove: false);
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.get('cancel')),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final catColor = _getCategoryColor(_selectedQuadrant);
    final allReminders = ref.watch(remindersProvider);
    // Reuse the index across local form changes; task mutations publish a new
    // list. Unlinked details never allocate an index for the whole database.
    if (_linkedTaskIds.isEmpty) {
      _linkedSource = null;
      _indexedLinkIds = null;
      _linkedTaskIndex = {};
    } else if (!identical(_linkedSource, allReminders) ||
        !identical(_indexedLinkIds, _linkedTaskIds)) {
      _linkedSource = allReminders;
      _indexedLinkIds = _linkedTaskIds;
      final needed = _linkedTaskIds.toSet();
      _linkedTaskIndex = {};
      for (final task in allReminders) {
        if (needed.remove(task.id)) _linkedTaskIndex[task.id] = task;
        if (needed.isEmpty) break;
      }
    }

    final scaffold = Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          l10n.get('taskDetailTitle'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        centerTitle: false,
        elevation: 0,
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          tooltip: l10n.get('cancel'),
          onPressed: _isMutating ? null : () => Navigator.of(context).pop(),
        ),
        actions: [
          // Toggle Complete
          IconButton(
            icon: Icon(
              _isCompleted
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: _isCompleted ? Colors.green : Colors.grey,
              size: 22,
            ),
            tooltip: _isCompleted
                ? l10n.get('markUndone')
                : l10n.get('markDone'),
            onPressed: _isMutating
                ? null
                : () {
                    setState(() {
                      _isCompleted = !_isCompleted;
                    });
                  },
          ),
          // Delete
          IconButton(
            icon: const Icon(
              Icons.delete_outline_rounded,
              size: 22,
              color: Colors.redAccent,
            ),
            tooltip: l10n.get('deleteTask'),
            onPressed: _isMutating ? null : _delete,
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            12 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Align(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1008),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: _isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined, size: 18),
                  label: Text(
                    l10n.get('saveChanges'),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: _isMutating ? null : _save,
                ),
              ),
            ),
          ),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: SafeArea(
            child: AbsorbPointer(
              absorbing: _isMutating,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 12.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1. Status & Category Banner Card
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: catColor.withValues(alpha: 0.35),
                          width: 1,
                        ),
                      ),
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          Icon(
                            _getCategoryIcon(_selectedQuadrant),
                            color: catColor,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _getCategoryName(l10n, _selectedQuadrant),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: catColor,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: _isCompleted
                                  ? Colors.green.withValues(alpha: 0.12)
                                  : Colors.blue.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _isCompleted
                                    ? Colors.green.withValues(alpha: 0.4)
                                    : Colors.blue.withValues(alpha: 0.4),
                                width: 0.8,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _isCompleted
                                        ? Colors.green
                                        : Colors.blue,
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  _isCompleted
                                      ? l10n.get('statusCompleted')
                                      : l10n.get('statusPending'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: _isCompleted
                                        ? Colors.green
                                        : Colors.blue,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Dynamic Promotion Alert Banner
                    if (!_isCompleted &&
                        _selectedQuadrant == 1 &&
                        _isDynamicallyPromoted) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.amber.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.bolt,
                              color: Colors.amber,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.get('dynamicPromotedAlertTitle'),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.amber,
                                    ),
                                  ),
                                  Text(
                                    l10n.get('dynamicPromotedAlertDesc'),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark
                                          ? Colors.grey.shade400
                                          : Colors.grey.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _selectedQuadrant = _originalQuadrant;
                                  _isDynamicallyPromoted = false;
                                });
                              },
                              child: Text(
                                l10n.get('revertToQ2'),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.amber,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 14),

                    // 2. Task Title Input
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.get('taskTitleLabel'),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            key: const ValueKey('detail-title'),
                            contextMenuBuilder: buildEditableTextMenu,
                            controller: _titleController,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: _isCompleted
                                  ? Colors.grey
                                  : Theme.of(
                                      context,
                                    ).textTheme.bodyLarge?.color,
                              decoration: _isCompleted
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                              border: InputBorder.none,
                              labelText: l10n.get('taskTitleLabel'),
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.never,
                            ),
                            maxLines: 2,
                            minLines: 1,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // 3. Supplemental Details / Notes (详情信息补充)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              Icon(
                                Icons.notes_rounded,
                                size: 16,
                                color: primaryColor,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                l10n.get('taskDetailsSupplement'),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            key: const ValueKey('detail-summary'),
                            contextMenuBuilder: buildEditableTextMenu,
                            controller: _summaryController,
                            style: const TextStyle(fontSize: 13, height: 1.45),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                              border: InputBorder.none,
                              labelText: l10n.get('taskDetailsSupplement'),
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.never,
                              hintText: l10n.get('supplementHint'),
                              hintStyle: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade400,
                              ),
                            ),
                            maxLines: 6,
                            minLines: 3,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // 4. Reminder Time Section (提示时间与快捷设定)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              Icon(
                                Icons.access_time_rounded,
                                size: 16,
                                color: primaryColor,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                l10n.get('triggerTimeLabel'),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(width: 6),
                              if (_selectedTime != null) ...[
                                if (!_isCompleted)
                                  Text(
                                    '${l10n.get('timeRemaining')}: ${_formatTimeRemaining(l10n)}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color:
                                          _selectedTime!.isBefore(
                                            DateTime.now(),
                                          )
                                          ? Colors.red.shade400
                                          : primaryColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                const SizedBox(width: 6),
                                IconButton(
                                  icon: const Icon(Icons.clear, size: 16),
                                  tooltip: l10n.get('clearTime'),
                                  splashRadius: 14,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () =>
                                      setState(() => _selectedTime = null),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 10),
                          InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: _pickDateTime,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.05)
                                    : Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                              child: Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  Icon(
                                    Icons.calendar_month_outlined,
                                    size: 18,
                                    color: primaryColor,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    _selectedTime != null
                                        ? formatLocalDateTime(_selectedTime!)
                                        : l10n.get('notSet'),
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: _selectedTime != null
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                      color: _selectedTime != null
                                          ? Theme.of(
                                              context,
                                            ).textTheme.bodyMedium?.color
                                          : Colors.grey,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    l10n.get('tapToChange'),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: primaryColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 10),

                          // Quick Presets
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              ActionChip(
                                avatar: const Icon(Icons.flash_on, size: 13),
                                label: Text(
                                  l10n.get('in15Min'),
                                  style: const TextStyle(fontSize: 11),
                                ),
                                onPressed: () => _applyQuickTime(
                                  const Duration(minutes: 15),
                                ),
                              ),
                              ActionChip(
                                avatar: const Icon(
                                  Icons.hourglass_top_rounded,
                                  size: 13,
                                ),
                                label: Text(
                                  l10n.get('in1Hour'),
                                  style: const TextStyle(fontSize: 11),
                                ),
                                onPressed: () =>
                                    _applyQuickTime(const Duration(hours: 1)),
                              ),
                              ActionChip(
                                avatar: const Icon(
                                  Icons.nightlight_round,
                                  size: 13,
                                ),
                                label: Text(
                                  l10n.get('tonight20'),
                                  style: const TextStyle(fontSize: 11),
                                ),
                                onPressed: () => _applyFixedHour(20),
                              ),
                              ActionChip(
                                avatar: const Icon(
                                  Icons.wb_sunny_rounded,
                                  size: 13,
                                ),
                                label: Text(
                                  l10n.get('tomorrow9'),
                                  style: const TextStyle(fontSize: 11),
                                ),
                                onPressed: () =>
                                    _applyFixedHour(9, tomorrow: true),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // 5. Category Selection & Recurrence Setting Card
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.get('quadrantLabel'),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final level in [1, 2, 3, 4])
                                ChoiceChip(
                                  avatar: Icon(
                                    _getCategoryIcon(level),
                                    size: 18,
                                    color: _getCategoryColor(level),
                                  ),
                                  label: Text(_getCategoryName(l10n, level)),
                                  selected: _selectedQuadrant == level,
                                  onSelected: (_) =>
                                      setState(() => _selectedQuadrant = level),
                                ),
                            ],
                          ),

                          const SizedBox(height: 14),

                          // Recurrence Rule Dropdown
                          Text(
                            l10n.get('recurrenceLabel'),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: _selectedRecurrenceRule,
                            decoration: InputDecoration(
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            items: [
                              DropdownMenuItem(
                                value: 'none',
                                child: Text(
                                  l10n.get('repeatNone'),
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              DropdownMenuItem(
                                value: 'daily',
                                child: Text(
                                  l10n.get('repeatDaily'),
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              DropdownMenuItem(
                                value: 'workday',
                                child: Text(
                                  l10n.get('repeatWorkday'),
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              DropdownMenuItem(
                                value: 'weekly',
                                child: Text(
                                  l10n.get('repeatWeekly'),
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              DropdownMenuItem(
                                value: 'monthly',
                                child: Text(
                                  l10n.get('repeatMonthly'),
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _selectedRecurrenceRule = val);
                              }
                            },
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // 6. Bi-directional Links (双向链接 / 关联备忘)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              const Icon(
                                Icons.link,
                                size: 16,
                                color: Colors.indigoAccent,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                l10n.get('bidirectionalLinks'),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(width: 6),
                              TextButton.icon(
                                icon: const Icon(Icons.hub_outlined, size: 14),
                                label: Text(
                                  l10n.get('viewInGraph'),
                                  style: const TextStyle(fontSize: 11),
                                ),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  minimumSize: Size.zero,
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => KnowledgeGraphScreen(
                                        initialFocusTaskId: widget.task.id,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (_linkedTaskIds.isEmpty)
                            Text(
                              l10n.get('noLinksYet'),
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark
                                    ? Colors.grey.shade500
                                    : Colors.grey.shade400,
                              ),
                            )
                          else
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                for (final linkedId in _linkedTaskIds)
                                  _buildLinkedTaskChip(
                                    linkedId,
                                    _linkedTaskIndex,
                                    l10n,
                                    isDark,
                                  ),
                              ],
                            ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.add_link, size: 16),
                            label: Text(
                              l10n.get('addLinkedTask'),
                              style: const TextStyle(fontSize: 12),
                            ),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              minimumSize: Size.zero,
                            ),
                            onPressed: () =>
                                _showAddLinkDialog(allReminders, l10n),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // 7. Context Trigger Section (情境感知触发器)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              const Icon(
                                Icons.near_me_outlined,
                                size: 16,
                                color: Colors.teal,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                l10n.get('contextTriggerTitle'),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              _buildTriggerTypeRadio(
                                'none',
                                l10n.get('triggerNone'),
                              ),
                              _buildTriggerTypeRadio(
                                'wifi',
                                l10n.get('triggerWifi'),
                              ),
                              _buildTriggerTypeRadio(
                                'profile',
                                l10n.get('triggerProfile'),
                              ),
                            ],
                          ),
                          if (_contextTriggerType == 'wifi') ...[
                            const SizedBox(height: 8),
                            TextField(
                              controller: _wifiSsidController,
                              style: const TextStyle(fontSize: 13),
                              decoration: InputDecoration(
                                labelText: l10n.get('wifiSsidLabel'),
                                hintText: 'e.g. Office-WiFi, Home-Net',
                                isDense: true,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ] else if (_contextTriggerType == 'profile') ...[
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: _contextProfileValue,
                              decoration: InputDecoration(
                                labelText: l10n.get('profileSelectLabel'),
                                isDense: true,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: 'office',
                                  child: Text(
                                    l10n.get('profileOffice'),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'deepWork',
                                  child: Text(
                                    l10n.get('profileDeepWork'),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'home',
                                  child: Text(
                                    l10n.get('profileHome'),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() => _contextProfileValue = val);
                                }
                              },
                            ),
                          ],
                          if (_contextTriggerType != 'none') ...[
                            const SizedBox(height: 8),
                            TextField(
                              controller: _contextPromptController,
                              style: const TextStyle(fontSize: 13),
                              decoration: InputDecoration(
                                labelText: l10n.get('contextPromptLabel'),
                                hintText: 'e.g. 提醒同步团队进度或更新站会看板',
                                isDense: true,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    // 8. Media Attachment if any
                    if (widget.task.recordId != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.attach_file_rounded,
                              size: 18,
                              color: primaryColor,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l10n.get('linkedInputRecord'),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ),
                            if (widget.onPlayMedia != null)
                              FilledButton.tonalIcon(
                                icon: const Icon(
                                  Icons.play_arrow_rounded,
                                  size: 16,
                                ),
                                label: Text(
                                  l10n.get('playOrPreview'),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                onPressed: widget.onPlayMedia,
                              ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return PopScope(canPop: !_isMutating, child: scaffold);
  }
}
