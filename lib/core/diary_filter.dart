import 'models/diary_entry.dart';

/// 列表的筛选条件。
///
/// 三个维度各自可选，组合起来是「与」的关系（标签=工作 且 心情=疲惫）。
/// 刻意做成不可变对象：筛选状态会被界面和控制器同时读，可变对象容易出
/// "改了一个地方、另一个地方看到的是中间状态"这类问题。
class DiaryFilter {
  const DiaryFilter({this.tag, this.mood, this.weather});

  /// 标签：命中条目标签列表里的任意一项即可。
  final String? tag;

  /// 心情：因为是自由文本，这里做**精确匹配**。
  /// 模糊匹配会让「烦」同时命中「烦躁」和「麻烦」，那不是筛选该有的行为。
  final String? mood;

  /// 天气：同上，精确匹配。
  final String? weather;

  static const DiaryFilter none = DiaryFilter();

  bool get isActive => tag != null || mood != null || weather != null;

  /// 传 null 表示清除这一维度。
  DiaryFilter withTag(String? value) =>
      DiaryFilter(tag: value, mood: mood, weather: weather);

  DiaryFilter withMood(String? value) =>
      DiaryFilter(tag: tag, mood: value, weather: weather);

  DiaryFilter withWeather(String? value) =>
      DiaryFilter(tag: tag, mood: mood, weather: value);

  bool matches(DiaryEntry entry) {
    if (tag != null && !entry.tags.contains(tag)) return false;
    if (mood != null && entry.mood != mood) return false;
    if (weather != null && entry.weather != weather) return false;
    return true;
  }

  /// 给界面用的一句话描述，例如 `标签「工作」 · 心情「疲惫」`。
  String describe() {
    final parts = <String>[
      if (tag != null) '标签「$tag」',
      if (mood != null) '心情「$mood」',
      if (weather != null) '天气「$weather」',
    ];
    return parts.join(' · ');
  }
}
