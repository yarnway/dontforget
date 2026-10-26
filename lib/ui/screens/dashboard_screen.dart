import '../widgets/workspace_tool_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';
import '../../models/review_report.dart';
import '../../models/settings.dart';
import '../../models/task_statistics.dart';
import '../../providers/providers.dart';
import '../../providers/task_statistics_provider.dart';
import '../../services/recovery/runtime_gate.dart';
import '../widgets/inline_feedback.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({
    super.key,
    this.embedded = false,
    this.onClose,
    this.onBusyChanged,
  });
  final bool embedded;
  final VoidCallback? onClose;
  final ValueChanged<bool>? onBusyChanged;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken? _birth;
  bool _isLoadingReport = false;
  bool _copying = false;
  bool _reportFailed = false;
  ReviewReport? _report;
  List<Reminder>? _reportTasks;
  AppSettings? _reportSettings;

  @override
  void initState() {
    super.initState();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.paused ? null : _runtime.capture();
  }

  bool get _isCurrent => mounted && _runtime.isCurrent(_birth);

  Future<void> _generateReport() async {
    if (!_isCurrent || _isLoadingReport) return;
    final tasks = ref.read(remindersProvider);
    final settings = ref.read(settingsProvider);
    if (tasks.isEmpty) return;
    setState(() {
      _isLoadingReport = true;
      _reportFailed = false;
    });
    widget.onBusyChanged?.call(true);
    try {
      final report = await ref
          .read(llmServiceProvider)
          .generateReview(tasks, settings, language: settings.language);
      if (!_isCurrent) return;
      if (report.content.trim().isEmpty) {
        throw const FormatException('Empty report');
      }
      setState(() {
        _report = report;
        _reportTasks = tasks;
        _reportSettings = settings;
      });
    } catch (_) {
      if (_isCurrent) setState(() => _reportFailed = true);
    } finally {
      if (_isCurrent) {
        setState(() => _isLoadingReport = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  Future<void> _copyReport() async {
    if (!_isCurrent || _copying || _report == null) return;
    final l10n = AppLocalizations.of(context);
    final source = _report!.source == ReviewReportSource.model
        ? 'reviewSourceModel'
        : 'reviewSourceLocal';
    final text = '${l10n.get(source)}\n\n${_report!.content}';
    setState(() => _copying = true);
    var message = l10n.get('reportCopied');
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      message = l10n.get('reportCopyFailed');
    }
    if (!mounted || !_isCurrent) return;
    setState(() => _copying = false);
    InlineFeedback.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final stats = ref.watch(taskStatisticsProvider);
    final tasks = ref.watch(remindersProvider);
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final stale =
        _report != null &&
        (!identical(_reportTasks, tasks) ||
            !identical(_reportSettings, settings));

    final body = SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: ListView(
            key: const PageStorageKey('dashboard-scroll'),
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            children: [
              Text(
                l10n.get('dashboardOverview'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.get('dashboardScope'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              if (stats.total == 0)
                _section(
                  context,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        Icon(
                          Icons.bar_chart_rounded,
                          size: 40,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          l10n.get('noTasksYet'),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                LayoutBuilder(
                  builder: (context, constraints) {
                    final scale =
                        MediaQuery.textScalerOf(context).scale(14) / 14;
                    final columns =
                        constraints.maxWidth >= 540 * scale.clamp(1, 2) ? 3 : 1;
                    final width =
                        (constraints.maxWidth - 12 * (columns - 1)) / columns;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _stat(
                          context,
                          l10n.get('total'),
                          stats.total,
                          Icons.checklist_rounded,
                          width,
                        ),
                        _stat(
                          context,
                          l10n.get('completed'),
                          stats.completed,
                          Icons.task_alt_rounded,
                          width,
                        ),
                        _stat(
                          context,
                          l10n.get('pending'),
                          stats.pending,
                          Icons.schedule_rounded,
                          width,
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                _section(
                  context,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            l10n.get('dashboardCompletion'),
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            '${stats.completionPercent}%',
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: stats.completionFraction,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(8),
                        semanticsLabel: l10n.get('dashboardCompletion'),
                        semanticsValue: '${stats.completionPercent}%',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final categories = _categories(context, stats, l10n);
                    final review = _review(context, l10n, settings, stale);
                    final scale =
                        MediaQuery.textScalerOf(context).scale(14) / 14;
                    if (constraints.maxWidth >= 860 && scale <= 1.3) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: categories),
                          const SizedBox(width: 20),
                          Expanded(flex: 7, child: review),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        categories,
                        const SizedBox(height: 20),
                        review,
                      ],
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (widget.embedded) {
      return WorkspaceToolFrame(
        title: l10n.get('dashboardTitle'),
        icon: Icons.bar_chart_rounded,
        embedded: true,
        onClose: widget.onClose,
        canClose: !_isLoadingReport,
        body: body,
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.get('dashboardTitle'))),
      body: body,
    );
  }

  Widget _section(BuildContext context, {required Widget child}) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  Widget _stat(
    BuildContext context,
    String label,
    int value,
    IconData icon,
    double width,
  ) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: _section(
        context,
        child: Row(
          children: [
            Icon(icon, color: theme.colorScheme.primary, size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$value',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _categories(
    BuildContext context,
    TaskStatistics stats,
    AppLocalizations l10n,
  ) {
    final theme = Theme.of(context);
    return _section(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.get('quadrantDist'),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.get('dashboardCategoryScope'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          for (var i = 0; i < 4; i++) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.get('cat${i + 1}'),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${stats.categories[i]}',
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: stats.categories[i] / stats.total,
              minHeight: 6,
              borderRadius: BorderRadius.circular(6),
              semanticsLabel: l10n.get('cat${i + 1}'),
              semanticsValue:
                  '${(stats.categories[i] / stats.total * 100).round()}%',
            ),
          ],
        ],
      ),
    );
  }

  Widget _review(
    BuildContext context,
    AppLocalizations l10n,
    AppSettings settings,
    bool stale,
  ) {
    final theme = Theme.of(context);
    final hasModel = settings.primaryModelSettings.apiKey.trim().isNotEmpty;
    final report = _report;
    final sourceLabel = report?.source == ReviewReportSource.model
        ? 'reviewSourceModel'
        : 'reviewSourceLocal';
    return _section(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.get('reviewTitle'),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.get('aiReviewSubtitle'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (report != null) ...[
            Text(
              l10n.get(sourceLabel),
              key: const ValueKey('review-source'),
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            if (report.source == ReviewReportSource.localAfterFailure)
              _notice(context, l10n.get('reviewModelUnavailable'), error: true)
            else if (report.source == ReviewReportSource.local)
              _notice(context, l10n.get('reviewLocalExplanation')),
            if (stale) _notice(context, l10n.get('reviewStale')),
            const SizedBox(height: 12),
            SelectableText(
              report.content,
              key: const ValueKey('review-content'),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
            ),
            const SizedBox(height: 16),
          ] else if (!hasModel)
            _notice(context, l10n.get('reviewLocalExplanation')),
          if (_reportFailed)
            _notice(context, l10n.get('reviewGenerationFailed'), error: true),
          if (_isLoadingReport)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                children: [
                  if (MediaQuery.disableAnimationsOf(context))
                    const Icon(Icons.hourglass_empty_rounded, size: 20)
                  else
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l10n.get('generatingAiReview'))),
                ],
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const ValueKey('review-generate'),
                onPressed: _isLoadingReport ? null : _generateReport,
                icon: Icon(
                  report == null
                      ? Icons.auto_awesome_outlined
                      : Icons.refresh_rounded,
                  size: 18,
                ),
                label: Text(
                  l10n.get(
                    _reportFailed ||
                            report?.source ==
                                ReviewReportSource.localAfterFailure
                        ? 'reviewRetry'
                        : report != null
                        ? 'regenerateAiReview'
                        : hasModel
                        ? 'generateAiReview'
                        : 'reviewGenerateLocal',
                  ),
                ),
              ),
              if (report != null)
                OutlinedButton.icon(
                  key: const ValueKey('review-copy'),
                  onPressed: _copying ? null : _copyReport,
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: Text(l10n.get('copyReport')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _notice(BuildContext context, String text, {bool error = false}) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Semantics(
        liveRegion: true,
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: error ? colors.error : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
