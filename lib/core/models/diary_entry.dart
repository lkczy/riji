import '../day.dart';
import '../ulid.dart';
import '../vault_format.dart';

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
    this.lock,
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

  /// 这天的上锁状态。null = 明文（绝大多数日子）。
  ///
  /// 见 `lib/core/vault_format.dart` 和 `docs/加密设计.md`：锁上的内容
  /// **就在这个文件里**（front matter 的 `enc-*` 字段），不是搬到别处去了。
  final DayLock? lock;

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

  /// 这一天有没有任何锁。
  bool get isLocked => lock?.isLocked ?? false;

  /// 是不是"空的一天"。
  ///
  /// ⚠️ **锁着的天算有内容。** 否则日历的"写过没有"、每日提醒的"今天写没写"
  /// 都会把一整天锁着的日记当成没写——那是最容易发生、也最难发现的错。
  bool get isEmpty {
    if (isLocked) return false;
    return body.trim().isEmpty &&
        (mood == null || mood!.isEmpty) &&
        (weather == null || weather!.isEmpty) &&
        tags.isEmpty;
  }

  /// 这一天的字数：锁着的时候用锁里存的（正文是密文或黑条，算不出来）。
  ///
  /// 明文的天按**码点**算（`runes`），和热力图/统计的口径一致。
  int get characterCount => lock?.characters ?? body.runes.length;

  /// 列表、搜索结果里显示的那一行。
  ///
  /// 锁着的天必须**一眼看得出来锁了**，而且**两种锁要能分清**：
  ///   · 整天锁：🔒（整篇都看不见）
  ///   · 部分黑条：⬛（只是几段看不见——用它左边那个方块，因为它就是黑条本身）
  ///
  /// 为什么不复用同一个锁图标：两者的"看不见的程度"完全不同，
  /// 一个图标会让人以为"整篇都锁了"，从而不敢去读还能读的部分。
  String get listPreview {
    final current = lock;
    if (current == null || !current.isLocked) return preview;
    if (current.isWholeDay) return '🔒 已加密';

    final badge = '⬛ ${current.redactions.length} 段黑条';
    final text = preview;
    // 第一行本身就是黑条时，没必要再把黑条当标题显示一遍
    if (text.isEmpty || isRedactionLine(text)) return badge;
    return '$badge · $text';
  }

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
    DayLock? lock,
    bool clearLock = false,
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
      lock: clearLock ? null : (lock ?? this.lock),
      extraFrontMatter: extraFrontMatter ?? this.extraFrontMatter,
    );
  }

  @override
  String toString() => 'DiaryEntry($id, ${formatIsoDate(date)}, '
      '${body.length} 字${isLocked ? '，已加密' : ''})';
}
