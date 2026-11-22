import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    show
        CupertinoLocalizationEn,
        CupertinoLocalizationJa,
        CupertinoLocalizationZh,
        MaterialLocalizationEn,
        MaterialLocalizationJa,
        MaterialLocalizationZh,
        WidgetsLocalizationEn,
        WidgetsLocalizationJa,
        WidgetsLocalizationZh;
import 'package:intl/date_symbol_data_custom.dart' as date_symbol_data_custom;
import 'package:intl/date_symbols.dart' as intl;
import 'package:intl/intl.dart' as intl;

const Set<String> _supportedLanguageCodes = <String>{'en', 'zh', 'ja'};

bool _dateIntlDataLoaded = false;

void _ensureDateIntlDataLoaded() {
  if (_dateIntlDataLoaded) return;
  _dateIntlDataLoaded = true;
  for (final code in _supportedLanguageCodes) {
    date_symbol_data_custom.initializeDateFormattingCustom(
      locale: code,
      patterns: _datePatterns[code],
      symbols: _dateSymbols[code],
    );
  }
}

String _resolveCode(Locale locale) {
  final code = locale.languageCode;
  return _supportedLanguageCodes.contains(code) ? code : 'en';
}

/// Three-locale (`en` / `zh` / `ja`) replacement for
/// `GlobalMaterialLocalizations.delegate` so release AOT builds tree-shake the
/// other 116 unused framework locale tables and 122 unused `DateSymbols`.
class AppMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const AppMaterialLocalizationsDelegate();

  static final Map<String, Future<MaterialLocalizations>> _cache =
      <String, Future<MaterialLocalizations>>{};

  @override
  bool isSupported(Locale locale) =>
      _supportedLanguageCodes.contains(locale.languageCode);

  @override
  Future<MaterialLocalizations> load(Locale locale) {
    final code = _resolveCode(locale);
    return _cache.putIfAbsent(code, () {
      _ensureDateIntlDataLoaded();
      final fullYearFormat = intl.DateFormat.y(code);
      final compactDateFormat = intl.DateFormat.yMd(code);
      final shortDateFormat = intl.DateFormat.yMMMd(code);
      final mediumDateFormat = intl.DateFormat.MMMEd(code);
      final longDateFormat = intl.DateFormat.yMMMMEEEEd(code);
      final yearMonthFormat = intl.DateFormat.yMMMM(code);
      final shortMonthDayFormat = intl.DateFormat.MMMd(code);
      final decimalFormat = intl.NumberFormat.decimalPattern(code);
      final twoDigitZeroPaddedFormat = intl.NumberFormat('00', code);

      final MaterialLocalizations instance = switch (code) {
        'zh' => MaterialLocalizationZh(
          fullYearFormat: fullYearFormat,
          compactDateFormat: compactDateFormat,
          shortDateFormat: shortDateFormat,
          mediumDateFormat: mediumDateFormat,
          longDateFormat: longDateFormat,
          yearMonthFormat: yearMonthFormat,
          shortMonthDayFormat: shortMonthDayFormat,
          decimalFormat: decimalFormat,
          twoDigitZeroPaddedFormat: twoDigitZeroPaddedFormat,
        ),
        'ja' => MaterialLocalizationJa(
          fullYearFormat: fullYearFormat,
          compactDateFormat: compactDateFormat,
          shortDateFormat: shortDateFormat,
          mediumDateFormat: mediumDateFormat,
          longDateFormat: longDateFormat,
          yearMonthFormat: yearMonthFormat,
          shortMonthDayFormat: shortMonthDayFormat,
          decimalFormat: decimalFormat,
          twoDigitZeroPaddedFormat: twoDigitZeroPaddedFormat,
        ),
        _ => MaterialLocalizationEn(
          fullYearFormat: fullYearFormat,
          compactDateFormat: compactDateFormat,
          shortDateFormat: shortDateFormat,
          mediumDateFormat: mediumDateFormat,
          longDateFormat: longDateFormat,
          yearMonthFormat: yearMonthFormat,
          shortMonthDayFormat: shortMonthDayFormat,
          decimalFormat: decimalFormat,
          twoDigitZeroPaddedFormat: twoDigitZeroPaddedFormat,
        ),
      };
      return SynchronousFuture<MaterialLocalizations>(instance);
    });
  }

  @override
  bool shouldReload(AppMaterialLocalizationsDelegate old) => false;
}

/// Three-locale (`en` / `zh` / `ja`) replacement for
/// `GlobalCupertinoLocalizations.delegate`.
class AppCupertinoLocalizationsDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const AppCupertinoLocalizationsDelegate();

  static final Map<String, Future<CupertinoLocalizations>> _cache =
      <String, Future<CupertinoLocalizations>>{};

  @override
  bool isSupported(Locale locale) =>
      _supportedLanguageCodes.contains(locale.languageCode);

  @override
  Future<CupertinoLocalizations> load(Locale locale) {
    final code = _resolveCode(locale);
    return _cache.putIfAbsent(code, () {
      _ensureDateIntlDataLoaded();
      final fullYearFormat = intl.DateFormat.y(code);
      final dayFormat = intl.DateFormat.d(code);
      final weekdayFormat = intl.DateFormat.E(code);
      final mediumDateFormat = intl.DateFormat.MMMEd(code);
      final singleDigitHourFormat = intl.DateFormat('HH', code);
      final singleDigitMinuteFormat = intl.DateFormat.m(code);
      final doubleDigitMinuteFormat = intl.DateFormat('mm', code);
      final singleDigitSecondFormat = intl.DateFormat.s(code);
      final decimalFormat = intl.NumberFormat.decimalPattern(code);

      final CupertinoLocalizations instance = switch (code) {
        'zh' => CupertinoLocalizationZh(
          fullYearFormat: fullYearFormat,
          dayFormat: dayFormat,
          weekdayFormat: weekdayFormat,
          mediumDateFormat: mediumDateFormat,
          singleDigitHourFormat: singleDigitHourFormat,
          singleDigitMinuteFormat: singleDigitMinuteFormat,
          doubleDigitMinuteFormat: doubleDigitMinuteFormat,
          singleDigitSecondFormat: singleDigitSecondFormat,
          decimalFormat: decimalFormat,
        ),
        'ja' => CupertinoLocalizationJa(
          fullYearFormat: fullYearFormat,
          dayFormat: dayFormat,
          weekdayFormat: weekdayFormat,
          mediumDateFormat: mediumDateFormat,
          singleDigitHourFormat: singleDigitHourFormat,
          singleDigitMinuteFormat: singleDigitMinuteFormat,
          doubleDigitMinuteFormat: doubleDigitMinuteFormat,
          singleDigitSecondFormat: singleDigitSecondFormat,
          decimalFormat: decimalFormat,
        ),
        _ => CupertinoLocalizationEn(
          fullYearFormat: fullYearFormat,
          dayFormat: dayFormat,
          weekdayFormat: weekdayFormat,
          mediumDateFormat: mediumDateFormat,
          singleDigitHourFormat: singleDigitHourFormat,
          singleDigitMinuteFormat: singleDigitMinuteFormat,
          doubleDigitMinuteFormat: doubleDigitMinuteFormat,
          singleDigitSecondFormat: singleDigitSecondFormat,
          decimalFormat: decimalFormat,
        ),
      };
      return SynchronousFuture<CupertinoLocalizations>(instance);
    });
  }

  @override
  bool shouldReload(AppCupertinoLocalizationsDelegate old) => false;
}

/// Three-locale (`en` / `zh` / `ja`) replacement for
/// `GlobalWidgetsLocalizations.delegate`.
class AppWidgetsLocalizationsDelegate
    extends LocalizationsDelegate<WidgetsLocalizations> {
  const AppWidgetsLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      _supportedLanguageCodes.contains(locale.languageCode);

  @override
  Future<WidgetsLocalizations> load(Locale locale) {
    final WidgetsLocalizations instance = switch (_resolveCode(locale)) {
      'zh' => const WidgetsLocalizationZh(),
      'ja' => const WidgetsLocalizationJa(),
      _ => const WidgetsLocalizationEn(),
    };
    return SynchronousFuture<WidgetsLocalizations>(instance);
  }

  @override
  bool shouldReload(AppWidgetsLocalizationsDelegate old) => false;
}

final Map<String, intl.DateSymbols> _dateSymbols = <String, intl.DateSymbols>{
  'en': intl.DateSymbols(
    NAME: 'en',
    ERAS: const <String>['BC', 'AD'],
    ERANAMES: const <String>['Before Christ', 'Anno Domini'],
    NARROWMONTHS: const <String>[
      'J',
      'F',
      'M',
      'A',
      'M',
      'J',
      'J',
      'A',
      'S',
      'O',
      'N',
      'D',
    ],
    STANDALONENARROWMONTHS: const <String>[
      'J',
      'F',
      'M',
      'A',
      'M',
      'J',
      'J',
      'A',
      'S',
      'O',
      'N',
      'D',
    ],
    MONTHS: const <String>[
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ],
    STANDALONEMONTHS: const <String>[
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ],
    SHORTMONTHS: const <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ],
    STANDALONESHORTMONTHS: const <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ],
    WEEKDAYS: const <String>[
      'Sunday',
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ],
    STANDALONEWEEKDAYS: const <String>[
      'Sunday',
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ],
    SHORTWEEKDAYS: const <String>[
      'Sun',
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
    ],
    STANDALONESHORTWEEKDAYS: const <String>[
      'Sun',
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
    ],
    NARROWWEEKDAYS: const <String>['S', 'M', 'T', 'W', 'T', 'F', 'S'],
    STANDALONENARROWWEEKDAYS: const <String>['S', 'M', 'T', 'W', 'T', 'F', 'S'],
    SHORTQUARTERS: const <String>['Q1', 'Q2', 'Q3', 'Q4'],
    QUARTERS: const <String>[
      '1st quarter',
      '2nd quarter',
      '3rd quarter',
      '4th quarter',
    ],
    AMPMS: const <String>['AM', 'PM'],
    DATEFORMATS: const <String>[
      'EEEE, MMMM d, y',
      'MMMM d, y',
      'MMM d, y',
      'M/d/yy',
    ],
    TIMEFORMATS: const <String>[
      'h:mm:ss\u202Fa zzzz',
      'h:mm:ss\u202Fa z',
      'h:mm:ss\u202Fa',
      'h:mm\u202Fa',
    ],
    FIRSTDAYOFWEEK: 6,
    WEEKENDRANGE: const <int>[5, 6],
    FIRSTWEEKCUTOFFDAY: 5,
    DATETIMEFORMATS: const <String>[
      '{1}, {0}',
      '{1}, {0}',
      '{1}, {0}',
      '{1}, {0}',
    ],
  ),
  'zh': intl.DateSymbols(
    NAME: 'zh',
    ERAS: const <String>['公元前', '公元'],
    ERANAMES: const <String>['公元前', '公元'],
    NARROWMONTHS: const <String>[
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '10',
      '11',
      '12',
    ],
    STANDALONENARROWMONTHS: const <String>[
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '10',
      '11',
      '12',
    ],
    MONTHS: const <String>[
      '一月',
      '二月',
      '三月',
      '四月',
      '五月',
      '六月',
      '七月',
      '八月',
      '九月',
      '十月',
      '十一月',
      '十二月',
    ],
    STANDALONEMONTHS: const <String>[
      '一月',
      '二月',
      '三月',
      '四月',
      '五月',
      '六月',
      '七月',
      '八月',
      '九月',
      '十月',
      '十一月',
      '十二月',
    ],
    SHORTMONTHS: const <String>[
      '1月',
      '2月',
      '3月',
      '4月',
      '5月',
      '6月',
      '7月',
      '8月',
      '9月',
      '10月',
      '11月',
      '12月',
    ],
    STANDALONESHORTMONTHS: const <String>[
      '1月',
      '2月',
      '3月',
      '4月',
      '5月',
      '6月',
      '7月',
      '8月',
      '9月',
      '10月',
      '11月',
      '12月',
    ],
    WEEKDAYS: const <String>['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'],
    STANDALONEWEEKDAYS: const <String>[
      '星期日',
      '星期一',
      '星期二',
      '星期三',
      '星期四',
      '星期五',
      '星期六',
    ],
    SHORTWEEKDAYS: const <String>['周日', '周一', '周二', '周三', '周四', '周五', '周六'],
    STANDALONESHORTWEEKDAYS: const <String>[
      '周日',
      '周一',
      '周二',
      '周三',
      '周四',
      '周五',
      '周六',
    ],
    NARROWWEEKDAYS: const <String>['日', '一', '二', '三', '四', '五', '六'],
    STANDALONENARROWWEEKDAYS: const <String>['日', '一', '二', '三', '四', '五', '六'],
    SHORTQUARTERS: const <String>['1季度', '2季度', '3季度', '4季度'],
    QUARTERS: const <String>['第一季度', '第二季度', '第三季度', '第四季度'],
    AMPMS: const <String>['上午', '下午'],
    DATEFORMATS: const <String>['y年M月d日EEEE', 'y年M月d日', 'y年M月d日', 'y/M/d'],
    TIMEFORMATS: const <String>['zzzz HH:mm:ss', 'z HH:mm:ss', 'HH:mm:ss', 'HH:mm'],
    FIRSTDAYOFWEEK: 0,
    WEEKENDRANGE: const <int>[5, 6],
    FIRSTWEEKCUTOFFDAY: 6,
    DATETIMEFORMATS: const <String>[
      '{1} {0}',
      '{1} {0}',
      '{1} {0}',
      '{1} {0}',
    ],
  ),
  'ja': intl.DateSymbols(
    NAME: 'ja',
    ERAS: const <String>['紀元前', '西暦'],
    ERANAMES: const <String>['紀元前', '西暦'],
    NARROWMONTHS: const <String>[
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '10',
      '11',
      '12',
    ],
    STANDALONENARROWMONTHS: const <String>[
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '10',
      '11',
      '12',
    ],
    MONTHS: const <String>[
      '1月',
      '2月',
      '3月',
      '4月',
      '5月',
      '6月',
      '7月',
      '8月',
      '9月',
      '10月',
      '11月',
      '12月',
    ],
    STANDALONEMONTHS: const <String>[
      '1月',
      '2月',
      '3月',
      '4月',
      '5月',
      '6月',
      '7月',
      '8月',
      '9月',
      '10月',
      '11月',
      '12月',
    ],
    SHORTMONTHS: const <String>[
      '1月',
      '2月',
      '3月',
      '4月',
      '5月',
      '6月',
      '7月',
      '8月',
      '9月',
      '10月',
      '11月',
      '12月',
    ],
    STANDALONESHORTMONTHS: const <String>[
      '1月',
      '2月',
      '3月',
      '4月',
      '5月',
      '6月',
      '7月',
      '8月',
      '9月',
      '10月',
      '11月',
      '12月',
    ],
    WEEKDAYS: const <String>['日曜日', '月曜日', '火曜日', '水曜日', '木曜日', '金曜日', '土曜日'],
    STANDALONEWEEKDAYS: const <String>[
      '日曜日',
      '月曜日',
      '火曜日',
      '水曜日',
      '木曜日',
      '金曜日',
      '土曜日',
    ],
    SHORTWEEKDAYS: const <String>['日', '月', '火', '水', '木', '金', '土'],
    STANDALONESHORTWEEKDAYS: const <String>['日', '月', '火', '水', '木', '金', '土'],
    NARROWWEEKDAYS: const <String>['日', '月', '火', '水', '木', '金', '土'],
    STANDALONENARROWWEEKDAYS: const <String>['日', '月', '火', '水', '木', '金', '土'],
    SHORTQUARTERS: const <String>['Q1', 'Q2', 'Q3', 'Q4'],
    QUARTERS: const <String>['第1四半期', '第2四半期', '第3四半期', '第4四半期'],
    AMPMS: const <String>['午前', '午後'],
    DATEFORMATS: const <String>['y年M月d日EEEE', 'y年M月d日', 'y/MM/dd', 'y/MM/dd'],
    TIMEFORMATS: const <String>[
      'H時mm分ss秒 zzzz',
      'H:mm:ss z',
      'H:mm:ss',
      'H:mm',
    ],
    FIRSTDAYOFWEEK: 6,
    WEEKENDRANGE: const <int>[5, 6],
    FIRSTWEEKCUTOFFDAY: 5,
    DATETIMEFORMATS: const <String>[
      '{1} {0}',
      '{1} {0}',
      '{1} {0}',
      '{1} {0}',
    ],
  ),
};

const Map<String, Map<String, String>> _datePatterns =
    <String, Map<String, String>>{
      'en': <String, String>{
        'd': 'd',
        'E': 'ccc',
        'EEEE': 'cccc',
        'LLL': 'LLL',
        'LLLL': 'LLLL',
        'M': 'L',
        'Md': 'M/d',
        'MEd': 'EEE, M/d',
        'MMM': 'LLL',
        'MMMd': 'MMM d',
        'MMMEd': 'EEE, MMM d',
        'MMMM': 'LLLL',
        'MMMMd': 'MMMM d',
        'MMMMEEEEd': 'EEEE, MMMM d',
        'QQQ': 'QQQ',
        'QQQQ': 'QQQQ',
        'y': 'y',
        'yM': 'M/y',
        'yMd': 'M/d/y',
        'yMEd': 'EEE, M/d/y',
        'yMMM': 'MMM y',
        'yMMMd': 'MMM d, y',
        'yMMMEd': 'EEE, MMM d, y',
        'yMMMM': 'MMMM y',
        'yMMMMd': 'MMMM d, y',
        'yMMMMEEEEd': 'EEEE, MMMM d, y',
        'yQQQ': 'QQQ y',
        'yQQQQ': 'QQQQ y',
        'H': 'HH',
        'Hm': 'HH:mm',
        'Hms': 'HH:mm:ss',
        'j': 'h\u202Fa',
        'jm': 'h:mm\u202Fa',
        'jms': 'h:mm:ss\u202Fa',
        'jmv': 'h:mm\u202Fa v',
        'jmz': 'h:mm\u202Fa z',
        'jz': 'h\u202Fa z',
        'm': 'm',
        'ms': 'mm:ss',
        's': 's',
        'v': 'v',
        'z': 'z',
        'zzzz': 'zzzz',
        'ZZZZ': 'ZZZZ',
      },
      'zh': <String, String>{
        'd': 'd日',
        'E': 'ccc',
        'EEEE': 'cccc',
        'LLL': 'LLL',
        'LLLL': 'LLLL',
        'M': 'M月',
        'Md': 'M/d',
        'MEd': 'M/dEEE',
        'MMM': 'LLL',
        'MMMd': 'M月d日',
        'MMMEd': 'M月d日EEE',
        'MMMM': 'LLLL',
        'MMMMd': 'M月d日',
        'MMMMEEEEd': 'M月d日EEEE',
        'QQQ': 'QQQ',
        'QQQQ': 'QQQQ',
        'y': 'y年',
        'yM': 'y/M',
        'yMd': 'y/M/d',
        'yMEd': 'y/M/dEEE',
        'yMMM': 'y年M月',
        'yMMMd': 'y年M月d日',
        'yMMMEd': 'y年M月d日EEE',
        'yMMMM': 'y年M月',
        'yMMMMd': 'y年M月d日',
        'yMMMMEEEEd': 'y年M月d日EEEE',
        'yQQQ': 'y年第Q季度',
        'yQQQQ': 'y年第Q季度',
        'H': 'H时',
        'Hm': 'HH:mm',
        'Hms': 'HH:mm:ss',
        'j': 'H时',
        'jm': 'HH:mm',
        'jms': 'HH:mm:ss',
        'jmv': 'v HH:mm',
        'jmz': 'z HH:mm',
        'jz': 'zH时',
        'm': 'm',
        'ms': 'mm:ss',
        's': 's',
        'v': 'v',
        'z': 'z',
        'zzzz': 'zzzz',
        'ZZZZ': 'ZZZZ',
      },
      'ja': <String, String>{
        'd': 'd日',
        'E': 'ccc',
        'EEEE': 'cccc',
        'LLL': 'M月',
        'LLLL': 'M月',
        'M': 'M月',
        'Md': 'M/d',
        'MEd': 'M/d(EEE)',
        'MMM': 'M月',
        'MMMd': 'M月d日',
        'MMMEd': 'M月d日(EEE)',
        'MMMM': 'M月',
        'MMMMd': 'M月d日',
        'MMMMEEEEd': 'M月d日EEEE',
        'QQQ': 'QQQ',
        'QQQQ': 'QQQQ',
        'y': 'y年',
        'yM': 'y/M',
        'yMd': 'y/M/d',
        'yMEd': 'y/M/d(EEE)',
        'yMMM': 'y年M月',
        'yMMMd': 'y年M月d日',
        'yMMMEd': 'y年M月d日(EEE)',
        'yMMMM': 'y年M月',
        'yMMMMd': 'y年M月d日',
        'yMMMMEEEEd': 'y年M月d日EEEE',
        'yQQQ': 'y/QQQ',
        'yQQQQ': 'y年QQQQ',
        'H': 'H時',
        'Hm': 'H:mm',
        'Hms': 'H:mm:ss',
        'j': 'H時',
        'jm': 'H:mm',
        'jms': 'H:mm:ss',
        'jmv': 'H:mm v',
        'jmz': 'H:mm z',
        'jz': 'H時 z',
        'm': 'm',
        'ms': 'mm:ss',
        's': 's',
        'v': 'v',
        'z': 'z',
        'zzzz': 'zzzz',
        'ZZZZ': 'ZZZZ',
      },
    };
