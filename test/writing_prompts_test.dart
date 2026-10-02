import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/writing_prompts.dart';

void main() {
  group('引子集合本身', () {
    test('数量够多，角度够广', () {
      expect(kWritingPrompts.length, greaterThanOrEqualTo(100));
      expect(
        writingPromptCategories.length,
        greaterThanOrEqualTo(10),
        reason: '要的就是"多角度"；角度太少就退化成一份问卷',
      );
    });

    test('没有重复的引子', () {
      final texts = kWritingPrompts.map((p) => p.text).toList();
      expect(texts.toSet().length, texts.length);
    });

    test('每条都是完整、够短的句子', () {
      for (final prompt in kWritingPrompts) {
        expect(prompt.text.trim(), isNotEmpty);
        expect(prompt.category.trim(), isNotEmpty);
        // 不强制是问句：「随想与碎片」那类用祈使句更自然
        // （「随便写一件今天想到的小事。」），硬改成问句反而别扭。
        expect(
          RegExp(r'[？。]$').hasMatch(prompt.text.trim()),
          isTrue,
          reason: '「${prompt.text}」没有句末标点',
        );
        expect(
          prompt.text.length,
          lessThanOrEqualTo(30),
          reason: '太长的引子本身就成了负担：「${prompt.text}」',
        );
      }
    });

    test('每个角度都有足够多的引子', () {
      for (final category in writingPromptCategories) {
        final count =
            kWritingPrompts.where((p) => p.category == category).length;
        expect(count, greaterThanOrEqualTo(8),
            reason: '「$category」只有 $count 条');
      }
    });

    test('角度数量少于引子总数（即有归类，不是每条一个角度）', () {
      expect(writingPromptCategories.length,
          lessThan(kWritingPrompts.length ~/ 2));
    });
  });

  group('promptForDate：稳定性', () {
    test('同一天永远同一条', () {
      final date = DateTime(2026, 2, 14);
      final first = promptForDate(date).text;
      for (var i = 0; i < 30; i++) {
        expect(promptForDate(date).text, first);
      }
    });

    test('只按天定，和时间无关', () {
      expect(
        promptForDate(DateTime(2026, 2, 14)).text,
        promptForDate(DateTime(2026, 2, 14, 23, 59, 59)).text,
      );
    });

    test('基准点之前的日期也能取到（取模不能出负数）', () {
      final prompt = promptForDate(DateTime(2015, 6, 1));
      expect(kWritingPrompts, contains(prompt));
    });
  });

  group('promptForDate：分散性与覆盖率', () {
    test('相邻日期一定不同', () {
      var date = DateTime(2026, 1, 1);
      for (var i = 0; i < 300; i++) {
        expect(
          promptForDate(date).text,
          isNot(promptForDate(date.add(const Duration(days: 1))).text),
          reason: '${date.toIso8601String()} 和它后一天撞了同一条',
        );
        date = date.add(const Duration(days: 1));
      }
    });

    test('相邻日期一定落在不同角度上', () {
      // 这条是「多角度」能不能落到日常使用里的关键：
      // 如果连着十天都在问同一类问题，用户一样会没话说。
      var date = DateTime(2026, 1, 1);
      for (var i = 0; i < 300; i++) {
        final today = promptForDate(date);
        final tomorrow = promptForDate(date.add(const Duration(days: 1)));
        expect(
          today.category,
          isNot(tomorrow.category),
          reason: '${date.toIso8601String()} 前后两天都是「${today.category}」',
        );
        date = date.add(const Duration(days: 1));
      }
    });

    test('任意连续 N 天刚好覆盖全部 N 条，不重不漏', () {
      final total = kWritingPrompts.length;
      final seen = <String>{};
      var date = DateTime(2024, 3, 1);
      for (var i = 0; i < total; i++) {
        seen.add(promptForDate(date).text);
        date = date.add(const Duration(days: 1));
      }
      expect(seen.length, total, reason: '$total 天里出现了重复的引子');
    });

    test('一年的跨度里每个角度都被用到', () {
      final categories = <String>{};
      var date = DateTime(2026, 1, 1);
      for (var i = 0; i < 365; i++) {
        categories.add(promptForDate(date).category);
        date = date.add(const Duration(days: 1));
      }
      expect(categories.length, writingPromptCategories.length);
    });
  });

  group('换一个', () {
    test('换了以后不一样', () {
      final date = DateTime(2026, 2, 14);
      expect(
        promptForDate(date, offset: 1).text,
        isNot(promptForDate(date).text),
      );
    });

    test('换满一圈刚好遍历全部，不会反复撞同几条', () {
      final date = DateTime(2026, 2, 14);
      final total = kWritingPrompts.length;
      final seen = <String>{};
      for (var offset = 0; offset < total; offset++) {
        seen.add(promptForDate(date, offset: offset).text);
      }
      expect(seen.length, total);
    });

    test('换过的结果同样是确定的', () {
      final date = DateTime(2026, 2, 14);
      expect(
        promptForDate(date, offset: 5).text,
        promptForDate(date, offset: 5).text,
      );
    });

    test('不同日期「换一个」的序列不同', () {
      // 否则每天点第一下都得到同一条，很快就腻了
      expect(
        promptForDate(DateTime(2026, 2, 14), offset: 1).text,
        isNot(promptForDate(DateTime(2026, 2, 15), offset: 1).text),
      );
    });
  });
}
