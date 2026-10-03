/// 命令面板：**搜什么**和**怎么排序**。
///
/// 这一层刻意不依赖 Flutter —— 图标、快捷键回调、「到底执行什么」都属于界面层。
/// 放进 `core` 是因为命令面板好不好用，秘密几乎全在**排序**上：搜「深色」
/// 能不能命中「外观：深色」、它排在第一条还是第五条。这类判断是纯逻辑，
/// 可以用普通 `test()` 一条条量出来（和 `diary_filter.dart`、
/// `writing_prompts.dart` 一个路子）。
library;

/// 一条命令里**参与搜索和显示**的部分。
///
/// 「怎么执行」不在这里：那需要 `BuildContext` 和闭包，是界面层的事。
/// 界面层用一个包装类把它和图标、回调接起来（见 `ui/command_palette.dart`）。
class PaletteCommand {
  const PaletteCommand({
    required this.id,
    required this.title,
    this.subtitle,
    this.keywords = const <String>[],
    this.shortcut,
    this.enabled = true,
    this.disabledReason,
  });

  /// 稳定标识。界面拿它做行的 key，测试拿它定位。
  final String id;

  /// 显示给用户的名字，也是主要的搜索目标。
  final String title;

  /// 副标题。用来显示**当前值**（例如字号、已开启/已关闭）。
  ///
  /// 「为什么不能点」不放这里，放 [disabledReason] —— 两者在界面上
  /// 显示在同一行，但语义完全不同，混成一个字段以后一定会有人用错。
  final String? subtitle;

  /// 别名：用户会想到的**另一个说法**。
  ///
  /// 中文没有词边界，只按标题匹配的话用户十有八九搜不到——想切深色的人会打
  /// 「主题」「夜间」「暗」，不会去打「外观：深色」。所以每条命令都必须给几个
  /// 别名。这不是锦上添花，是这个功能能不能用起来的前提。
  final List<String> keywords;

  /// 显示在行尾的快捷键，例如 `Ctrl+B`。没有就留空。
  ///
  /// 顺带一个好处：这个列表本身就是「快捷键总览」，
  /// 不必再单独做一个界面（README 的待办里有这一条）。
  final String? shortcut;

  /// 现在能不能执行。
  final bool enabled;

  /// 不能执行的原因。**禁用而不是隐藏**：这一条仍然要出现在列表里，
  /// 否则用户会以为程序根本没有这个功能（项目里已经定下的原则）。
  final String? disabledReason;
}

/// 标题命中相对别名命中的加成。
///
/// 取值远大于子序列评分能达到的量级（见 [_subsequenceScore]，几十的量级），
/// 所以它表达的是**优先级**而不是「稍微高一点」：只要标题能命中，就不该被
/// 一个别名命中得很漂亮的命令挤下去 —— 用户打的是他在界面上看到的那些字。
const int _titleBonus = 1000;

/// 算出 [query] 命中的命令下标，按相关度从高到低排。
///
/// 返回下标而不是命令本身：界面层拿它直接索引自己的动作表，
/// 不需要按 id 再查一次（那要求 id 唯一，是个不必要的约束）。
///
/// 查询为空时返回全部下标，保持注册顺序 —— 注册顺序是刻意排的
/// （日常在上、破坏性的在下），空查询时打乱它没有任何好处。
List<int> rankCommands(String query, List<PaletteCommand> commands) {
  final tokens = <String>[];
  for (final token in query.trim().toLowerCase().split(RegExp(r'\s+'))) {
    if (token.isNotEmpty) tokens.add(token);
  }
  if (tokens.isEmpty) {
    return <int>[for (var i = 0; i < commands.length; i++) i];
  }

  final ranked = <_Ranked>[];
  for (var index = 0; index < commands.length; index++) {
    var total = 0;
    var matchedAll = true;
    for (final token in tokens) {
      final score = _scoreToken(token, commands[index]);
      if (score == null) {
        matchedAll = false;
        break;
      }
      total += score;
    }
    if (matchedAll) ranked.add(_Ranked(index, total));
  }

  ranked.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    // 同分时按注册顺序。排序必须是稳定的：搜同一个词每次都要得到同样的列表，
    // 否则用户会觉得列表在自己乱跳。
    return byScore != 0 ? byScore : a.index.compareTo(b.index);
  });

  return <int>[for (final item in ranked) item.index];
}

/// 同 [rankCommands]，但直接返回命令本身。测试和调用方读起来更直白。
List<PaletteCommand> filterCommands(
  String query,
  List<PaletteCommand> commands,
) {
  return <PaletteCommand>[
    for (final index in rankCommands(query, commands)) commands[index],
  ];
}

class _Ranked {
  const _Ranked(this.index, this.score);

  final int index;
  final int score;
}

/// 一个词对一条命令的得分。null 表示这个词命中不了这条命令。
int? _scoreToken(String token, PaletteCommand command) {
  final onTitle = _subsequenceScore(token, command.title.toLowerCase());
  if (onTitle != null) return onTitle + _titleBonus;

  int? best;
  for (final keyword in command.keywords) {
    final score = _subsequenceScore(token, keyword.toLowerCase());
    if (score != null && (best == null || score > best)) best = score;
  }
  return best;
}

/// 子序列匹配：`token` 的每个字符都要在 `target` 里**按顺序**出现。
///
/// 为什么不是简单的 `contains`：用户打「字行」也想能搜到「字体与行距」。
/// 但**连续命中必须显著高于跳着命中**，否则 `置` 这种单字会命中一大堆命令，
/// 而 `字行` 会排在某个散落命中的后面，列表就没法看了。
///
/// 返回 null 表示匹配不上；否则分数越大越相关。
int? _subsequenceScore(String token, String target) {
  if (token.isEmpty || target.isEmpty) return null;
  // 子序列当然要求 token 不比 target 长。先挡掉能省一整趟扫描。
  if (token.length > target.length) return null;

  var tokenIndex = 0;
  var score = 0;
  var previousHit = -2;

  for (var i = 0; i < target.length && tokenIndex < token.length; i++) {
    if (target[i] != token[tokenIndex]) continue;

    // 四类加权，每一条都是「用户大概是这么打字的」的直接翻译。
    // 权重的相对大小是有意的，不是随手填的：
    //   · 与上一个命中字符相邻（+12）—— 最可靠的信号：他打的是一个连续片段
    //   · 落在词首（+8）—— 用户常常只打词头
    //   · 越靠前越好（最多 +10）—— 同样的匹配，出现在开头比结尾更相关
    //   · 目标越短越好（最后减长度）—— 搜「深色」时，「外观：深色」要排在
    //     「外观：深色（夜间阅读模式）」前面
    // 连续性必须压过词首权重：否则「行距」会优先命中「行…距」这种散落
    // 匹配，而真正的「字体与行距」被挤下去。
    score += _isWordStart(target, i) ? 8 : 2;
    if (i == previousHit + 1) score += 12;
    score += (10 - i).clamp(0, 10);

    previousHit = i;
    tokenIndex++;
  }

  if (tokenIndex < token.length) return null;

  return score - target.length;
}

/// 这些字符在标题里起的是「分词」的作用（`外观：深色` 里的冒号）。
///
/// 中文没有空格分词，所以标点和括号就是事实上的词边界。
const String _wordBreaks = ' ：:（(）)/-·，,、';

bool _isWordStart(String target, int index) =>
    index == 0 || _wordBreaks.contains(target[index - 1]);
