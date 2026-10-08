import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/day.dart';
import 'package:riji/core/models/diary_entry.dart';
import 'package:riji/core/writing_stats.dart';

/// 热力图的格子怎么排、哪天算"写过"、深浅怎么分档。
///
/// 这一层值得单独测：它错起来是**静默**的——格子整体错一天、闰年二月少一格、
/// 连续天数多算一天，界面上都只是"看起来怪"，不会报任何错。
void main() {
  DiaryEntry entry(
    DateTime date, {
    String body = '',
    String? mood,
    String? weather,
    List<String> tags = const <String>[],
  }) =>
      DiaryEntry.create(
        date: date,
        device: 'test',
        body: body,
        mood: mood,
        weather: weather,
        tags: tags,
      );

  YearHeatmap build(int year, List<DiaryEntry> entries) =>
      YearHeatmap.build(year: year, entries: entries);

  /// 把格子摊平成一串（含 null），便于按"第几天"断言。
  List<DayWriting?> flat(YearHeatmap heatmap) =>
      <DayWriting?>[for (final column in heatmap.columns) ...column];

  /// 取某一天的格子。一年里的每一天都有一格，所以这里必然找得到。
  DayWriting dayAt(YearHeatmap heatmap, DateTime date) =>
      flat(heatmap).whereType<DayWriting>().firstWhere(
            (day) => isSameDay(day.date, date),
          );

  group('深浅分档', () {
    test('阈值是 0 / 100 / 300 / 700', () {
      expect(levelForCharacters(0), 0);
      expect(levelForCharacters(1), 1);
      expect(levelForCharacters(99), 1);
      expect(levelForCharacters(100), 2);
      expect(levelForCharacters(299), 2);
      expect(levelForCharacters(300), 3);
      expect(levelForCharacters(699), 3);
      expect(levelForCharacters(700), 4);
      expect(levelForCharacters(100000), 4);
    });

    test('负数字数不会越界', () {
      expect(levelForCharacters(-5), 0);
    });
  });

  group('格子怎么排', () {
    test('2026-01-01 是周四，所以第一列前面空三格', () {
      // 这条同时守着"周一起算"这个决定：和左侧列表的 weekdayShort 一致
      final heatmap = build(2026, <DiaryEntry>[]);
      final first = heatmap.columns.first;

      expect(first.length, 7, reason: '每列必须是整整一周');
      expect(first[0], isNull);
      expect(first[1], isNull);
      expect(first[2], isNull);
      expect(first[3]!.date, DateTime(2026, 1, 1));
      expect(first[4]!.date, DateTime(2026, 1, 2));
    });

    test('2024-01-01 是周一，第一列不空格', () {
      final heatmap = build(2024, <DiaryEntry>[]);
      expect(heatmap.columns.first[0]!.date, DateTime(2024, 1, 1));
    });

    test('每一列都是 7 格', () {
      for (final year in <int>[2024, 2025, 2026, 2027]) {
        final heatmap = build(year, <DiaryEntry>[]);
        for (final column in heatmap.columns) {
          expect(column.length, 7, reason: '$year 年有一列不是 7 格');
        }
      }
    });

    test('一年里的每一天出现且只出现一次，顺序是递增的', () {
      for (final year in <int>[2024, 2025, 2026, 2027]) {
        final days = flat(build(year, <DiaryEntry>[]))
            .whereType<DayWriting>()
            .map((day) => day.date)
            .toList();

        final expected = year == 2024 || year == 2028 ? 366 : 365;
        expect(days.length, expected, reason: '$year 年的格子数不对');
        expect(days.first, DateTime(year, 1, 1));
        expect(days.last, DateTime(year, 12, 31));

        for (var i = 1; i < days.length; i++) {
          expect(days[i].isAfter(days[i - 1]), isTrue,
              reason: '$year 年的格子顺序乱了：${days[i - 1]} → ${days[i]}');
        }
      }
    });

    test('闰年的 2 月 29 日在格子里', () {
      final days = flat(build(2024, <DiaryEntry>[]))
          .whereType<DayWriting>()
          .map((day) => day.date);
      expect(days.contains(DateTime(2024, 2, 29)), isTrue);
    });

    test('别的年份的条目不会掉进这一年', () {
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2025, 12, 31), body: '去年最后一天'),
        entry(DateTime(2027, 1, 1), body: '明年第一天'),
      ]);

      expect(heatmap.writtenDays, 0);
      expect(flat(heatmap).whereType<DayWriting>().any((d) => d.hasContent),
          isFalse);
      // 隔壁那两天不能"渗"进来
      expect(dayAt(heatmap, DateTime(2026, 1, 1)).hasContent, isFalse);
      expect(dayAt(heatmap, DateTime(2026, 12, 31)).hasContent, isFalse);
    });

    test('带时分秒的日期会被归一化，不会整天错位', () {
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 3, 14, 23, 59, 59), body: '深夜写的'),
      ]);
      final day = dayAt(heatmap, DateTime(2026, 3, 14));
      expect(day.hasContent, isTrue);
      // 隔壁两天不该被带上
      expect(dayAt(heatmap, DateTime(2026, 3, 13)).hasContent, isFalse);
      expect(dayAt(heatmap, DateTime(2026, 3, 15)).hasContent, isFalse);
    });

    test('月份刻度落在每个月第一次出现的那一列', () {
      final heatmap = build(2026, <DiaryEntry>[]);
      final starts = heatmap.monthStarts;

      expect(starts.keys.toList(), List<int>.generate(12, (i) => i + 1));
      expect(starts[1], 0);
      // 列号随月份单调不减
      for (var month = 2; month <= 12; month++) {
        expect(starts[month]! >= starts[month - 1]!, isTrue);
      }
    });
  });

  group('哪天算"写过"', () {
    test('只有正文算', () {
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 1, 5), body: '写了一句'),
      ]);
      expect(heatmap.writtenDays, 1);
    });

    test('正文只有空白、但点了心情，也算写过', () {
      // 定义来自 DiaryEntry.isEmpty：只要有一项非空就不是空条目
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 1, 5), body: '   \n  ', mood: '平静'),
      ]);
      expect(heatmap.writtenDays, 1);
    });

    test('只有标签也算写过', () {
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 1, 5), tags: <String>['阅读']),
      ]);
      expect(heatmap.writtenDays, 1);
    });

    test('空的条目不算写过（手机同步过来的空文件就是这样）', () {
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 1, 5), body: '   \n'),
        entry(DateTime(2026, 1, 6)),
      ]);
      expect(heatmap.writtenDays, 0);
      expect(heatmap.isEmpty, isTrue);
    });

    test('空格子归零以后再算连续，不会把空文件的间隔跳过', () {
      // 1-5 有内容、1-6 是空文件、1-7 有内容 → 最长连续是 1 天，不是 3 天
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 1, 5), body: 'a'),
        entry(DateTime(2026, 1, 6), body: '   '),
        entry(DateTime(2026, 1, 7), body: 'b'),
      ]);
      expect(heatmap.writtenDays, 2);
      expect(heatmap.longestStreak, 1);
    });
  });

  group('汇总', () {
    test('写了几天、共多少字', () {
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 3, 1), body: '一二三'),
        entry(DateTime(2026, 3, 2), body: '一二三四五'),
      ]);
      expect(heatmap.writtenDays, 2);
      expect(heatmap.totalCharacters, 8);
    });

    test('最长连续天数：中间断一天就断', () {
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 3, 1), body: 'a'),
        entry(DateTime(2026, 3, 2), body: 'b'),
        entry(DateTime(2026, 3, 3), body: 'c'),
        // 3-4 空
        entry(DateTime(2026, 3, 5), body: 'd'),
      ]);
      expect(heatmap.longestStreak, 3);
    });

    test('连续天数能跨过"周的边界"（周日 → 周一）', () {
      // 这是最容易写错的一处：格子是按列拼的，如果连续计数按列重置，
      // 拼出来的最长连续会永远不超过 7 天。
      // 2026-03-01 是周日，所以 2-23(一)…3-01(日) 刚好一整周。
      final heatmap = build(2026, <DiaryEntry>[
        for (var day = 23; day <= 28; day++)
          entry(DateTime(2026, 2, day), body: 'a'),
        entry(DateTime(2026, 3, 1), body: 'b'), // 周日
        entry(DateTime(2026, 3, 2), body: 'c'), // 下周一
      ]);
      expect(heatmap.longestStreak, 8);
    });

    test('跨年不算进这一年', () {
      // 2025-12-31 和 2026-01-01 连着，但热力图只统计 2026
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2025, 12, 31), body: 'a'),
        entry(DateTime(2026, 1, 1), body: 'b'),
        entry(DateTime(2026, 1, 2), body: 'c'),
      ]);
      expect(heatmap.writtenDays, 2);
      expect(heatmap.longestStreak, 2);
    });

    test('一天都没写的时候是个明说的空状态', () {
      final heatmap = build(2026, <DiaryEntry>[]);
      expect(heatmap.isEmpty, isTrue);
      expect(heatmap.totalCharacters, 0);
      expect(heatmap.longestStreak, 0);
      expect(heatmap.columns, isNotEmpty, reason: '空年份也要画得出格子');
    });
  });

  group('字数和预览', () {
    test('字数和状态栏同一套算法（runes，不是 length）', () {
      // 一个 emoji 在 Dart 里 length == 2、runes == 1
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 1, 5), body: '😀'),
      ]);
      expect(dayAt(heatmap, DateTime(2026, 1, 5)).characters, 1);
    });

    test('正文带的是**全文**，不是首行（标题符号逐行去掉）', () {
      final heatmap = build(2026, <DiaryEntry>[
        entry(
          DateTime(2026, 1, 5),
          body: '\n## 今天的标题\n第一段。\n\n第二段也必须在里面。\n',
        ),
      ]);
      final day = dayAt(heatmap, DateTime(2026, 1, 5));

      // 用 DiaryEntry.preview 的话这里只有「今天的标题」——那正是被指出的那个 bug
      expect(day.text, '今天的标题\n第一段。\n\n第二段也必须在里面。');
      expect(day.text, contains('第二段'));
    });

    test('正文只有缩进和空行时不留首尾空白', () {
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 1, 5), body: '\n\n   \n正文\n\n\n'),
      ]);
      expect(dayAt(heatmap, DateTime(2026, 1, 5)).text, '正文');
    });

    test('Markdown 的其它符号不动（正文是用户写的，不替他重排）', () {
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 1, 5), body: '- 一条\n  - 缩进的子项\n**粗**'),
      ]);
      expect(
        dayAt(heatmap, DateTime(2026, 1, 5)).text,
        '- 一条\n  - 缩进的子项\n**粗**',
      );
    });

    test('同一天两条时只记第一条，不替用户挑', () {
      // 一天一个文件是数据格式的约定；两条说明有冲突文件，热力图不合并
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 1, 5), body: '第一条'),
        entry(DateTime(2026, 1, 5), body: '第二条'),
      ]);
      expect(heatmap.writtenDays, 1);
      expect(dayAt(heatmap, DateTime(2026, 1, 5)).text, '第一条');
    });

    test('没写过的那天是一格"0 字"，不是空缺', () {
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 1, 5), body: '写了'),
      ]);
      final empty = dayAt(heatmap, DateTime(2026, 1, 6));
      expect(empty.characters, 0);
      expect(empty.hasContent, isFalse);
      expect(empty.level, 0);
      expect(empty.date, DateTime(2026, 1, 6),
          reason: '空白的日子也要知道自己是哪一天——鼠标停上去要能说出日期');
    });
  });

  group('和 dateOnly 的一致性', () {
    test('格子里的日期都是当天零点', () {
      final heatmap = build(2026, <DiaryEntry>[
        entry(DateTime(2026, 6, 15, 8, 30), body: '早上写的'),
      ]);
      for (final day in flat(heatmap).whereType<DayWriting>()) {
        expect(day.date, dateOnly(day.date));
      }
    });
  });

  group('月视图的格子', () {
    MonthGrid month(int year, int monthNumber, [List<DiaryEntry>? entries]) =>
        MonthGrid.build(
          year: year,
          month: monthNumber,
          entries: entries ?? <DiaryEntry>[],
        );

    List<DayWriting?> flatMonth(MonthGrid grid) =>
        <DayWriting?>[for (final row in grid.weeks) ...row];

    test('固定 6 行 × 7 列，行数不随月份变', () {
      // 固定行数是为了翻月份时对话框高度不跳
      for (final m in <int>[1, 2, 3, 6, 11, 12]) {
        final grid = month(2026, m);
        expect(grid.weeks.length, 6, reason: '$m 月不是 6 行');
        for (final row in grid.weeks) {
          expect(row.length, 7);
        }
      }
    });

    test('2024-01-01 是周一 → 第一格就是 1 号', () {
      final grid = month(2024, 1);
      expect(grid.weeks.first[0]!.date, DateTime(2024, 1, 1));
    });

    test('2026-01-01 是周四 → 第一行前三格是空的', () {
      // 2026-01-01 周四这条由独立证据确认过：2026-10-01 是周四（界面截图里就写着）
      final grid = month(2026, 1);
      expect(grid.weeks.first[0], isNull);
      expect(grid.weeks.first[1], isNull);
      expect(grid.weeks.first[2], isNull);
      expect(grid.weeks.first[3]!.date, DateTime(2026, 1, 1));
    });

    test('这个月的每一天出现且只出现一次', () {
      for (final m in <int>[1, 2, 4, 12]) {
        final days = flatMonth(month(2026, m)).whereType<DayWriting>().toList();
        final expected = m == 2 ? 28 : (m == 4 ? 30 : 31);
        expect(days.length, expected, reason: '2026 年 $m 月的格子数不对');
        expect(days.first.date, DateTime(2026, m, 1));
        expect(days.last.date.day, expected);
      }
    });

    test('闰年二月有 29 格', () {
      final days = flatMonth(month(2024, 2)).whereType<DayWriting>().toList();
      expect(days.length, 29);
      expect(days.last.date, DateTime(2024, 2, 29));
    });

    test('相邻月份的条目不会渗进来', () {
      final grid = month(2026, 3, <DiaryEntry>[
        entry(DateTime(2026, 2, 28), body: '二月的'),
        entry(DateTime(2026, 3, 15), body: '三月的'),
        entry(DateTime(2026, 4, 1), body: '四月的'),
      ]);

      expect(grid.writtenDays, 1);
      expect(grid.totalCharacters, 3);
      expect(
        flatMonth(grid).whereType<DayWriting>().any(
              (day) => day.date.month != 3,
            ),
        isFalse,
      );
    });

    test('汇总只算这个月', () {
      final grid = month(2026, 3, <DiaryEntry>[
        entry(DateTime(2026, 3, 1), body: '一二三'),
        entry(DateTime(2026, 3, 2), body: '一二三四五'),
        entry(DateTime(2026, 2, 28), body: '不算'),
      ]);
      expect(grid.writtenDays, 2);
      expect(grid.totalCharacters, 8);
    });

    test('空文件不算写过，和年视图同一套判断', () {
      final grid = month(2026, 3, <DiaryEntry>[
        entry(DateTime(2026, 3, 5), body: '   '),
        entry(DateTime(2026, 3, 6), mood: '平静'),
      ]);
      expect(grid.writtenDays, 1);
      expect(grid.isEmpty, isFalse);
    });

    test('整月没写时 isEmpty 为真，但格子照画', () {
      final grid = month(2026, 3);
      expect(grid.isEmpty, isTrue);
      expect(flatMonth(grid).whereType<DayWriting>().length, 31);
    });
  });
}
