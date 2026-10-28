import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/planning_strings.dart';
import '../formatters/local_date_time.dart';

class DoseTakenTimeDialog extends StatefulWidget {
  const DoseTakenTimeDialog({super.key, this.initialTime});
  final DateTime? initialTime;
  @override
  State<DoseTakenTimeDialog> createState() => _DoseTakenTimeDialogState();
}

class _DoseTakenTimeDialogState extends State<DoseTakenTimeDialog> {
  late DateTime _actual;
  bool _future = false;
  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _actual = widget.initialTime?.toLocal() ?? now;
    if (_actual.isAfter(now)) _actual = now;
  }

  @override
  Widget build(BuildContext context) {
    String t(String key) => planningText(context, key);
    return AlertDialog(
      title: Text(t('actualDoseTime')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t('doseTimeHint')),
              TextButton.icon(
                key: const ValueKey('dose-actual-date'),
                icon: const Icon(Icons.calendar_today),
                label: Text(
                  formatLocalDateTime(_actual, pattern: 'yyyy-MM-dd'),
                ),
                onPressed: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: _actual,
                    firstDate: DateTime(1900),
                    lastDate: DateTime.now(),
                  );
                  if (!mounted || date == null) return;
                  setState(() {
                    _actual = DateTime(
                      date.year,
                      date.month,
                      date.day,
                      _actual.hour,
                      _actual.minute,
                    );
                    _future = false;
                  });
                },
              ),
              TextButton.icon(
                key: const ValueKey('dose-actual-clock'),
                icon: const Icon(Icons.schedule),
                label: Text(formatLocalDateTime(_actual, pattern: 'HH:mm')),
                onPressed: () async {
                  final time = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.fromDateTime(_actual),
                  );
                  if (!mounted || time == null) return;
                  setState(() {
                    _actual = DateTime(
                      _actual.year,
                      _actual.month,
                      _actual.day,
                      time.hour,
                      time.minute,
                    );
                    _future = false;
                  });
                },
              ),
              if (_future)
                Text(
                  t('futureDoseTime'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
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
          key: const ValueKey('dose-actual-save'),
          onPressed: () {
            if (_actual.isAfter(DateTime.now())) {
              setState(() => _future = true);
              return;
            }
            Navigator.pop(context, _actual);
          },
          child: Text(t('saveDoseTime')),
        ),
      ],
    );
  }
}
