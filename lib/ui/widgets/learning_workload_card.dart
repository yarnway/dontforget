import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/study_management_strings.dart';
import '../../providers/providers.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/learning_workload_service.dart';
import '../../services/learning_forecast_service.dart';

class LearningWorkloadCard extends ConsumerStatefulWidget {
  const LearningWorkloadCard({super.key});
  @override
  ConsumerState<LearningWorkloadCard> createState() =>
      _LearningWorkloadCardState();
}

class _LearningWorkloadCardState extends ConsumerState<LearningWorkloadCard>
    with WidgetsBindingObserver {
  Timer? _midnight;
  bool _forecast = false;
  int _grade = 2;
  Object? _forecastKey;
  List<LearningForecastDay>? _forecastCache;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  void _schedule() {
    _midnight?.cancel();
    final now = DateTime.now();
    final next = DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(
      next.difference(now) + const Duration(milliseconds: 50),
      () {
        if (!mounted) return;
        setState(() {});
        _schedule();
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _forecastKey = null;
      setState(() {});
      _schedule();
    } else {
      _midnight?.cancel();
    }
  }

  @override
  void dispose() {
    _midnight?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    String t(String key) => studyManagementText(loc.locale.languageCode, key);
    final pref = ref.watch(
      workspaceDraftsProvider.select((s) => s['learningPreferences']),
    );
    final stored = pref is Map ? pref : const {};
    final daily = const [5, 10, 20, 40].contains(stored['daily'])
        ? stored['daily'] as int
        : 20;
    final fresh = (stored['new'] is int ? stored['new'] as int : 10).clamp(
      0,
      daily,
    );
    final tasks = ref.watch(remindersProvider);
    final intervals = ref.watch(
      workspaceDraftsProvider.select((s) => s['learningIntervals']),
    );
    final now = DateTime.now();
    List<LearningDayLoad>? days;
    List<LearningForecastDay>? forecast;
    try {
      days = LearningWorkloadService.project(tasks, now: now);
    } on FormatException {
      days = null;
    }
    if (_forecast) {
      final local = now.toLocal();
      final key = (
        tasks,
        DateTime(local.year, local.month, local.day),
        daily,
        fresh,
        _grade,
        intervals,
      );
      if (key != _forecastKey) {
        try {
          _forecastCache = LearningForecastService.project(
            tasks,
            now: now,
            dailyLimit: daily,
            newLimit: fresh,
            grade: _grade,
            intervals: intervals == null
                ? const [1, 2, 4, 7, 15]
                : (intervals as List).cast<int>(),
          );
          _forecastKey = key;
        } on FormatException {
          _forecastCache = null;
          _forecastKey = null;
        } on TypeError {
          _forecastCache = null;
          _forecastKey = null;
        }
      }
      forecast = _forecastCache;
    }
    final rows = _forecast
        ? forecast
              ?.map(
                (d) => (
                  date: d.date,
                  fresh: d.newWords,
                  review: d.reviewWords,
                  waiting: d.deferred,
                ),
              )
              .toList()
        : days
              ?.map(
                (d) => (
                  date: d.date,
                  fresh: d.newWords,
                  review: d.reviewWords,
                  waiting: d.excess(daily, fresh),
                ),
              )
              .toList();
    return Card.outlined(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        key: const PageStorageKey('learning-workload'),
        title: Text(t('workload')),
        subtitle: days == null
            ? Text(loc.get('learningProgressInvalid'))
            : Text(
                '${days.fold(0, (sum, d) => sum + d.total)} ${t('scheduledWords')}',
              ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mode in [false, true])
                  ChoiceChip(
                    key: ValueKey(
                      mode
                          ? 'workload-view-forecast'
                          : 'workload-view-scheduled',
                    ),
                    label: Text(t(mode ? 'forecastView' : 'scheduledView')),
                    selected: _forecast == mode,
                    onSelected: (_) => setState(() => _forecast = mode),
                  ),
              ],
            ),
          ),
          if (_forecast) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(t('forecastFeedback')),
            ),
            SizedBox(
              width: double.infinity,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final grade in [2, 1, 0])
                    ChoiceChip(
                      key: ValueKey('workload-grade-$grade'),
                      label: Text(
                        loc.get(
                          const [
                            'wordUnknown',
                            'wordFuzzy',
                            'wordKnown',
                          ][grade],
                        ),
                      ),
                      selected: _grade == grade,
                      onSelected: (_) => setState(() => _grade = grade),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (rows == null)
            Text(
              _forecast
                  ? t('forecastUnavailable')
                  : loc.get('learningProgressInvalid'),
            )
          else ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${t('dailyLimit')} $daily · ${t('newWords')} $fresh',
              ),
            ),
            for (var i = 0; i < rows.length; i++)
              Padding(
                key: ValueKey('workload-day-$i'),
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    alignment: WrapAlignment.spaceBetween,
                    children: [
                      Text(
                        MaterialLocalizations.of(
                          context,
                        ).formatShortMonthDay(rows[i].date),
                      ),
                      Text(
                        '${t('newWords')} ${rows[i].fresh} · ${t('reviewWords')} ${rows[i].review}',
                      ),
                      if (rows[i].waiting > 0)
                        Text(
                          '${t(_forecast ? 'forecastDeferred' : 'overLimit')} ${rows[i].waiting}',
                          style: TextStyle(
                            color: _forecast
                                ? Theme.of(context).colorScheme.onSurfaceVariant
                                : Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            Text(
              t(_forecast ? 'forecastScope' : 'workloadScope'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}
