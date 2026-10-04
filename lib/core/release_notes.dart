/// 从 `CHANGELOG.md` 里抽出「升级后弹给用户看的那两句话」。
///
/// 纯逻辑，输入是文本。约定写在 `CHANGELOG.md` 开头：
/// **只有 `### 新功能` 和 `### 修复` 两节会进弹窗**，其余小节（内部、已知限制……）
/// 只留在文件里给开发者看。
///
/// 这样做是为了**不制造第二个真相来源**：如果另写一份「更新摘要」，
/// 它和 CHANGELOG 迟早会不一致，而那种不一致没人会发现。
library;

import 'app_version.dart';

/// 一个版本要显示给用户的东西。
class ReleaseNotes {
  const ReleaseNotes({
    required this.version,
    this.date,
    this.features = const <String>[],
    this.fixes = const <String>[],
  });

  final String version;

  /// 版本标题里的日期，形如 `2026-10-03`。取不到就是 null，界面会省掉那一行。
  ///
  /// 刻意保持字符串：它是**从文件里读出来的**，重排一次格式只会多一处出错的地方。
  final String? date;

  final List<String> features;
  final List<String> fixes;
}

/// 从 Markdown 文本里解析出来的更新记录。
///
/// 契约只有一条：**[forVersion] 返回 null 表示"这一版没有要给用户看的内容"**，
/// 界面据此整个跳过弹窗——绝不显示一个空框。
class ChangeLog {
  const ChangeLog(this._byVersion);

  final Map<String, ReleaseNotes> _byVersion;

  /// 这一版要显示的内容；没有就是 null。
  ReleaseNotes? forVersion(String version) => _byVersion[_normalize(version)];

  /// 把版本号统一成「主.次.修订」。
  ///
  /// 两边都要归一化：pubspec 里可能写成 `1.1.0+4`，而 CHANGELOG 的标题一般只写
  /// `1.1.0`。构建号不该影响用户看到哪一份更新说明——**只归一化一边是不够的**，
  /// 那样会变成"用 1.1.0+4 查不到、用 1.1.0 也查不到"。
  ///
  /// 代价：真出现 `1.1.0` 和 `1.1.0+1` 两节时，后者会盖掉前者。更新说明按
  /// 「主.次.修订」归类本来就是这样，可以接受。
  static String _normalize(String version) {
    final trimmed = version.trim();
    final parsed = AppVersion.tryParse(trimmed);
    if (parsed == null) return trimmed;
    return '${parsed.major}.${parsed.minor}.${parsed.patch}';
  }

  static final RegExp _versionHeading = RegExp(r'^##\s+(.+)$');
  static final RegExp _sectionHeading = RegExp(r'^###\s+(.+)$');
  static final RegExp _bullet = RegExp(r'^[-*]\s+(.*)$');
  static final RegExp _date = RegExp(r'\d{4}-\d{2}-\d{2}');
  static final RegExp _firstToken = RegExp(r'^(\S+)');

  static ChangeLog parse(String markdown) {
    final byVersion = <String, ReleaseNotes>{};

    String? version;
    String? date;
    _Section section = _Section.other;
    var features = <String>[];
    var fixes = <String>[];

    // 当前这一条。CHANGELOG 里的条目为了好读会折行，续行要拼回同一条——
    // 否则弹窗里会出现半句话。
    var pending = StringBuffer();

    void flush() {
      final text = plainTextOf(pending.toString());
      pending = StringBuffer();
      if (text.isEmpty) return;
      if (section == _Section.features) features.add(text);
      if (section == _Section.fixes) fixes.add(text);
    }

    void closeVersion() {
      flush();
      if (version != null && (features.isNotEmpty || fixes.isNotEmpty)) {
        byVersion[version!] = ReleaseNotes(
          version: version!,
          date: date,
          features: List<String>.of(features),
          fixes: List<String>.of(fixes),
        );
      }
      version = null;
      date = null;
      section = _Section.other;
      features = <String>[];
      fixes = <String>[];
    }

    for (final rawLine in markdown.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trimRight();

      final versionHeading = _versionHeading.firstMatch(line);
      if (versionHeading != null) {
        closeVersion();
        final heading = versionHeading.group(1)!.trim();
        final token = _firstToken.firstMatch(heading)?.group(1);
        // 标题第一个词必须像个版本号，否则这一节整个跳过（`## 未发布` 这类）。
        if (token != null && AppVersion.tryParse(token) != null) {
          version = _normalize(token);
          date = _date.firstMatch(heading)?.group(0);
        }
        continue;
      }

      final sectionHeading = _sectionHeading.firstMatch(line);
      if (sectionHeading != null) {
        flush();
        section = _sectionOf(sectionHeading.group(1)!.trim());
        continue;
      }

      if (line.startsWith('# ')) continue; // 文件大标题

      final bullet = _bullet.firstMatch(line);
      if (bullet != null) {
        flush();
        pending.write(bullet.group(1));
        continue;
      }

      if (line.trim().isEmpty) {
        flush();
        continue;
      }

      // 续行：接到当前这一条后面。
      if (pending.isNotEmpty) {
        pending.write(' ');
        pending.write(line.trim());
      }
    }

    closeVersion();
    return ChangeLog(byVersion);
  }

  /// 小节属于哪一类。**认的是名字**，所以 CHANGELOG 里改标题就等于改弹窗内容。
  static _Section _sectionOf(String name) {
    if (name.contains('新功能') || name.contains('新增')) return _Section.features;
    if (name.contains('修复') || name.toLowerCase().contains('bug')) {
      return _Section.fixes;
    }
    return _Section.other;
  }
}

enum _Section { features, fixes, other }

/// 把一条 Markdown 行内标记去掉，压成一行纯文本。
///
/// 弹窗是纯文本的：`**加粗**` 和 `` `Ctrl+K` `` 这种标记**不该露给用户**。
/// 刻意**不处理单个 `*` 和 `_`**（斜体）：正文里出现一个 `*` 或下划线的可能性
/// 远大于真的有人用斜体，宁可留着也不要误删用户的字。
String plainTextOf(String line) {
  var text = line;
  // 链接只留文字：弹窗里点不开，留着 URL 只是噪音
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^)]*\)'),
    (match) => match.group(1)!,
  );
  text = text.replaceAll('**', '');
  text = text.replaceAll('`', '');
  text = text.replaceAll(RegExp(r'\s+'), ' ');
  return text.trim();
}
