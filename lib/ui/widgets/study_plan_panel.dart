import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/database_helper.dart';
import '../../l10n/app_localizations.dart';
import '../../models/study_plan.dart';
import '../../providers/providers.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';
import 'editable_text_menu.dart';
import 'workspace_tool_panel.dart';
import 'vocabulary_deck.dart';

/// Owned by the workspace, so closing/switching a panel retains its draft.
class StudyPlanDraft extends ChangeNotifier {
  StudyExam exam = StudyExam.cet4;
  int days = 3, words = 10;
  String notes = '';
  StudyPlan? plan;
  List<StudyBatch> edited = [];
  DateTime? firstReminder;
  DataGeneration? generation;
  CancelToken? request;
  bool busy = false, saving = false, saved = false;
  int syncFailures = 0, completedDays = 0;
  String? feedback;
  bool _disposed = false;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  void reset() {
    plan = null;
    edited = [];
    generation = null;
    firstReminder = null;
    feedback = null;
    saved = false;
    syncFailures = 0;
    completedDays = 0;
    changed();
  }

  @override
  void dispose() {
    _disposed = true;
    request?.cancel('Study workspace closed');
    super.dispose();
  }
}

class StudyPlanPanel extends ConsumerStatefulWidget {
  const StudyPlanPanel({
    super.key,
    required this.draft,
    required this.onClose,
    required this.onBusyChanged,
    required this.onReview,
  });
  final StudyPlanDraft draft;
  final VoidCallback onClose, onReview;
  final ValueChanged<bool> onBusyChanged;
  @override
  ConsumerState<StudyPlanPanel> createState() => _StudyPlanPanelState();
}

class _StudyPlanPanelState extends ConsumerState<StudyPlanPanel> {
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken? _birth;
  final _editingBatches = <int>{};
  StudyPlanDraft get d => widget.draft;
  bool get _current => mounted && _runtime.isCurrent(_birth);
  @override
  void initState() {
    super.initState();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.paused ? null : _runtime.capture();
  }

  Future<void> _generate() async {
    if (!_current || d.busy || d.saving || d.notes.length > 1000) return;
    final database = ref.read(databaseHelperProvider);
    final generation = database.captureGeneration();
    final service = ref.read(studyPlanServiceProvider);
    final token = CancelToken();
    d.request = token;
    d.busy = true;
    d.completedDays = 0;
    d.feedback = null;
    d.changed();
    widget.onBusyChanged(true);
    try {
      await ref.read(settingsProvider.notifier).ready;
      if (!_current || token.isCancelled) return;
      final settings = ref.read(settingsProvider);
      final plan = await service.generate(
        StudyRequest(
          exam: d.exam,
          days: d.days,
          wordsPerDay: d.words,
          notes: d.notes,
          language: settings.language,
        ),
        settings,
        cancelToken: token,
        onProgress: (completed) {
          if (_current && !token.isCancelled) {
            d.completedDays = completed;
            d.changed();
          }
        },
      );
      if (!_current || token.isCancelled) return;
      database.checkGeneration(generation);
      final now = DateTime.now();
      var first = DateTime(
        now.year,
        now.month,
        now.day,
        plan.suggestedMinute ~/ 60,
        plan.suggestedMinute % 60,
      );
      if (!first.isAfter(now.add(const Duration(minutes: 1)))) {
        first = DateTime(
          first.year,
          first.month,
          first.day + 1,
          first.hour,
          first.minute,
        );
      }
      _editingBatches.clear();
      d.plan = plan;
      d.edited = plan.batches.toList();
      d.firstReminder = first;
      d.generation = generation;
    } catch (_) {
      if (_current && !token.isCancelled) d.feedback = 'studyGenerateFailed';
    } finally {
      token.cancel('Study generation finished');
      d.request = null;
      d.busy = false;
      if (mounted) {
        d.changed();
        widget.onBusyChanged(false);
      }
    }
  }

  Future<void> _save() async {
    if (!_current || d.busy || d.saving || d.saved || d.plan == null) return;
    final focused = FocusManager.instance.primaryFocus?.context;
    final editable = focused?.widget is EditableText
        ? focused!.widget as EditableText
        : focused?.findAncestorWidgetOfExactType<EditableText>();
    final composing = editable?.controller.value.composing;
    if (composing != null && composing.isValid && !composing.isCollapsed) {
      return;
    }
    if (d.edited.any((b) => !b.isValid) ||
        !(d.firstReminder?.isAfter(DateTime.now()) ?? false)) {
      d.feedback = 'studyCheckPreview';
      d.changed();
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    d.saving = true;
    d.feedback = null;
    d.changed();
    widget.onBusyChanged(true);
    try {
      final rows = d.plan!.reminders(
        edited: d.edited,
        firstReminder: d.firstReminder!,
      );
      final result = await ref
          .read(remindersProvider.notifier)
          .addStudyPlan(rows, d.generation!);
      if (!_current) return;
      d.saved = true;
      d.syncFailures = result.nativeSyncFailures;
    } catch (_) {
      if (_current) d.feedback = 'studySaveFailed';
    } finally {
      d.saving = false;
      if (mounted) {
        d.changed();
        widget.onBusyChanged(false);
      }
    }
  }

  Future<void> _discard() async {
    if (d.busy || d.saving || !_current) return;
    final loc = AppLocalizations.of(context);
    final discard =
        d.saved ||
        await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(loc.get('unsavedChangesTitle')),
                content: Text(loc.get('studyDiscardMessage')),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(loc.get('keepEditing')),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(loc.get('discardChanges')),
                  ),
                ],
              ),
            ) ==
            true;
    if (_current && discard) d.reset();
  }

  Future<void> _pickDate() async {
    final initial = d.firstReminder!;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(today) ? today : initial,
      firstDate: today,
      lastDate: DateTime(now.year + 1, now.month, now.day),
    );
    if (date != null && _current) {
      d.firstReminder = DateTime(
        date.year,
        date.month,
        date.day,
        initial.hour,
        initial.minute,
      );
      d.changed();
    }
  }

  Future<void> _pickTime() async {
    final initial = d.firstReminder!;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time != null && _current) {
      d.firstReminder = DateTime(
        initial.year,
        initial.month,
        initial.day,
        time.hour,
        time.minute,
      );
      d.changed();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: d,
    builder: (context, _) {
      final loc = AppLocalizations.of(context);
      final colors = Theme.of(context).colorScheme;
      final locked = d.busy || d.saving;
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        },
        child: WorkspaceToolFrame(
          title: loc.get('studyTitle'),
          icon: Icons.auto_stories_outlined,
          embedded: true,
          onClose: widget.onClose,
          canClose: !locked,
          children: [
            Text(
              loc.get(
                d.saved
                    ? 'studySaved'
                    : d.plan == null
                    ? 'studyIntro'
                    : 'studyPreview',
              ),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            if (d.plan == null) ...[
              DropdownButtonFormField<StudyExam>(
                key: const ValueKey('study-exam'),
                initialValue: d.exam,
                decoration: InputDecoration(
                  labelText: loc.get('studyExam'),
                  border: const OutlineInputBorder(),
                ),
                isExpanded: true,
                isDense: false,
                itemHeight: null,
                selectedItemBuilder: (context) => [
                  for (final exam in StudyExam.values)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(loc.get('studyExam_${exam.name}')),
                    ),
                ],
                items: [
                  for (final exam in StudyExam.values)
                    DropdownMenuItem(
                      value: exam,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(loc.get('studyExam_${exam.name}')),
                      ),
                    ),
                ],
                onChanged: locked
                    ? null
                    : (v) {
                        if (v != null) {
                          d.exam = v;
                          d.changed();
                        }
                      },
              ),
              const SizedBox(height: 16),
              Text(loc.get('studyDailyWords')),
              Wrap(
                spacing: 8,
                children: [
                  for (final count in [5, 10, 15, 20])
                    ChoiceChip(
                      label: Text('$count'),
                      selected: d.words == count,
                      onSelected: locked
                          ? null
                          : (_) {
                              d.words = count;
                              d.changed();
                            },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(loc.get('studyDays')),
              Wrap(
                spacing: 8,
                children: [
                  for (final days in [1, 3, 7])
                    ChoiceChip(
                      label: Text('$days'),
                      selected: d.days == days,
                      onSelected: locked
                          ? null
                          : (_) {
                              d.days = days;
                              d.changed();
                            },
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('study-notes'),
                initialValue: d.notes,
                minLines: 2,
                maxLines: 4,
                maxLength: 1000,
                readOnly: locked,
                contextMenuBuilder: buildEditableTextMenu,
                decoration: InputDecoration(
                  labelText: loc.get('studyNotes'),
                  hintText: loc.get('studyNotesHint'),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => d.notes = v,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('study-generate'),
                onPressed: locked ? null : _generate,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: Text(loc.get('studyGenerate')),
              ),
            ],
            if (d.plan != null && !d.saved) ...[
              Text(
                '${loc.get('studyModel')}: ${d.plan!.modelLabel ?? ''}${d.plan!.usedFallback ? ' · ${loc.get('studyFallback')}' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text(
                '${loc.get('studyFirstReminder')}: ${formatLocalDateTime(d.firstReminder!)}',
              ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: locked ? null : _pickDate,
                    icon: const Icon(Icons.calendar_today_outlined),
                    label: Text(loc.get('studyChangeDate')),
                  ),
                  OutlinedButton.icon(
                    onPressed: locked ? null : _pickTime,
                    icon: const Icon(Icons.schedule),
                    label: Text(loc.get('studyChangeTime')),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < d.edited.length; i++)
                Card.outlined(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${loc.get('studyBatch')} ${i + 1}',
                          style: TextStyle(
                            color: colors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          key: ValueKey('study-title-$i'),
                          initialValue: d.edited[i].title,
                          maxLength: 120,
                          readOnly: locked,
                          contextMenuBuilder: buildEditableTextMenu,
                          decoration: InputDecoration(
                            labelText: loc.get('studyBatchTitle'),
                          ),
                          onChanged: (v) {
                            d.edited[i] = d.edited[i].copyWith(title: v);
                          },
                        ),
                        if (_editingBatches.contains(i)) ...[
                          TextFormField(
                            key: ValueKey('study-content-$i'),
                            initialValue: d.edited[i].content,
                            minLines: 3,
                            maxLines: 8,
                            maxLength: 24000,
                            readOnly: locked,
                            contextMenuBuilder: buildEditableTextMenu,
                            decoration: InputDecoration(
                              labelText: loc.get('studyWords'),
                            ),
                            onChanged: (v) {
                              d.edited[i] = d.edited[i].copyWith(content: v);
                            },
                          ),
                          Text(
                            loc.get('vocabEditHint'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ] else
                          VocabularyDeck(
                            key: ValueKey('study-deck-${d.plan!.id}-$i'),
                            content: d.edited[i].content,
                          ),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton.icon(
                            key: ValueKey('study-edit-$i'),
                            onPressed: locked
                                ? null
                                : () => setState(() {
                                    if (!_editingBatches.remove(i)) {
                                      _editingBatches.add(i);
                                    }
                                  }),
                            icon: Icon(
                              _editingBatches.contains(i)
                                  ? Icons.style_outlined
                                  : Icons.edit_outlined,
                            ),
                            label: Text(
                              loc.get(
                                _editingBatches.contains(i)
                                    ? 'vocabPreview'
                                    : 'vocabEdit',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('study-save'),
                onPressed: locked ? null : _save,
                icon: const Icon(Icons.add_task_rounded),
                label: Text(loc.get('studyConfirm')),
              ),
              TextButton(
                onPressed: locked ? null : _discard,
                child: Text(loc.get('studyStartOver')),
              ),
            ],
            if (d.saved) ...[
              Icon(Icons.check_circle_outline, size: 40, color: colors.primary),
              const SizedBox(height: 12),
              Text('${d.edited.length} · ${loc.get('studySavedHint')}'),
              Text(
                loc.get(
                  d.syncFailures > 0
                      ? 'reminderNativeSyncFailed'
                      : 'studyNotificationHint',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: widget.onReview,
                icon: const Icon(Icons.school_outlined),
                label: Text(loc.get('spacedRepetitionTitle')),
              ),
              TextButton(
                onPressed: _discard,
                child: Text(loc.get('studyNewPlan')),
              ),
            ],
            if (locked) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: d.busy && d.completedDays > 0
                    ? d.completedDays / d.days
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                d.saving
                    ? loc.get('reviewSaving')
                    : '${loc.get('studyGenerating')} ${d.completedDays}/${d.days}',
              ),
              if (d.busy)
                TextButton(
                  onPressed: () {
                    d.request?.cancel('User cancelled study generation');
                  },
                  child: Text(loc.get('cancel')),
                ),
            ],
            if (d.feedback != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    loc.get(d.feedback!),
                    style: TextStyle(color: colors.error),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                loc.get('studyAbout'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              childrenPadding: const EdgeInsets.only(bottom: 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loc.get('studyReviewPolicy'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  loc.get('studyDraftHint'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
