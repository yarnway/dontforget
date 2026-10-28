import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/database_helper.dart';
import '../../l10n/routine_policy_strings.dart';
import '../../l10n/planning_strings.dart';
import '../../models/reminder.dart';
import '../../models/routine_date.dart';
import '../../providers/providers.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';
import '../screens/notification_repair_screen.dart';
import 'inline_feedback.dart';

Future<void> showRoutineDates(BuildContext context, String planId) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 680,
          height: 680,
          child: RoutineDatesPanel(planId: planId),
        ),
      ),
    );

class RoutineDatesPanel extends ConsumerStatefulWidget {
  const RoutineDatesPanel({super.key, required this.planId, this.now});
  final String planId;
  final DateTime? now;
  @override
  ConsumerState<RoutineDatesPanel> createState() => _RoutineDatesPanelState();
}

class _RoutineDatesPanelState extends ConsumerState<RoutineDatesPanel> {
  late final DatabaseHelper _database;
  late final RuntimeRecoveryGate _runtime;
  late final DataGeneration? _generation;
  late final RuntimeRecoveryToken? _birth;
  String _view = 'past', _status = 'all', _query = '';
  DateTime? _from, _to;
  int _limit = 50;
  bool _busy = false;
  bool get _current =>
      mounted &&
      _runtime.isCurrent(_birth) &&
      _generation != null &&
      _database.isCurrent(_generation);
  String t(String key) => routineText(context, key);
  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.paused ? null : _runtime.capture();
    _generation = _birth == null ? null : _database.captureGeneration();
  }

  Future<void> _range(bool start) async {
    if (!_current || _busy) return;
    final day = await showDatePicker(
      context: context,
      initialDate: (start ? _from : _to) ?? widget.now ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
    );
    if (!_current || day == null) return;
    setState(() {
      if (start) {
        _from = day;
        if (_to != null && _to!.isBefore(day)) _to = day;
      } else {
        _to = day;
        if (_from != null && _from!.isAfter(day)) _from = day;
      }
      _limit = 50;
    });
  }

  Future<void> _act(Reminder child, Reminder parent, String action) async {
    if (!_current || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('date_$action')),
        content: Text(
          [
            child.taskTitle,
            '${t('dateScheduled')}: ${formatLocalDateTime(RoutineDate.from(child)!.scheduled)}',
            if (child.triggerTime != null)
              '${t('dateAlarm')}: ${formatLocalDateTime(child.triggerTime!)}',
            t('dateActionHint'),
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('cancel')),
          ),
          FilledButton(
            key: const ValueKey('routine-date-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: Text(t('confirm')),
          ),
        ],
      ),
    );
    if (!_current || confirmed != true) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(remindersProvider.notifier)
          .changeRoutineDate(
            child,
            parent,
            action,
            _generation!,
            now: widget.now,
          );
      if (!mounted || !context.mounted || !_current) return;
      if (result.nativeSyncFailed) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(t('dateNativeFailed')),
            action: SnackBarAction(
              label: t('dateRepair'),
              onPressed: notificationRepairAction(context).onPressed,
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted && context.mounted && _current) {
        InlineFeedback.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('dateStale'))));
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) return Center(child: Text(t('dateUnavailable')));
    final all = ref.watch(remindersProvider);
    final parent = all
        .where((e) => e.id == widget.planId && e.details.planId == null)
        .firstOrNull;
    if (parent == null) return Center(child: Text(t('dateUnavailable')));
    final dates = RoutineDate.select(
      all,
      widget.planId,
      widget.now ?? DateTime.now(),
      view: _view,
      status: _status,
      from: _from,
      to: _to,
      query: _query,
    );
    final actionable =
        parent.isVisible &&
        !parent.details.paused &&
        parent.details.kind != 'medicationPlan';
    return Padding(
      padding: const EdgeInsets.all(12),
      child: ListView(
        children: [
          Text(t('datesTitle'), style: Theme.of(context).textTheme.titleLarge),
          Text(parent.taskTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          Wrap(
            spacing: 6,
            children: [
              for (final view in ['past', 'future', 'all'])
                ChoiceChip(
                  key: ValueKey('routine-view:$view'),
                  label: Text(t('date_$view')),
                  selected: _view == view,
                  onSelected: _busy
                      ? null
                      : (_) => setState(() {
                          _view = view;
                          _limit = 50;
                        }),
                ),
            ],
          ),
          DropdownButtonFormField<String>(
            initialValue: _status,
            decoration: InputDecoration(labelText: t('dateStatus')),
            items: [
              for (final s in ['all', 'pending', 'handled', 'removed'])
                DropdownMenuItem(value: s, child: Text(t('date_$s'))),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _status = value!;
                    _limit = 50;
                  }),
          ),
          TextField(
            key: const ValueKey('routine-dates-query'),
            decoration: InputDecoration(labelText: t('dateSearch')),
            onChanged: (value) => setState(() {
              _query = value;
              _limit = 50;
            }),
          ),
          Wrap(
            children: [
              TextButton(
                key: const ValueKey('routine-date-from'),
                onPressed: _busy ? null : () => _range(true),
                child: Text(
                  '${t('dateFrom')} ${_from == null ? '' : formatLocalDateTime(_from!, pattern: 'yyyy-MM-dd')}',
                ),
              ),
              TextButton(
                key: const ValueKey('routine-date-to'),
                onPressed: _busy ? null : () => _range(false),
                child: Text(
                  '${t('dateTo')} ${_to == null ? '' : formatLocalDateTime(_to!, pattern: 'yyyy-MM-dd')}',
                ),
              ),
              if (_from != null || _to != null)
                TextButton(
                  onPressed: () => setState(() {
                    _from = null;
                    _to = null;
                    _limit = 50;
                  }),
                  child: Text(t('dateClear')),
                ),
            ],
          ),
          Text('${t('dateCount')}: ${dates.length}'),
          if (!actionable)
            Text(
              t(
                parent.details.kind == 'medicationPlan'
                    ? 'dateMedicationReadOnly'
                    : 'dateParentInactive',
              ),
            ),
          if (dates.isEmpty) Center(child: Text(t('dateEmpty'))),
          for (final entry in dates.take(_limit))
            _dateCard(entry, parent, actionable),
          if (dates.length > _limit)
            TextButton(
              key: const ValueKey('routine-date-more'),
              onPressed: () => setState(() => _limit += 50),
              child: Text(t('dateMore')),
            ),
        ],
      ),
    );
  }

  Widget _dateCard(RoutineDate entry, Reminder parent, bool actionable) {
    final row = entry.row;
    return Card(
      key: ValueKey('routine-date:${row.id}'),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${entry.dateKey} · ${t('date_${entry.status}')}'),
            Text(
              '${t('dateScheduled')}: ${formatLocalDateTime(entry.scheduled)}',
            ),
            if (row.triggerTime != null &&
                row.snoozedAt == null &&
                !row.triggerTime!.isAtSameMomentAs(entry.scheduled))
              Text(
                '${t('dateAlarm')}: ${formatLocalDateTime(row.triggerTime!)}',
              ),
            if (row.eventTime != null &&
                !row.eventTime!.isAtSameMomentAs(entry.scheduled))
              Text('${t('dateEvent')}: ${formatLocalDateTime(row.eventTime!)}'),
            if (row.snoozedAt != null && row.triggerTime != null)
              Text(
                '${t('dateSnoozed')}: ${formatLocalDateTime(row.triggerTime!)}',
              ),
            if (row.details.paused) Text(planningText(context, 'pause')),
            if (row.details.effectiveDoseOutcome != null)
              Text(
                planningText(
                  context,
                  row.details.effectiveDoseOutcome == 'taken'
                      ? 'taken'
                      : 'notTaken',
                ),
              ),
            if (row.details.history.isNotEmpty)
              ExpansionTile(
                title: Text(t('dateHistory')),
                children: [
                  for (final e in row.details.history.reversed.take(20))
                    ListTile(
                      dense: true,
                      title: Text(
                        e.action == 'reopened'
                            ? t('date_reopen')
                            : e.action == 'schedule_replaced'
                            ? routineText(context, 'schedule_replaced')
                            : planningText(context, e.action),
                      ),
                      subtitle: Text(formatLocalDateTime(e.at)),
                    ),
                ],
              ),
            if (actionable)
              Wrap(
                spacing: 4,
                children: [
                  for (final action
                      in row.details.deletedAt != null &&
                              row.details.archivedAt == null
                          ? ['restore']
                          : row.isVisible
                          ? row.isCompleted
                                ? ['reopen', 'trash']
                                : ['complete', 'skip', 'trash']
                          : <String>[])
                    TextButton(
                      key: ValueKey('routine-date-$action:${row.id}'),
                      onPressed: _busy ? null : () => _act(row, parent, action),
                      child: Text(t('date_$action')),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
