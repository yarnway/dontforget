import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/study_management_strings.dart';
import '../../providers/providers.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/learning_workload_service.dart';

class LearningWorkloadCard extends ConsumerStatefulWidget {
  const LearningWorkloadCard({super.key});
  @override
  ConsumerState<LearningWorkloadCard> createState() =>
      _LearningWorkloadCardState();
}

class _LearningWorkloadCardState extends ConsumerState<LearningWorkloadCard>
    with WidgetsBindingObserver {
  Timer? _midnight;
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
    List<LearningDayLoad>? days;
    try {
      days = LearningWorkloadService.project(
        ref.watch(remindersProvider),
        now: DateTime.now(),
      );
    } on FormatException {
      days = null;
    }
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
          if (days != null) ...[
            Text('${t('dailyLimit')} $daily · ${t('newWords')} $fresh'),
            for (final day in days)
              Padding(
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
                        ).formatShortMonthDay(day.date),
                      ),
                      Text(
                        '${t('newWords')} ${day.newWords} · ${t('reviewWords')} ${day.reviewWords}',
                      ),
                      if (day.excess(daily, fresh) > 0)
                        Text(
                          '${t('overLimit')} ${day.excess(daily, fresh)}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            Text(
              t('workloadScope'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}
