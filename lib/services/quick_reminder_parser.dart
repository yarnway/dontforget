/// Deliberately small offline grammar. Ambiguous or past dates stay unscheduled.
class QuickReminderParser {
  static final _unclear = RegExp(
    r'大概|大约|可能|也许|左右|差不多|待定|暂定|不确定|看情况|如果|假如|有空|稍后|尽快|或者|还是|分别|然后|等.+再|[?？]|是否|不(?:要|用).{0,8}提醒|取消提醒|\b(?:do not|don.t|never) remind\b|\b(maybe|perhaps|around|approximately|unless|if|either|or|sometime)\b|たぶん|多分|未定|ごろ',
    caseSensitive: false,
  );
  static final _recurrenceIntent = RegExp(
    r'每天|每日|毎日|每周|毎週|每星期|每月|每年|工作日|平日|\b(?:daily|weekly|monthly|yearly|weekdays)\b|every\s+',
    caseSensitive: false,
  );
  static final _advanceMarker = RegExp(
    r'提前|之前|before|in advance',
    caseSensitive: false,
  );
  static final _boundedRecurrence = RegExp(
    r'[;；。\n]|[0-9一二两三四五六七八九十]+\s*(?:天|周|星期|个月|月|年)|截至|截止|直到|到期|until|ending',
    caseSensitive: false,
  );
  static final _clockToken = RegExp(
    r'(?:\d{1,2}|[一二两三四五六七八九十]{1,3})(?::\d{2}|[点時]|\s*(?:am|pm)\b)',
    caseSensitive: false,
  );
  static final _dailyPattern = RegExp(
    r'每天|每日|毎日|\bdaily\b|every day',
    caseSensitive: false,
  );
  static final _workdayPattern = RegExp(
    r'工作日|平日|\bweekdays\b|every workday',
    caseSensitive: false,
  );
  static final _weeklyPattern = RegExp(
    r'(?:每周|每星期|毎週)[一二三四五六日天月火水木金土]|every (?:mon|tues|wednes|thurs|fri|satur|sun)day',
    caseSensitive: false,
  );
  static final _multiWeeklyPattern = RegExp(
    r'(?:每周|每星期|毎週)[一二三四五六日天月火水木金土][、和及至到-]',
  );
  static final _cjkNumber = RegExp(
    r'([零〇一二两三四五六七八九十]{1,3})(?=分钟|小时|点|分|時|時間)',
  );
  static final _relativeDuration = RegExp(
    r'(\d{1,4})\s*(分钟|小時|小时|minutes?|mins?|hours?|hrs?|分|時間)(?:后|後|\s+later)?',
    caseSensitive: false,
  );
  static final _hoursUnit = RegExp(
    r'小时|小時|時間|hour|hr',
    caseSensitive: false,
  );
  static final _dayMarker = RegExp(
    r'今天|明天|后天|今晚|明早|明日|今日|today|tomorrow',
    caseSensitive: false,
  );
  static final _periodOnlyMarker = RegExp(r'上午|早上|早晨|下午|晚上|中午|午前|午後');
  static final _timePattern = RegExp(
    r'(上午|早上|早晨|下午|晚上|中午|午前|午後|am|pm)?\s*(\d{1,2})(?::(\d{2})|[点時](半|\d{1,2}分?)?)\s*(am|pm)?',
    caseSensitive: false,
  );
  static final _simpleAmPm = RegExp(
    r'\b(\d{1,2})\s*(am|pm)\b',
    caseSensitive: false,
  );
  static final _pastMarker = RegExp(
    r'昨天|前天|昨日|一昨日|上周|上星期|先週|\byesterday\b|last week',
    caseSensitive: false,
  );
  static final _explicitDate = RegExp(
    r'(\d{4})[-年](\d{1,2})[-月](\d{1,2})日?',
  );
  static final _timezoneSuffix = RegExp(
    r'\b(?:UTC|GMT)\b|\d[Zz]\b|[+-]\d{2}:?\d{2}',
    caseSensitive: false,
  );
  static final _leadingIsoT = RegExp(r'^[Tt]');
  static final _cjkWeekday = RegExp(
    r'(?:每周|毎週|每星期|星期|周)([一二三四五六日天月火水木金土])',
  );
  static final _englishWeekday = RegExp(
    r'\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b',
    caseSensitive: false,
  );
  static const _englishWeekdayMap = {
    'monday': 1,
    'tuesday': 2,
    'wednesday': 3,
    'thursday': 4,
    'friday': 5,
    'saturday': 6,
    'sunday': 7,
  };
  static final _nextWeekPattern = RegExp(
    r'下周|下星期|来週|next week|\bnext\s+(?:mon|tues|wednes|thurs|fri|satur|sun)day',
    caseSensitive: false,
  );
  static final _thisWeekPattern = RegExp(
    r'本周|这周|今週|this week',
    caseSensitive: false,
  );

  static bool isAmbiguous(String text) => _unclear.hasMatch(text);
  static bool hasRecurrenceIntent(String text) =>
      _recurrenceIntent.hasMatch(text);

  /// Only one unbounded cadence and one readable clock may bypass AI review.
  static String? recurrence(String text) {
    if (text.length > 500 ||
        _advanceMarker.hasMatch(text) ||
        isAmbiguous(text) ||
        _boundedRecurrence.hasMatch(text)) {
      return null;
    }
    final clocks = _clockToken.allMatches(text).length;
    if (clocks != 1) return null;
    final matches = <String>[];
    if (_dailyPattern.hasMatch(text)) {
      matches.add('daily');
    }
    if (_workdayPattern.hasMatch(text)) {
      matches.add('workday');
    }
    if (_weeklyPattern.allMatches(text).length == 1) {
      matches.add('weekly');
    }
    if (_multiWeeklyPattern.hasMatch(text)) {
      return null;
    }
    return matches.length == 1 ? matches.single : null;
  }

  static DateTime? parse(String text, {DateTime? now}) =>
      isAmbiguous(text) ? null : _parse(text, now: now);
  static DateTime? _parse(String text, {DateTime? now, bool calendar = true}) {
    const digits = {
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    text = text.replaceAllMapped(_cjkNumber, (match) {
      final value = match.group(1)!;
      if (!value.contains('十')) return '${digits[value] ?? value}';
      final parts = value.split('十');
      if (parts.length != 2) return value;
      return '${(parts.first.isEmpty ? 1 : digits[parts.first] ?? 0) * 10 + (parts.last.isEmpty ? 0 : digits[parts.last] ?? 0)}';
    });
    final local = (now ?? DateTime.now()).toLocal();
    final relative = _relativeDuration.firstMatch(text);
    if (relative != null) {
      // A number of minutes without a relative marker is a duration, not a date.
      final prefix = text.substring(0, relative.start).toLowerCase();
      final matched = relative.group(0)!.toLowerCase();
      if (prefix.endsWith('in ') ||
          matched.endsWith('后') ||
          matched.endsWith('後') ||
          matched.endsWith('later')) {
        final amount = int.parse(relative.group(1)!);
        if (amount == 0) return null;
        final hours = _hoursUnit.hasMatch(relative.group(2)!);
        return local.add(Duration(minutes: hours ? amount * 60 : amount));
      }
    }
    if (calendar) {
      final exact = _calendar(text, local);
      if (exact.matched) return exact.time;
    }
    final day = _dayMarker.firstMatch(text);
    if (day == null && !_periodOnlyMarker.hasMatch(text)) {
      return null;
    }
    final marker = day?.group(0)?.toLowerCase() ?? '今天';
    final offset = ['明天', '明早', '明日', 'tomorrow'].contains(marker)
        ? 1
        : marker == '后天'
        ? 2
        : 0;
    final tail = text.substring(day?.end ?? 0);
    final time = _timePattern.firstMatch(tail);
    // Also accept "tomorrow 9 am" without a colon.
    final simple = time == null ? _simpleAmPm.firstMatch(tail) : null;
    if (time == null && simple == null) return null;
    var hour = int.parse(time?.group(2) ?? simple!.group(1)!);
    final minuteText = time?.group(3) ?? time?.group(4);
    final minute = minuteText == '半'
        ? 30
        : int.tryParse((minuteText ?? '0').replaceAll('分', '')) ?? 0;
    final period = (time?.group(1) ?? time?.group(5) ?? simple?.group(2) ?? '')
        .toLowerCase();
    if (hour > 23 || minute > 59) return null;
    final evening = ['下午', '晚上', '午後', 'pm'].contains(period) || marker == '今晚';
    if (evening && hour < 12) hour += 12;
    if (['am', '上午', '早上', '早晨', '午前'].contains(period) && hour == 12) hour = 0;
    final value = DateTime(
      local.year,
      local.month,
      local.day + offset,
      hour,
      minute,
    );
    return value.isAfter(local) ? value : null;
  }

  static DateTime tonight(DateTime now) {
    final local = now.toLocal();
    final value = DateTime(local.year, local.month, local.day, 20);
    return value.isAfter(local)
        ? value
        : DateTime(local.year, local.month, local.day + 1, 20);
  }

  static ({bool matched, DateTime? time}) _calendar(String text, DateTime now) {
    if (_pastMarker.hasMatch(text) || _multiWeeklyPattern.hasMatch(text)) {
      return (matched: true, time: null);
    }
    final date = _explicitDate.firstMatch(text);
    if (date != null) {
      if (_timezoneSuffix.hasMatch(text)) {
        return (matched: true, time: null);
      }
      final y = int.parse(date.group(1)!),
          m = int.parse(date.group(2)!),
          d = int.parse(date.group(3)!);
      final tail = text.substring(date.end).replaceFirst(_leadingIsoT, '');
      final clock = _parse(
        '明天 $tail',
        now: DateTime(now.year, now.month, now.day),
        calendar: false,
      );
      if (clock == null) return (matched: true, time: null);
      final at = DateTime(y, m, d, clock.hour, clock.minute);
      return (
        matched: true,
        time:
            y >= 1900 &&
                y <= 2200 &&
                at.year == y &&
                at.month == m &&
                at.day == d &&
                at.hour == clock.hour &&
                at.minute == clock.minute &&
                at.isAfter(now)
            ? at
            : null,
      );
    }
    final mark = _cjkWeekday.firstMatch(text)?.group(1);
    int? weekday = const {
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '日': 7,
      '天': 7,
      '月': 1,
      '火': 2,
      '水': 3,
      '木': 4,
      '金': 5,
      '土': 6,
    }[mark];
    // Preserve original last-matching-weekday-index precedence across English names.
    for (final match in _englishWeekday.allMatches(text)) {
      final candidate = _englishWeekdayMap[match.group(1)!.toLowerCase()];
      if (candidate != null && (weekday == null || candidate > weekday)) {
        weekday = candidate;
      }
    }
    final business = _workdayPattern.hasMatch(text);
    final daily = _dailyPattern.hasMatch(text);
    if (weekday == null && !business && !daily) {
      return (matched: false, time: null);
    }
    final clock = _parse(
      '明天 $text',
      now: DateTime(now.year, now.month, now.day),
      calendar: false,
    );
    if (clock == null) return (matched: true, time: null);
    final next = _nextWeekPattern.hasMatch(text);
    final current = _thisWeekPattern.hasMatch(text);
    if (weekday != null && (next || current)) {
      final at = DateTime(
        now.year,
        now.month,
        now.day - now.weekday + weekday + (next ? 7 : 0),
        clock.hour,
        clock.minute,
      );
      return (
        matched: true,
        time:
            at.hour == clock.hour &&
                at.minute == clock.minute &&
                at.isAfter(now)
            ? at
            : null,
      );
    }
    for (var offset = 0; offset < 8; offset++) {
      final at = DateTime(
        now.year,
        now.month,
        now.day + offset,
        clock.hour,
        clock.minute,
      );
      if ((weekday == null || at.weekday == weekday) &&
          (!business || at.weekday <= 5) &&
          at.isAfter(now)) {
        return (
          matched: true,
          time: at.hour == clock.hour && at.minute == clock.minute ? at : null,
        );
      }
    }
    return (matched: true, time: null);
  }

  static DateTime tomorrowMorning(DateTime now) {
    final local = now.toLocal();
    return DateTime(local.year, local.month, local.day + 1, 9);
  }
}
