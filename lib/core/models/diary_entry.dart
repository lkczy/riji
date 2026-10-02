import '../day.dart';
import '../ulid.dart';

/// 一条日记。
///
/// [body] 是**原样保存**的 Markdown。编解码过程绝不能对它做 trim、转义或重排——
/// 用户手写的格式就是最终格式。
class DiaryEntry {
  const DiaryEntry({
    required this.id,
    required this.date,
    required this.created,
    required this.updated,
    required this.device,
    required this.body,
    this.mood,
    this.weather,
    this.tags = const <String>[],
    this.extraFrontMatter = '',
  });

  /// 条目永久标识，ULID。手工创建、没有 front matter 的文件会用
  /// `legacy-YYYYMMDD` 形式的确定性占位 id。
  final String id;

  /// 归属日期，只到天。
  final DateTime date;

  final DateTime created;
  final DateTime updated;

  /// 写入设备，用于排查同步问题。
  final String device;

  final String body;

  /// 心情。预设之外允许自由输入，所以是字符串而不是枚举。
  final String? mood;

  /// 天气。同样是自由输入的字符串——预设有用，但天气的说法太多，
  /// 强行限定成几个选项只会让用户写不下想写的东西。
  final String? weather;

  final List<String> tags;

  /// 程序不认识的 front matter 原文，逐字节保留，重新保存时原样写回。
  ///
  /// 存在的理由：程序必须能安全地「不认识」某些字段。
  /// 只要有一台设备跑着旧版本（比如将来电脑端升级了、手机端还没升），
  /// 它就会把新版本写入的字段悄悄抹掉——而用户永远不会发现。
  /// 有了这个字段，加新功能（天气、位置、心情曲线……）就不会再有这种风险。
  final String extraFrontMatter;

  /// 新建一条今天的日记。
  factory DiaryEntry.create({
    required DateTime date,
    required String device,
    String body = '',
    String? mood,
    String? weather,
    List<String> tags = const <String>[],
  }) {
    final now = DateTime.now();
    return DiaryEntry(
      id: Ulid.generate(at: now),
      date: dateOnly(date),
      created: now,
      updated: now,
      device: device,
      body: body,
      mood: mood,
      weather: weather,
      tags: tags,
    );
  }

  /// 从文件名兜底构造一个条目。用于解析没有 front matter 的手写文件。
  factory DiaryEntry.legacy({
    required DateTime date,
    required DateTime timestamp,
    required String device,
    required String body,
  }) {
    return DiaryEntry(
      id: legacyIdFor(date),
      date: dateOnly(date),
      created: timestamp,
      updated: timestamp,
      device: device,
      body: body,
    );
  }

  /// 缺少 id 的文件所用的确定性占位标识。必须是确定性的，
  /// 否则每读一次文件都会产生一个新 id，同步时会误判成新条目。
  static String legacyIdFor(DateTime date) =>
      'legacy-${date.year.toString().padLeft(4, '0')}'
      '${date.month.toString().padLeft(2, '0')}'
      '${date.day.toString().padLeft(2, '0')}';

  bool get hasLegacyId => id.startsWith('legacy-');

  bool get isEmpty =>
      body.trim().isEmpty &&
      (mood == null || mood!.isEmpty) &&
      (weather == null || weather!.isEmpty) &&
      tags.isEmpty;

  /// 正文首行，用作列表和搜索结果里的标题。
  String get preview {
    for (final line in body.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      // 去掉 Markdown 标题符号，让预览更像标题
      return trimmed.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    }
    return '';
  }

  DiaryEntry copyWith({
    String? id,
    DateTime? date,
    DateTime? created,
    DateTime? updated,
    String? device,
    String? body,
    String? mood,
    bool clearMood = false,
    String? weather,
    bool clearWeather = false,
    List<String>? tags,
    String? extraFrontMatter,
  }) {
    return DiaryEntry(
      id: id ?? this.id,
      date: date ?? this.date,
      created: created ?? this.created,
      updated: updated ?? this.updated,
      device: device ?? this.device,
      body: body ?? this.body,
      mood: clearMood ? null : (mood ?? this.mood),
      weather: clearWeather ? null : (weather ?? this.weather),
      tags: tags ?? this.tags,
      extraFrontMatter: extraFrontMatter ?? this.extraFrontMatter,
    );
  }

  @override
  String toString() => 'DiaryEntry($id, ${formatIsoDate(date)}, ${body.length} 字)';
}
