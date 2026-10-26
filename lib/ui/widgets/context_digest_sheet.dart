import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/database_helper.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../l10n/app_localizations.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';
import '../screens/task_detail_screen.dart';
import 'inline_feedback.dart';

class ContextDigestSheet extends ConsumerStatefulWidget {
  const ContextDigestSheet({super.key, required this.digestReminders});
  final List<Reminder> digestReminders;
  @override
  ConsumerState<ContextDigestSheet> createState() => _ContextDigestSheetState();
}

class _ContextDigestSheetState extends ConsumerState<ContextDigestSheet> {
  DataGeneration? _generation;
  late final RuntimeRecoveryGate _gate;
  late final RuntimeRecoveryToken? _birth;
  late Map<String, Reminder> _members;
  final _busy = <String>{}, _resolved = <String>{};
  List<Reminder>? _source;
  List<Reminder> _visible = const [];
  @override
  void initState() {
    super.initState();
    _members = {for (final r in widget.digestReminders) r.id: r};
    _gate = ref.read(runtimeRecoveryGateProvider);
    _birth = _gate.paused ? null : _gate.capture();
    try {
      _generation = ref.read(databaseHelperProvider).captureGeneration();
    } on DatabaseAccessException {
      /* Keep the snapshot readable. */
    }
  }

  @override
  void didUpdateWidget(ContextDigestSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.digestReminders, widget.digestReminders)) {
      _members = {for (final r in widget.digestReminders) r.id: r};
      _source = null;
    }
  }

  void _refresh(List<Reminder> tasks) {
    if (identical(tasks, _source)) return;
    _source = tasks;
    _visible = [
      for (final task in tasks)
        if (_members.containsKey(task.id) &&
            !task.isCompleted &&
            !_resolved.contains(task.id) &&
            _members[task.id]!.noticeRevision == task.noticeRevision &&
            _members[task.id]!.triggerTime == task.triggerTime)
          task,
    ];
  }

  bool get _current => mounted && _gate.isCurrent(_birth);
  void _message(String value) =>
      InlineFeedback.of(context).showSnackBar(SnackBar(content: Text(value)));
  Future<void> _complete(Reminder task) async {
    if (_busy.contains(task.id) || _resolved.contains(task.id)) return;
    final loc = AppLocalizations.of(context);
    try {
      final database = ref.read(databaseHelperProvider);
      if (!_current || _generation == null) throw StateError('Old digest');
      database.checkGeneration(_generation!);
      setState(() => _busy.add(task.id));
      final result = await database.runOperation(
        _generation!,
        () => ref.read(remindersProvider.notifier).completeOccurrence(task),
      );
      database.checkGeneration(_generation!);
      if (!_current) return;
      setState(() {
        _resolved.add(task.id);
        _source = null;
      });
      _message(
        result.nativeSyncFailed
            ? loc.get('reminderNativeSyncFailed')
            : result.disposition == ReminderActionDisposition.stale
            ? loc.get('reminderOccurrenceChanged')
            : result.reminder?.isCompleted == false &&
                  result.reminder?.triggerTime != null
            ? '${loc.get('periodicNext')}${formatLocalDateTime(result.reminder!.triggerTime!)}'
            : '${loc.get('taskCompleted')}: ${task.taskTitle}',
      );
    } catch (_) {
      if (mounted) _message(loc.get('reminderUpdateFailed'));
    } finally {
      if (mounted) setState(() => _busy.remove(task.id));
    }
  }

  void _open(Reminder task) {
    if (!_current || _generation == null || _busy.contains(task.id)) return;
    try {
      ref.read(databaseHelperProvider).checkGeneration(_generation!);
    } on DatabaseAccessException {
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => TaskDetailScreen(task: task)),
    );
  }

  @override
  Widget build(BuildContext context) {
    _refresh(ref.watch(remindersProvider));
    final loc = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: LayoutBuilder(
            builder: (context, size) => Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: size.maxHeight * .35),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          loc
                              .get('digestPending')
                              .replaceAll('{count}', '${_visible.length}'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text(loc.get('digestScope')),
                          children: [
                            Text(
                              loc.get('digestSessionHint'),
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _visible.isEmpty
                      ? SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            loc.get('digestEmpty'),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.builder(
                          itemCount: _visible.length,
                          padding: const EdgeInsets.all(12),
                          itemBuilder: (context, index) {
                            final task = _visible[index];
                            return Card.outlined(
                              key: ValueKey('digest-${task.id}'),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      'Q${task.quadrantLevel} · ${task.taskTitle}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (task.taskSummary?.trim().isNotEmpty ==
                                        true) ...[
                                      const SizedBox(height: 8),
                                      Text(
                                        task.taskSummary!,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                    const SizedBox(height: 8),
                                    Wrap(
                                      alignment: WrapAlignment.end,
                                      spacing: 8,
                                      children: [
                                        if (_busy.contains(task.id))
                                          const SizedBox(
                                            width: 24,
                                            height: 24,
                                            child: CircularProgressIndicator(),
                                          ),
                                        IconButton(
                                          tooltip: loc.get('markDone'),
                                          onPressed: _busy.contains(task.id)
                                              ? null
                                              : () async => _complete(task),
                                          icon: const Icon(
                                            Icons.check_circle_outline,
                                          ),
                                        ),
                                        TextButton.icon(
                                          onPressed: _busy.contains(task.id)
                                              ? null
                                              : () => _open(task),
                                          icon: const Icon(Icons.open_in_new),
                                          label: Text(
                                            loc.get('openTaskDetail'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(loc.get('close')),
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
