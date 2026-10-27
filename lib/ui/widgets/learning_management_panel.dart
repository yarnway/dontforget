import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/database_helper.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/planning_strings.dart';
import '../../models/reminder.dart';
import '../../models/study_plan.dart';
import '../../models/vocabulary_entry.dart';
import '../../providers/providers.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/learning_queue_service.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';
import '../screens/notification_repair_screen.dart';
import 'inline_feedback.dart';

class LearningManagementPanel extends ConsumerStatefulWidget {
  const LearningManagementPanel({super.key});
  @override
  ConsumerState<LearningManagementPanel> createState() =>
      _LearningManagementPanelState();
}

class _LearningManagementPanelState
    extends ConsumerState<LearningManagementPanel> {
  late final DatabaseHelper _database;
  late final DataGeneration _generation;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken _birth;
  final _words = TextEditingController(),
      _title = TextEditingController(),
      _intervals = TextEditingController(text: '1, 2, 4, 7, 15'),
      _answer = TextEditingController();
  late DateTime _first;
  bool _busy = false, _ready = false, _preview = false;
  StudyPlan? _importPlan;
  int _practiceIndex = 0;
  String? _practiceResult;
  bool get _current =>
      mounted && _runtime.isCurrent(_birth) && _database.isCurrent(_generation);
  String t(String key) => planningText(context, key);
  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _generation = _database.captureGeneration();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.capture();
    final now = DateTime.now();
    _first = DateTime(now.year, now.month, now.day + 1, 20);
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      await ref.read(workspaceDraftsProvider.notifier).ready;
      if (!mounted || !context.mounted || !_current) return;
      final stored = ref.read(workspaceDraftsProvider);
      final draft = stored['wordlistDraft'];
      if (draft is Map &&
          draft['words'] is String &&
          draft['title'] is String) {
        _words.text = draft['words'];
        _title.text = draft['title'];
      }
      if (stored['learningIntervals'] is List) {
        _intervals.text = (stored['learningIntervals'] as List).join(', ');
      }
      setState(() => _ready = true);
    } catch (_) {
      if (mounted && context.mounted && _current) setState(() => _ready = true);
    }
  }

  @override
  void dispose() {
    for (final controller in [_words, _title, _intervals, _answer]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _feedback(String text, {bool repair = false}) {
    if (!mounted || !context.mounted || !_current) return;
    InlineFeedback.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        action: repair ? notificationRepairAction(context) : null,
      ),
    );
  }

  void _draft() {
    if (!mounted || !context.mounted || !_current) return;
    setState(() {
      _preview = false;
      _importPlan = null;
    });
    unawaited(
      ref
          .read(workspaceDraftsProvider.notifier)
          .put('wordlistDraft', {'title': _title.text, 'words': _words.text})
          .catchError((Object _) {
            if (mounted && context.mounted && _current) _feedback(t('failed'));
          }),
    );
  }

  void _makePreview() {
    try {
      final entries = <VocabularyEntry>[];
      final keys = <String>{};
      for (final line
          in _words.text.split('\n').where((line) => line.trim().isNotEmpty)) {
        final fields = line.split('\t');
        if (fields.length != 3 ||
            fields.any((f) => f.trim().isEmpty) ||
            fields[0].length > 80 ||
            fields[1].length > 180 ||
            fields[2].length > 240 ||
            fields[0].contains(' — ')) {
          throw const FormatException('Use word, meaning and example columns');
        }
        if (!keys.add(LearningQueueService.wordKey(fields[0]))) continue;
        entries.add(
          VocabularyEntry(
            word: fields[0].trim(),
            meaning: fields[1].trim(),
            example: fields[2].trim(),
          ),
        );
      }
      if (entries.isEmpty ||
          entries.length > 140 ||
          _title.text.trim().isEmpty) {
        throw const FormatException('Invalid word list');
      }
      final batches = <StudyBatch>[];
      for (var offset = 0; offset < entries.length; offset += 20) {
        batches.add(
          StudyBatch(
            title: '${_title.text.trim()} ${batches.length + 1}',
            content: entries
                .skip(offset)
                .take(20)
                .map((w) => w.toNotes())
                .join('\n\n'),
          ),
        );
      }
      setState(() {
        _importPlan = StudyPlan(batches: batches);
        _preview = true;
      });
    } catch (_) {
      _feedback(t('wordlistFormat'));
    }
  }

  Future<void> _import() async {
    if (!mounted ||
        !context.mounted ||
        !_current ||
        _busy ||
        !_preview ||
        _importPlan == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final plan = _importPlan!;
      final reminders = plan.reminders(
        edited: plan.batches,
        firstReminder: _first,
      );
      final result = await ref
          .read(remindersProvider.notifier)
          .addStudyPlan(reminders, _generation);
      if (!mounted || !context.mounted || !_current) return;
      _feedback(
        result.nativeSyncFailures > 0
            ? AppLocalizations.of(context).get('reminderNativeSyncFailed')
            : t('saved'),
        repair: result.nativeSyncFailures > 0,
      );
      await ref
          .read(workspaceDraftsProvider.notifier)
          .put('wordlistDraft', null);
      if (mounted && context.mounted && _current) {
        setState(() => _preview = false);
      }
    } catch (_) {
      if (mounted && context.mounted && _current) _feedback(t('failed'));
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  Future<void> _lifecycle(Reminder task) async {
    if (!mounted || !context.mounted || !_current || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(remindersProvider.notifier)
          .changeLifecycle(
            task,
            task.details.paused ? 'resume' : 'pause',
            _generation,
          );
      if (mounted && context.mounted && _current) {
        _feedback(
          result.nativeSyncFailures > 0
              ? AppLocalizations.of(context).get('reminderNativeSyncFailed')
              : t('saved'),
          repair: result.nativeSyncFailures > 0,
        );
      }
    } catch (_) {
      if (mounted && context.mounted && _current) _feedback(t('failed'));
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  Future<void> _edit(Reminder task) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _VocabularyNotesDialog(notes: task.taskSummary ?? ''),
    );
    if (!mounted || !context.mounted || !_current || result == null) return;
    setState(() => _busy = true);
    try {
      final response = await ref
          .read(remindersProvider.notifier)
          .updateReminderForGeneration(
            task.copyWith(taskSummary: result),
            _generation,
            baseline: task,
          );
      if (mounted && context.mounted && _current) {
        _feedback(
          response.nativeSyncFailed
              ? AppLocalizations.of(context).get('reminderNativeSyncFailed')
              : t('saved'),
          repair: response.nativeSyncFailed,
        );
      }
    } catch (_) {
      if (mounted && context.mounted && _current) _feedback(t('failed'));
    } finally {
      if (mounted && context.mounted && _current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Center(child: CircularProgressIndicator());
    final tasks = ref.watch(remindersProvider),
        progress = LearningQueueService.progress(tasks);
    final batches = tasks
        .where((r) => r.isVisible && r.spacedRepetitionLevel > 0)
        .toList();
    final words = <String, VocabularyEntry>{};
    for (final task in tasks.where(
      (r) => r.isVisible || r.details.data['learning_archive'] == true,
    )) {
      for (final word in VocabularyEntry.parseNotes(task.taskSummary ?? '')) {
        words.putIfAbsent(LearningQueueService.wordKey(word.word), () => word);
      }
    }
    final practice = words.values.toList();
    final current = practice.isEmpty
        ? null
        : practice[_practiceIndex % practice.length];
    final events = <String, DateTime>{};
    for (final task in tasks) {
      for (final event in task.details.history.where(
        (e) => e.action == 'word_review',
      )) {
        events['${event.at.toIso8601String()}:${event.note}'] = event.at;
      }
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          t('learningOverview'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text('${t('wordArchive')}: ${progress.length}'),
        Wrap(
          spacing: 12,
          runSpacing: 5,
          children: [
            for (var level = 0; level <= 5; level++)
              Text(
                '$level: ${progress.values.where((p) => p.level == level).length}',
              ),
          ],
        ),
        Text(t('learningEvidence')),
        for (var i = 6; i >= 0; i--)
          (() {
            final day = DateTime(today.year, today.month, today.day - i);
            return Text(
              '${formatLocalDateTime(day, pattern: 'MM-dd')} · ${events.values.where((at) => LearningQueueService.sameDay(at, day)).length}',
            );
          })(),
        const Divider(),
        Text(t('loadForecast')),
        for (var i = 0; i < 7; i++)
          (() {
            final day = DateTime(today.year, today.month, today.day + i);
            final keys = <String>{};
            for (final task in batches.where(
              (r) => !r.details.paused && !r.isCompleted,
            )) {
              for (final word in VocabularyEntry.parseNotes(
                task.taskSummary ?? '',
              )) {
                final key = LearningQueueService.wordKey(word.word),
                    due =
                        progress[key]?.due ??
                        task.nextReviewAt ??
                        task.triggerTime ??
                        today;
                if (LearningQueueService.sameDay(due, day)) keys.add(key);
              }
            }
            return Text(
              '${formatLocalDateTime(day, pattern: 'MM-dd')} · ${keys.length}',
            );
          })(),
        const Divider(),
        Text(t('studyPlans')),
        for (final task in batches)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(task.taskTitle),
            subtitle: Text(
              '${task.nextReviewAt == null ? '' : formatLocalDateTime(task.nextReviewAt!)}${task.details.paused ? ' · ${t('pause')}' : ''}',
            ),
            trailing: PopupMenuButton<String>(
              enabled: !_busy,
              onSelected: (value) =>
                  value == 'edit' ? _edit(task) : _lifecycle(task),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'pause',
                  child: Text(t(task.details.paused ? 'resume' : 'pause')),
                ),
                PopupMenuItem(value: 'edit', child: Text(t('correctWords'))),
              ],
            ),
          ),
        const Divider(),
        Text(t('learningIntervals')),
        TextField(
          controller: _intervals,
          enabled: !_busy,
          decoration: const InputDecoration(hintText: '1, 2, 4, 7, 15'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  final values = _intervals.text
                      .split(RegExp('[,，]'))
                      .map((s) => int.tryParse(s.trim()))
                      .toList();
                  if (values.length != 5 ||
                      values.any((v) => v == null || v < 1 || v > 365)) {
                    _feedback(t('failed'));
                    return;
                  }
                  try {
                    await ref
                        .read(workspaceDraftsProvider.notifier)
                        .put('learningIntervals', values);
                    if (mounted && context.mounted && _current) {
                      _feedback(t('saved'));
                    }
                  } catch (_) {
                    if (mounted && context.mounted && _current) {
                      _feedback(t('failed'));
                    }
                  }
                },
          child: Text(t('saveIntervals')),
        ),
        const Divider(),
        Text(t('customWords')),
        Text(t('wordlistFormat')),
        TextField(
          controller: _title,
          maxLength: 100,
          enabled: !_busy,
          decoration: InputDecoration(labelText: t('title')),
          onChanged: (_) => _draft(),
        ),
        TextField(
          controller: _words,
          maxLength: 32000,
          enabled: !_busy,
          maxLines: 6,
          decoration: InputDecoration(labelText: t('customWords')),
          onChanged: (_) => _draft(),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: _first,
                    firstDate: DateTime.now(),
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
                    initialTime: TimeOfDay.fromDateTime(_first),
                  );
                  if (mounted && context.mounted && _current && time != null) {
                    setState(
                      () => _first = DateTime(
                        date.year,
                        date.month,
                        date.day,
                        time.hour,
                        time.minute,
                      ),
                    );
                  }
                },
          child: Text(formatLocalDateTime(_first)),
        ),
        FilledButton.tonal(
          onPressed: _busy ? null : _makePreview,
          child: Text(t('preview')),
        ),
        if (_preview && _importPlan != null) ...[
          for (final batch in _importPlan!.batches)
            ListTile(title: Text(batch.title), subtitle: Text(batch.content)),
          FilledButton(
            onPressed: _busy ? null : _import,
            child: Text(t('activate')),
          ),
        ],
        if (current != null) ...[
          const Divider(),
          Text(t('spellingPractice')),
          Text(current.meaning),
          TextField(
            controller: _answer,
            decoration: InputDecoration(labelText: t('spellingAnswer')),
          ),
          TextButton(
            onPressed: () => setState(
              () => _practiceResult =
                  LearningQueueService.wordKey(_answer.text) ==
                      LearningQueueService.wordKey(current.word)
                  ? t('spellingCorrect')
                  : '${t('spellingExpected')}: ${current.word}',
            ),
            child: Text(t('checkSpelling')),
          ),
          if (_practiceResult != null) Text(_practiceResult!),
          TextButton(
            onPressed: () => setState(() {
              _practiceIndex++;
              _practiceResult = null;
              _answer.clear();
            }),
            child: Text(t('nextWord')),
          ),
        ],
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }
}

class _VocabularyNotesDialog extends StatefulWidget {
  const _VocabularyNotesDialog({required this.notes});
  final String notes;
  @override
  State<_VocabularyNotesDialog> createState() => _VocabularyNotesDialogState();
}

class _VocabularyNotesDialogState extends State<_VocabularyNotesDialog> {
  late final TextEditingController _controller;
  String? _error;
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.notes);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(planningText(context, 'correctWords')),
    content: SizedBox(
      width: 600,
      child: TextField(
        controller: _controller,
        maxLines: 12,
        decoration: InputDecoration(
          labelText: planningText(context, 'wordNotes'),
          errorText: _error,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(AppLocalizations.of(context).get('cancel')),
      ),
      FilledButton(
        onPressed: () {
          if (VocabularyEntry.parseNotes(_controller.text).isEmpty) {
            setState(() => _error = planningText(context, 'failed'));
            return;
          }
          Navigator.pop(context, _controller.text);
        },
        child: Text(planningText(context, 'saved')),
      ),
    ],
  );
}
