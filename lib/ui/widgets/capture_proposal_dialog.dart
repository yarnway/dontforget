import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';
import '../formatters/local_date_time.dart';

/// The proposal is only applied after this dialog returns a confirmed list.
class CaptureProposalDialog extends StatefulWidget {
  const CaptureProposalDialog({
    super.key,
    required this.original,
    required this.proposals,
  });

  final Reminder original;
  final List<Reminder> proposals;

  @override
  State<CaptureProposalDialog> createState() => _CaptureProposalDialogState();
}

class _ProposalDraft {
  _ProposalDraft(this.task)
    : title = TextEditingController(text: task.taskTitle),
      summary = TextEditingController(text: task.taskSummary ?? '');

  Reminder task;
  final TextEditingController title;
  final TextEditingController summary;
  bool included = true;

  void dispose() {
    title.dispose();
    summary.dispose();
  }
}

class _CaptureProposalDialogState extends State<CaptureProposalDialog> {
  late final List<_ProposalDraft> _drafts;
  String? _error;

  @override
  void initState() {
    super.initState();
    _drafts = [
      for (var i = 0; i < widget.proposals.length; i++)
        _ProposalDraft(
          widget.proposals[i].copyWith(
            triggerTime:
                widget.proposals[i].triggerTime ??
                (i == 0 ? widget.original.triggerTime : null),
            eventTime:
                widget.proposals[i].eventTime ??
                (i == 0 ? widget.original.eventTime : null),
            timeOrigin: widget.proposals[i].triggerTime != null
                ? ReminderTimeOrigin.aiSuggested
                : i == 0
                ? widget.original.timeOrigin
                : ReminderTimeOrigin.unknown,
          ),
        ),
    ];
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  Future<void> _pickTime(int index, {required bool event}) async {
    final draft = _drafts[index];
    final initial =
        (event ? draft.task.eventTime : draft.task.triggerTime)?.toLocal() ??
        DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(initial.year < 1900 ? initial.year : 1900),
      lastDate: DateTime(initial.year >= 2200 ? initial.year + 1 : 2200),
    );
    if (!mounted || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!mounted || time == null) return;
    final selected = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      draft.task = event
          ? draft.task.copyWith(eventTime: selected)
          : draft.task.copyWith(
              triggerTime: selected,
              timeOrigin: ReminderTimeOrigin.manual,
            );
      _error = null;
    });
  }

  void _confirm() {
    final selected = _drafts.where((draft) => draft.included).toList();
    final l10n = AppLocalizations.of(context);
    if (selected.isEmpty ||
        selected.any((draft) => draft.title.text.trim().isEmpty)) {
      setState(() => _error = l10n.get('captureProposalInvalid'));
      return;
    }
    if (selected.any(
      (draft) =>
          draft.task.triggerTime != null &&
          !draft.task.triggerTime!.isAfter(DateTime.now()),
    )) {
      setState(() => _error = l10n.get('captureProposalFuture'));
      return;
    }
    Navigator.of(context).pop([
      for (final draft in selected)
        draft.task.copyWith(
          taskTitle: draft.title.text.trim(),
          taskSummary: draft.summary.text.trim().isEmpty
              ? null
              : draft.summary.text.trim(),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.get('captureProposalTitle')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.get('captureProposalHint')),
              if (widget.original.sourceText != null) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.get('sourceText'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                SelectableText(widget.original.sourceText!),
              ],
              for (var i = 0; i < _drafts.length; i++) ...[
                const Divider(height: 24),
                CheckboxListTile(
                  key: ValueKey('proposal-include-$i'),
                  value: _drafts[i].included,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${l10n.get('captureProposalItem')} ${i + 1}'),
                  onChanged: (value) =>
                      setState(() => _drafts[i].included = value ?? false),
                ),
                if (_drafts[i].included) ...[
                  TextField(
                    key: ValueKey('proposal-title-$i'),
                    controller: _drafts[i].title,
                    decoration: InputDecoration(
                      labelText: l10n.get('taskTitleLabel'),
                    ),
                  ),
                  TextField(
                    key: ValueKey('proposal-summary-$i'),
                    controller: _drafts[i].summary,
                    maxLines: 3,
                    minLines: 1,
                    decoration: InputDecoration(
                      labelText: l10n.get('captureProposalSummary'),
                    ),
                  ),
                  for (final event in [true, false])
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      key: ValueKey(
                        event ? 'proposal-event-$i' : 'proposal-time-$i',
                      ),
                      title: Text(
                        l10n.get(
                          event ? 'eventTimeShort' : 'reminderTimeShort',
                        ),
                      ),
                      subtitle: Text(
                        (event
                                    ? _drafts[i].task.eventTime
                                    : _drafts[i].task.triggerTime) ==
                                null
                            ? l10n.get('notSet')
                            : formatLocalDateTime(
                                (event
                                    ? _drafts[i].task.eventTime
                                    : _drafts[i].task.triggerTime)!,
                              ),
                      ),
                      onTap: () => _pickTime(i, event: event),
                      trailing: IconButton(
                        tooltip: l10n.get('clear'),
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() {
                          _drafts[i].task = event
                              ? _drafts[i].task.copyWith(eventTime: null)
                              : _drafts[i].task.copyWith(
                                  triggerTime: null,
                                  timeOrigin: ReminderTimeOrigin.unknown,
                                );
                        }),
                      ),
                    ),
                ],
              ],
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.get('cancel')),
        ),
        FilledButton(
          key: const ValueKey('proposal-confirm'),
          onPressed: _confirm,
          child: Text(l10n.get('captureProposalConfirm')),
        ),
      ],
    );
  }
}
