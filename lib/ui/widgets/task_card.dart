import 'inline_feedback.dart';
import 'capture_preview_dialog.dart';
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
  bool _showSubtasks = false;
  bool _showChecklist = false;
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

  bool get _isBusy => _isUpdating || _isDeleting;

  void _showMessage(String message) {
    if (!mounted) return;
    InlineFeedback.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action:
            message ==
                AppLocalizations.of(context).get('reminderNativeSyncFailed')
            ? notificationRepairAction(context)
            : null,
      ),
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
    final databaseForFeedback = ref.read(databaseHelperProvider);
    final generationForFeedback = databaseForFeedback.captureGeneration();
    final host = InlineFeedback.of(context);
    final repair = notificationRepairAction(context);
    void showNativeFailure() {
      if (host.mounted &&
          databaseForFeedback.isCurrent(generationForFeedback)) {
        host.showSnackBar(
          SnackBar(
            content: Text(l10n.get('reminderNativeSyncFailed')),
            action: repair,
          ),
        );
      }
    }

    try {
      if (completed) {
        final result = await ref
            .read(remindersProvider.notifier)
            .completeOccurrence(task);
        if (result.disposition == ReminderActionDisposition.stale) {
          _showMessage(l10n.get('reminderOccurrenceChanged'));
        } else if (result.nativeSyncFailed) {
          showNativeFailure();
        } else if (result.reminder?.isCompleted == false &&
            result.reminder?.triggerTime != null) {
          _showMessage(
            '${l10n.get('periodicNext')}${formatLocalDateTime(result.reminder!.triggerTime!)}',
          );
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
      _showMessage(l10n.get('reminderUpdateFailed'));
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
        _showMessage(l10n.get('reminderNativeSyncFailed'));
      }
    } catch (_) {
      if (!gate.paused) _showMessage(l10n.get('reminderUpdateFailed'));
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
    if (!widget.task.isCompleted)
      _menuItem(
        'pin',
        Icons.push_pin_outlined,
        l10n.get(widget.task.isPinned ? 'unpinToday' : 'pinToday'),
      ),
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

  Future<void> _onAction(String action) async {
    if (_isBusy) return;
    if (action == 'edit') {
      _openDetails();
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
                        triggerTime: widget.task.suggestedTriggerTime,
                        timeOrigin: ReminderTimeOrigin.aiSuggested,
                        suggestedTriggerTime: null,
                      ),
                baseline: widget.task,
              );
        if (result.nativeSyncFailed) {
          _showMessage(loc.get('reminderNativeSyncFailed'));
        } else if (!result.accepted) {
          _showMessage(loc.get('reminderOccurrenceChanged'));
        }
      } on PinLimitException {
        _showMessage(loc.get('pinLimit'));
      } catch (_) {
        _showMessage(loc.get('reminderUpdateFailed'));
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
    if (!task.isVisible) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subTasks = task.subTasksView;
    final details = task.details;
    final summary = task.taskSummary?.trim();
    final showSummary =
        summary != null &&
        summary.isNotEmpty &&
        summary.replaceAll(RegExp(r'\s+'), ' ') !=
            task.taskTitle.trim().replaceAll(RegExp(r'\s+'), ' ');
    final sharedTime =
        task.eventTime != null &&
        task.triggerTime != null &&
        task.eventTime!.isAtSameMomentAs(task.triggerTime!);
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
    if (details.attachmentIds.isNotEmpty) {
      mediaIcon = Icons.attach_file_rounded;
    }
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
          colors.onSurfaceVariant,
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
          colors.onSurfaceVariant,
        ),
      if (task.triggerTime != null &&
          task.timeOrigin == ReminderTimeOrigin.aiSuggested)
        _badge(
          l10n.get('reminderSourceAi'),
          Icons.auto_awesome_outlined,
          colors.primary,
        ),
      if (!task.isCompleted && task.isOverdue)
        _badge(l10n.get('overdue'), Icons.schedule_rounded, colors.error),
      if (!task.isCompleted &&
          !sharedTime &&
          task.eventTime != null &&
          task.eventTime!.isBefore(DateTime.now()))
        _badge(
          l10n.get('deadlinePassed'),
          Icons.event_busy_outlined,
          colors.error,
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
          color: task.isCompleted
              ? colors.surfaceContainerLowest
              : colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: 0.65),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _openDetails,
          onSecondaryTapUp: (details) =>
              _showContextMenu(details.globalPosition),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        Icons.circle,
                        size: 6,
                        color: task.isCompleted
                            ? colors.onSurfaceVariant
                            : priorityColor,
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
                if (showSummary)
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
                if (task.suggestedTriggerTime != null && !task.isCompleted)
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    children: [
                      Text(
                        '${l10n.get('suggestedReminder')}: ${formatLocalDateTime(task.suggestedTriggerTime!)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      TextButton(
                        key: ValueKey('adopt-time-${task.id}'),
                        onPressed:
                            _isBusy ||
                                !task.suggestedTriggerTime!.isAfter(
                                  DateTime.now(),
                                )
                            ? null
                            : () => _onAction('adopt'),
                        child: Text(l10n.get('adoptSuggestion')),
                      ),
                    ],
                  ),
                if (task.capturePending && !task.isCompleted)
                  Consumer(
                    builder: (context, ref, _) {
                      ref.watch(homeControllerProvider);
                      final controller = ref.read(
                        homeControllerProvider.notifier,
                      );
                      final running =
                          controller.isCaptureRunning(task.id) ||
                          (task.recordId != null &&
                              ref
                                  .read(homeControllerProvider)
                                  .isProcessingInBackground);
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
                if (mediaIcon != null)
                  TextButton(
                    key: ValueKey('media-${task.id}'),
                    onPressed: _isBusy
                        ? null
                        : details.attachmentIds.isNotEmpty
                        ? _openDetails
                        : widget.onPlayMedia,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: colors.primary,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(mediaIcon, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            details.attachmentIds.isNotEmpty
                                ? '${l10n.get('taskAttachments')} · ${details.attachmentIds.length}'
                                : l10n.get('playOrPreview'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (details.checklist.isNotEmpty) ...[
                  TextButton(
                    key: ValueKey('checklist-${task.id}'),
                    onPressed: () =>
                        setState(() => _showChecklist = !_showChecklist),
                    child: Row(
                      children: [
                        const Icon(Icons.checklist_rounded, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n
                                .get('taskChecklistProgress')
                                .replaceAll(
                                  '{done}',
                                  '${details.checklist.where((e) => e.done).length}',
                                )
                                .replaceAll(
                                  '{total}',
                                  '${details.checklist.length}',
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
                  ),
                  if (_showChecklist)
                    for (final item in details.checklist)
                      Material(
                        color: Colors.transparent,
                        child: CheckboxListTile(
                          key: ValueKey('checklist-item-${task.id}-${item.id}'),
                          value: item.done,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(item.label),
                          onChanged: _isBusy || details.kind != 'task'
                              ? null
                              : (value) =>
                                    _setChecklistItem(item.id, value ?? false),
                        ),
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
                if (_isDecomposing)
                  LinearProgressIndicator(
                    semanticsLabel: l10n.get('breakdownLoading'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
