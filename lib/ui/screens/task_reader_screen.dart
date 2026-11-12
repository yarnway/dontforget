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

  Widget _card(Widget child, {Key? key}) => Card.outlined(
    key: key,
    clipBehavior: Clip.antiAlias,
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(remindersProvider);
    final latest = rows.where((r) => r.id == widget.task.id).firstOrNull;
    final task = latest ?? widget.task;
    final details = task.details;
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final hasAttachments =
        task.recordId != null || details.attachmentIds.isNotEmpty;
    final linked = <String, Reminder>{};
    if (task.linkedTaskIds.isNotEmpty) {
      final needed = task.linkedTaskIds.toSet();
      for (final row in rows) {
        if (needed.remove(row.id) && row.isVisible) linked[row.id] = row;
        if (needed.isEmpty) break;
      }
    }
    Widget date(String label, DateTime? value, IconData icon) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(loc.get(label)),
      subtitle: Text(
        value == null ? loc.get('notSet') : formatLocalDateTime(value),
      ),
    );
    final rule = ContextTriggerRule.tryParse(task.contextTrigger);
    return Scaffold(
      key: const ValueKey('task-detail-reader'),
      appBar: AppBar(title: Text(loc.get('taskDetailTitle'))),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Align(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1008),
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
      body: SafeArea(
        top: false,
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
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
                            label: Text(loc.get('cat${task.quadrantLevel}')),
                          ),
                          Chip(
                            avatar: Icon(
                              task.isCompleted
                                  ? Icons.check_circle_outline
                                  : Icons.schedule,
                              size: 18,
                            ),
                            label: Text(
                              loc.get(
                                task.isCompleted
                                    ? 'statusCompleted'
                                    : 'statusPending',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        task.taskTitle,
                        key: const ValueKey('task-detail-read-title'),
                        style: theme.textTheme.headlineSmall,
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
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 12),
                        if (VocabularyEntry.parseNotes(
                          task.taskSummary!,
                        ).isNotEmpty)
                          VocabularyDeck(content: task.taskSummary!)
                        else
                          SelectableText(
                            task.taskSummary!,
                            key: const ValueKey('task-detail-read-summary'),
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
                          date(
                            'eventTimeShort',
                            task.eventTime,
                            Icons.event_outlined,
                          ),
                        if (task.triggerTime != null)
                          date(
                            'triggerTimeLabel',
                            task.triggerTime,
                            Icons.notifications_none,
                          ),
                        if (task.isRecurring)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.event_repeat),
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
                            ),
                            title: Text(
                              rule.type == 'profile'
                                  ? switch (rule.value) {
                                      'general' => loc.get('profileGeneral'),
                                      'office' => loc.get('profileOffice'),
                                      'deepWork' => loc.get('profileDeepWork'),
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
                    details.checklist.isNotEmpty)
                  _card(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (details.project.isNotEmpty)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(loc.get('taskProject')),
                            subtitle: SelectableText(details.project),
                          ),
                        if (details.tags.isNotEmpty)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final tag in details.tags)
                                Chip(label: Text(tag)),
                            ],
                          ),
                        for (final item in details.checklist)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              item.done
                                  ? Icons.check_box_outlined
                                  : Icons.check_box_outline_blank,
                            ),
                            title: Text(item.label),
                          ),
                      ],
                    ),
                  ),
                if (task.subTasksView.isNotEmpty)
                  _card(
                    ExpansionTile(
                      title: Text(loc.get('taskMicroHabits')),
                      children: [
                        for (final habit in task.subTasksView)
                          ListTile(title: Text(habit)),
                      ],
                    ),
                  ),
                if (task.linkedTaskIds.isNotEmpty)
                  _card(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          loc.get('bidirectionalLinks'),
                          style: theme.textTheme.titleSmall,
                        ),
                        for (final id in task.linkedTaskIds)
                          ListTile(
                            key: ValueKey('reader-linked-$id'),
                            leading: const Icon(Icons.link),
                            title: Text(
                              linked[id]?.taskTitle ??
                                  loc.get('linkedTaskUnavailable'),
                            ),
                            trailing: linked[id] == null
                                ? null
                                : const Icon(Icons.chevron_right),
                            onTap: linked[id] == null
                                ? null
                                : () => Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          TaskDetailScreen(task: linked[id]!),
                                    ),
                                  ),
                          ),
                      ],
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
                      title: Text(loc.get('sourceText')),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(task.sourceText!),
                        ),
                      ],
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
