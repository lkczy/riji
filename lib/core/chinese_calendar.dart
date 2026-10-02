import 'chinese_calendar_data.dart';
import 'day.dart';

/// 农历日期。
class LunarDate {
  const LunarDate({
    required this.year,
    required this.month,
    required this.day,
    required this.isLeapMonth,
  });

  final int year;

  /// 1–12。
  final int month;

  /// 1–30。
  final int day;

  final bool isLeapMonth;

  static const List<String> _monthNames = <String>[
    '正月', '二月', '三月', '四月', '五月', '六月',
    '七月', '八月', '九月', '十月', '冬月', '腊月',
  ];

  /// 中文习惯的日名：初一到初十、十一到十九、二十、廿一到廿九、三十。
  static const List<String> _dayNames = <String>[
    '初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十',
    '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
    '廿一', '廿二', '廿三', '廿四', '廿五', '廿六', '廿七', '廿八', '廿九', '三十',
  ];

  String get monthName => _monthNames[month - 1];

  String get dayName => _dayNames[day - 1];

  /// 例如 `正月初一`、`闰六月十三`。
  String get text => '${isLeapMonth ? '闰' : ''}$monthName$dayName';

  @override
  String toString() => 'LunarDate($year, $text)';
}

/// 某一天的附加信息：农历、节气、节日。
///
/// 阳历节日和阴历节日**分开存**，因为它们在界面上要显示在两个不同的位置：
/// 阳历节日跟在阳历日期后面（第一行），阴历节日跟在农历日期前面（第二行）。
/// 两者可能撞在同一天（比如春节正好是 2 月 14 日），所以不能合并成一个字段。
class DayAnnotation {
  const DayAnnotation({
    this.lunar,
    this.solarTerm,
    this.solarFestival,
    this.lunarFestival,
  });

  final LunarDate? lunar;

  /// 二十四节气名，例如 `立春`。只有节气当天才有值。
  final String? solarTerm;

  /// 阳历节日，例如 `国庆节`。
  final String? solarFestival;

  /// 阴历节日，例如 `春节`。
  final String? lunarFestival;

  /// 第二行（农历那一行）要显示的文本：`阴历节日 · 农历 · 节气`。
  String get lunarLine => <String>[
        ?lunarFestival,
        ?lunar?.text,
        ?solarTerm,
      ].join(' · ');

  /// 第二行有没有东西可显示。没有就不占那一行的高度。
  bool get hasLunarLine =>
      lunarFestival != null || lunar != null || solarTerm != null;

  /// 这一天有没有任何值得高亮的信息。
  bool get hasHighlight =>
      solarFestival != null || lunarFestival != null || solarTerm != null;

  /// 整个没有任何信息（超出农历支持范围、又没有公历节日）。
  bool get isEmpty => !hasLunarLine && solarFestival == null;
}

/// 农历、节气、节日。
///
/// **为什么是查表而不是推算**：农历要算朔望月，节气要算太阳黄经，两者都是
/// 天文推算。用低精度公式在个别年份会差一天，而日记里显示错日期比不显示更糟。
/// 所以数据由 `tool/generate_chinese_calendar.py` 生成，并且经过交叉验证：
/// 1950–2100 共 55152 天，和 .NET 的 ChineseLunisolarCalendar 逐日对拍，
/// 149 年完全一致；只有 2089 和 2097 各一处月首边界有分歧，而那一处
/// 另有三个独立实现（lunar_python / cnlunar / zhdate）与 .NET 意见相反，
/// 所以采用了多数派的取值。
///
/// 支持范围：[firstSupportedYear]–[lastSupportedYear]。范围外返回 null，
/// 界面显示为空——宁可什么都不显示，也不显示错的。
class ChineseCalendar {
  const ChineseCalendar._();

  static const int firstSupportedYear = 1950;
  static const int lastSupportedYear = 2100;

  /// 24 个节气名，顺序与数据表一致。
  static const List<String> solarTermNames = <String>[
    '小寒', '大寒', '立春', '雨水', '惊蛰', '春分',
    '清明', '谷雨', '立夏', '小满', '芒种', '夏至',
    '小暑', '大暑', '立秋', '处暑', '白露', '秋分',
    '寒露', '霜降', '立冬', '小雪', '大雪', '冬至',
  ];

  /// 每个节气固定的公历月份（小寒大寒在 1 月，立春雨水在 2 月……）。
  /// 数据表只存"日"，月份就是这个顺序决定的，测试也用它来校验。
  static const List<int> solarTermMonths = <int>[
    1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12,
  ];

  /// 公历节日。`月-日` 为键。
  static const Map<String, String> _solarFestivals = <String, String>{
    '01-01': '元旦',
    '02-14': '情人节',
    '03-08': '妇女节',
    '03-12': '植树节',
    '04-01': '愚人节',
    '05-01': '劳动节',
    '05-04': '青年节',
    '06-01': '儿童节',
    '07-01': '建党节',
    '08-01': '建军节',
    '09-10': '教师节',
    '10-01': '国庆节',
    '12-24': '平安夜',
    '12-25': '圣诞节',
    '12-31': '跨年夜',
  };

  /// 农历节日。`月-日` 为键，闰月不算（闰五月初五不是端午）。
  static const Map<String, String> _lunarFestivals = <String, String>{
    '1-1': '春节',
    '1-15': '元宵节',
    '5-5': '端午节',
    '7-7': '七夕',
    '8-15': '中秋节',
    '9-9': '重阳节',
    '12-8': '腊八节',
  };

  static DayAnnotation annotate(DateTime date) {
    final day = dateOnly(date);
    final lunar = lunarFor(day);
    return DayAnnotation(
      lunar: lunar,
      solarTerm: solarTermFor(day),
      solarFestival: _solarFestivalFor(day),
      lunarFestival:
          lunar == null ? null : _lunarFestivalFor(day, lunar),
    );
  }

  // ---------------------------------------------------------------------------
  // 农历
  // ---------------------------------------------------------------------------

  static LunarDate? lunarFor(DateTime date) {
    final target = dateOnly(date);
    // 表里虽然多存了前后各一个农历年（用来夹出某一天属于哪个农历年），
    // 但对外声明的支持范围就是 [firstSupportedYear]–[lastSupportedYear]。
    // 说了支持到哪一年，就只对哪些年负责，不越界给答案。
    if (target.year < firstSupportedYear || target.year > lastSupportedYear) {
      return null;
    }

    // 正月初一落在一月或二月，所以农历年只可能是 target.year 或它前一年。
    // 两个都试一下，比推算更省事也更不容易错。
    for (final candidate in <int>[target.year, target.year - 1]) {
      final start = _lunarNewYear(candidate);
      final end = _lunarNewYear(candidate + 1);
      if (start == null || end == null) continue;
      if (!target.isBefore(start) && target.isBefore(end)) {
        return _decode(candidate, start, target);
      }
    }
    return null;
  }

  static DateTime? _lunarNewYear(int lunarYear) {
    final packed = kLunarYearTable[lunarYear];
    if (packed == null) return null;
    final day = packed & 0x1F;
    final isFebruary = (packed >> 5) & 1 == 1;
    return DateTime(lunarYear, isFebruary ? 2 : 1, day);
  }

  static LunarDate? _decode(int lunarYear, DateTime start, DateTime target) {
    final packed = kLunarYearTable[lunarYear];
    if (packed == null) return null;

    final leapMonth = (packed >> 6) & 0xF;
    var remaining = target.difference(start).inDays;

    for (var index = 0; index < 13; index++) {
      final month = _monthAt(index, leapMonth);
      if (month == null) return null;

      final length = ((packed >> (10 + index)) & 1) == 1 ? 30 : 29;
      if (remaining < length) {
        return LunarDate(
          year: lunarYear,
          month: month.$1,
          day: remaining + 1,
          isLeapMonth: month.$2,
        );
      }
      remaining -= length;
    }
    return null;
  }

  /// 第 [index] 个农历月在「第几个月、是不是闰月」。
  ///
  /// 闰月排在它的本位月**之后**：闰六月在六月后面，所以顺序是
  /// 正月…六月、闰六月、七月…十二月。
  static (int, bool)? _monthAt(int index, int leapMonth) {
    if (leapMonth == 0) {
      return index < 12 ? (index + 1, false) : null;
    }
    if (index < leapMonth) return (index + 1, false);
    if (index == leapMonth) return (leapMonth, true);
    return index <= 12 ? (index, false) : null;
  }

  // ---------------------------------------------------------------------------
  // 节气
  // ---------------------------------------------------------------------------

  /// 每个月的两个节气在 [solarTermNames] 里的起始下标是 `(月-1)*2`：
  /// 1 月是小寒/大寒，2 月是立春/雨水……12 月是大雪/冬至。
  static String? solarTermFor(DateTime date) {
    if (date.year < firstSupportedYear || date.year > lastSupportedYear) {
      return null;
    }
    final days = kSolarTermDays[date.year];
    if (days == null) return null;

    final firstIndex = (date.month - 1) * 2;
    for (var index = firstIndex; index <= firstIndex + 1; index++) {
      final day = int.parse(days.substring(index * 2, index * 2 + 2));
      if (day == date.day) return solarTermNames[index];
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 节日
  // ---------------------------------------------------------------------------

  static String? _solarFestivalFor(DateTime date) {
    final key = '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final fixed = _solarFestivals[key];
    if (fixed != null) return fixed;

    // 按星期算的那几个
    if (date.month == 5 && _isNthWeekday(date, weekday: DateTime.sunday, nth: 2)) {
      return '母亲节';
    }
    if (date.month == 6 && _isNthWeekday(date, weekday: DateTime.sunday, nth: 3)) {
      return '父亲节';
    }
    if (date.month == 11 &&
        _isNthWeekday(date, weekday: DateTime.thursday, nth: 4)) {
      return '感恩节';
    }
    return null;
  }

  static bool _isNthWeekday(
    DateTime date, {
    required int weekday,
    required int nth,
  }) {
    if (date.weekday != weekday) return false;
    return ((date.day - 1) ~/ 7) + 1 == nth;
  }

  static String? _lunarFestivalFor(DateTime date, LunarDate lunar) {
    if (!lunar.isLeapMonth) {
      final named = _lunarFestivals['${lunar.month}-${lunar.day}'];
      if (named != null) return named;
    }

    // 除夕：第二天就是正月初一。腊月有时 29 天有时 30 天，所以
    // 不能写死成「腊月三十」。
    final tomorrow = lunarFor(DateTime(date.year, date.month, date.day + 1));
    if (tomorrow != null && tomorrow.month == 1 && tomorrow.day == 1) {
      return '除夕';
    }
    return null;
  }
}
