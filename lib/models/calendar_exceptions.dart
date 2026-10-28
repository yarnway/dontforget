/// Explicit calendar dates, independent of weekdays and elapsed 24-hour days.
class CalendarExceptions {
  const CalendarExceptions({this.skip = const [], this.add = const []});
  final List<String> skip, add;
  static const maxDates = 366;
  bool get isEmpty => skip.isEmpty && add.isEmpty;
  static String key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static DateTime day(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const FormatException('Use YYYY-MM-DD');
    }
    final date = DateTime.tryParse('${value}T00:00:00Z');
    if (date == null ||
        date.year < 1900 ||
        date.year > 2200 ||
        key(date) != value) {
      throw const FormatException('Invalid exception date');
    }
    return date;
  }

  factory CalendarExceptions.fromJson(dynamic value) {
    if (value == null) return const CalendarExceptions();
    if (value is! Map || value.keys.any((k) => k != 'skip' && k != 'add')) {
      throw const FormatException('Invalid date exceptions');
    }
    List<String> dates(String field) {
      final raw = value[field] ?? [];
      if (raw is! List ||
          raw.length > maxDates ||
          raw.any((e) => e is! String)) {
        throw const FormatException('Too many exception dates');
      }
      final result = List<String>.from(raw);
      for (final date in result) {
        day(date);
      }
      if (result.toSet().length != result.length) {
        throw const FormatException('Duplicate exception date');
      }
      return List.unmodifiable(result..sort());
    }

    final skip = dates('skip'), add = dates('add');
    if (skip.toSet().intersection(add.toSet()).isNotEmpty) {
      throw const FormatException('Conflicting exception dates');
    }
    return CalendarExceptions(skip: skip, add: add);
  }
  Map<String, dynamic> toJson() => {'skip': skip, 'add': add};
  bool excludes(DateTime date) => skip.contains(key(date));
  bool includes(DateTime date) => add.contains(key(date));
  bool permits(DateTime date, List<int> weekdays) =>
      !excludes(date) && (includes(date) || weekdays.contains(date.weekday));
  CalendarExceptions shift(int days) => CalendarExceptions.fromJson({
    'skip': [for (final d in skip) key(day(d).add(Duration(days: days)))],
    'add': [for (final d in add) key(day(d).add(Duration(days: days)))],
  });
}
