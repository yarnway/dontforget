import '../../data/database_helper.dart';
import '../../services/recovery/runtime_gate.dart';
import '../../services/scheduled_task_reminder.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../formatters/local_date_time.dart';
import '../theme/app_theme.dart';
import 'inline_feedback.dart';
import '../screens/notification_repair_screen.dart';

class CapturePreviewDialog extends ConsumerStatefulWidget {
  const CapturePreviewDialog({super.key, required this.task});
  final Reminder task;
  @override
  ConsumerState<CapturePreviewDialog> createState() =>
      _CapturePreviewDialogState();
}

class _CapturePreviewDialogState extends ConsumerState<CapturePreviewDialog> {
  List<Reminder> _items = [];
  final _selected = <bool>[];
  bool _saving = false;
  late final DatabaseHelper _database;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken? _birth;
  DataGeneration? _generation;
  bool get _current =>
      mounted &&
      _runtime.isCurrent(_birth) &&
      _generation != null &&
      _database.isCurrent(_generation!);

  String? _error;
  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.paused ? null : _runtime.capture();
    try {
      _generation = _database.captureGeneration();
    } on DatabaseAccessException {
      _generation = null;
    }

    try {
      final data = jsonDecode(widget.task.captureProposalJson!);
      if (data is! List || data.isEmpty || data.length > 32) {
        throw const FormatException();
      }
      _items =
          [
                for (final row in data)
                  Reminder.fromJson(Map<String, dynamic>.from(row as Map)),
              ]
              .map(
                (item) => item.copyWith(
                  timeOrigin: item.triggerTime == null
                      ? ReminderTimeOrigin.unknown
                      : ReminderTimeOrigin.aiSuggested,
                ),
              )
              .toList();
      if (widget.task.triggerTime != null) {
        final details = _items[0].details;
        final marked = ScheduledTaskReminder.withLead(
          details,
          ScheduledTaskReminder.leadOf(widget.task),
        );
        _items[0] = _items[0].copyWith(
          triggerTime: widget.task.triggerTime,
          timeOrigin: widget.task.timeOrigin,
          eventTime: widget.task.eventTime ?? _items[0].eventTime,
          detailsJson: identical(marked, details)
              ? _items[0].detailsJson
              : marked.encode(),
        );
      }
      _selected.addAll(List.filled(_items.length, true));
    } catch (_) {
      _error = 'capturePreviewInvalid';
    }
  }

  Future<void> _pick(int index, bool event) async {
    if (!_current) return;
    final now = DateTime.now();
    final initial =
        (event ? _items[index].eventTime : _items[index].triggerTime)
            ?.toLocal() ??
        now;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(initial.year < 1900 ? initial.year : 1900),
      lastDate: DateTime(initial.year >= 2200 ? initial.year + 1 : 2200),
    );
    if (!mounted || !_current || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!mounted || !_current || time == null) return;
    final value = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() => _changeTime(index, event, value));
  }

  void _changeTime(int index, bool event, DateTime? value) {
    final item = _items[index];
    var lead = ScheduledTaskReminder.leadOf(item);
    var trigger = item.triggerTime;
    if (!event) {
      trigger = value;
      lead = null;
    } else if (ScheduledTaskReminder.canSetLead(item) &&
        (lead != null || (value != null && trigger == null))) {
      lead ??= ScheduledTaskReminder.defaultLeadMinutes;
      trigger = ScheduledTaskReminder.timeFor(
        value,
        DateTime.now(),
        lead: lead,
      );
      if (trigger == null) lead = null;
    }
    final details = item.details;
    final marked = ScheduledTaskReminder.withLead(details, lead);
    _items[index] = item.copyWith(
      eventTime: event ? value : item.eventTime,
      triggerTime: trigger,
      timeOrigin: trigger == null
          ? ReminderTimeOrigin.unknown
          : !event || trigger != item.triggerTime
          ? ReminderTimeOrigin.manual
          : item.timeOrigin,
      detailsJson: identical(marked, details)
          ? item.detailsJson
          : marked.encode(),
    );
  }

  Future<void> _confirm() async {
    if (_saving) return;
    if (!_current) {
      if (mounted) setState(() => _error = 'dataTemporarilyUnavailable');
      return;
    }
    final chosen = <Reminder>[
      for (var i = 0; i < _items.length; i++)
        if (_selected[i]) _items[i],
    ];
    if (chosen.isEmpty || chosen.any((r) => r.taskTitle.trim().isEmpty)) {
      setState(() => _error = 'captureProposalInvalid');
      return;
    }
    final now = DateTime.now();
    if (chosen.any((r) => r.triggerTime != null && !r.triggerTime!.isAfter(now))) {
      setState(() => _error = 'captureProposalFuture');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(remindersProvider.notifier)
          .applyCaptureProposal(widget.task, chosen, generation: _generation);
      if (!mounted || !_current) return;
      if (result.nativeSyncFailures > 0) {
        InlineFeedback.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).get('reminderNativeSyncFailed'),
            ),
            action: notificationRepairAction(context),
          ),
          tone: FeedbackTone.warning,
        );
      }
      Navigator.pop(context);
    } on StaleReminderOccurrenceException {
      if (mounted) setState(() => _error = 'reminderOccurrenceChanged');
    } catch (_) {
      if (mounted) setState(() => _error = 'capturePreviewInvalid');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final now = DateTime.now();
    return PopScope(
      canPop: !_saving,
      child: Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 720,
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                  child: Text(
                    loc.get('capturePreview'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    loc.get('capturePreviewHint'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                ExpansionTile(
                  title: Text(loc.get('sourceText')),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: SelectableText(widget.task.sourceText ?? ''),
                    ),
                  ],
                ),
                for (var i = 0; i < _items.length; i++)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          CheckboxListTile(
                            value: _selected[i],
                            onChanged: _saving
                                ? null
                                : (value) => setState(
                                    () => _selected[i] = value ?? true,
                                  ),
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    '${loc.get('captureProposalItem')} ${i + 1}',
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  AppTheme.quadrantIcon(_items[i].quadrantLevel),
                                  size: 16,
                                  color: AppTheme.quadrantColor(
                                    brightness,
                                    _items[i].quadrantLevel,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TextFormField(
                            key: ValueKey('proposal-title-$i'),
                            initialValue: _items[i].taskTitle,
                            enabled: !_saving,
                            decoration: InputDecoration(
                              labelText: loc.get('taskTitleLabel'),
                            ),
                            maxLength: 200,
                            onChanged: (text) => _items[i] = _items[i].copyWith(
                              taskTitle: text.trim(),
                            ),
                          ),
                          TextFormField(
                            key: ValueKey('proposal-summary-$i'),
                            initialValue: _items[i].taskSummary,
                            enabled: !_saving,
                            maxLines: 3,
                            decoration: InputDecoration(
                              labelText: loc.get('reviewNotes'),
                            ),
                            onChanged: (text) => _items[i] = _items[i].copyWith(
                              taskSummary: text,
                            ),
                          ),
                          for (final event in [true, false])
                            Builder(
                              builder: (context) {
                                final dt = event
                                    ? _items[i].eventTime
                                    : _items[i].triggerTime;
                                final isPastReminder =
                                    !event && dt != null && !dt.isAfter(now);
                                return ListTile(
                                  key: ValueKey(
                                    'proposal-${event ? 'event' : 'reminder'}-$i',
                                  ),
                                  title: Text(
                                    loc.get(
                                      event
                                          ? 'eventTimeShort'
                                          : 'reminderTimeShort',
                                    ),
                                  ),
                                  subtitle: Text(
                                    dt == null
                                        ? loc.get('notSet')
                                        : formatLocalDateTime(dt),
                                    style: isPastReminder
                                        ? TextStyle(
                                            color: colors.error,
                                            fontWeight: FontWeight.w600,
                                          )
                                        : null,
                                  ),
                                  onTap: _saving ? null : () => _pick(i, event),
                                  trailing: IconButton(
                                    key: ValueKey(
                                      'proposal-clear-${event ? 'event' : 'reminder'}-$i',
                                    ),
                                    tooltip: loc.get('clear'),
                                    icon: const Icon(Icons.clear),
                                    onPressed: _saving || dt == null
                                        ? null
                                        : () => setState(
                                            () => _changeTime(i, event, null),
                                          ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      loc.get(_error!),
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context),
                        child: Text(loc.get('captureKeepOriginal')),
                      ),
                      FilledButton(
                        key: const ValueKey('confirm-capture-proposal'),
                        onPressed: _saving || _items.isEmpty ? null : _confirm,
                        child: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(loc.get('captureConfirm')),
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
