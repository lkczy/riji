import 'vault_crypto.dart';

/// 黑条：[U+2588] 重复 8 次。
///
/// 固定 8 个、**不代表原文长短**——所以"这段有几个字"不会从黑条上看出来。
/// 识别时宽容一点（见 [isRedactionLine]）：用户手打 6 个或 10 个也算黑条，
/// 但程序写出去的一律是这 8 个。
const String redactionBar = '████████';

/// 整天锁之后正文里显示的占位符。
///
/// **写进文件**（2026-10-08 决定），这样手机上、记事本里打开都能看懂
/// "这一天锁着"，而不是一片空白让人以为那天没写。
const String wholeDayPlaceholder = '[正文已加密]';

/// 按原文长度生成黑条：一个码点一个方块。
///
/// 用 `runes`（码点）而不是 `length`（UTF-16 单元）：一个 emoji 是 1 个码点，
/// 却是 2 个 length——按 length 算黑条会比原文长一截。
String barForRunLength(int runes) => '█' * (runes < 1 ? 1 : runes);

/// 一条黑条最少要几个方块才算数。
///
/// **一个也算**（2026-10-08 决定）：黑条要和原文等长，而一个字的段落就会
/// 渲染成 1 个方块——如果这里还要求 2 个，那种段落会被当成普通正文，
/// 内容明明加密了、看起来却像没加密。
///
/// 代价是正文里手打一个 █ 也会被当成黑条。那种情况由保存护栏兜住：
/// 黑条数多过密文数时**拒绝保存**，不会出现"看着锁着、其实搜得到"。
const int minBarCharacters = 1;

/// 这一行是不是黑条行。
///
/// 判定只看**整行去掉空白后是否全是方块**：用户如果在黑条旁边写了字
/// （`██████ 后来说了`），那就不再是黑条行，而是普通正文——这样才不会
/// 出现"看着像黑条、其实底下没有密文"的状态。
bool isRedactionLine(String line) {
  final trimmed = line.trim();
  if (trimmed.length < minBarCharacters) return false;
  for (final rune in trimmed.runes) {
    if (rune != 0x2588) return false;
  }
  return true;
}

/// 正文里有几行黑条。
int redactionLineCount(String body) {
  var count = 0;
  for (final line in body.split('\n')) {
    if (isRedactionLine(line)) count++;
  }
  return count;
}

/// 正文里所有黑条行的下标（从 0 开始）。
List<int> redactionLineIndexes(String body) {
  final indexes = <int>[];
  final lines = body.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (isRedactionLine(lines[i])) indexes.add(i);
  }
  return indexes;
}

/// 把第 [lineIndex] 行换成黑条（"锁上这一段"）。
///
/// 黑条长度 = 原文的**码点数**（2026-10-08 决定：等长）。所以"这一段大概
/// 多长"是看得出来的——这是明确接受的代价，也写进了 `详细说明.md`。
String barForLineAt(String body, int lineIndex, int runes) {
  final lines = body.split('\n');
  if (lineIndex < 0 || lineIndex >= lines.length) return body;
  lines[lineIndex] = barForRunLength(runes);
  return lines.join('\n');
}

/// 保留旧名字：不指定长度时按 [redactionBar] 写（只在测试和兼容路径上用）。
String barForLine(String body, int lineIndex) {
  final lines = body.split('\n');
  if (lineIndex < 0 || lineIndex >= lines.length) return body;
  lines[lineIndex] = redactionBar;
  return lines.join('\n');
}

/// 把第 [lineIndex] 行的黑条换回明文（"解开这一段"）。
String revealLine(String body, int lineIndex, String text) {
  final lines = body.split('\n');
  if (lineIndex < 0 || lineIndex >= lines.length) return body;
  if (!isRedactionLine(lines[lineIndex])) return body;
  lines[lineIndex] = text;
  return lines.join('\n');
}

/// 一段正文、一组密文，配不配得上。
///
/// 对应关系是**按出现顺序**：第 1 行黑条取 `r1`，第 2 行取 `r2`。
/// 所以：
///   · 黑条比密文多 → **不许保存**。多出来的黑条底下没有密文，
///     界面上看着"锁着"、其实一搜就搜得到——这是最坏的一种谎。
///   · 密文比黑条多 → 允许（用户删掉了一行黑条）。多余的密文**保留不删**，
///     按项目纪律，程序不替用户销毁任何东西。
String? barsMismatchError(String body, int redactionCount) {
  final bars = redactionLineCount(body);
  if (bars > redactionCount) {
    return '正文里有 $bars 行黑条，但只找得到 $redactionCount 段密文。'
        '多出来的黑条底下没有内容，保存下去会变成"看着锁着、其实搜得到"。';
  }
  return null;
}

/// 一天的锁状态。
///
/// 两种形态**互斥**（`enc-body` 与 `enc-redactions` 不能同时有）：
///   · 整天锁：正文留空，整篇密文在 [bodyCipher] 里
///   · 按段锁：正文是带黑条的骨架，每段密文在 [redactions] 里
///
/// 为什么互斥：整天锁之后正文是空的，黑条没有地方可放；两种同时存在
/// 只会让"到底以哪个为准"变成一个没人说得清的问题。
class DayLock {
  const DayLock({
    required this.params,
    this.bodyCipher,
    this.redactions = const <String, String>{},
    this.characters,
    this.version = vaultVersion,
  });

  /// 格式版本。将来换算法就是 v2。
  final String version;

  /// 口令派生参数（跟着文件走，所以文件是自描述的）。
  ///
  /// **可以为 null**：文件里的 `enc-params` 被改坏、或者将来出现一种这个
  /// 版本不认识的参数时，锁照样要建起来——那样界面才能老实说"参数不认识，
  /// 打不开"，而不是把这天显示成"没写过"。
  final KdfParams? params;

  /// 整天锁的密文；按段锁时是 null。
  final String? bodyCipher;

  /// 按段锁的密文，键是 `r1`、`r2`……顺序即黑条出现的顺序。
  final Map<String, String> redactions;

  /// 锁上那一刻的**完整字数**。
  ///
  /// 为什么要单独存：正文是密文或黑条的时候，字数算不出来。热力图和
  /// 统计要它。代价是"这天写了多少字"是公开的——这是 2026-10-08 明确
  /// 决定接受的（见 `docs/加密设计.md`）。
  final int? characters;

  bool get isWholeDay => bodyCipher != null;

  bool get isParagraphs => bodyCipher == null && redactions.isNotEmpty;

  /// 这一天有没有任何形式的上锁。
  bool get isLocked => isWholeDay || redactions.isNotEmpty;

  DayLock copyWith({
    KdfParams? params,
    String? bodyCipher,
    bool clearBodyCipher = false,
    Map<String, String>? redactions,
    int? characters,
  }) =>
      DayLock(
        version: version,
        params: params ?? this.params,
        bodyCipher: clearBodyCipher ? null : (bodyCipher ?? this.bodyCipher),
        redactions: redactions ?? this.redactions,
        characters: characters ?? this.characters,
      );

  @override
  String toString() => 'DayLock($version, '
      '${isWholeDay ? '整天' : '${redactions.length} 段'}, '
      '${characters ?? '?'} 字)';
}

/// 密文的键名：`r1`、`r2`……**从 1 开始**（给人看的，别从 0 开始）。
String redactionKey(int index) => 'r${index + 1}';
