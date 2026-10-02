// 黄历核心逻辑的测试。
//
// 用普通 test()：要读真实的资源文件，而 testWidgets 跑在假异步环境里，
// await 真实 dart:io 的 Future 永远不会返回。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/huangli.dart';
import 'package:riji/core/huangli_data.dart';

import 'huangli_fixture.dart';

/// 从原始文本里取出数据行（跳过表头注释和空行）。
///
/// 不直接用 `HuangliTable` 的解析结果，是因为有些不变量要看**原始编码**
/// （比如"索引有没有越界被静默丢掉"），那需要索引串本身。
List<String> splitHuangliDataLines(String content) {
  final lines = <String>[];
  for (final raw in content.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    lines.add(line);
  }
  return lines;
}

void main() {
  late HuangliTable table;
  late List<String> rawLines;

  setUpAll(() {
    final content = File('assets/huangli.tsv').readAsStringSync();
    rawLines = splitHuangliDataLines(content);
    table = HuangliTable.parse(content);
  });

  group('表的结构', () {
    test('天数与年份范围对得上', () {
      final expected = DateTime(2061, 1, 1).difference(DateTime(2000, 1, 1)).inDays;
      expect(table.dayCount, expected);
      expect(HuangliTable.firstYear, 2000);
      expect(HuangliTable.lastYear, 2060);
    });

    test('第一行是 2000-01-01，最后一行是 2060-12-31', () {
      final first = table.forDate(DateTime(2000, 1, 1));
      expect(first, isNotNull);
      expect(first!.date, DateTime(2000, 1, 1));

      final last = table.forDate(DateTime(2060, 12, 31));
      expect(last, isNotNull);
      expect(last!.date, DateTime(2060, 12, 31));
    });

    test('词表大小在 36 进制两位能表示的范围内', () {
      // 超出这个范围，索引编码就会静默错位
      expect(kHuangliTerms.length, lessThanOrEqualTo(36 * 36));
      expect(kHuangliTerms.toSet().length, kHuangliTerms.length,
          reason: '词表不该有重复项');
    });
  });

  group('全范围结构不变量', () {
    // 这些不需要第二个实现就能验证，而且是抓编码错误最有效的手段。

    test('日干支每天正好前进一位（六十甲子循环）', () {
      const stems = '甲乙丙丁戊己庚辛壬癸';
      const branches = '子丑寅卯辰巳午未申酉戌亥';

      int stemAt = -1;
      int branchAt = -1;
      for (var i = 0; i < rawLines.length; i++) {
        final ganZhi = rawLines[i].split('\t')[2];
        final stem = stems.indexOf(ganZhi[0]);
        final branch = branches.indexOf(ganZhi[1]);
        expect(stem, greaterThanOrEqualTo(0), reason: '第 $i 行的日干认不出来：$ganZhi');
        expect(branch, greaterThanOrEqualTo(0), reason: '第 $i 行的日支认不出来：$ganZhi');

        if (i > 0) {
          expect(stem, (stemAt + 1) % 10, reason: '第 $i 行的日干断了');
          expect(branch, (branchAt + 1) % 12, reason: '第 $i 行的日支断了');
        }
        stemAt = stem;
        branchAt = branch;
      }
    });

    test('冲必须是日支的对面（相隔六位）', () {
      const branches = '子丑寅卯辰巳午未申酉戌亥';
      for (var i = 0; i < rawLines.length; i++) {
        final parts = rawLines[i].split('\t');
        final dayBranch = branches.indexOf(parts[2][1]);
        final chong = branches.indexOf(parts[3]);
        expect(chong, (dayBranch + 6) % 12, reason: '第 $i 行的冲不对：${parts[3]}');
      }
    });

    test('每一行的宜忌索引都能解析出词（没有越界被静默丢掉）', () {
      // 解析器对越界索引是「跳过」，所以这里要独立确认一个都没被跳过：
      // 词数必须正好等于索引串长度的一半。
      for (var i = 0; i < rawLines.length; i++) {
        final parts = rawLines[i].split('\t');
        for (final column in <int>[5, 6]) {
          final encoded = parts[column];
          expect(encoded.length.isEven, isTrue,
              reason: '第 $i 行第 $column 列的索引串长度是奇数');
          final day = table.forDate(DateTime(2000, 1, 1 + i))!;
          final decoded = column == 5 ? day.yi : day.ji;
          expect(decoded.length, encoded.length ~/ 2,
              reason: '第 $i 行第 $column 列有索引越界，被静默丢掉了');
        }
      }
    });

    test('每一行的字段数都对', () {
      for (var i = 0; i < rawLines.length; i++) {
        expect(rawLines[i].split('\t').length, 7, reason: '第 $i 行字段数不对');
      }
    });
  });

  group('与生成时的夹具一致', () {
    test('${kHuangliFixture.length} 条夹具的干支、冲煞、宜忌都对得上', () {
      for (final row in kHuangliFixture) {
        final date = DateTime(
          int.parse(row[0]),
          int.parse(row[1]),
          int.parse(row[2]),
        );
        final day = table.forDate(date);
        expect(day, isNotNull, reason: '$date 取不到黄历');

        expect(day!.yearGanZhi, row[3], reason: '$date 年干支');
        expect(day.monthGanZhi, row[4], reason: '$date 月干支');
        expect(day.dayGanZhi, row[5], reason: '$date 日干支');
        expect(day.chongBranch, row[6], reason: '$date 冲');
        expect(day.shaDirection, row[7], reason: '$date 煞');
        expect(day.yi.join(','), row[8], reason: '$date 宜');
        expect(day.ji.join(','), row[9], reason: '$date 忌');
      }
    });
  });

  group('范围边界', () {
    test('范围内外判断正确', () {
      expect(table.contains(DateTime(2000, 1, 1)), isTrue);
      expect(table.contains(DateTime(2060, 12, 31)), isTrue);
      expect(table.contains(DateTime(1999, 12, 31)), isFalse);
      expect(table.contains(DateTime(2061, 1, 1)), isFalse);
    });

    test('范围外返回 null，而不是编一天出来', () {
      expect(table.forDate(DateTime(1999, 12, 31)), isNull);
      expect(table.forDate(DateTime(2061, 1, 1)), isNull);
      expect(table.forDate(DateTime(1900, 1, 1)), isNull);
    });

    test('带时间的 DateTime 也能查到（只看日期部分）', () {
      final a = table.forDate(DateTime(2026, 10, 4, 23, 59, 59));
      final b = table.forDate(DateTime(2026, 10, 4));
      expect(a, isNotNull);
      expect(a!.dayGanZhi, b!.dayGanZhi);
    });
  });

  group('解读成显示用的字段', () {
    test('冲的地支能转成生肖', () {
      final day = table.forDate(DateTime(2026, 10, 4))!;
      expect(day.chongBranch, '巳');
      expect(day.chongAnimal, '蛇');
      expect(day.chongShaSummary, contains('冲蛇'));
      expect(day.chongShaSummary, contains('煞'));
    });

    test('干支摘要格式稳定', () {
      final day = table.forDate(DateTime(2026, 10, 4))!;
      expect(day.ganZhiSummary, matches(RegExp(r'^\S+年 \S+月 \S+日$')));
    });

    test('十二地支和十二生肖一一对应', () {
      expect(kEarthlyBranches.length, 12);
      expect(kZodiacAnimals.length, 12);
    });
  });

  group('坏数据不能把整块卡片搞崩', () {
    test('字段不够的行返回 null', () {
      final broken = HuangliTable.parse('甲子\t乙丑\t丙寅\n');
      expect(broken.forDate(DateTime(2000, 1, 1)), isNull);
    });

    test('索引越界的词被跳过，其余照常显示', () {
      // zz = 1295，远超词表长度
      final broken = HuangliTable.parse('甲子\t乙丑\t丙寅\t卯\t西\tzz00\t01\n');
      final day = broken.forDate(DateTime(2000, 1, 1));
      expect(day, isNotNull);
      expect(day!.yi, hasLength(1), reason: '越界那个应该被跳过');
      expect(day.ji, hasLength(1));
    });

    test('注释行和空行被跳过', () {
      final parsed = HuangliTable.parse('# 注释\n\n甲子\t乙丑\t丙寅\t卯\t西\t\t\n');
      expect(parsed.dayCount, 1);
    });
  });
}
