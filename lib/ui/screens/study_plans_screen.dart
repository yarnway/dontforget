import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/database_helper.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/study_management_strings.dart';
import '../../models/study_plan_group.dart';
import '../../providers/providers.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';
import '../widgets/inline_feedback.dart';
import 'notification_repair_screen.dart';

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
  bool _busy = false;
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

  Future<void> _change(StudyPlanGroup group, String action) async {
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
                  for (final row in group.retained)
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
      final result = await ref
          .read(remindersProvider.notifier)
          .changeStudyPlan(group, action, _generation!);
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
    } catch (error) {
      if (mounted && _current) {
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
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t('title')),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: _busy ? null : () => Navigator.maybePop(context),
          ),
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                children: [
                  if (_busy) const LinearProgressIndicator(),
                  Expanded(
                    child: groups.isEmpty
                        ? Center(child: Text(t('empty')))
                        : ListView.builder(
                            key: const ValueKey('study-plan-list'),
                            padding: const EdgeInsets.all(16),
                            itemCount: groups.length,
                            itemBuilder: (context, index) {
                              final group = groups[index];
                              final paused = group.pending
                                  .where((row) => row.details.paused)
                                  .length;
                              final active = group.pending.length - paused;
                              return Card.outlined(
                                key: ValueKey('study-plan-${group.id}'),
                                margin: const EdgeInsets.only(bottom: 16),
                                child: Column(
                                  children: [
                                    ListTile(
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
                                        enabled: !_busy && _current,
                                        onSelected: (action) =>
                                            _change(group, action),
                                        itemBuilder: (_) => [
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
