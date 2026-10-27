import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/ui/formatters/local_date_time.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final instant = DateTime.utc(2026, 10, 27, 12);
  const intervals = [
    Duration(days: 2, hours: 3),
    Duration(hours: 1, minutes: 5),
    Duration(minutes: 3),
    Duration(microseconds: 1),
    Duration.zero,
    Duration(minutes: -1),
  ];
  const expected = {
    'en': [
      '2d 3h',
      '1h 5m',
      '3m',
      'Less than a minute',
      'Reminder time passed',
      'Reminder time passed',
    ],
    'zh': ['2天 3小时', '1小时 5分钟', '3分钟', '不足1分钟', '提醒时间已过', '提醒时间已过'],
    'ja': ['2日 3時間', '1時間 5分', '3分', '1分未満', '通知時刻を経過', '通知時刻を経過'],
  };
  for (final language in expected.keys) {
    test('$language countdown units and exact due boundary', () {
      final l10n = AppLocalizations(Locale(language));
      expect([
        for (final interval in intervals)
          formatReminderTimeRemaining(l10n, instant.add(interval), instant),
      ], expected[language]);
      expect(
        formatReminderTimeRemaining(l10n, instant.toLocal(), instant),
        expected[language]![4],
      );
    });
  }
}
