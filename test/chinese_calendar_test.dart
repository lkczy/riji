import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/chinese_calendar.dart';

import 'chinese_calendar_fixture.dart';

void main() {
  // 扫一遍 1950–2100，找出两种"重合"的日子给下面的测试用。
  // 只扫这一次：151 年逐日调用 annotate 有点慢，两个测试共用结果。
  DateTime? bothFestivals;
  DateTime? festivalAndTerm;
  {
    var date = DateTime(1950, 1, 1);
    final end = DateTime(2100, 12, 31);
    while ((bothFestivals == null || festivalAndTerm == null) &&
        !date.isAfter(end)) {
      final annotation = ChineseCalendar.annotate(date);
      if (bothFestivals == null &&
          annotation.solarFestival != null &&
          annotation.lunarFestival != null) {
        bothFestivals = date;
      }
      if (festivalAndTerm == null &&
          annotation.lunarFestival != null &&
          annotation.solarTerm != null) {
        festivalAndTerm = date;
      }
      date = DateTime(date.year, date.month, date.day + 1);
    }
  }

  group('农历解码：与基准数据逐条比对', () {
    // 夹具是生成脚本直接用权威数据产出的：每个农历年的正月初一、每个闰月的
    // 初一、以及每年的最后一天。解码表的时候出错，最先就表现在这些位置上。
    test('${kLunarBoundaryFixture.length} 个边界日期全部对得上', () {
      for (final row in kLunarBoundaryFixture) {
        final date = DateTime(row[0], row[1], row[2]);
        final lunar = ChineseCalendar.lunarFor(date);

        expect(lunar, isNotNull, reason: '$date 没有解出农历');
        expect(lunar!.year, row[3], reason: '$date 的农历年');
        expect(lunar.month, row[4].abs(), reason: '$date 的农历月');
        expect(lunar.day, row[5], reason: '$date 的农历日');
        expect(lunar.isLeapMonth, row[4] < 0, reason: '$date 的闰月标志');
      }
    });

    test('正月之前的那一天属于上一年腊月，不是新年的正月', () {
      final newYear = DateTime(2026, 2, 17);
      expect(ChineseCalendar.lunarFor(newYear)!.text, '正月初一');

      final eve = DateTime(2026, 2, 16);
      final lunar = ChineseCalendar.lunarFor(eve)!;
      expect(lunar.month, 12);
      expect(lunar.year, 2025);
    });

    test('闰月排在本位月之后', () {
      // 2025 年闰六月。2025-07-25 是闰六月初一（不是六月初一——我一开始记错了）。
      final leapFirst = ChineseCalendar.lunarFor(DateTime(2025, 7, 25))!;
      expect(leapFirst.month, 6);
      expect(leapFirst.isLeapMonth, isTrue);
      expect(leapFirst.day, 1);
      expect(leapFirst.text, startsWith('闰六月'));

      // 它的前一天必须是「六月」的最后一天，而不是别的月
      final before = ChineseCalendar.lunarFor(DateTime(2025, 7, 24))!;
      expect(before.month, 6);
      expect(before.isLeapMonth, isFalse, reason: '闰月必须排在本位月之后');
      expect(before.day, greaterThanOrEqualTo(29));

      // 闰月结束之后回到七月
      final after = ChineseCalendar.lunarFor(DateTime(2025, 8, 23))!;
      expect(after.month, 7);
      expect(after.isLeapMonth, isFalse);
    });

    test('范围外返回 null，而不是编一个日期出来', () {
      expect(ChineseCalendar.lunarFor(DateTime(1949, 6, 1)), isNull);
      expect(ChineseCalendar.lunarFor(DateTime(2200, 6, 1)), isNull);
    });
  });

  group('农历日名与月名', () {
    test('中文习惯的写法', () {
      const cases = <String, String>{
        '正月初一': '2026-02-17',
        '正月初十': '2026-02-26',
        '腊月廿三': '2026-02-10',
      };
      cases.forEach((expected, iso) {
        final parts = iso.split('-').map(int.parse).toList();
        final lunar = ChineseCalendar.lunarFor(
          DateTime(parts[0], parts[1], parts[2]),
        )!;
        expect(lunar.text, expected);
      });
    });

    test('每一种月名和日名都能取到，不会越界', () {
      // 走遍 1950–2100 的每一天，确保名字表的下标永远合法
      var date = DateTime(1950, 1, 1);
      final end = DateTime(2100, 12, 31);
      var checked = 0;
      while (!date.isAfter(end)) {
        final lunar = ChineseCalendar.lunarFor(date);
        expect(lunar, isNotNull, reason: '$date 应该能解出农历');
        expect(lunar!.month, inInclusiveRange(1, 12));
        expect(lunar.day, inInclusiveRange(1, 30));
        expect(lunar.monthName, isNotEmpty);
        expect(lunar.dayName, isNotEmpty);
        checked++;
        date = DateTime(date.year, date.month, date.day + 1);
      }
      expect(checked, greaterThan(55000));
    });
  });

  group('节气：与基准数据逐条比对', () {
    test('${kSolarTermFixture.length} 条节气记录全部对得上', () {
      for (final row in kSolarTermFixture) {
        final date = DateTime(row[0], row[2], row[3]);
        expect(
          ChineseCalendar.solarTermFor(date),
          ChineseCalendar.solarTermNames[row[1]],
          reason: '$date 应该是 ${ChineseCalendar.solarTermNames[row[1]]}',
        );
      }
    });

    test('每年恰好 24 个节气，日期严格递增，且落在固定的月份里', () {
      for (var year = 1950; year <= 2100; year++) {
        final found = <int, DateTime>{};
        var date = DateTime(year, 1, 1);
        while (date.year == year) {
          final term = ChineseCalendar.solarTermFor(date);
          if (term != null) {
            found[ChineseCalendar.solarTermNames.indexOf(term)] = date;
          }
          date = DateTime(date.year, date.month, date.day + 1);
        }

        expect(found.length, 24, reason: '$year 年节气数量不是 24');
        DateTime? previous;
        for (var index = 0; index < 24; index++) {
          final at = found[index];
          expect(at, isNotNull, reason: '$year 年缺第 $index 个节气');
          expect(at!.month, ChineseCalendar.solarTermMonths[index],
              reason: '$year 年 ${ChineseCalendar.solarTermNames[index]} 的月份不对');
          if (previous != null) {
            expect(at.isAfter(previous), isTrue,
                reason: '$year 年 ${ChineseCalendar.solarTermNames[index]} 的日期没有递增');
          }
          previous = at;
        }
      }
    });

    test('范围外返回 null', () {
      expect(ChineseCalendar.solarTermFor(DateTime(1949, 2, 4)), isNull);
      expect(ChineseCalendar.solarTermFor(DateTime(2200, 2, 4)), isNull);
    });

    test('非节气日返回 null', () {
      // 2026-02-14 不是节气
      expect(ChineseCalendar.solarTermFor(DateTime(2026, 2, 14)), isNull);
    });
  });

  group('节日', () {
    test('公历固定节日走 solarFestival', () {
      expect(ChineseCalendar.annotate(DateTime(2026, 1, 1)).solarFestival, '元旦');
      expect(ChineseCalendar.annotate(DateTime(2026, 10, 1)).solarFestival, '国庆节');
      expect(ChineseCalendar.annotate(DateTime(2026, 12, 25)).solarFestival, '圣诞节');
    });

    test('按星期算的公历节日', () {
      // 2026 年母亲节 = 5 月 10 日（5 月第二个星期日）
      expect(
          ChineseCalendar.annotate(DateTime(2026, 5, 10)).solarFestival, '母亲节');
      expect(ChineseCalendar.annotate(DateTime(2026, 5, 3)).solarFestival, isNull);
      expect(
          ChineseCalendar.annotate(DateTime(2026, 5, 17)).solarFestival, isNull);
    });

    test('农历节日走 lunarFestival', () {
      expect(ChineseCalendar.annotate(DateTime(2026, 2, 17)).lunarFestival, '春节');
      expect(
          ChineseCalendar.annotate(DateTime(2026, 3, 3)).lunarFestival, '元宵节');
      expect(
          ChineseCalendar.annotate(DateTime(2026, 6, 19)).lunarFestival, '端午节');
      expect(
          ChineseCalendar.annotate(DateTime(2026, 9, 25)).lunarFestival, '中秋节');
    });

    test('两种节日分属两个字段，不会互相串', () {
      final nationalDay = ChineseCalendar.annotate(DateTime(2026, 10, 1));
      expect(nationalDay.solarFestival, '国庆节');
      expect(nationalDay.lunarFestival, isNull);

      final springFestival = ChineseCalendar.annotate(DateTime(2026, 2, 17));
      expect(springFestival.solarFestival, isNull);
      expect(springFestival.lunarFestival, '春节');
    });

    test('同一天可能既是阳历节日又是阴历节日，两边都要保留', () {
      // 春节落在 1/21–2/21，完全可能撞上 2/14 情人节；中秋（八月十五）
      // 也可能撞上 10/1 国庆节。所以这两个字段不能合并成一个。
      expect(bothFestivals, isNotNull, reason: '151 年里总该有重合的日子');

      final annotation = ChineseCalendar.annotate(bothFestivals!);
      expect(annotation.solarFestival, isNotNull);
      expect(annotation.lunarFestival, isNotNull);
      // 阳历节日只出现在第一行的字段里，阴历节日只在第二行
      expect(annotation.lunarLine, isNot(contains(annotation.solarFestival!)));
    });

    test('除夕是腊月的最后一天，不是写死的「三十」', () {
      // 2025 年腊月只有 29 天，除夕落在腊月廿九
      final eve = ChineseCalendar.annotate(DateTime(2026, 2, 16));
      expect(eve.lunarFestival, '除夕');
      expect(eve.lunar!.month, 12);
      expect(eve.lunar!.day, 29, reason: '这一年的腊月只有 29 天');
    });

    test('闰月里的任何一天都不会被认成农历节日', () {
      // 闰五月初五不是端午，闰八月十五不是中秋——真实数据里就有闰月，
      // 所以这条必须靠规则保证，不能靠"碰不到"。
      const lunarFestivalNames = <String>[
        '春节', '元宵节', '端午节', '七夕', '中秋节', '重阳节', '腊八节',
      ];

      var date = DateTime(1950, 1, 1);
      var leapDays = 0;
      while (!date.isAfter(DateTime(2100, 12, 31))) {
        final lunar = ChineseCalendar.lunarFor(date);
        if (lunar != null && lunar.isLeapMonth) {
          leapDays++;
          final festival = ChineseCalendar.annotate(date).lunarFestival;
          expect(
            lunarFestivalNames.contains(festival),
            isFalse,
            reason: '$date 是闰${lunar.monthName}${lunar.dayName}，不该算成$festival',
          );
        }
        date = DateTime(date.year, date.month, date.day + 1);
      }
      expect(leapDays, greaterThan(1000), reason: '151 年里应该扫到不少闰月的日子');
    });
  });

  group('显示的排列顺序', () {
    // 界面上的位置约定：
    //   第一行：阳历日期 · 星期 · **阳历节日**
    //   第二行：**阴历节日** · 农历日期 · **节气**
    // 这里是纯字符串顺序的验证，位置本身由界面测试用坐标检查。

    test('阴历节日排在农历日期之前', () {
      final annotation = ChineseCalendar.annotate(DateTime(2026, 2, 17));
      expect(annotation.lunarLine, '春节 · 正月初一');
    });

    test('节气排在农历日期之后', () {
      final annotation = ChineseCalendar.annotate(DateTime(2026, 2, 4));
      expect(annotation.solarTerm, '立春');
      expect(annotation.lunarLine, endsWith('立春'));
    });

    test('三段齐全时顺序是 阴历节日 · 农历 · 节气', () {
      expect(festivalAndTerm, isNotNull, reason: '应该能找到节日和节气同一天的日子');

      final annotation = ChineseCalendar.annotate(festivalAndTerm!);
      expect(
        annotation.lunarLine,
        '${annotation.lunarFestival} · ${annotation.lunar!.text} · ${annotation.solarTerm}',
      );
    });

    test('阳历节日不进第二行', () {
      final annotation = ChineseCalendar.annotate(DateTime(2026, 10, 1));
      expect(annotation.solarFestival, '国庆节');
      expect(annotation.lunarLine, isNot(contains('国庆节')));
    });

    test('README 里举的例子与实际行为一致', () {
      // 文档里写了具体输出，就该有测试钉住它，否则文档会悄悄过时。
      // docs/详细说明.md 的「农历、节日与节气」一节引用的就是这些。
      expect(
        ChineseCalendar.annotate(DateTime(2026, 10, 1)).lunarLine,
        '八月廿一',
      );
      expect(
        ChineseCalendar.annotate(DateTime(2026, 10, 1)).solarFestival,
        '国庆节',
      );
      expect(
        ChineseCalendar.annotate(DateTime(2026, 2, 17)).lunarLine,
        '春节 · 正月初一',
      );
      expect(
        ChineseCalendar.annotate(DateTime(2026, 2, 18)).lunarLine,
        '正月初二 · 雨水',
      );
      // 第二行三段齐全
      expect(
        ChineseCalendar.annotate(DateTime(2027, 8, 8)).lunarLine,
        '七夕 · 七月初七 · 立秋',
      );
      // 同一天既是阳历节日又是阴历节日
      final overlap = ChineseCalendar.annotate(DateTime(2031, 10, 1));
      expect(overlap.solarFestival, '国庆节');
      expect(overlap.lunarFestival, '中秋节');
      expect(overlap.lunarLine, '中秋节 · 八月十五');
    });
  });

  group('DayAnnotation', () {
    test('普通日子只有农历', () {
      final annotation = ChineseCalendar.annotate(DateTime(2026, 3, 10));
      expect(annotation.lunar, isNotNull);
      expect(annotation.solarTerm, isNull);
      expect(annotation.solarFestival, isNull);
      expect(annotation.lunarFestival, isNull);
      expect(annotation.hasHighlight, isFalse);
      expect(annotation.isEmpty, isFalse);
      expect(annotation.hasLunarLine, isTrue);
    });

    test('范围外又没有公历节日时，两行都没东西可显示', () {
      final plain = ChineseCalendar.annotate(DateTime(1949, 6, 15));
      expect(plain.lunar, isNull);
      expect(plain.solarTerm, isNull);
      expect(plain.hasLunarLine, isFalse);
      expect(plain.lunarLine, isEmpty);
      expect(plain.isEmpty, isTrue);
    });

    test('范围外但有公历节日时，只有第一行有东西', () {
      // 公历节日是纯规则算出来的，不依赖农历表，所以范围外也认——
      // 这是有意的：儿童节在 1949 年也是儿童节。
      final childrensDay = ChineseCalendar.annotate(DateTime(1949, 6, 1));
      expect(childrensDay.lunar, isNull);
      expect(childrensDay.solarTerm, isNull);
      expect(childrensDay.solarFestival, '儿童节');
      expect(childrensDay.hasLunarLine, isFalse, reason: '第二行不该占位置');
      expect(childrensDay.isEmpty, isFalse);
    });
  });
}
