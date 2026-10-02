import 'day.dart';
import 'huangli_data.dart';

/// 十二地支与对应生肖。冲煞的显示要用它把地支转成生肖。
const List<String> kEarthlyBranches = <String>[
  '子', '丑', '寅', '卯', '辰', '巳', '午', '未', '申', '酉', '戌', '亥',
];

const List<String> kZodiacAnimals = <String>[
  '鼠', '牛', '虎', '兔', '龙', '蛇', '马', '羊', '猴', '鸡', '狗', '猪',
];

/// 某一天的黄历。
///
/// **关于可信度**：干支、冲煞是可验证的（两个独立实现在 730 天里 100% 一致）；
/// **宜忌不是**——同样两个实现在同一年里完全一致的日子是 0%。宜忌是传统历注，
/// 依据的是某一套通书规则，界面必须如实标注，不能当成客观事实呈现。
class HuangliDay {
  const HuangliDay({
    required this.date,
    required this.yearGanZhi,
    required this.monthGanZhi,
    required this.dayGanZhi,
    required this.chongBranch,
    required this.shaDirection,
    required this.yi,
    required this.ji,
  });

  final DateTime date;

  /// 年干支，**按春节分界**（与农历年一致）。
  final String yearGanZhi;

  /// 月干支，按节气分界。
  final String monthGanZhi;

  final String dayGanZhi;

  /// 当日所冲的**地支**（例如 `巳`）。生肖由它推出来。
  final String chongBranch;

  /// 煞方（例如 `西`）。
  final String shaDirection;

  final List<String> yi;
  final List<String> ji;

  /// 所冲的生肖，例如 `蛇`。
  String get chongAnimal {
    final index = kEarthlyBranches.indexOf(chongBranch);
    return index < 0 ? chongBranch : kZodiacAnimals[index];
  }

  /// `冲蛇` / `煞西` 这种一行摘要。
  String get chongShaSummary => '冲$chongAnimal（$chongBranch）· 煞$shaDirection';

  String get ganZhiSummary => '$yearGanZhi年 $monthGanZhi月 $dayGanZhi日';
}

/// 黄历数据表。
///
/// 数据是一张按日连续的表（`assets/huangli.tsv`），所以第 N 行就是起始日
/// 之后的第 N 天——不需要在数据里存日期，查一天是 O(1)。
///
/// 刻意**不在加载时解析全部两万多行**：那会白白构造几万个对象。
/// 这里只把文本切成行（一次线性扫描），被问到的那些天才会真正解析。
class HuangliTable {
  HuangliTable._(this._lines);

  final List<String> _lines;

  static const int firstYear = kHuangliFirstYear;
  static const int lastYear = kHuangliLastYear;

  static DateTime get firstDate => DateTime(firstYear, 1, 1);
  static DateTime get lastDate => DateTime(lastYear, 12, 31);

  static HuangliTable? _cached;

  int get dayCount => _lines.length;

  /// 表里覆盖的第一天 / 最后一天（按表的实际长度算，用来自检范围常量对不对）。
  DateTime get actualFirstDate => firstDate;
  DateTime get actualLastDate =>
      DateTime(firstYear, 1, 1 + _lines.length - 1);

  /// 从文本建表。跳过空行和 `#` 开头的注释行。
  ///
  /// 测试可以直接喂文件内容，不必经过资源包——这样核心逻辑的测试
  /// 不需要跑在 Flutter 的资源环境里。
  static HuangliTable parse(String content) {
    final lines = <String>[];
    for (final raw in content.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      lines.add(line);
    }
    return HuangliTable._(lines);
  }

  /// 加载整张表，只做一次。
  ///
  /// [readAsset] 是为了可测试性：默认从资源包读，测试可以注入别的来源。
  static Future<HuangliTable> load({
    required Future<String> Function() readAsset,
  }) async {
    final cached = _cached;
    if (cached != null) return cached;

    final table = parse(await readAsset());
    _cached = table;
    return table;
  }

  /// 测试用：直接注入已经解析好的表。
  ///
  /// 界面测试走的是 [load]（会去读资源包），而资源包在测试环境里不一定可用；
  /// 先把缓存填上，`load` 就会直接命中缓存，不去碰资源包。
  /// 用同步注入是为了避开 `testWidgets` 的假异步环境——那里 `await` 真实 I/O
  /// 永远不会返回。
  static void seedCache(HuangliTable table) => _cached = table;

  /// 测试用：清掉缓存。
  static void resetCacheForTest() => _cached = null;

  bool contains(DateTime date) {
    final day = dateOnly(date);
    if (day.year < firstYear || day.year > lastYear) return false;
    final index = _indexOf(day);
    return index >= 0 && index < _lines.length;
  }

  HuangliDay? forDate(DateTime date) {
    final day = dateOnly(date);
    if (!contains(day)) return null;

    final line = _lines[_indexOf(day)];
    final parts = line.split('\t');
    if (parts.length < 7) return null;

    return HuangliDay(
      // 用 DateTime 的溢出归一化来还原日期，这样跨月跨年不用自己算
      date: DateTime(firstYear, 1, 1 + _indexOf(day)),
      yearGanZhi: parts[0],
      monthGanZhi: parts[1],
      dayGanZhi: parts[2],
      chongBranch: parts[3],
      shaDirection: parts[4],
      yi: _decodeTerms(parts[5]),
      ji: _decodeTerms(parts[6]),
    );
  }

  /// 用 UTC 算天数差：本地时间跨夏令时会差一天，UTC 不会。
  int _indexOf(DateTime day) => DateTime.utc(day.year, day.month, day.day)
          .difference(DateTime.utc(firstYear, 1, 1))
          .inDays;

  /// 每两个字符是一个 36 进制索引。认不出来的词直接跳过——
  /// 数据坏掉时宁可少显示一个词，也不能让悬浮窗整块打不开。
  static List<String> _decodeTerms(String encoded) {
    final terms = <String>[];
    for (var i = 0; i + 1 < encoded.length; i += 2) {
      final value = _base36(encoded[i]) * 36 + _base36(encoded[i + 1]);
      if (value < 0 || value >= kHuangliTerms.length) continue;
      terms.add(kHuangliTerms[value]);
    }
    return terms;
  }

  static int _base36(String char) {
    final code = char.codeUnitAt(0);
    if (code >= 0x30 && code <= 0x39) return code - 0x30; // 0-9
    if (code >= 0x61 && code <= 0x7A) return code - 0x61 + 10; // a-z
    if (code >= 0x41 && code <= 0x5A) return code - 0x41 + 10; // A-Z
    return -1;
  }
}
