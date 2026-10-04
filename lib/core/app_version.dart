/// 版本号：解析、比较，以及「这次启动该不该弹本版更新」。
///
/// 纯逻辑，输入是文本；读文件是 `data/` 的事，弹窗是 `ui/` 的事。
library;

import 'package:yaml/yaml.dart';

/// 一个版本号，只认 `主.次.修订`，可选 `+构建号`。
///
/// 为什么不引一个 semver 包：这里只需要"谁更新"这一个判断，多一个依赖就多一处
/// 会坏的地方。但代价要说清楚——**它只认 pubspec.yaml 里的那种写法**，
/// 遇到别的形式（`v1.1.0`、`1.1`、`1.1.0-beta`）一律返回 null，
/// 让调用方**少弹一次**，而不是拿猜出来的结果去比。
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.build = 0]);

  final int major;
  final int minor;
  final int patch;
  final int build;

  static final RegExp _pattern = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$');

  static AppVersion? tryParse(String raw) {
    final match = _pattern.firstMatch(raw.trim());
    if (match == null) return null;
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      match.group(4) == null ? 0 : int.parse(match.group(4)!),
    );
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major - other.major;
    if (minor != other.minor) return minor - other.minor;
    if (patch != other.patch) return patch - other.patch;
    return build - other.build;
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.build == build;

  @override
  int get hashCode => Object.hash(major, minor, patch, build);

  @override
  String toString() => build == 0
      ? '$major.$minor.$patch'
      : '$major.$minor.$patch+$build';
}

/// 这次启动该不该弹「本版更新」。
///
/// 三种情况都**不弹**，而且理由各不相同：
///
/// | 情况 | 为什么不弹 |
/// |---|---|
/// | `lastSeen` 是 null | 第一次装，没有"上一版"可比。给刚装上的人看更新说明是噪音 |
/// | 任一边解析不出来 | 宁可少弹一次，也不拿猜出来的版本去比 |
/// | 不比自己新 | 相同＝已经看过；更旧＝用户回退到旧版，给他看"未来的更新记录"没有意义 |
///
/// 这里**只回答"该不该弹"**，"有没有内容可弹"是 [ChangeLog] 的事——
/// 两件事分开，各自都能单独测。
bool shouldAnnounceVersion({
  required String current,
  required String? lastSeen,
}) {
  if (lastSeen == null) return false;
  final currentVersion = AppVersion.tryParse(current);
  final lastSeenVersion = AppVersion.tryParse(lastSeen);
  if (currentVersion == null || lastSeenVersion == null) return false;
  return currentVersion.compareTo(lastSeenVersion) > 0;
}

/// 从 pubspec.yaml 的文本里取出 `version:`。
///
/// 用真正的 YAML 解析而不是正则：这份文件是程序自己打进包的，但它仍然是可以被
/// 手改的文本，正则在缩进、引号、注释变化时会**静默给出错答案**——而"版本号读错"
/// 的表现是弹窗该弹不弹、或者弹错内容，都属于最难查的那一类。
String? versionFromPubspecText(String text) {
  try {
    final document = loadYaml(text);
    if (document is! Map) return null;
    final value = document['version'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  } catch (_) {
    // 解析失败＝没有版本信息。这个功能宁可整个不出现，也不能让程序打不开。
    return null;
  }
}
