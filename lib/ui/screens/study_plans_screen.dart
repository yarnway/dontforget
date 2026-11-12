import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/database_helper.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/study_management_strings.dart';
import '../../models/study_plan_group.dart';
import '../../providers/providers.dart';
import '../../services/recovery/runtime_gate.dart';
import '../../services/study_schedule_service.dart';
import '../formatters/local_date_time.dart';
import '../widgets/inline_feedback.dart';
import '../widgets/learning_workload_card.dart';
import '../widgets/study_schedule_dialog.dart';
import 'notification_repair_screen.dart';
import 'word_archive_screen.dart';

class StudyPlansScreen extends ConsumerStatefulWidget {
  const StudyPlansScreen({super.key});
  @override
  ConsumerState<StudyPlansScreen> createState() => _StudyPlansScreenState();
}

class _StudyPlansScreenState extends ConsumerState<StudyPlansScreen> {
  late final DatabaseHelper _database;
  late final RuntimeRecoveryGate _runtime;
  RuntimeRecoveryToken? _birth;
  DataGeneration? _generation;
  bool _busy = false, _selecting = false;
  bool _previewingDates = false;
  final _selected = <String, StudyPlanGroup>{};
  bool get _current =>
      mounted &&
      _runtime.isCurrent(_birth) &&
      _generation != null &&
      _database.isCurrent(_generation!);
  String t(String key) => studyManagementText(
    AppLocalizations.of(context).locale.languageCode,
    key,
  );

  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _runtime = ref.read(runtimeRecoveryGateProvider);
    if (!_runtime.paused) {
      _birth = _runtime.capture();
      try {
        _generation = _database.captureGeneration();
      } on DatabaseAccessException {
        _generation = null;
      }
    }
  }

  void _select(StudyPlanGroup group, bool selected) {
    if (_busy || !_current) return;
    if (selected &&
        (_selected.length >= 20 ||
            _selected.values.fold(0, (n, g) => n + g.members.length) +
                    group.members.length >
                50)) {
      InlineFeedback.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('selectionLimit'))));
      return;
    }
    setState(() {
      if (selected) {
        _selected[group.id] = group;
      } else {
        _selected.remove(group.id);
      }
    });
  }

  void _cancelSelection() => setState(() {
    _selecting = false;
    _selected.clear();
  });
  Future<void> _change(StudyPlanGroup group, String action) =>
      action == 'shift' ? _shift([group]) : _apply([group], action);

  Future<void> _shift(List<StudyPlanGroup> groups) async {
    if (_busy || !_current) return;
    setState(() {
      _busy = true;
      _previewingDates = true;
    });
    try {
      final preview = await showDialog<StudySchedulePreview>(
        context: context,
        builder: (_) => StudyScheduleDialog(
          rows: ref.read(remindersProvider),
          groups: groups,
        ),
      );
      if (preview == null || !mounted || !_current) return;
      setState(() => _previewingDates = false);
      final result = await ref
          .read(remindersProvider.notifier)
          .shiftStudyPlanDates(preview, _generation!);
      if (!mounted || !_current) return;
      _cancelSelection();
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
    } catch (error) {
      if (mounted && _current) {
        final stale =
            error is StaleReminderOccurrenceException ||
            error is StudyScheduleStale;
        if (stale) _cancelSelection();
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                stale
                    ? 'stale'
                    : error is StudyScheduleConflict
                    ? 'sharedDates'
                    : error is StudyScheduleRecurring
                    ? 'recurringDates'
                    : 'failed',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _previewingDates = false;
        });
      }
    }
  }

  Future<void> _apply(List<StudyPlanGroup> groups, String action) async {
    if (_busy || !_current) return;
    if (action == 'trash') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(t('confirm')),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final row in groups.single.retained)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(row.taskTitle),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(AppLocalizations.of(context).get('cancel')),
            ),
            FilledButton(
              key: const ValueKey('study-plan-confirm-trash'),
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(t('trash')),
            ),
          ],
        ),
      );
      if (confirmed != true || !_current) return;
    }
    setState(() => _busy = true);
    try {
      final notifier = ref.read(remindersProvider.notifier);
      final result = groups.length == 1
          ? await notifier.changeStudyPlan(groups.single, action, _generation!)
          : await notifier.changeStudyPlans(groups, action, _generation!);
      if (!mounted || !_current) return;
      _cancelSelection();
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
    } catch (error) {
      if (mounted && _current) {
        if (error is StaleReminderOccurrenceException) _cancelSelection();
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(error is StaleReminderOccurrenceException ? 'stale' : 'failed'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = StudyPlanGroup.project(ref.watch(remindersProvider));
    return PopScope(
      canPop: !_busy && !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy && _selecting) _cancelSelection();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(t('title')),
          actions: [
            IconButton(
              key: const ValueKey('study-word-archive'),
              tooltip: t('wordArchive'),
              icon: const Icon(Icons.history_rounded),
              onPressed: !_current || _busy
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const WordArchiveScreen(),
                      ),
                    ),
            ),
            if (groups.isNotEmpty)
              IconButton(
                key: const ValueKey('study-plan-select'),
                tooltip: t(_selecting ? 'cancelSelection' : 'selectPlans'),
                icon: Icon(_selecting ? Icons.close : Icons.checklist),
                onPressed: !_current || _busy
                    ? null
                    : () {
                        if (_selecting) {
                          _cancelSelection();
                        } else {
                          setState(() => _selecting = true);
                        }
                      },
              ),
          ],
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: _busy
                ? null
                : _selecting
                ? _cancelSelection
                : () => Navigator.maybePop(context),
          ),
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                children: [
                  if (_busy && !_previewingDates)
                    const LinearProgressIndicator(),
                  Expanded(
                    child: groups.isEmpty
                        ? Center(child: Text(t('empty')))
                        : ListView.builder(
                            key: const ValueKey('study-plan-list'),
                            padding: const EdgeInsets.all(16),
                            itemCount: groups.length + 1,
                            itemBuilder: (context, index) {
                              if (index == 0) {
                                return const LearningWorkloadCard();
                              }
                              final group = groups[index - 1];
                              final paused = group.pending
                                  .where((row) => row.details.paused)
                                  .length;
                              final active = group.pending.length - paused;
                              return Card.outlined(
                                key: ValueKey('study-plan-${group.id}'),
                                margin: const EdgeInsets.only(bottom: 16),
                                clipBehavior: Clip.antiAlias,
                                child: Column(
                                  children: [
                                    ListTile(
                                      leading: _selecting
                                          ? Checkbox(
                                              key: ValueKey(
                                                'study-plan-check-${group.id}',
                                              ),
                                              semanticLabel:
                                                  '${t('selectPlans')} · ${group.title}',
                                              value: _selected.containsKey(
                                                group.id,
                                              ),
                                              onChanged:
                                                  _busy ||
                                                      !_current ||
                                                      group.pending.isEmpty
                                                  ? null
                                                  : (value) => _select(
                                                      group,
                                                      value == true,
                                                    ),
                                            )
                                          : null,
                                      title: Text(group.title),
                                      subtitle: Text(
                                        '${group.createdAt == null ? '' : '${formatLocalDateTime(group.createdAt!)}\n'}'
                                        '${group.retained.length} ${t('batches')} · $active ${t('pending')}'
                                        '${paused == 0 ? '' : ' · $paused ${t('paused')}'}',
                                      ),
                                      trailing: PopupMenuButton<String>(
                                        tooltip:
                                            '${t('actions')} · ${group.title}',
                                        key: ValueKey(
                                          'study-plan-actions-${group.id}',
                                        ),
                                        enabled:
                                            !_busy && !_selecting && _current,
                                        onSelected: (action) =>
                                            _change(group, action),
                                        itemBuilder: (_) => [
                                          if (group.pending.isNotEmpty)
                                            PopupMenuItem(
                                              value: 'shift',
                                              child: Text(t('shiftDates')),
                                            ),
                                          if (group.canPause)
                                            PopupMenuItem(
                                              value: 'pause',
                                              child: Text(t('pause')),
                                            ),
                                          if (group.canResume)
                                            PopupMenuItem(
                                              value: 'resume',
                                              child: Text(t('resume')),
                                            ),
                                          PopupMenuItem(
                                            value: 'trash',
                                            child: Text(t('trash')),
                                          ),
                                        ],
                                      ),
                                    ),
                                    ExpansionTile(
                                      key: PageStorageKey(
                                        'study-plan-members-${group.id}',
                                      ),
                                      title: Text(t('batches')),
                                      children: [
                                        for (final row in group.retained)
                                          ListTile(
                                            dense: true,
                                            title: Text(row.taskTitle),
                                            subtitle: Text(
                                              row.details.archivedAt != null
                                                  ? t('archived')
                                                  : row.isCompleted
                                                  ? t('completed')
                                                  : row.details.paused
                                                  ? t('paused')
                                                  : row.nextReviewAt == null
                                                  ? t('pending')
                                                  : formatLocalDateTime(
                                                      row.nextReviewAt!,
                                                    ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  if (_selecting)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: double.infinity,
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text('${t('selectedPlans')} ${_selected.length}'),
                            FilledButton.tonal(
                              key: const ValueKey('study-plans-shift'),
                              onPressed: _busy || !_current || _selected.isEmpty
                                  ? null
                                  : () => _shift(_selected.values.toList()),
                              child: Text(t('shiftDates')),
                            ),
                            FilledButton.tonal(
                              key: const ValueKey('study-plans-pause'),
                              onPressed:
                                  _busy ||
                                      !_current ||
                                      !_selected.values.any((g) => g.canPause)
                                  ? null
                                  : () => _apply(
                                      _selected.values.toList(),
                                      'pause',
                                    ),
                              child: Text(t('pause')),
                            ),
                            FilledButton.tonal(
                              key: const ValueKey('study-plans-resume'),
                              onPressed:
                                  _busy ||
                                      !_current ||
                                      !_selected.values.any((g) => g.canResume)
                                  ? null
                                  : () => _apply(
                                      _selected.values.toList(),
                                      'resume',
                                    ),
                              child: Text(t('resume')),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
