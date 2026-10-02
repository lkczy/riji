import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/diary_filter.dart';
import 'package:riji/core/models/diary_entry.dart';

void main() {
  DiaryEntry make({
    DateTime? date,
    List<String> tags = const <String>[],
    String? mood,
    String? weather,
  }) {
    return DiaryEntry.create(
      date: date ?? DateTime(2026, 2, 14),
      device: 'test',
      body: '正文',
      mood: mood,
      weather: weather,
      tags: tags,
    );
  }

  group('DiaryFilter.matches', () {
    test('没有条件时全部通过', () {
      expect(DiaryFilter.none.matches(make()), isTrue);
      expect(DiaryFilter.none.isActive, isFalse);
    });

    test('按标签筛选：命中标签列表里任意一项即可', () {
      const filter = DiaryFilter(tag: '工作');
      expect(filter.matches(make(tags: <String>['工作', '阅读'])), isTrue);
      expect(filter.matches(make(tags: <String>['阅读'])), isFalse);
      expect(filter.matches(make()), isFalse);
    });

    test('心情是精确匹配，不做模糊', () {
      const filter = DiaryFilter(mood: '烦');
      expect(filter.matches(make(mood: '烦')), isTrue);
      // 「烦躁」不该被「烦」筛出来——那是搜索该干的事，不是筛选。
      // 筛选做模糊匹配的结果是用户没法只看某一类，条件形同虚设。
      expect(filter.matches(make(mood: '烦躁')), isFalse);
      expect(filter.matches(make()), isFalse);
    });

    test('天气同样是精确匹配', () {
      const filter = DiaryFilter(weather: '晴');
      expect(filter.matches(make(weather: '晴')), isTrue);
      expect(filter.matches(make(weather: '晴转多云')), isFalse);
      expect(filter.matches(make(weather: '多云')), isFalse);
    });

    test('多个条件是「与」的关系', () {
      const filter = DiaryFilter(tag: '工作', mood: '疲惫', weather: '雨');
      const matching = <String>['工作'];
      expect(
        filter.matches(make(
            tags: matching, mood: '疲惫', weather: '雨')),
        isTrue,
      );
      // 任意一项不满足就整体不满足
      expect(filter.matches(make(tags: matching, mood: '疲惫', weather: '晴')), isFalse);
      expect(filter.matches(make(tags: matching, mood: '开心', weather: '雨')), isFalse);
      expect(filter.matches(make(tags: <String>['生活'], mood: '疲惫', weather: '雨')), isFalse);
    });

    test('条目没有心情/天气时不会被空条件筛掉', () {
      expect(const DiaryFilter(mood: '平静').matches(make()), isFalse);
      expect(DiaryFilter.none.matches(make()), isTrue);
    });
  });

  group('修改单个维度', () {
    test('传 null 表示清除这一维度，且不影响其它维度', () {
      const filter = DiaryFilter(tag: 'a', mood: 'b', weather: 'c');

      final noTag = filter.withTag(null);
      expect(noTag.tag, isNull);
      expect(noTag.mood, 'b', reason: '清标签不能顺手把心情也清掉');
      expect(noTag.weather, 'c');

      final noMood = filter.withMood(null);
      expect(noMood.tag, 'a');
      expect(noMood.mood, isNull);
      expect(noMood.weather, 'c');

      final noWeather = filter.withWeather(null);
      expect(noWeather.tag, 'a');
      expect(noWeather.mood, 'b');
      expect(noWeather.weather, isNull);
    });

    test('替换单个维度', () {
      const filter = DiaryFilter(tag: 'a');
      expect(filter.withMood('平静').tag, 'a');
      expect(filter.withMood('平静').mood, '平静');
      expect(filter.withMood('平静').isActive, isTrue);
    });
  });

  group('describe', () {
    test('没有条件时是空串', () {
      expect(DiaryFilter.none.describe(), '');
    });

    test('列出所有生效的条件', () {
      expect(
        const DiaryFilter(tag: '工作', mood: '疲惫').describe(),
        '标签「工作」 · 心情「疲惫」',
      );
      expect(const DiaryFilter(weather: '晴').describe(), '天气「晴」');
      expect(
        const DiaryFilter(tag: '工作', mood: '疲惫', weather: '雨').describe(),
        '标签「工作」 · 心情「疲惫」 · 天气「雨」',
      );
    });
  });
}
