part of 'task_detail_screen.dart';

/// All ordinary detail routes are readers; only Edit opens a writable form.
class TaskDetailScreen extends ConsumerStatefulWidget {
  const TaskDetailScreen({super.key, required this.task, this.onPlayMedia});
  final Reminder task;
  final VoidCallback? onPlayMedia;
  @override
  ConsumerState<TaskDetailScreen> createState() => _TaskReaderState();
}

class _TaskReaderState extends ConsumerState<TaskDetailScreen> {
  DataGeneration? _generation;
  RuntimeRecoveryToken? _token;
  bool _openingEditor = false;

  @override
  void initState() {
    super.initState();
    try {
      _generation = ref.read(databaseHelperProvider).captureGeneration();
      _token = ref.read(runtimeRecoveryGateProvider).capture();
    } catch (_) {
      // A maintenance-era snapshot remains readable, never editable.
    }
  }

  bool get _current =>
      mounted &&
      _generation != null &&
      ref.read(databaseHelperProvider).isCurrent(_generation!) &&
      ref.read(runtimeRecoveryGateProvider).isCurrent(_token);

  Future<void> _edit() async {
    if (_openingEditor || !_current) return;
    final latest = ref
        .read(remindersProvider)
        .where((r) => r.id == widget.task.id && r.isVisible)
        .firstOrNull;
    if (latest == null) return;
    setState(() => _openingEditor = true);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TaskEditScreen(
            task: Reminder.fromJson(latest.toJson()),
            originGeneration: _generation,
            originToken: _token,
            onPlayMedia: latest.recordId == widget.task.recordId
                ? widget.onPlayMedia
                : null,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingEditor = false);
    }
  }

  Future<void> _copyTask(Reminder task) async {
    final loc = AppLocalizations.of(context);
    final summary = task.taskSummary?.trim();
    final checklist = task.details.checklist;
    final buffer = StringBuffer(task.taskTitle.trim());
    if (summary != null && summary.isNotEmpty && summary != task.taskTitle.trim()) {
      buffer
        ..writeln()
        ..write(summary);
    }
    if (checklist.isNotEmpty) {
      for (final item in checklist) {
        buffer
          ..writeln()
          ..write(item.done ? '- [x] ' : '- [ ] ')
          ..write(item.label);
      }
    }
    try {
      await Clipboard.setData(ClipboardData(text: buffer.toString()));
      if (!mounted) return;
      final inline = context.findAncestorStateOfType<InlineFeedbackState>();
      if (inline != null) {
        inline.showSnackBar(
          SnackBar(content: Text(loc.get('taskContentCopied'))),
          tone: FeedbackTone.success,
        );
      } else {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(loc.get('taskContentCopied'))),
        );
      }
    } catch (_) {}
  }

  Widget _card(Widget child, {Key? key}) => Card.outlined(
    key: key,
    clipBehavior: Clip.antiAlias,
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );

  @override
  Widget build(BuildContext context) {
    final latest = ref.watch(
      remindersByIdProvider.select((byId) => byId[widget.task.id]),
    );
    final task = latest ?? widget.task;
    final details = task.details;
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final quadrantColor = AppTheme.quadrantColor(
      theme.brightness,
      task.quadrantLevel,
    );
    final readingStyle = theme.textTheme.bodyLarge?.copyWith(height: 1.6);
    final hasAttachments =
        task.recordId != null || details.attachmentIds.isNotEmpty;
    final vocabEntries = task.taskSummary?.isNotEmpty == true
        ? VocabularyEntry.parseNotes(task.taskSummary!)
        : const <VocabularyEntry>[];
    final checklist = details.checklist;
    final checklistDone = checklist.where((e) => e.done).length;

    Widget dateTile(
      String label,
      DateTime? value,
      IconData icon, {
      bool showCountdown = false,
    }) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: colors.primary),
      title: Text(loc.get(label)),
      subtitle: value == null
          ? Text(loc.get('notSet'))
          : showCountdown && !task.isCompleted
          ? ForegroundTimeBuilder(
              boundary: value,
              builder: (context, now) {
                final overdue = !value.isAfter(now);
                return Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      formatLocalDateTime(value),
                      style: overdue
                          ? TextStyle(
                              color: colors.error,
                              fontWeight: FontWeight.w600,
                            )
                          : null,
                    ),
                    Text(
                      formatReminderTimeRemaining(loc, value, now),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: overdue ? colors.error : colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                );
              },
            )
          : Text(formatLocalDateTime(value)),
    );

    final rule = ContextTriggerRule.tryParse(task.contextTrigger);
    final now = DateTime.now();
    final isOverdue =
        !task.isCompleted &&
        ((task.triggerTime != null && task.triggerTime!.isBefore(now)) ||
            (task.eventTime != null && task.eventTime!.isBefore(now)));
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Navigator.of(context).maybePop();
        },
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): _edit,
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true): _edit,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const ValueKey('task-detail-reader'),
          appBar: AppBar(
            centerTitle: false,
            title: Text(loc.get('taskDetailTitle')),
            actions: [
              IconButton(
                key: const ValueKey('task-detail-copy'),
                tooltip: loc.get('copyTaskContent'),
                onPressed: () => _copyTask(task),
                icon: const Icon(Icons.copy_outlined),
              ),
            ],
          ),
          bottomNavigationBar: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border(
                top: BorderSide(
                  color: colors.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Align(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 768),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('task-detail-modify'),
                        onPressed:
                            !_current ||
                                _openingEditor ||
                                latest == null ||
                                !latest.isVisible
                            ? null
                            : _edit,
                        icon: const Icon(Icons.edit_outlined),
                        label: Text(loc.get('modifyTask')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: ListView(
                  key: const ValueKey('task-detail-reader-list'),
                  padding: const EdgeInsets.all(16),
                  children: [
                    _card(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              Chip(
                                avatar: Icon(
                                  AppTheme.quadrantIcon(task.quadrantLevel),
                                  size: 16,
                                  color: quadrantColor,
                                ),
                                backgroundColor: quadrantColor.withValues(
                                  alpha: 0.12,
                                ),
                                side: BorderSide(
                                  color: quadrantColor.withValues(alpha: 0.3),
                                ),
                                label: Text(
                                  loc.get('cat${task.quadrantLevel}'),
                                  style: TextStyle(
                                    color: quadrantColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Chip(
                                avatar: Icon(
                                  task.isCompleted
                                      ? Icons.check_circle_outline
                                      : Icons.schedule,
                                  size: 18,
                                  color: task.isCompleted
                                      ? colors.primary
                                      : colors.onSurfaceVariant,
                                ),
                                label: Text(
                                  loc.get(
                                    task.isCompleted
                                        ? 'statusCompleted'
                                        : 'statusPending',
                                  ),
                                ),
                              ),
                              if (task.isPinned)
                                Chip(
                                  avatar: Icon(
                                    Icons.push_pin_rounded,
                                    size: 16,
                                    color: colors.primary,
                                  ),
                                  label: Text(loc.get('pin')),
                                ),
                              if (isOverdue)
                                Chip(
                                  avatar: Icon(
                                    Icons.schedule_rounded,
                                    size: 16,
                                    color: colors.onErrorContainer,
                                  ),
                                  backgroundColor: colors.errorContainer,
                                  side: BorderSide(
                                    color: colors.error.withValues(alpha: 0.35),
                                  ),
                                  label: Text(
                                    loc.get('overdue'),
                                    style: TextStyle(
                                      color: colors.onErrorContainer,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SelectableText(
                            task.taskTitle,
                            key: const ValueKey('task-detail-read-title'),
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (task.taskSummary?.isNotEmpty == true)
                      _card(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              loc.get('taskDetailsSupplement'),
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: colors.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (vocabEntries.isNotEmpty)
                              VocabularyDeck(
                                content: task.taskSummary!,
                                preparsedEntries: vocabEntries,
                              )
                            else
                              SelectableText(
                                task.taskSummary!,
                                key: const ValueKey('task-detail-read-summary'),
                                style: readingStyle,
                              ),
                          ],
                        ),
                      ),
                    if (task.eventTime != null ||
                        task.triggerTime != null ||
                        task.isRecurring ||
                        rule != null)
                      _card(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (task.eventTime != null)
                              dateTile(
                                'eventTimeShort',
                                task.eventTime,
                                Icons.event_outlined,
                                showCountdown: true,
                              ),
                            if (task.triggerTime != null)
                              dateTile(
                                'triggerTimeLabel',
                                task.triggerTime,
                                Icons.notifications_none,
                                showCountdown: true,
                              ),
                            if (task.isRecurring)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  Icons.event_repeat,
                                  color: colors.primary,
                                ),
                                title: Text(loc.get('recurrenceLabel')),
                                subtitle: Text(
                                  task.recurrenceDescription ??
                                      loc.get(switch (task.recurrenceRule) {
                                        'daily' => 'repeatDaily',
                                        'workday' => 'repeatWorkday',
                                        'weekly' => 'repeatWeekly',
                                        'monthly' => 'repeatMonthly',
                                        'yearly' => 'repeatYearly',
                                        _ => 'repeatNone',
                                      }),
                                ),
                              ),
                            if (rule != null)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  rule.type == 'wifi'
                                      ? Icons.wifi
                                      : Icons.location_on_outlined,
                                  color: colors.primary,
                                ),
                                title: Text(
                                  rule.type == 'profile'
                                      ? switch (rule.value) {
                                          'general' => loc.get('profileGeneral'),
                                          'office' => loc.get('profileOffice'),
                                          'deepWork' =>
                                            loc.get('profileDeepWork'),
                                          'home' => loc.get('profileHome'),
                                          'commute' => loc.get('profileCommute'),
                                          _ => rule.value,
                                        }
                                      : rule.value,
                                ),
                                subtitle: rule.prompt == null
                                    ? null
                                    : Text(rule.prompt!),
                              ),
                          ],
                        ),
                      ),
                    if (details.project.isNotEmpty ||
                        details.tags.isNotEmpty ||
                        checklist.isNotEmpty)
                      _card(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (details.project.isNotEmpty)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  Icons.folder_outlined,
                                  color: colors.primary,
                                ),
                                title: Text(loc.get('taskProject')),
                                subtitle: SelectableText(details.project),
                              ),
                            if (details.tags.isNotEmpty) ...[
                              Text(
                                loc.get('taskTags'),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final tag in details.tags)
                                    Chip(label: Text(tag)),
                                ],
                              ),
                              if (checklist.isNotEmpty)
                                const SizedBox(height: 12),
                            ],
                            if (checklist.isNotEmpty) ...[
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      loc.get('taskChecklist'),
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            color: colors.onSurfaceVariant,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ),
                                  Text(
                                    '$checklistDone / ${checklist.length}',
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: colors.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: checklistDone / checklist.length,
                                  minHeight: 4,
                                  backgroundColor:
                                      colors.surfaceContainerHighest,
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                            for (final item in checklist)
                              Semantics(
                                container: true,
                                checked: item.done,
                                child: ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    item.done
                                        ? Icons.check_box_outlined
                                        : Icons.check_box_outline_blank,
                                    color: item.done
                                        ? colors.primary
                                        : colors.onSurfaceVariant,
                                    semanticLabel: loc.get(
                                      item.done
                                          ? 'checklistDone'
                                          : 'checklistPending',
                                    ),
                                  ),
                                  title: Text(
                                    item.label,
                                    style: item.done
                                        ? TextStyle(
                                            decoration:
                                                TextDecoration.lineThrough,
                                            color: colors.onSurfaceVariant,
                                          )
                                        : null,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (task.subTasksView.isNotEmpty)
                      _card(
                        ExpansionTile(
                          shape: const Border(),
                          collapsedShape: const Border(),
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(bottom: 4),
                          title: Text(
                            '${loc.get('taskMicroHabits')} (${task.subTasksView.length})',
                          ),
                          children: [
                            for (final habit in task.subTasksView)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  Icons.subdirectory_arrow_right_rounded,
                                  size: 18,
                                  color: colors.onSurfaceVariant,
                                ),
                                title: Text(habit),
                              ),
                          ],
                        ),
                      ),
                    if (task.linkedTaskIds.isNotEmpty)
                      _card(
                        Consumer(
                          builder: (context, ref, _) {
                            final byId = ref.watch(remindersByIdProvider);
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  loc.get('bidirectionalLinks'),
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                for (final id in task.linkedTaskIds)
                                  Builder(
                                    builder: (context) {
                                      final row = byId[id];
                                      final visibleRow =
                                          row != null && row.isVisible
                                          ? row
                                          : null;
                                      return ListTile(
                                        key: ValueKey('reader-linked-$id'),
                                        contentPadding: EdgeInsets.zero,
                                        leading: Icon(
                                          Icons.link,
                                          color: colors.primary,
                                        ),
                                        title: Text(
                                          visibleRow?.taskTitle ??
                                              loc.get('linkedTaskUnavailable'),
                                        ),
                                        trailing: visibleRow == null
                                            ? null
                                            : const Icon(Icons.chevron_right),
                                        onTap: visibleRow == null
                                            ? null
                                            : () => Navigator.push(
                                                context,
                                                MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      TaskDetailScreen(
                                                        task: visibleRow,
                                                      ),
                                                ),
                                              ),
                                      );
                                    },
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    if (hasAttachments)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: TaskAttachmentsPanel(task: task, readOnly: true),
                      ),
                    if (task.recordId != null &&
                        task.recordId == widget.task.recordId &&
                        widget.onPlayMedia != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: OutlinedButton.icon(
                          onPressed: widget.onPlayMedia,
                          icon: const Icon(Icons.play_arrow_outlined),
                          label: Text(loc.get('playOrPreview')),
                        ),
                      ),
                    if (task.sourceText?.isNotEmpty == true)
                      _card(
                        ExpansionTile(
                          shape: const Border(),
                          collapsedShape: const Border(),
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(bottom: 4),
                          title: Text(loc.get('sourceText')),
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: SelectableText(
                                task.sourceText!,
                                style: readingStyle,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
