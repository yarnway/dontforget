/// Deliberately small offline grammar. Ambiguous or past dates stay unscheduled.
class QuickReminderParser {
  static DateTime? parse(String text, {DateTime? now}) {
    const digits = {'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3,
      '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9};
    text = text.replaceAllMapped(RegExp(r'([零〇一二两三四五六七八九十]{1,3})(?=分钟|小时|点|分|時|時間)'), (match) {
      final value = match.group(1)!;
      if (!value.contains('十')) return '${digits[value] ?? value}';
      final parts = value.split('十');
      if (parts.length != 2) return value;
      return '${(parts.first.isEmpty ? 1 : digits[parts.first] ?? 0) * 10 + (parts.last.isEmpty ? 0 : digits[parts.last] ?? 0)}';
    });
    final local = (now ?? DateTime.now()).toLocal();
    final relative = RegExp(
      r'(\d{1,4})\s*(分钟|小時|小时|minutes?|mins?|hours?|hrs?|分|時間)(?:后|後|\s+later)?',
      caseSensitive: false,
    ).firstMatch(text);
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
        final hours = RegExp(
          r'小时|小時|時間|hour|hr',
          caseSensitive: false,
        ).hasMatch(relative.group(2)!);
        return local.add(Duration(minutes: hours ? amount * 60 : amount));
      }
    }
    final day = RegExp(
      r'今天|明天|后天|今晚|明早|明日|今日|today|tomorrow',
      caseSensitive: false,
    ).firstMatch(text);
    if (day == null && !RegExp(r'上午|早上|早晨|下午|晚上|中午|午前|午後').hasMatch(text)) return null;
    final marker = day?.group(0)?.toLowerCase() ?? '今天';
    final offset = ['明天', '明早', '明日', 'tomorrow'].contains(marker)
        ? 1
        : marker == '后天'
        ? 2
        : 0;
    final tail = text.substring(day?.end ?? 0);
    final time = RegExp(
      r'(上午|早上|早晨|下午|晚上|中午|午前|午後|am|pm)?\s*(\d{1,2})(?::(\d{2})|[点時](半|\d{1,2}分?)?)\s*(am|pm)?',
      caseSensitive: false,
    ).firstMatch(tail);
    // Also accept "tomorrow 9 am" without a colon.
    final simple = time == null
        ? RegExp(
            r'\b(\d{1,2})\s*(am|pm)\b',
            caseSensitive: false,
          ).firstMatch(tail)
        : null;
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

  static DateTime tomorrowMorning(DateTime now) {
    final local = now.toLocal();
    return DateTime(local.year, local.month, local.day + 1, 9);
  }
}
