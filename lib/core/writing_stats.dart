/// 写作热力图：一年的格子、每格的状态、以及一行汇总。
///
/// 纯逻辑——没有 Flutter、没有日期格式化。这样"格子怎么排""哪天算写过""深浅
/// 怎么分档"全都能用普通 `test()` 量出来；界面那一层只负责画和点。
library;

import 'day.dart';
import 'models/diary_entry.dart';

/// 一天的写作情况，也就是热力图里的一格。
class DayWriting {
  const DayWriting({
    required this.date,
    required this.characters,
    required this.hasContent,
    this.mood,
    this.weather,
    this.tags = const <String>[],
    this.text = '',
  });

  final DateTime date;

  /// 正文字数。和状态栏那个「N 字」同一套算法（`body.runes.length`）。
  final int characters;

  /// 这一天算不算"写过"。定义来自 `DiaryEntry.isEmpty`（正文去掉空白、心情、
  /// 天气、标签**全都**为空才算空）——**不在这一层另写一套**。
  ///
  /// ⚠️ 侧栏那个「今天（已写）」徽标用的是**另一套**判断（`hasWrittenToday`，
  /// 看"有没有这个文件"）。一个空的 `.md`——手机同步过来的空文件就会这样，
  /// 见 `docs/手机写作.md`——会让两种定义给出**相反**的答案。热力图这里选
  /// "有内容"；要不要把徽标也统一过来是另一个决定（那会改动界面上已有的行为）。
  final bool hasContent;

  final String? mood;
  final String? weather;
  final List<String> tags;

  /// 正文**全文**（Markdown 标题符号逐行去掉），给日历的「当日详细」用。
  ///
  /// ⚠️ **不是** `DiaryEntry.preview`——那个按定义只有第一行（逐行找第一个非空行）。
  /// 详情面板要"尽量显示全部内容"，所以这里必须带整篇；放不下的部分由界面
  /// 按能放下的行数截断加省略号（见 `calendar_dialog.dart` 的 `_buildDayDetail`）。
  final String text;

  /// 深浅档位（0–4）。
  int get level => levelForCharacters(characters);

  /// 从一条日记生成一格。**日期要用格子自己的日期**（已经归一化过的），
  /// 不要用 `entry.date`——两边都必须过 `dateOnly`，否则会整天错位。
  factory DayWriting.fromEntry(DateTime date, DiaryEntry entry) => DayWriting(
        date: date,
        characters: entry.characterCount,
        // 复用模型层已有的定义，不要在这里再拼一遍"什么算写过"。
        hasContent: !entry.isEmpty,
        mood: entry.mood,
        weather: entry.weather,
        tags: entry.tags,
        text: displayTextOf(entry.body),
      );

  /// 没写过的那一天。**仍然是"一格"**，不是 null——null 的含义是
  /// "不属于当前范围的补位格"，两者混起来的话"没写"和"不适用"就分不清了。
  factory DayWriting.empty(DateTime date) =>
      DayWriting(date: date, characters: 0, hasContent: false);
}

/// 正文拿来做展示时的样子：**逐行去掉 Markdown 标题符号**，再去掉首尾空行。
///
/// 只做这两件事：正文是用户写的，不要顺手替他重排（缩进、空行、列表符号都留着）。
/// 去掉 `#` 是因为详情面板是"读"的地方，`## 今天的标题` 里的井号在那里只是噪音。
String displayTextOf(String body) => body
    .split('\n')
    .map((line) => line.replaceFirst(RegExp(r'^\s*#{1,6}\s*'), ''))
    .join('\n')
    .trim();

/// 字数 → 深浅档位（0–4）。
///
/// 阈值刻意只写在这一处，并且会显示在图例上——"多少字算深色"没有客观答案，
/// 但用户至少应该能看见程序用的是什么标准。
int levelForCharacters(int characters) {
  if (characters <= 0) return 0;
  if (characters < 100) return 1;
  if (characters < 300) return 2;
  if (characters < 700) return 3;
  return 4;
}

/// 一年的热力图。
class YearHeatmap {
  const YearHeatmap({
    required this.year,
    required this.columns,
    required this.writtenDays,
    required this.totalCharacters,
    required this.longestStreak,
  });

  final int year;

  /// 每一列是一周，周一到周日；不属于这一年的位置是 null。
  ///
  /// **周一开头**：和左侧列表里的 `weekdayShort` 保持一致。两处不一致的话，
  /// 看久了会觉得哪里不对，但说不出是哪。
  final List<List<DayWriting?>> columns;

  /// 有内容的天数。
  final int writtenDays;

  /// 全年总字数。
  final int totalCharacters;

  /// 最长连续写作天数。
  ///
  /// 定义：**连续的自然日**都"有内容"才算连上，中间空一天就断。
  final int longestStreak;

  /// 这一年一天都没写过。
  bool get isEmpty => writtenDays == 0;

  static YearHeatmap build({
    required int year,
    required List<DiaryEntry> entries,
  }) {
    // 先把这一年的条目按"当年第几天"归位。
    final byDay = <int, DiaryEntry>{};
    for (final entry in entries) {
      // 必须过 dateOnly：万一有带时分秒的日期混进来，不归一化会整天错位。
      final date = dateOnly(entry.date);
      if (date.year != year) continue;
      // 一天一个文件是数据格式的约定；真出现同一天两条（冲突文件），
      // 热力图不替用户挑，只记第一条。
      byDay.putIfAbsent(_dayOfYear(year, date), () => entry);
    }

    final daysInYear = _daysInYear(year);
    // 2026-01-01 是周四 → 第一列前面空 3 格（周一起算）。
    var filled = DateTime(year, 1, 1).weekday - 1;

    final columns = <List<DayWriting?>>[];
    var current = List<DayWriting?>.filled(7, null);

    // 逐日构造，**刻意不用 Duration 加法**：`add(Duration(days: 1))` 跨夏令时
    // 会跳天或重复，而这个项目的数据格式是带时区的，逻辑上不该假设没有夏令时。
    // `DateTime(y, m, d + 1)` 由 DateTime 自己归一化，永远走"下一个自然日"。
    var date = DateTime(year, 1, 1);
    for (var i = 0; i < daysInYear; i++) {
      final entry = byDay[_dayOfYear(year, date)];
      // **一年里的每一天都要有一格**，没写过的那天是"0 字的一格"，不是 null。
      // null 在界面里的含义是"不属于这一年的补位格"（年初年末凑满一周用），
      // 两者混起来的话空年份会整片空白，而"没写"和"不适用"也就分不清了。
      current[filled % 7] = entry == null
          ? DayWriting.empty(date)
          : DayWriting.fromEntry(date, entry);
      filled++;
      if (filled % 7 == 0) {
        columns.add(current);
        current = List<DayWriting?>.filled(7, null);
      }
      date = DateTime(year, date.month, date.day + 1);
    }
    if (filled % 7 != 0) columns.add(current);

    var writtenDays = 0;
    var totalCharacters = 0;
    var longestStreak = 0;
    var run = 0;
    for (final column in columns) {
      for (final day in column) {
        if (day != null && day.hasContent) {
          writtenDays++;
          totalCharacters += day.characters;
          run++;
          if (run > longestStreak) longestStreak = run;
        } else {
          run = 0;
        }
      }
    }

    return YearHeatmap(
      year: year,
      columns: columns,
      writtenDays: writtenDays,
      totalCharacters: totalCharacters,
      longestStreak: longestStreak,
    );
  }

  /// 每一列（周）里某月第一次出现的位置：`月 → 第几列`。界面拿它画月份刻度。
  Map<int, int> get monthStarts {
    final starts = <int, int>{};
    for (var index = 0; index < columns.length; index++) {
      for (final day in columns[index]) {
        if (day == null) continue;
        starts.putIfAbsent(day.date.month, () => index);
      }
    }
    return starts;
  }

  /// 公历年长。整数运算，不用两个 DateTime 相减——那又是一次 Duration。
  static int _daysInYear(int year) {
    final leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    return leap ? 366 : 365;
  }

  static int _daysInMonth(int year, int month) {
    if (month == 2) return _daysInYear(year) == 366 ? 29 : 28;
    const lengths = <int>[31, 0, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return lengths[month - 1];
  }

  /// 当年第几天（1 起）。
  static int _dayOfYear(int year, DateTime date) {
    var day = date.day;
    for (var month = 1; month < date.month; month++) {
      day += _daysInMonth(year, month);
    }
    return day;
  }
}

/// 一个月的格子：7 列（周一起）× **固定 6 行**。
///
/// 固定 6 行是有意的：月份本身是 4/5/6 行，行数一变对话框高度就跳，
/// 翻月份时上下的东西会跟着抖。
class MonthGrid {
  const MonthGrid({
    required this.year,
    required this.month,
    required this.weeks,
    required this.writtenDays,
    required this.totalCharacters,
  });

  final int year;
  final int month;

  /// 6 行 × 7 列，周一到周日；不属于这个月的位置是 null。
  final List<List<DayWriting?>> weeks;

  /// 这个月有内容的天数（只看这个月，不受相邻月份影响）。
  final int writtenDays;
  final int totalCharacters;

  bool get isEmpty => writtenDays == 0;

  static MonthGrid build({
    required int year,
    required int month,
    required List<DiaryEntry> entries,
  }) {
    final byDay = <int, DiaryEntry>{};
    for (final entry in entries) {
      final date = dateOnly(entry.date);
      if (date.year != year || date.month != month) continue;
      byDay.putIfAbsent(date.day, () => entry);
    }

    final daysInMonth = YearHeatmap._daysInMonth(year, month);
    // 当月 1 号是周几 → 第一行前面空几格（周一起算）
    var filled = DateTime(year, month, 1).weekday - 1;

    final weeks = <List<DayWriting?>>[];
    var week = List<DayWriting?>.filled(7, null);

    for (var dayOfMonth = 1; dayOfMonth <= daysInMonth; dayOfMonth++) {
      // 构造式算术，理由同 YearHeatmap：不用 Duration 加法
      final date = DateTime(year, month, dayOfMonth);
      final entry = byDay[dayOfMonth];
      week[filled % 7] = entry == null
          ? DayWriting.empty(date)
          : DayWriting.fromEntry(date, entry);
      filled++;
      if (filled % 7 == 0) {
        weeks.add(week);
        week = List<DayWriting?>.filled(7, null);
      }
    }
    if (filled % 7 != 0) weeks.add(week);

    // 补到固定 6 行，保证高度不跳
    while (weeks.length < 6) {
      weeks.add(List<DayWriting?>.filled(7, null));
    }

    var writtenDays = 0;
    var totalCharacters = 0;
    for (final row in weeks) {
      for (final day in row) {
        if (day == null || !day.hasContent) continue;
        writtenDays++;
        totalCharacters += day.characters;
      }
    }

    return MonthGrid(
      year: year,
      month: month,
      weeks: weeks,
      writtenDays: writtenDays,
      totalCharacters: totalCharacters,
    );
  }
}
