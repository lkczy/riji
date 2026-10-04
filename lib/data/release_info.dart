import 'package:flutter/services.dart' show rootBundle;

import '../core/app_version.dart';
import '../core/release_notes.dart';

/// 「本版更新」弹窗需要的两样东西：当前版本号 + 解析好的更新记录。
///
/// 放在 `data/` 而不是 `core/`：读资源包是 Flutter 的事，解析是纯逻辑。
/// 界面拿到的是一份**已经解析好**的数据，所以界面测试可以直接塞一份进来，
/// 完全不必碰资源包——测试环境不保证读得到（`test/ui_test.dart` 里黄历那段有
/// 同样的处理）。
class ReleaseInfo {
  const ReleaseInfo({required this.version, required this.changeLog});

  final String version;
  final ChangeLog changeLog;
}

/// 这两个文件是**故意**打进包里的，理由见 `pubspec.yaml` 的 assets 注释：
/// 版本号和更新说明各自只有一个真相来源。
const String kChangeLogAssetPath = 'CHANGELOG.md';
const String kPubspecAssetPath = 'pubspec.yaml';

/// 读出版本与更新记录；任何一步失败都返回 null。
///
/// 返回 null 的意思是「这个功能这次不出现」，界面必须能照常启动——
/// 它是锦上添花，绝不能挡住"打开即写"。
Future<ReleaseInfo?> loadReleaseInfo() async {
  try {
    final pubspec = await rootBundle.loadString(kPubspecAssetPath);
    final version = versionFromPubspecText(pubspec);
    if (version == null) return null;

    final changelog = await rootBundle.loadString(kChangeLogAssetPath);
    return ReleaseInfo(version: version, changeLog: ChangeLog.parse(changelog));
  } catch (_) {
    return null;
  }
}
