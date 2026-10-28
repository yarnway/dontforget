import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/database_helper.dart';
import '../../l10n/planning_strings.dart';
import '../../models/reminder.dart';
import '../../models/task_details.dart';
import '../../models/task_template.dart';
import '../../models/calendar_exceptions.dart';
import '../../models/ordinary_series.dart';
import '../../models/holiday_calendar.dart';
import '../../l10n/routine_policy_strings.dart';
import 'holiday_policy_editor.dart';
import '../../providers/providers.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';
import '../screens/notification_repair_screen.dart';
import '../../l10n/app_localizations.dart';
import 'departure_plan_panel.dart';
import 'routine_coverage_panel.dart';
import 'medication_plan_panel.dart';
import 'portable_backup_panel.dart';
import 'learning_management_panel.dart';
import 'inline_feedback.dart';
import 'workspace_tool_panel.dart';
import 'saved_task_filters_bar.dart';
import 'task_template_library.dart';
import 'weekly_task_review_panel.dart';
import 'calendar_exceptions_editor.dart';
import '../../l10n/content_management_strings.dart';
import '../../models/task_metadata_patch.dart';
import 'task_metadata_dialog.dart';
import 'content_management_panel.dart';

class PlanningPanel extends StatefulWidget {
  const PlanningPanel({
    super.key,
    this.onClose,
    this.initialMedicationId,
    this.initialDepartureId,
  });
  final String? initialMedicationId, initialDepartureId;
  final VoidCallback? onClose;
  @override
  State<PlanningPanel> createState() => _PlanningPanelState();
}

class _PlanningPanelState extends State<PlanningPanel> {
  late int _tab;
  @override
  void initState() {
    super.initState();
    _tab = widget.initialDepartureId == null ? 0 : 1;
  }

  @override
  Widget build(BuildContext context) => WorkspaceToolFrame(
    title: planningText(context, 'planning'),
    icon: Icons.event_repeat,
    embedded: true,
    onClose: widget.onClose,
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              for (var i = 0; i < 6; i++)
                ChoiceChip(
                  label: Text(
                    i == 5
                        ? contentText(context, 'title')
                        : planningText(
                            context,
                            [
                              'medication',
                              'departure',
                              'manage',
                              'backup',
                              'learningManage',
                            ][i],
                          ),
                  ),
                  selected: _tab == i,
                  onSelected: (_) => setState(() => _tab = i),
                ),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              MedicationPlanPanel(initialPlanId: widget.initialMedicationId),
              DeparturePlanPanel(initialPlanId: widget.initialDepartureId),
              const TaskManagementPanel(),
              const PortableBackupPanel(),
              const LearningManagementPanel(),
              _tab == 5
                  ? const ContentManagementPanel()
                  : const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    ),
  );
}

class TaskManagementPanel extends ConsumerStatefulWidget {
  const TaskManagementPanel({super.key});
  @override
  ConsumerState<TaskManagementPanel> createState() =>
      _TaskManagementPanelState();
}

class _TaskManagementPanelState extends ConsumerState<TaskManagementPanel> {
  final _modelCancellation = CancelToken();
  final _queryController = TextEditingController();
  String _view = 'manage', _query = '';
  bool _busy = false;
  bool _promptOpen = false;
  bool _selecting = false;
  final _selection = <String, Reminder>{};
  late final DatabaseHelper _database;
  late final DataGeneration _generation;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken _birth;
  bool get _current =>
      mounted && _runtime.isCurrent(_birth) && _database.isCurrent(_generation);
  String t(String key) => planningText(context, key);
  @override
  void dispose() {
    _modelCancellation.cancel('Task manager closed');
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _testAi() async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(llmServiceProvider)
          .structuredProposal(
            'Return exactly JSON {"ok":true}. This is a user-requested text/JSON connection test. Do not create tasks.',
            'Connection test',
            ref.read(settingsProvider),
            cancelToken: _modelCancellation,
          );
      if (!mounted || !_current) return;
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          content: Text(t(result['ok'] == true ? 'aiTestPassed' : 'failed')),
        ),
      );
    } catch (_) {
      if (mounted && _current) {
        InlineFeedback.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('failed'))));
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _generation = _database.captureGeneration();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.capture();
  }

  Future<void> _action(Reminder row, String action) async {
    if (!mounted || !context.mounted || !_current || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(remindersProvider.notifier)
          .changeLifecycle(row, action, _generation);
      if (mounted && context.mounted && _current) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.nativeSyncFailures > 0
                  ? AppLocalizations.of(context).get('reminderNativeSyncFailed')
                  : t('saved'),
            ),
            action: result.nativeSyncFailures > 0
                ? SnackBarAction(
                    label: AppLocalizations.of(
                      context,
                    ).get('repairNotifications'),
                    onPressed: notificationRepairAction(context).onPressed,
                  )
                : null,
          ),
        );
      }
    } catch (_) {
      if (mounted && context.mounted && _current) {
        InlineFeedback.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('failed'))));
      }
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  Future<void> _editor(Reminder? row) async {
    await showDialog<void>(
      context: context,
      builder: (_) => TaskManagementEditor(task: row),
    );
  }

  Future<void> _bulk(String action) async {
    if (!_current || _busy || _promptOpen || _selection.isEmpty) return;
    final selected = List<Reminder>.unmodifiable(_selection.values);
    _promptOpen = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            '${t('bulkConfirm')} · ${t(action == 'trash' ? 'moveTrash' : action)} · ${selected.length}',
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(t('bulkHint')),
                  for (final row in selected.take(5)) Text(row.taskTitle),
                  if (selected.length > 5) Text('… +${selected.length - 5}'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppLocalizations.of(context).get('cancel')),
            ),
            FilledButton(
              key: const ValueKey('bulk-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(t(action == 'trash' ? 'moveTrash' : action)),
            ),
          ],
        ),
      );
      if (!mounted || !context.mounted || !_current || confirmed != true) {
        return;
      }
      setState(() => _busy = true);
      final result = await ref
          .read(remindersProvider.notifier)
          .changeLifecycleBatch(selected, action, _generation);
      if (!mounted || !context.mounted || !_current) return;
      setState(() {
        _selection.clear();
        _selecting = false;
      });
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.nativeSyncFailures > 0
                ? AppLocalizations.of(context).get('reminderNativeSyncFailed')
                : t('saved'),
          ),
          action: result.nativeSyncFailures > 0
              ? SnackBarAction(
                  label: AppLocalizations.of(
                    context,
                  ).get('repairNotifications'),
                  onPressed: notificationRepairAction(context).onPressed,
                )
              : null,
        ),
      );
    } catch (_) {
      if (mounted && context.mounted && _current) {
        InlineFeedback.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('bulkChanged'))));
      }
    } finally {
      _promptOpen = false;
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _metadata() async {
    if (!_current || _busy || _promptOpen || _selection.isEmpty) return;
    final rows = List<Reminder>.unmodifiable(_selection.values);
    _promptOpen = true;
    try {
      final patch = await showDialog<TaskMetadataPatch>(
        context: context,
        builder: (_) => TaskMetadataDialog(rows: rows),
      );
      if (!_current || patch == null) return;
      setState(() => _busy = true);
      await ref
          .read(remindersProvider.notifier)
          .updateMetadataBatch(rows, patch, _generation);
      if (_current) {
        setState(() {
          _selection.clear();
          _selecting = false;
        });
      }
    } catch (_) {
      if (mounted && _current) {
        InlineFeedback.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('bulkChanged'))));
      }
    } finally {
      _promptOpen = false;
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(remindersProvider);
    final configured = ref.watch(settingsProvider).hasConfiguredExtraction;
    return LayoutBuilder(
      builder: (_, constraints) => _content(all, constraints, configured),
    );
  }

  Widget _content(
    List<Reminder> all,
    BoxConstraints constraints,
    bool configured,
  ) {
    final query = _query.trim().toLowerCase();
    final rows =
        all.where((r) {
          final accepted = switch (_view) {
            'trash' => r.details.deletedAt != null,
            'archive' =>
              r.details.deletedAt == null && r.details.archivedAt != null,
            'pause' => r.isVisible && r.details.paused,
            _ => r.isVisible,
          };
          return accepted &&
              r.details.data['learning_archive'] != true &&
              r.details.planId == null &&
              '${r.taskTitle} ${r.details.project} ${r.details.tags.join(' ')}'
                  .toLowerCase()
                  .contains(query);
        }).toList()..sort(
          (a, b) => (b.createdAt ?? DateTime(2000)).compareTo(
            a.createdAt ?? DateTime(2000),
          ),
        );
    final events = [
      for (final row in all)
        if ('${row.taskTitle} ${row.details.project} ${row.details.tags.join(' ')}'
            .toLowerCase()
            .contains(query))
          for (final event in row.details.history) (row: row, event: event),
    ]..sort((a, b) => b.event.at.compareTo(a.event.at));
    return Column(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: constraints.maxHeight * .65),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      for (final view in [
                        'manage',
                        'pause',
                        'trash',
                        'archive',
                        'history',
                      ])
                        ChoiceChip(
                          label: Text(t(view)),
                          selected: _view == view,
                          onSelected: _busy
                              ? null
                              : (_) => setState(() {
                                  _view = view;
                                  _selection.clear();
                                  _selecting = false;
                                }),
                        ),
                    ],
                  ),
                  TextField(
                    controller: _queryController,
                    decoration: InputDecoration(
                      labelText: t('filter'),
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onChanged: (v) => setState(() {
                      _query = v;
                      _selection.clear();
                    }),
                  ),
                  SavedTaskFiltersBar(
                    view: _view,
                    query: _query,
                    onSelected: (filter) {
                      if (!_current) return;
                      setState(() {
                        _view = filter.view;
                        _query = filter.query;
                        _queryController.text = filter.query;
                        _selection.clear();
                        _selecting = false;
                      });
                    },
                  ),
                  TextButton.icon(
                    onPressed: _busy || !configured ? null : _testAi,
                    icon: const Icon(Icons.network_check),
                    label: Text(t('testAi')),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : () => _editor(null),
                    icon: const Icon(Icons.add),
                    label: Text(t('newChecklist')),
                  ),
                  Wrap(
                    spacing: 6,
                    children: [
                      TextButton.icon(
                        key: const ValueKey('manage-templates'),
                        onPressed: _busy
                            ? null
                            : () => showDialog<void>(
                                context: context,
                                builder: (_) => const TaskTemplateLibrary(),
                              ),
                        icon: const Icon(Icons.library_books_outlined),
                        label: Text(t('templates')),
                      ),
                      if (_view != 'history')
                        TextButton.icon(
                          key: const ValueKey('bulk-select'),
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _selecting = !_selecting;
                                  _selection.clear();
                                }),
                          icon: const Icon(Icons.checklist),
                          label: Text(
                            t(_selecting ? 'bulkCancel' : 'bulkSelect'),
                          ),
                        ),
                    ],
                  ),
                  if (_selecting) ...[
                    Text('${t('bulkSelected')}: ${_selection.length}/50'),
                    Text(
                      t('bulkHint'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        TextButton(
                          key: const ValueKey('bulk-visible'),
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _selection.clear();
                                  for (final row
                                      in rows
                                          .where(
                                            (r) =>
                                                r.details.kind == 'task' &&
                                                r.details.planId == null &&
                                                !all.any(
                                                  (child) =>
                                                      child.details.planId ==
                                                      r.id,
                                                ),
                                          )
                                          .take(50)) {
                                    _selection[row.id] = row;
                                  }
                                }),
                          child: Text(t('bulkSelectVisible')),
                        ),
                        if (_view != 'trash')
                          TextButton(
                            key: const ValueKey('bulk-metadata'),
                            onPressed: _busy || _selection.isEmpty
                                ? null
                                : _metadata,
                            child: Text(contentText(context, 'metadata')),
                          ),
                        for (final action in [
                          if (_view == 'trash')
                            'restore'
                          else if (_view == 'archive')
                            'unarchive'
                          else ...[
                            'pause',
                            'resume',
                            'archive',
                            'trash',
                          ],
                        ])
                          TextButton(
                            key: ValueKey('bulk-$action'),
                            onPressed:
                                _busy ||
                                    _selection.isEmpty ||
                                    (action == 'pause' &&
                                        _selection.values.any(
                                          (r) =>
                                              r.isCompleted || r.details.paused,
                                        )) ||
                                    (action == 'resume' &&
                                        _selection.values.any(
                                          (r) =>
                                              r.isCompleted ||
                                              !r.details.paused,
                                        )) ||
                                    (action == 'archive' &&
                                        _selection.values.any(
                                          (r) => !r.isCompleted,
                                        ))
                                ? null
                                : () => _bulk(action),
                            child: Text(
                              t(action == 'trash' ? 'moveTrash' : action),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: _view == 'history'
              ? ListView.builder(
                  itemCount: (events.length > 300 ? 300 : events.length) + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return WeeklyTaskReviewPanel(rows: all, query: _query);
                    }
                    final e = events[i - 1];
                    return ListTile(
                      title: Text(e.row.taskTitle),
                      subtitle: Text(
                        '${formatLocalDateTime(e.event.at)} · ${e.event.action == 'schedule_replaced' ? routineText(context, 'schedule_replaced') : t(e.event.action == 'not_taken' ? 'notTaken' : e.event.action)}\n${e.event.scheduled == null ? '' : formatLocalDateTime(e.event.scheduled!)}',
                      ),
                    );
                  },
                )
              : rows.isEmpty
              ? Center(child: Text(t('empty')))
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    return Card(
                      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_selecting &&
                                row.details.kind == 'task' &&
                                row.details.planId == null &&
                                !all.any(
                                  (child) => child.details.planId == row.id,
                                ))
                              CheckboxListTile(
                                key: ValueKey('bulk-row:${row.id}'),
                                contentPadding: EdgeInsets.zero,
                                value: _selection.containsKey(row.id),
                                title: Text(t('bulkSelectTask')),
                                onChanged:
                                    _busy ||
                                        (!_selection.containsKey(row.id) &&
                                            _selection.length >= 50)
                                    ? null
                                    : (value) => setState(() {
                                        if (value == true) {
                                          _selection[row.id] = row;
                                        } else {
                                          _selection.remove(row.id);
                                        }
                                      }),
                              ),
                            Text(
                              row.taskTitle,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            if (row.details.tags.isNotEmpty ||
                                row.details.project.isNotEmpty)
                              Text(
                                '${row.details.project} · ${row.details.tags.join(' / ')}',
                              ),
                            if (OrdinarySeries.isOwner(row))
                              Text(routineText(context, 'seriesOwner')),
                            if (row.triggerTime != null)
                              Text(formatLocalDateTime(row.triggerTime!)),
                            if (OrdinarySeries.isOwner(row))
                              RoutineCoveragePanel(planId: row.id),
                            if (!OrdinarySeries.isOwner(row))
                              for (final item in row.details.checklist.take(10))
                                CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  value: item.done,
                                  title: Text(item.label),
                                  onChanged: _busy || !row.isVisible
                                      ? null
                                      : (v) async {
                                          if (!mounted ||
                                              !context.mounted ||
                                              !_current) {
                                            return;
                                          }
                                          setState(() => _busy = true);
                                          try {
                                            await ref
                                                .read(
                                                  remindersProvider.notifier,
                                                )
                                                .setChecklistItem(
                                                  row,
                                                  item.id,
                                                  v ?? false,
                                                  _generation,
                                                );
                                          } catch (_) {
                                            if (mounted &&
                                                context.mounted &&
                                                _current) {
                                              InlineFeedback.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text(t('failed')),
                                                ),
                                              );
                                            }
                                          } finally {
                                            if (mounted &&
                                                context.mounted &&
                                                _current) {
                                              setState(() => _busy = false);
                                            }
                                          }
                                        },
                                ),
                            Wrap(
                              spacing: 5,
                              runSpacing: 5,
                              children: [
                                if (row.details.deletedAt != null)
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _action(row, 'restore'),
                                    child: Text(t('restore')),
                                  )
                                else if (row.details.archivedAt != null)
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _action(row, 'unarchive'),
                                    child: Text(t('unarchive')),
                                  )
                                else ...[
                                  if (!const {
                                    'medicationPlan',
                                    'departure',
                                  }.contains(row.details.kind))
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _editor(row),
                                      child: Text(t('edit')),
                                    ),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _action(
                                            row,
                                            row.details.paused
                                                ? 'resume'
                                                : 'pause',
                                          ),
                                    child: Text(
                                      t(
                                        row.details.paused ? 'resume' : 'pause',
                                      ),
                                    ),
                                  ),
                                  if (row.isCompleted)
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _action(row, 'archive'),
                                      child: Text(t('archive')),
                                    ),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _action(row, 'trash'),
                                    child: Text(t('moveTrash')),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }
}

class TaskManagementEditor extends ConsumerStatefulWidget {
  const TaskManagementEditor({super.key, this.task});
  final Reminder? task;
  @override
  ConsumerState<TaskManagementEditor> createState() =>
      _TaskManagementEditorState();
}

class _TaskManagementEditorState extends ConsumerState<TaskManagementEditor> {
  late final TextEditingController _title, _tags, _project, _items, _interval;
  late final DataGeneration _generation;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken _birth;
  late final String _id;
  final _form = GlobalKey<FormState>();
  String _rule = 'none';
  bool _templateApplied = false;
  bool _independent = true;
  HolidayPolicy _holidayPolicy = const HolidayPolicy();
  List<int> _weekdays = [];
  DateTime? _end, _due;
  CalendarExceptions _exceptions = const CalendarExceptions();
  bool _exceptionsValid = true;
  bool _saving = false;
  String t(String key) => planningText(context, key);
  bool get _current =>
      mounted &&
      _runtime.isCurrent(_birth) &&
      ref.read(databaseHelperProvider).isCurrent(_generation);
  @override
  void initState() {
    super.initState();
    final task = widget.task != null && OrdinarySeries.isOwner(widget.task!)
        ? OrdinarySeries.template(widget.task!)
        : widget.task;
    _independent = widget.task == null || OrdinarySeries.isOwner(widget.task!);
    _holidayPolicy = HolidayPolicy.fromJson(
      task?.details.data['holiday_policy'],
    );
    _id = task?.id ?? const Uuid().v4();
    final details = task?.details ?? const TaskDetails();
    _title = TextEditingController(text: task?.taskTitle ?? '');
    _tags = TextEditingController(text: details.tags.join(', '));
    _project = TextEditingController(text: details.project);
    _items = TextEditingController(
      text: details.checklist.map((e) => e.label).join('\n'),
    );
    _interval = TextEditingController(text: '${details.repeat?.interval ?? 1}');
    _weekdays = details.repeat?.weekdays.toList() ?? [];
    _end = details.repeat?.end;
    _exceptions = details.repeat?.exceptions ?? const CalendarExceptions();
    _due = task?.triggerTime;
    _rule = task?.recurrenceRule ?? 'none';
    _generation = ref.read(databaseHelperProvider).captureGeneration();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.capture();
  }

  @override
  void dispose() {
    for (final c in [_title, _tags, _project, _items, _interval]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseTemplate() async {
    if (!_current || _saving) return;
    setState(() => _saving = true);
    try {
      final item = await showDialog<TaskTemplate>(
        context: context,
        builder: (_) => const TaskTemplateLibrary(allowApply: true),
      );
      if (!_current || item == null) return;
      setState(() {
        _title.text = item.title;
        _items.text = item.items.join('\n');
        _tags.text = item.tags.join(', ');
        _project.text = item.project;
        _templateApplied = true;
      });
    } finally {
      if (_current) setState(() => _saving = false);
    }
  }

  Future<void> _saveTemplate() async {
    if (!_current || _saving) return;
    setState(() => _saving = true);
    try {
      await showDialog<bool>(
        context: context,
        builder: (_) => TaskTemplateEditorDialog(
          seedTitle: _title.text.trim(),
          seedItems: _items.text
              .split('\n')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
          seedTags: _tags.text
              .split(RegExp('[,，]'))
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toSet()
              .toList(),
          seedProject: _project.text.trim(),
        ),
      );
    } finally {
      if (_current) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (!mounted ||
        !context.mounted ||
        !_current ||
        _saving ||
        !_form.currentState!.validate()) {
      return;
    }
    setState(() => _saving = true);
    try {
      final baseline = widget.task;
      final base = baseline != null && OrdinarySeries.isOwner(baseline)
          ? OrdinarySeries.template(baseline)
          : baseline;
      final details = base?.details ?? const TaskDetails();
      if (baseline != null &&
          OrdinarySeries.isOwner(baseline) &&
          _rule == 'none') {
        throw const FormatException('Pause the plan to stop independent dates');
      }
      var effectiveDue = _due;
      final retainedAnchor =
          _due == base?.triggerTime && _rule == base?.recurrenceRule
          ? details.repeat?.anchor
          : null;
      final labels = _items.text
          .split('\n')
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty)
          .toList();
      if (labels.length > 64 || labels.any((e) => e.length > 512)) {
        throw const FormatException('Too many checklist items');
      }
      final available = _templateApplied
          ? <ChecklistItem>[]
          : [...details.checklist];
      final items = <ChecklistItem>[];
      for (final label in labels) {
        final index = available.indexWhere((item) => item.label == label);
        items.add(
          index < 0
              ? ChecklistItem(const Uuid().v4(), label)
              : available.removeAt(index),
        );
      }
      final tags = _tags.text
          .split(RegExp('[,，]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList();
      final repeat = _rule == 'none'
          ? null
          : RepeatWindow(
              interval: int.parse(_interval.text),
              weekdays: _rule == 'weekly' ? _weekdays : const [],
              exceptions: _exceptions,
              anchor: _exceptions.isEmpty
                  ? retainedAnchor
                  : retainedAnchor ?? _due,
              end: _end == null
                  ? null
                  : DateTime(_end!.year, _end!.month, _end!.day, 23, 59, 59),
            );
      if (_rule != 'none' && _due == null) {
        throw const FormatException('Repeat time required');
      }
      if (_rule != 'none' &&
          (!_exceptionsValid ||
              _exceptions.add.any(
                (day) => day.compareTo(CalendarExceptions.key(_due!)) < 0,
              ))) {
        throw const FormatException('Invalid exception dates');
      }
      if (repeat != null &&
          _due != null &&
          (_exceptions.excludes(_due!) ||
              (!_exceptions.includes(_due!) &&
                  ((_rule == 'weekly' &&
                          _weekdays.isNotEmpty &&
                          !_weekdays.contains(_due!.weekday)) ||
                      (_rule == 'workday' &&
                          _holidayPolicy.mode != 'workdays' &&
                          _due!.weekday > 5))))) {
        final next = repeat.next(
          _due!,
          _due!.subtract(const Duration(microseconds: 1)),
          _rule,
        );
        if (next == null) {
          throw const FormatException('No occurrence inside repeat dates');
        }
        effectiveDue = next;
      }
      if (repeat?.end != null && effectiveDue!.isAfter(repeat!.end!)) {
        throw const FormatException('Repeat end precedes first time');
      }
      final data = {...details.data}..remove('holiday_policy');
      if (_independent && _rule != 'none' && _holidayPolicy.mode != 'none') {
        data['holiday_policy'] = _holidayPolicy.toJson();
      }
      final updated = details.patch({
        'tags': tags,
        'project': _project.text.trim(),
        'checklist': items.map((e) => e.toJson()).toList(),
        'repeat': repeat?.toJson(),
        'data': data,
      });
      final row =
          (base ??
                  Reminder(
                    id: _id,
                    taskTitle: '',
                    quadrantLevel: 2,
                    createdAt: DateTime.now(),
                  ))
              .copyWith(
                taskTitle: _title.text.trim(),
                triggerTime: effectiveDue,
                eventTime:
                    base?.eventTime != null &&
                        base?.triggerTime != null &&
                        effectiveDue != null
                    ? effectiveDue.add(
                        base!.eventTime!.difference(base.triggerTime!),
                      )
                    : effectiveDue,
                isRecurring: _rule != 'none',
                recurrenceRule: _rule,
                detailsJson: updated.encode(),
              );
      final notifier = ref.read(remindersProvider.notifier);
      final bool nativeFailed;
      if (_independent && _rule != 'none') {
        final batch = await notifier.saveOrdinarySeries(
          row,
          _generation,
          baseline: baseline,
        );
        nativeFailed = batch.nativeSyncFailures > 0;
      } else {
        final result = baseline == null
            ? await notifier.addReminderForGeneration(row, _generation)
            : await notifier.updateReminderForGeneration(
                row,
                _generation,
                baseline: baseline,
              );
        nativeFailed = result.nativeSyncFailed;
      }
      if (!mounted || !context.mounted || !_current) return;
      if (nativeFailed) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).get('reminderNativeSyncFailed'),
            ),
            action: SnackBarAction(
              label: AppLocalizations.of(context).get('repairNotifications'),
              onPressed: notificationRepairAction(context).onPressed,
            ),
          ),
        );
      }
      Navigator.pop(context);
    } catch (_) {
      if (mounted && context.mounted && _current) {
        InlineFeedback.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('failed'))));
      }
    } finally {
      if (mounted && context.mounted && _current) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('checklist')),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const ValueKey('task-management-title'),
                controller: _title,
                maxLength: 160,
                decoration: InputDecoration(labelText: t('title')),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? t('incomplete') : null,
              ),
              TextFormField(
                key: const ValueKey('task-management-tags'),
                controller: _tags,
                decoration: InputDecoration(labelText: t('tags')),
              ),
              TextFormField(
                key: const ValueKey('task-management-project'),
                controller: _project,
                maxLength: 128,
                decoration: InputDecoration(labelText: t('project')),
              ),
              TextFormField(
                key: const ValueKey('task-management-items'),
                controller: _items,
                maxLines: 5,
                decoration: InputDecoration(labelText: t('checklist')),
              ),
              if (widget.task == null || widget.task!.details.kind == 'task')
                Wrap(
                  spacing: 6,
                  children: [
                    TextButton.icon(
                      key: const ValueKey('editor-templates'),
                      onPressed: _saving ? null : _chooseTemplate,
                      icon: const Icon(Icons.library_books_outlined),
                      label: Text(t('useTemplate')),
                    ),
                    TextButton.icon(
                      key: const ValueKey('editor-save-template'),
                      onPressed: _saving ? null : _saveTemplate,
                      icon: const Icon(Icons.bookmark_add_outlined),
                      label: Text(t('saveAsTemplate')),
                    ),
                  ],
                ),
              Wrap(
                spacing: 4,
                children: [
                  for (final labels in [
                    const ['证件', '手机', '充电器'],
                    const ['钥匙', '耳机', '垃圾'],
                  ])
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () =>
                                setState(() => _items.text = labels.join('\n')),
                      child: Text(labels.join(' / ')),
                    ),
                ],
              ),
              DropdownButtonFormField<String>(
                initialValue: _rule,
                isExpanded: true,
                items: [
                  for (final rule in [
                    if (widget.task == null ||
                        !OrdinarySeries.isOwner(widget.task!))
                      'none',
                    'daily',
                    'workday',
                    'weekly',
                    'monthly',
                    'yearly',
                  ])
                    DropdownMenuItem(
                      value: rule,
                      child: Text(
                        AppLocalizations.of(context).get(
                          'repeat${rule[0].toUpperCase()}${rule.substring(1)}',
                        ),
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _rule = v ?? 'none'),
              ),
              TextButton.icon(
                icon: const Icon(Icons.schedule),
                label: Text(
                  _due == null ? t('times') : formatLocalDateTime(_due!),
                ),
                onPressed: _saving
                    ? null
                    : () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: _due ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (!mounted ||
                            !context.mounted ||
                            !_current ||
                            date == null) {
                          return;
                        }
                        final time = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(
                            _due ?? DateTime.now(),
                          ),
                        );
                        if (mounted &&
                            context.mounted &&
                            _current &&
                            time != null) {
                          setState(
                            () => _due = DateTime(
                              date.year,
                              date.month,
                              date.day,
                              time.hour,
                              time.minute,
                            ),
                          );
                        }
                      },
              ),
              if (_rule != 'none') ...[
                SwitchListTile(
                  key: const ValueKey('ordinary-independent'),
                  title: Text(routineText(context, 'independent')),
                  subtitle: Text(routineText(context, 'independentHint')),
                  value: _independent,
                  onChanged:
                      _saving ||
                          (widget.task != null &&
                              OrdinarySeries.isOwner(widget.task!))
                      ? null
                      : (value) => setState(() => _independent = value),
                ),
                if (_independent)
                  HolidayPolicyEditor(
                    value: _holidayPolicy,
                    enabled: !_saving,
                    onChanged: (value) => setState(() {
                      _holidayPolicy = value;
                      if (value.mode == 'workdays') {
                        _rule = 'workday';
                        _interval.text = '1';
                      }
                    }),
                  ),
              ],
              if (_rule != 'none') ...[
                CalendarExceptionsEditor(
                  key: const ValueKey('task-date-exceptions'),
                  initial: _exceptions,
                  enabled: !_saving,
                  scopeHint: 'reminderDatesHint',
                  onChanged: (value, raw) => setState(() {
                    _exceptionsValid = value != null;
                    if (value != null) _exceptions = value;
                  }),
                ),
                TextFormField(
                  controller: _interval,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t('interval')),
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    return n == null || n < 1 || n > 365 ? t('failed') : null;
                  },
                ),
                if (_rule == 'weekly')
                  Wrap(
                    spacing: 4,
                    children: [
                      for (var day = 1; day <= 7; day++)
                        FilterChip(
                          label: Text('$day'),
                          selected: _weekdays.contains(day),
                          onSelected: _saving
                              ? null
                              : (v) => setState(() {
                                  if (v) {
                                    _weekdays.add(day);
                                  } else {
                                    _weekdays.remove(day);
                                  }
                                }),
                        ),
                    ],
                  ),
                TextButton(
                  onPressed: _saving
                      ? null
                      : () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: _end ?? _due ?? DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2100),
                          );
                          if (mounted &&
                              context.mounted &&
                              _current &&
                              date != null) {
                            setState(() => _end = date);
                          }
                        },
                  child: Text(
                    '${t('repeatEnd')} ${_end == null ? '' : formatLocalDateTime(_end!, pattern: 'yyyy-MM-dd')}',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: Text(AppLocalizations.of(context).get('cancel')),
      ),
      FilledButton(
        key: const ValueKey('task-management-save'),
        onPressed: _saving ? null : _save,
        child: Text(t('activate')),
      ),
    ],
  );
}
