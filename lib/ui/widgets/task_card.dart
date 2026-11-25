import 'inline_feedback.dart';
import 'capture_preview_dialog.dart';
import 'task_category_picker_dialog.dart';
import 'task_postpone_dialog.dart';
import 'task_snooze_picker.dart';
import '../formatters/local_date_time.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../data/database_helper.dart';
import '../../services/recovery/runtime_gate.dart';
import '../../providers/providers.dart';
import '../../providers/home_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/planning_strings.dart';
import '../screens/task_detail_screen.dart';
import '../screens/notification_repair_screen.dart';
import '../theme/app_theme.dart';

class TaskCard extends ConsumerStatefulWidget {
  final Reminder task;
  final VoidCallback onPlayMedia;
  final DateTime? referenceNow;

  const TaskCard({
    super.key,
    required this.task,
    required this.onPlayMedia,
    this.referenceNow,
  });

  @override
  ConsumerState<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends ConsumerState<TaskCard> {
  static final _whitespace = RegExp(r'\s+');
  bool _isDecomposing = false;
  bool _isUpdating = false;
  bool _isDeleting = false;
  bool _showSubtasks = false;
  bool _showChecklist = false;
  final _hovered = ValueNotifier<bool>(false);
  DataGeneration? _checklistGeneration;
  RuntimeRecoveryToken? _checklistToken;

  @override
  void initState() {
    super.initState();
    try {
      _checklistGeneration = ref
          .read(databaseHelperProvider)
          .captureGeneration();
      _checklistToken = ref.read(runtimeRecoveryGateProvider).capture();
    } catch (_) {
      // A card opened during recovery remains readable until it is remounted.
    }
  }

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }

  bool get _isBusy => _isUpdating || _isDeleting;

  void _showMessage(
    String message, {
    FeedbackTone tone = FeedbackTone.info,
    Duration? dismissAfter,
  }) {
    if (!mounted) return;
    final isNativeSyncFailure =
        message == AppLocalizations.of(context).get('reminderNativeSyncFailed');
    InlineFeedback.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: isNativeSyncFailure ? notificationRepairAction(context) : null,
      ),
      tone: isNativeSyncFailure ? FeedbackTone.warning : tone,
      dismissAfter: isNativeSyncFailure ? null : dismissAfter,
    );
  }

  Future<void> _decomposeToMicroHabits() async {
    if (_isDecomposing || _isBusy) return;
    setState(() => _isDecomposing = true);
    final l10n = AppLocalizations.of(context);
    try {
      final database = ref.read(databaseHelperProvider);
      final generation = database.captureGeneration();
      final settings = ref.read(settingsProvider);
      final habits = await ref
          .read(llmServiceProvider)
          .decomposeTaskToMicroHabits(
            widget.task,
            settings,
            language: settings.language,
          );
      if (!mounted) return;
      database.checkGeneration(generation);
      // Preserve edits made while the request was running, and do not revive a deleted task.
      final current = ref
          .read(remindersProvider)
          .where((task) => task.id == widget.task.id)
          .firstOrNull;
      if (current == null) return;
      await ref
          .read(remindersProvider.notifier)
          .updateReminderForGeneration(
            current.copyWith(subTasks: jsonEncode(habits)),
            generation,
            baseline: current,
          );
      database.checkGeneration(generation);
      if (mounted) setState(() => _showSubtasks = true);
      _showMessage(
        l10n.get('addMicroHabitsAsSubtasks'),
        tone: FeedbackTone.success,
      );
    } catch (_) {
      _showMessage(l10n.get('taskBreakdownFailed'), tone: FeedbackTone.error);
    } finally {
      if (mounted) setState(() => _isDecomposing = false);
    }
  }

  Future<void> _setCompleted(bool completed) async {
    if (_isBusy) return;
    setState(() => _isUpdating = true);
    final l10n = AppLocalizations.of(context);
    final task = widget.task;
    final databaseForFeedback = ref.read(databaseHelperProvider);
    final host = InlineFeedback.of(context);
    final repair = notificationRepairAction(context);
    DataGeneration? generationForFeedback;
    void showNativeFailure() {
      final gen = generationForFeedback;
      if (host.mounted &&
          (gen == null || databaseForFeedback.isCurrent(gen))) {
        host.showSnackBar(
          SnackBar(
            content: Text(l10n.get('reminderNativeSyncFailed')),
            action: repair,
          ),
          tone: FeedbackTone.warning,
        );
      }
    }

    try {
      generationForFeedback = databaseForFeedback.captureGeneration();
      if (completed) {
        final notifier = ref.read(remindersProvider.notifier);
        final result = await notifier.completeOccurrence(task);
        if (result.disposition == ReminderActionDisposition.stale) {
          _showMessage(
            l10n.get('reminderOccurrenceChanged'),
            tone: FeedbackTone.warning,
          );
        } else if (result.nativeSyncFailed) {
          showNativeFailure();
        } else if (result.reminder?.isCompleted == false &&
            result.reminder?.triggerTime != null) {
          _showMessage(
            l10n.taskCompletionMessage(
              result.reminder!.taskTitle,
              nextReminder: formatLocalDateTime(result.reminder!.triggerTime!),
            ),
            tone: FeedbackTone.success,
            dismissAfter: const Duration(seconds: 5),
          );
        } else if (result.reminder?.isCompleted == true) {
          final completedTask = result.reminder!;
          final gen = generationForFeedback;
          if (host.mounted && databaseForFeedback.isCurrent(gen)) {
            host.showSnackBar(
              SnackBar(
                content: Text(l10n.taskCompletionMessage(completedTask.taskTitle)),
                action: SnackBarAction(
                  label: l10n.get('undo'),
                  onPressed: () async {
                    try {
                      final undone = await databaseForFeedback.runOperation(
                        gen,
                        () => notifier.updateReminder(
                          completedTask.copyWith(isCompleted: false),
                          baseline: completedTask,
                        ),
                      );
                      if (undone.nativeSyncFailed && host.mounted) {
                        host.showSnackBar(
                          SnackBar(
                            content: Text(l10n.get('reminderNativeSyncFailed')),
                            action: repair,
                          ),
                          tone: FeedbackTone.warning,
                        );
                      }
                    } catch (_) {
                      if (host.mounted) {
                        host.showSnackBar(
                          SnackBar(
                            content: Text(l10n.get('reminderUpdateFailed')),
                          ),
                          tone: FeedbackTone.error,
                        );
                      }
                    }
                  },
                ),
              ),
              tone: FeedbackTone.success,
              dismissAfter: const Duration(seconds: 5),
            );
          }
        }
      } else {
        final database = ref.read(databaseHelperProvider);
        final generation = database.captureGeneration();
        final result = await database.runOperation(
          generation,
          () => ref
              .read(remindersProvider.notifier)
              .updateReminder(
                task.copyWith(isCompleted: false),
                baseline: task,
              ),
        );
        if (result.nativeSyncFailed) {
          showNativeFailure();
        }
        database.checkGeneration(generation);
      }
    } catch (_) {
      _showMessage(l10n.get('reminderUpdateFailed'), tone: FeedbackTone.error);
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  Future<void> _setChecklistItem(String id, bool done) async {
    if (_isBusy || widget.task.details.kind != 'task') return;
    final database = ref.read(databaseHelperProvider);
    final gate = ref.read(runtimeRecoveryGateProvider);
    final l10n = AppLocalizations.of(context);
    setState(() => _isUpdating = true);
    try {
      final token = _checklistToken;
      final generation = _checklistGeneration;
      if (generation == null) throw const RuntimeRecoveryException();
      gate.check(token);
      final result = await database.runOperation(generation, () async {
        gate.check(token);
        return ref
            .read(remindersProvider.notifier)
            .setChecklistItem(widget.task, id, done, generation);
      });
      database.checkGeneration(generation);
      gate.check(token);
      if (result.nativeSyncFailed) {
        _showMessage(
          l10n.get('reminderNativeSyncFailed'),
          tone: FeedbackTone.warning,
        );
      }
    } catch (_) {
      if (!gate.paused) {
        _showMessage(l10n.get('reminderUpdateFailed'), tone: FeedbackTone.error);
      }
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
    final feedback = InlineFeedback.of(context);
    try {
      final database = ref.read(databaseHelperProvider);
      final generation = database.captureGeneration();
      final result = await database.runOperation(
        generation,
        () => notifier.trashTask(task, generation),
      );
      final deleted = result.reminder ?? task;
      database.checkGeneration(generation);
      if (!feedback.mounted) return;
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
                  () => notifier.restoreTrashedTask(deleted, generation),
                );
                if (restored.nativeSyncFailed && feedback.mounted) {
                  feedback.showSnackBar(
                    SnackBar(
                      content: Text(l10n.get('reminderNativeSyncFailed')),
                    ),
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
        tone: result.nativeSyncFailed
            ? FeedbackTone.warning
            : FeedbackTone.info,
      );
    } catch (_) {
      if (feedback.mounted) {
        feedback.showSnackBar(
          SnackBar(content: Text(l10n.get('taskDeleteFailed'))),
          tone: FeedbackTone.error,
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

  void _openEditor() {
    final database = ref.read(databaseHelperProvider);
    final gate = ref.read(runtimeRecoveryGateProvider);
    if (_checklistGeneration == null ||
        !database.isCurrent(_checklistGeneration!) ||
        !gate.isCurrent(_checklistToken)) {
      _showMessage(
        AppLocalizations.of(context).get('reminderOccurrenceChanged'),
      );
      return;
    }
    final latest = ref
        .read(remindersProvider)
        .where((row) => row.id == widget.task.id && row.isVisible)
        .firstOrNull;
    if (latest == null) {
      _showMessage(
        AppLocalizations.of(context).get('reminderOccurrenceChanged'),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TaskEditScreen(
          task: Reminder.fromJson(latest.toJson()),
          originGeneration: _checklistGeneration,
          originToken: _checklistToken,
          onPlayMedia: latest.recordId == widget.task.recordId
              ? widget.onPlayMedia
              : null,
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

  bool get _canQuickPostpone {
    final task = widget.task;
    if (task.isCompleted || task.triggerTime == null) return false;
    if (task.details.kind == 'medication') return false;
    if (task.details.kind == 'departure' && task.details.planId != null) {
      return false;
    }
    return true;
  }

  List<PopupMenuEntry<String>> _menuItems(AppLocalizations l10n) => [
    _menuItem('edit', Icons.edit_outlined, l10n.get('editTask')),
    if (!widget.task.isCompleted)
      _menuItem(
        'pin',
        Icons.push_pin_outlined,
        l10n.get(widget.task.isPinned ? 'unpinToday' : 'pinToday'),
      ),
    _menuItem('move_category', Icons.drive_file_move_outlined, l10n.get('moveCategory')),
    if (_canQuickPostpone)
      _menuItem('postpone', Icons.snooze_outlined, l10n.get('quickPostpone')),
    if (widget.task.canSkipOccurrence)
      _menuItem('skip', Icons.skip_next_outlined, l10n.get('skipOccurrence')),
    if (widget.task.sourceText != null)
      _menuItem('source', Icons.notes_outlined, l10n.get('sourceText')),
    _menuItem(
      'toggle',
      widget.task.isCompleted
          ? Icons.radio_button_unchecked
          : Icons.check_circle_outline,
      widget.task.details.kind == 'medication' && !widget.task.isCompleted
          ? planningText(context, 'taken')
          : l10n.get(widget.task.isCompleted ? 'markUndone' : 'markDone'),
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

  Future<void> _chooseCategory() async {
    if (_isBusy) return;
    final l10n = AppLocalizations.of(context);
    final target = await showTaskCategoryPickerDialog(
      context,
      currentLevel: widget.task.quadrantLevel,
    );
    if (!mounted || target == null || target == widget.task.quadrantLevel) {
      return;
    }
    setState(() => _isUpdating = true);
    try {
      final result = await ref
          .read(remindersProvider.notifier)
          .updateReminder(
            widget.task.copyWith(quadrantLevel: target),
            baseline: widget.task,
          );
      if (!mounted) return;
      if (!result.accepted) {
        _showMessage(
          l10n.get('reminderOccurrenceChanged'),
          tone: FeedbackTone.warning,
        );
        return;
      }
      _showMessage(
        result.nativeSyncFailed
            ? l10n.get('reminderNativeSyncFailed')
            : '${l10n.get('movedToQuadrant')}${l10n.get('cat$target')}: ${widget.task.taskTitle}',
        tone: result.nativeSyncFailed
            ? FeedbackTone.warning
            : FeedbackTone.success,
      );
    } catch (_) {
      _showMessage(l10n.get('reminderUpdateFailed'), tone: FeedbackTone.error);
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  Future<void> _choosePostpone() async {
    if (_isBusy || !_canQuickPostpone) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final choice = await showTaskPostponeDialog(context, widget.task);
    if (!mounted || choice == null) return;
    final now = DateTime.now();
    final currentTrigger = widget.task.triggerTime!;
    final isFuture = currentTrigger.isAfter(now);
    final base = isFuture ? currentTrigger : now;
    final target = await pickSnoozeUntil(context, choice, now: now, base: base);
    if (!mounted || target == null) return;
    setState(() => _isUpdating = true);
    try {
      final notifier = ref.read(remindersProvider.notifier);
      final ReminderActionResult result;
      if (isFuture) {
        final data = Map<String, dynamic>.from(widget.task.details.data)
          ..remove('reminder_lead_minutes');
        final updated = widget.task.copyWith(
          triggerTime: target,
          timeOrigin: ReminderTimeOrigin.manual,
          detailsJson: widget.task.details.data.containsKey('reminder_lead_minutes')
              ? widget.task.details.patch({'data': data}).encode()
              : widget.task.detailsJson,
        );
        result = await notifier.updateReminder(updated, baseline: widget.task);
      } else {
        result = await notifier.snoozeOccurrence(
          widget.task,
          now: now,
          duration: target.difference(now),
        );
      }
      if (!mounted) return;
      if (result.disposition == ReminderActionDisposition.stale) {
        _showMessage(
          l10n.get('reminderOccurrenceChanged'),
          tone: FeedbackTone.warning,
        );
      } else if (result.nativeSyncFailed) {
        _showMessage(
          l10n.get('reminderNativeSyncFailed'),
          tone: FeedbackTone.warning,
        );
      } else {
        final savedTime = result.reminder?.triggerTime ?? target;
        _showMessage(
          '${l10n.get('reminderDelayedTo')} ${formatLocalDateTime(savedTime)}',
          tone: FeedbackTone.success,
        );
      }
    } catch (_) {
      _showMessage(l10n.get('reminderUpdateFailed'), tone: FeedbackTone.error);
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  Future<void> _onAction(String action) async {
    if (_isBusy) return;
    if (action == 'edit') {
      _openEditor();
    } else if (action == 'move_category') {
      await _chooseCategory();
    } else if (action == 'postpone') {
      await _choosePostpone();
    } else if (action == 'source') {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(AppLocalizations.of(context).get('sourceText')),
          content: SingleChildScrollView(
            child: SelectableText(widget.task.sourceText ?? ''),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocalizations.of(context).get('close')),
            ),
          ],
        ),
      );
    } else if (action == 'pin' || action == 'adopt' || action == 'skip') {
      setState(() => _isUpdating = true);
      final loc = AppLocalizations.of(context);
      try {
        final notifier = ref.read(remindersProvider.notifier);
        final result = action == 'skip'
            ? await notifier.skipOccurrence(widget.task)
            : await notifier.updateReminder(
                action == 'pin'
                    ? widget.task.copyWith(isPinned: !widget.task.isPinned)
                    : widget.task.copyWith(
                        triggerTime: widget.task.usableSuggestedTriggerTime,
                        timeOrigin: ReminderTimeOrigin.aiSuggested,
                        suggestedTriggerTime: null,
                      ),
                baseline: widget.task,
              );
        if (result.nativeSyncFailed) {
          _showMessage(
            loc.get('reminderNativeSyncFailed'),
            tone: FeedbackTone.warning,
          );
        } else if (!result.accepted) {
          _showMessage(
            loc.get('reminderOccurrenceChanged'),
            tone: FeedbackTone.warning,
          );
        }
      } on PinLimitException {
        _showMessage(loc.get('pinLimit'), tone: FeedbackTone.warning);
      } catch (_) {
        _showMessage(loc.get('reminderUpdateFailed'), tone: FeedbackTone.error);
      } finally {
        if (mounted) setState(() => _isUpdating = false);
      }
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
        final database = ref.read(databaseHelperProvider);
        final generation = database.captureGeneration();
        await database.runOperation(generation, () async {
          await ref
              .read(remindersProvider.notifier)
              .updateReminder(updated, baseline: widget.task);
        });
      } catch (_) {
        _showMessage(l10n.get('reminderUpdateFailed'), tone: FeedbackTone.error);
      } finally {
        if (mounted) setState(() => _isUpdating = false);
      }
    }
  }

  Widget _badge(
    String label,
    IconData icon,
    Color color, {
    bool tabular = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.22), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: color,
                fontFeatures: tabular ? AppTheme.tabularFigures : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaButton(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colors,
    Reminder task,
    List<String> attachmentIds,
  ) {
    if (attachmentIds.isNotEmpty) {
      return _mediaActionButton(
        colors: colors,
        taskId: task.id,
        icon: Icons.attach_file_rounded,
        label: '${l10n.get('taskAttachments')} · ${attachmentIds.length}',
        onPressed: _isBusy ? null : _openDetails,
      );
    }
    final recordId = task.recordId;
    if (recordId == null) return const SizedBox.shrink();
    return Consumer(
      builder: (context, ref, _) {
        final media = ref.watch(
          mediaRecordByIdProvider.select((byId) => byId[recordId]),
        );
        final mediaIcon = switch (media?.type) {
          'audio' => Icons.mic_none,
          'image' => Icons.image_outlined,
          'video' => Icons.videocam_outlined,
          'file' => Icons.description_outlined,
          _ => null,
        };
        if (mediaIcon == null) return const SizedBox.shrink();
        return _mediaActionButton(
          colors: colors,
          taskId: task.id,
          icon: mediaIcon,
          label: l10n.get('playOrPreview'),
          onPressed: _isBusy ? null : widget.onPlayMedia,
        );
      },
    );
  }

  Widget _mediaActionButton({
    required ColorScheme colors,
    required String taskId,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) => TextButton(
    key: ValueKey('media-$taskId'),
    onPressed: onPressed,
    style: TextButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: colors.primary,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    ),
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final task = widget.task;
    if (!task.isVisible) return const SizedBox.shrink();
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final subTasks = task.subTasksView;
    final details = task.details;
    final summary = task.taskSummary?.trim();
    final now = widget.referenceNow ?? DateTime.now();
    final isOverdue =
        !task.isCompleted &&
        task.triggerTime != null &&
        task.triggerTime!.isBefore(now);
    final isDueSoon =
        !task.isCompleted &&
        !isOverdue &&
        task.triggerTime != null &&
        task.triggerTime!.difference(now) <= const Duration(hours: 24);
    final showSummary =
        summary != null &&
        summary.isNotEmpty &&
        summary.replaceAll(_whitespace, ' ') !=
            task.taskTitle.trim().replaceAll(_whitespace, ' ');
    final sharedTime =
        task.eventTime != null &&
        task.triggerTime != null &&
        task.eventTime!.isAtSameMomentAs(task.triggerTime!);
    final priorityColor = AppTheme.quadrantColor(brightness, task.quadrantLevel);
    final reminderTimeColor = isOverdue
        ? colors.error
        : isDueSoon
        ? colors.primary
        : colors.onSurfaceVariant;
    final eventTimeColor =
        !task.isCompleted && task.eventTime != null && task.eventTime!.isBefore(now)
        ? colors.error
        : (sharedTime && isDueSoon)
        ? colors.primary
        : colors.onSurfaceVariant;
    final metadata = <Widget>[
      if (details.project.isNotEmpty)
        _badge(details.project, Icons.folder_outlined, colors.onSurfaceVariant),
      for (final tag in details.tags.take(3))
        _badge(tag, Icons.tag, colors.onSurfaceVariant),
      if (details.tags.length > 3)
        _badge(
          '+${details.tags.length - 3}',
          Icons.tag,
          colors.onSurfaceVariant,
        ),
      if (task.isPinned && !task.isCompleted)
        _badge(
          l10n.get('todayPinned'),
          Icons.push_pin_outlined,
          colors.primary,
        ),
      if (task.eventTime != null)
        _badge(
          '${l10n.get(sharedTime ? 'taskTimeAndReminder' : 'eventTimeShort')}: ${formatLocalDateTime(task.eventTime!)}',
          Icons.event_outlined,
          eventTimeColor,
          tabular: true,
        ),
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
          l10n.get('priorityRaisedBadge'),
          Icons.bolt_outlined,
          colors.error,
        ),
      if (task.triggerTime != null && !sharedTime)
        _badge(
          '${l10n.get('reminderTimeShort')}: ${formatLocalDateTime(task.triggerTime!)}',
          Icons.access_time,
          reminderTimeColor,
          tabular: true,
        ),
      if (task.triggerTime != null &&
          task.timeOrigin == ReminderTimeOrigin.aiSuggested)
        _badge(
          l10n.get('reminderSourceAi'),
          Icons.auto_awesome_outlined,
          colors.primary,
        ),
      if (isOverdue)
        _badge(l10n.get('overdue'), Icons.schedule_rounded, colors.error),
      if (!task.isCompleted &&
          !sharedTime &&
          task.eventTime != null &&
          task.eventTime!.isBefore(now))
        _badge(
          l10n.get('deadlinePassed'),
          Icons.event_busy_outlined,
          colors.error,
        ),
      if (task.isRecurring || details.data['ordinary_occurrence'] == true)
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

    final cardSurfaceColor = task.isCompleted
        ? colors.surfaceContainerLowest
        : colors.surfaceContainerLow;

    return Dismissible(
      key: ValueKey(task.id),
      direction: _isBusy ? DismissDirection.none : DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(14),
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
      child: MouseRegion(
        onEnter: (_) {
          if (!_hovered.value) _hovered.value = true;
        },
        onExit: (_) {
          if (_hovered.value) _hovered.value = false;
        },
        child: ValueListenableBuilder<bool>(
          valueListenable: _hovered,
          builder: (context, hovered, cardContent) => Container(
            key: ValueKey('task-surface-${task.id}'),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: cardSurfaceColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: hovered
                    ? colors.primary.withValues(alpha: 0.55)
                    : isOverdue
                    ? colors.error.withValues(alpha: 0.45)
                    : (!task.isCompleted && task.isPinned)
                    ? colors.primary.withValues(alpha: 0.35)
                    : colors.outlineVariant.withValues(alpha: 0.65),
              ),
              boxShadow: task.isCompleted
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark
                              ? (hovered ? 0.28 : 0.16)
                              : (hovered ? 0.08 : 0.035),
                        ),
                        blurRadius: hovered ? 10 : 4,
                        offset: Offset(0, hovered ? 3 : 1),
                      ),
                    ],
            ),
            child: cardContent,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _openDetails,
            onSecondaryTapUp: (details) =>
                _showContextMenu(details.globalPosition),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: LayoutBuilder(
                builder: (context, cardConstraints) {
                  final allowHoverActions = cardConstraints.maxWidth >= 440;
                  final checklistDone = details.checklist
                      .where((e) => e.done)
                      .length;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Stack(
                        alignment: AlignmentDirectional.centerEnd,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 3.5,
                                      height: 16,
                                      margin: const EdgeInsets.only(
                                        top: 2,
                                        right: 9,
                                      ),
                                      decoration: BoxDecoration(
                                        color: task.isCompleted
                                            ? colors.outlineVariant
                                            : priorityColor,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                    Expanded(
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
                                  ],
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
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.padded,
                                  value: task.isCompleted,
                                  onChanged: _isBusy
                                      ? null
                                      : (value) {
                                          HapticFeedback.selectionClick();
                                          if (value != null) {
                                            _setCompleted(value);
                                          }
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
                          if (allowHoverActions)
                            PositionedDirectional(
                              end: 96,
                              child: ValueListenableBuilder<bool>(
                                valueListenable: _hovered,
                                builder: (context, hovered, _) {
                                  if (!hovered || _isBusy) {
                                    return const SizedBox.shrink();
                                  }
                                  return DecoratedBox(
                                    key: ValueKey('hover-actions-${task.id}'),
                                    decoration: BoxDecoration(
                                      color: cardSurfaceColor.withValues(
                                        alpha: 0.96,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: colors.outlineVariant.withValues(
                                          alpha: 0.55,
                                        ),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha:
                                                Theme.of(context).brightness ==
                                                    Brightness.dark
                                                ? 0.24
                                                : 0.08,
                                          ),
                                          blurRadius: 8,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (!task.isCompleted)
                                          IconButton(
                                            key: ValueKey(
                                              'hover-pin-${task.id}',
                                            ),
                                            tooltip: l10n.get(
                                              task.isPinned
                                                  ? 'unpinToday'
                                                  : 'pinToday',
                                            ),
                                            constraints: const BoxConstraints(
                                              minWidth: 48,
                                              minHeight: 48,
                                            ),
                                            icon: Icon(
                                              task.isPinned
                                                  ? Icons.push_pin_rounded
                                                  : Icons.push_pin_outlined,
                                              size: 18,
                                              color: task.isPinned
                                                  ? colors.primary
                                                  : colors.onSurfaceVariant,
                                            ),
                                            onPressed: () => _onAction('pin'),
                                          ),
                                        if (_canQuickPostpone)
                                          IconButton(
                                            key: ValueKey(
                                              'hover-postpone-${task.id}',
                                            ),
                                            tooltip: l10n.get('quickPostpone'),
                                            constraints: const BoxConstraints(
                                              minWidth: 48,
                                              minHeight: 48,
                                            ),
                                            icon: Icon(
                                              Icons.snooze_outlined,
                                              size: 18,
                                              color: colors.onSurfaceVariant,
                                            ),
                                            onPressed: _choosePostpone,
                                          ),
                                        IconButton(
                                          key: ValueKey(
                                            'hover-edit-${task.id}',
                                          ),
                                          tooltip: l10n.get('editTask'),
                                          constraints: const BoxConstraints(
                                            minWidth: 48,
                                            minHeight: 48,
                                          ),
                                          icon: Icon(
                                            Icons.edit_outlined,
                                            size: 18,
                                            color: colors.onSurfaceVariant,
                                          ),
                                          onPressed: _openEditor,
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                if (showSummary)
                  Padding(
                    padding: const EdgeInsets.only(left: 12.5, top: 2),
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
                if (isOverdue && _canQuickPostpone)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: TextButton.icon(
                      key: ValueKey('overdue-postpone-${task.id}'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        foregroundColor: colors.error,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: _isBusy ? null : _choosePostpone,
                      icon: const Icon(Icons.snooze_outlined, size: 17),
                      label: Text(l10n.get('quickPostpone')),
                    ),
                  ),
                if (task.usableSuggestedTriggerTime != null &&
                    !task.isCompleted)
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    children: [
                      Text(
                        '${l10n.get('suggestedReminder')}: ${formatLocalDateTime(task.usableSuggestedTriggerTime!)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      TextButton(
                        key: ValueKey('adopt-time-${task.id}'),
                        onPressed:
                            _isBusy ||
                                !task.usableSuggestedTriggerTime!.isAfter(now)
                            ? null
                            : () => _onAction('adopt'),
                        child: Text(l10n.get('adoptSuggestion')),
                      ),
                    ],
                  ),
                if (task.capturePending && !task.isCompleted)
                  Consumer(
                    builder: (context, ref, _) {
                      final pendingCount = ref.watch(
                        homeControllerProvider.select(
                          (s) => s.pendingTasksCount,
                        ),
                      );
                      final controller = ref.read(
                        homeControllerProvider.notifier,
                      );
                      final running =
                          controller.isCaptureRunning(task.id) ||
                          (task.recordId != null && pendingCount > 0);
                      return TextButton.icon(
                        key: ValueKey('retry-capture-${task.id}'),
                        onPressed: running
                            ? null
                            : () => controller.retryCapture(task),
                        icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                        label: Text(
                          l10n.get(
                            running ? 'captureOrganizing' : 'captureContinue',
                          ),
                        ),
                      );
                    },
                  ),
                if (task.captureProposalJson != null && !task.isCompleted)
                  TextButton.icon(
                    key: ValueKey('preview-capture-${task.id}'),
                    onPressed: _isBusy
                        ? null
                        : () => showDialog<void>(
                            context: context,
                            builder: (_) => CapturePreviewDialog(task: task),
                          ),
                    icon: const Icon(Icons.preview_outlined, size: 16),
                    label: Text(l10n.get('capturePreview')),
                  ),
                if (task.recordId != null || details.attachmentIds.isNotEmpty)
                  _buildMediaButton(
                    context,
                    l10n,
                    colors,
                    task,
                    details.attachmentIds,
                  ),
                if (details.checklist.isNotEmpty) ...[
                  Semantics(
                    expanded: _showChecklist,
                    child: TextButton(
                      key: ValueKey('checklist-${task.id}'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        foregroundColor: colors.primary,
                        alignment: Alignment.centerLeft,
                      ),
                      onPressed: () =>
                          setState(() => _showChecklist = !_showChecklist),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.checklist_rounded, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  l10n
                                      .get('taskChecklistProgress')
                                      .replaceAll('{done}', '$checklistDone')
                                      .replaceAll(
                                        '{total}',
                                        '${details.checklist.length}',
                                      ),
                                  style: const TextStyle(
                                    fontFeatures: AppTheme.tabularFigures,
                                  ),
                                ),
                              ),
                              Icon(
                                _showChecklist
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: checklistDone / details.checklist.length,
                              minHeight: 3,
                              backgroundColor: colors.surfaceContainerHighest,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_showChecklist)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final item in details.checklist)
                          Material(
                            color: Colors.transparent,
                            child: CheckboxListTile(
                              key: ValueKey(
                                'checklist-item-${task.id}-${item.id}',
                              ),
                              value: item.done,
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(
                                item.label,
                                style: item.done
                                    ? TextStyle(
                                        decoration: TextDecoration.lineThrough,
                                        color: colors.onSurfaceVariant,
                                      )
                                    : null,
                              ),
                              onChanged: _isBusy || details.kind != 'task'
                                  ? null
                                  : (value) {
                                      HapticFeedback.selectionClick();
                                      _setChecklistItem(
                                        item.id,
                                        value ?? false,
                                      );
                                    },
                            ),
                          ),
                      ],
                    ),
                ],
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
                              '${l10n.get('taskMicroHabits')} (${subTasks.length})',
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
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
                      ],
                    ),
                ],
                if (_isDecomposing)
                  LinearProgressIndicator(
                    semanticsLabel: l10n.get('breakdownLoading'),
                  ),
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
