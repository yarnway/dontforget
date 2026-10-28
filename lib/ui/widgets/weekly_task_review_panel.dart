import 'package:flutter/material.dart';
import '../../l10n/planning_strings.dart';
import '../../models/reminder.dart';
import '../../models/weekly_task_review.dart';
import '../formatters/local_date_time.dart';

class WeeklyTaskReviewPanel extends StatefulWidget {
  const WeeklyTaskReviewPanel({super.key, required this.rows, this.query = ''});
  final List<Reminder> rows;
  final String query;
  @override
  State<WeeklyTaskReviewPanel> createState() => _WeeklyTaskReviewPanelState();
}

class _WeeklyTaskReviewPanelState extends State<WeeklyTaskReviewPanel> {
  DateTime _week = DateTime.now();
  @override
  Widget build(BuildContext context) {
    String t(String key) => planningText(context, key);
    final now = DateTime.now();
    final review = WeeklyTaskReview.build(
      widget.rows,
      weekContaining: _week,
      now: now,
      query: widget.query,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t('weeklyReview'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    key: const ValueKey('review-previous-week'),
                    tooltip: t('previousWeek'),
                    onPressed: () => setState(
                      () => _week = DateTime(
                        review.start.year,
                        review.start.month,
                        review.start.day - 7,
                      ),
                    ),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    '${formatLocalDateTime(review.start, pattern: 'yyyy-MM-dd')} — ${formatLocalDateTime(DateTime(review.end.year, review.end.month, review.end.day - 1), pattern: 'MM-dd')}',
                  ),
                  IconButton(
                    key: const ValueKey('review-next-week'),
                    tooltip: t('nextWeek'),
                    onPressed: review.end.isAfter(now)
                        ? null
                        : () => setState(() => _week = review.end),
                    icon: const Icon(Icons.chevron_right),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _week = now),
                    child: Text(t('thisWeek')),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final key in review.counts.keys)
                    Chip(
                      label: Text('${t('review_$key')}: ${review.counts[key]}'),
                    ),
                  Chip(
                    label: Text(
                      '${t('reviewActiveDays')}: ${review.activeDays}',
                    ),
                  ),
                ],
              ),
              if (review.frequentPostponements.isNotEmpty) ...[
                Text(t('reviewFrequentPostponements')),
                for (final item in review.frequentPostponements)
                  Text('${item.title} · ${item.count}'),
              ],
              Text(
                t('weeklyReviewHint'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
