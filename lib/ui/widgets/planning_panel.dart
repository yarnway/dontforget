import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/database_helper.dart';
import '../../l10n/planning_strings.dart';
import '../../models/reminder.dart';
import '../../models/task_details.dart';
import '../../providers/providers.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';
import '../screens/notification_repair_screen.dart';
import '../../l10n/app_localizations.dart';
import 'departure_plan_panel.dart';
import 'medication_plan_panel.dart';
import 'portable_backup_panel.dart';
import 'learning_management_panel.dart';
import 'inline_feedback.dart';
import 'workspace_tool_panel.dart';

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
              for (var i = 0; i < 5; i++)
                ChoiceChip(
                  label: Text(
                    planningText(
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
  String _view = 'manage', _query = '';
  bool _busy = false;
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

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(remindersProvider);
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
                  .contains(_query.toLowerCase());
        }).toList()..sort(
          (a, b) => (b.createdAt ?? DateTime(2000)).compareTo(
            a.createdAt ?? DateTime(2000),
          ),
        );
    final events = [
      for (final row in all)
        for (final event in row.details.history) (row: row, event: event),
    ]..sort((a, b) => b.event.at.compareTo(a.event.at));
    return Column(
      children: [
        Padding(
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
                      onSelected: (_) => setState(() => _view = view),
                    ),
                ],
              ),
              TextField(
                decoration: InputDecoration(
                  labelText: t('filter'),
                  prefixIcon: const Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
              TextButton.icon(
                onPressed:
                    _busy ||
                        !ref.watch(settingsProvider).hasConfiguredExtraction
                    ? null
                    : _testAi,
                icon: const Icon(Icons.network_check),
                label: Text(t('testAi')),
              ),
              TextButton.icon(
                onPressed: _busy ? null : () => _editor(null),
                icon: const Icon(Icons.add),
                label: Text(t('newChecklist')),
              ),
            ],
          ),
        ),
        Expanded(
          child: _view == 'history'
              ? ListView.builder(
                  itemCount: events.length > 300 ? 300 : events.length,
                  itemBuilder: (context, i) {
                    final e = events[i];
                    return ListTile(
                      title: Text(e.row.taskTitle),
                      subtitle: Text(
                        '${formatLocalDateTime(e.event.at)} · ${t(e.event.action == 'not_taken' ? 'notTaken' : e.event.action)}\n${e.event.scheduled == null ? '' : formatLocalDateTime(e.event.scheduled!)}',
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
                            Text(
                              row.taskTitle,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            if (row.details.tags.isNotEmpty ||
                                row.details.project.isNotEmpty)
                              Text(
                                '${row.details.project} · ${row.details.tags.join(' / ')}',
                              ),
                            if (row.triggerTime != null)
                              Text(formatLocalDateTime(row.triggerTime!)),
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
                                              .read(remindersProvider.notifier)
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
  List<int> _weekdays = [];
  DateTime? _end, _due;
  bool _saving = false;
  String t(String key) => planningText(context, key);
  bool get _current =>
      mounted &&
      _runtime.isCurrent(_birth) &&
      ref.read(databaseHelperProvider).isCurrent(_generation);
  @override
  void initState() {
    super.initState();
    final task = widget.task;
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
      final base = widget.task, details = base?.details ?? const TaskDetails();
      final labels = _items.text
          .split('\n')
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty)
          .toList();
      if (labels.length > 64 || labels.any((e) => e.length > 512)) {
        throw const FormatException('Too many checklist items');
      }
      final items = [
        for (final label in labels)
          details.checklist.where((item) => item.label == label).firstOrNull ??
              ChecklistItem(const Uuid().v4(), label),
      ];
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
              end: _end == null
                  ? null
                  : DateTime(_end!.year, _end!.month, _end!.day, 23, 59, 59),
            );
      if (_rule != 'none' && _due == null) {
        throw const FormatException('Repeat time required');
      }
      if (repeat != null &&
          _due != null &&
          ((_rule == 'weekly' &&
                  _weekdays.isNotEmpty &&
                  !_weekdays.contains(_due!.weekday)) ||
              (_rule == 'workday' && _due!.weekday > 5))) {
        final next = repeat.next(
          _due!,
          _due!.subtract(const Duration(microseconds: 1)),
          _rule,
        );
        if (next == null) {
          throw const FormatException('No occurrence inside repeat dates');
        }
        _due = next;
      }
      if (repeat?.end != null && _due!.isAfter(repeat!.end!)) {
        throw const FormatException('Repeat end precedes first time');
      }
      final updated = details.patch({
        'tags': tags,
        'project': _project.text.trim(),
        'checklist': items.map((e) => e.toJson()).toList(),
        'repeat': repeat?.toJson(),
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
                triggerTime: _due,
                eventTime:
                    base?.eventTime != null &&
                        base?.triggerTime != null &&
                        _due != null
                    ? _due!.add(base!.eventTime!.difference(base.triggerTime!))
                    : _due,
                isRecurring: _rule != 'none',
                recurrenceRule: _rule,
                detailsJson: updated.encode(),
              );
      final notifier = ref.read(remindersProvider.notifier);
      final result = base == null
          ? await notifier.addReminderForGeneration(row, _generation)
          : await notifier.updateReminderForGeneration(
              row,
              _generation,
              baseline: base,
            );
      if (!mounted || !context.mounted || !_current) return;
      if (result.nativeSyncFailed) {
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
                controller: _title,
                maxLength: 160,
                decoration: InputDecoration(labelText: t('title')),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? t('incomplete') : null,
              ),
              TextFormField(
                controller: _tags,
                decoration: InputDecoration(labelText: t('tags')),
              ),
              TextFormField(
                controller: _project,
                maxLength: 128,
                decoration: InputDecoration(labelText: t('project')),
              ),
              TextFormField(
                controller: _items,
                maxLines: 5,
                decoration: InputDecoration(labelText: t('checklist')),
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
        onPressed: _saving ? null : _save,
        child: Text(t('activate')),
      ),
    ],
  );
}
