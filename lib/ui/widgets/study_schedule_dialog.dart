import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/study_management_strings.dart';
import '../../models/reminder.dart';
import '../../models/study_plan_group.dart';
import '../../services/study_schedule_service.dart';
import '../formatters/local_date_time.dart';

class StudyScheduleDialog extends StatefulWidget {
  const StudyScheduleDialog({
    super.key,
    required this.rows,
    required this.groups,
  });
  final List<Reminder> rows;
  final List<StudyPlanGroup> groups;

  @override
  State<StudyScheduleDialog> createState() => _StudyScheduleDialogState();
}

class _StudyScheduleDialogState extends State<StudyScheduleDialog> {
  final _days = TextEditingController(text: '1');
  late final List<Reminder> _rows;
  late final List<StudyPlanGroup> _groups;
  String t(String key) => studyManagementText(
    AppLocalizations.of(context).locale.languageCode,
    key,
  );

  @override
  void initState() {
    super.initState();
    _rows = [for (final row in widget.rows) Reminder.fromJson(row.toJson())];
    _groups = StudyPlanGroup.freezeSelection(widget.groups);
  }

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    StudySchedulePreview? preview;
    String? error;
    try {
      final days = int.tryParse(_days.text.trim());
      if (days == null) throw const FormatException();
      preview = StudyScheduleService.preview(_rows, _groups, days);
    } on StudyScheduleConflict {
      error = t('sharedDates');
    } on StudyScheduleRecurring {
      error = t('recurringDates');
    } on StudyScheduleStale {
      error = t('stale');
    } on FormatException {
      error = t('invalidDays');
    }
    final original = {for (final row in _rows) row.id: row};
    final skipped =
        _groups.fold(0, (n, g) => n + g.members.length) -
        (preview?.changes.length ??
            _groups.fold(0, (n, g) => n + g.pending.length));
    return AlertDialog(
      title: Text(t('shiftDates')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('study-shift-days'),
                controller: _days,
                maxLength: 4,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                ),
                decoration: InputDecoration(
                  labelText: t('shiftDays'),
                  helperText: t('daysHint'),
                  helperMaxLines: 3,
                  counterText: '',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in {
                    -1: 'earlierDay',
                    1: 'laterDay',
                    7: 'laterWeek',
                  }.entries)
                    ActionChip(
                      label: Text(t(entry.value)),
                      onPressed: () => setState(() {
                        _days.text = '${entry.key}';
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (error != null)
                Text(
                  error,
                  key: const ValueKey('study-shift-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (preview != null)
                for (final row in preview.changes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.taskTitle,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          formatLocalDateTime(
                            original[row.id]!.nextReviewAt ??
                                original[row.id]!.triggerTime!,
                          ),
                        ),
                        Text(
                          '→ ${formatLocalDateTime(row.nextReviewAt ?? row.triggerTime!)}',
                        ),
                      ],
                    ),
                  ),
              if (skipped > 0) Text('${t('datesExcluded')} $skipped'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).get('cancel')),
        ),
        FilledButton(
          key: const ValueKey('study-shift-confirm'),
          onPressed: preview == null
              ? null
              : () => Navigator.pop(context, preview),
          child: Text(t('applyDates')),
        ),
      ],
    );
  }
}
