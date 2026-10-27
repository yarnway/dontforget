import '../../data/database_helper.dart';
import '../../services/recovery/runtime_gate.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../formatters/local_date_time.dart';
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
        _items[0] = _items[0].copyWith(
          triggerTime: widget.task.triggerTime,
          timeOrigin: widget.task.timeOrigin,
          eventTime: widget.task.eventTime ?? _items[0].eventTime,
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
    setState(
      () => _items[index] = event
          ? _items[index].copyWith(eventTime: value)
          : _items[index].copyWith(
              triggerTime: value,
              timeOrigin: ReminderTimeOrigin.manual,
            ),
    );
  }

  Future<void> _confirm() async {
    if (_saving || !_current) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(remindersProvider.notifier)
          .applyCaptureProposal(widget.task, [
            for (var i = 0; i < _items.length; i++)
              if (_selected[i]) _items[i],
          ], generation: _generation);
      if (!mounted || !_current) return;
      if (result.nativeSyncFailures > 0) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).get('reminderNativeSyncFailed'),
            ),
            action: notificationRepairAction(context),
          ),
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
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    loc.get('capturePreview'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Text(loc.get('capturePreviewHint')),
                ExpansionTile(
                  title: Text(loc.get('sourceText')),
                  children: [SelectableText(widget.task.sourceText ?? '')],
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
                            title: Text('${i + 1}'),
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
                            ListTile(
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
                                (event
                                            ? _items[i].eventTime
                                            : _items[i].triggerTime) ==
                                        null
                                    ? loc.get('notSet')
                                    : formatLocalDateTime(
                                        (event
                                            ? _items[i].eventTime
                                            : _items[i].triggerTime)!,
                                      ),
                              ),
                              onTap: _saving ? null : () => _pick(i, event),
                              trailing: IconButton(
                                key: ValueKey(
                                  'proposal-clear-${event ? 'event' : 'reminder'}-$i',
                                ),
                                tooltip: loc.get('clear'),
                                icon: const Icon(Icons.clear),
                                onPressed: _saving
                                    ? null
                                    : () => setState(
                                        () => _items[i] = event
                                            ? _items[i].copyWith(
                                                eventTime: null,
                                              )
                                            : _items[i].copyWith(
                                                triggerTime: null,
                                                timeOrigin:
                                                    ReminderTimeOrigin.unknown,
                                              ),
                                      ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (_error != null)
                  Text(
                    loc.get(_error!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 12,
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
                        child: Text(loc.get('captureConfirm')),
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
