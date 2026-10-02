import 'package:flutter/services.dart' show rootBundle;

import '../core/huangli.dart';

/// 黄历数据的加载入口。
///
/// 放在 `data/` 而不是 `core/`：`core/` 是纯逻辑、不依赖 Flutter，
/// 而 `rootBundle` 是 Flutter 的东西。这样黄历的解析与查询逻辑
/// 可以在普通 `test()` 里测，不必进 Flutter 的资源环境。
///
/// 数据是资源文件（约 1.4 MB）而不是 Dart 源码：两万多行的常量会让
/// 每次编译都变慢。读取用 `rootBundle`，仍然是核心 Flutter，没有插件。
const String kHuangliAssetPath = 'assets/huangli.tsv';

Future<HuangliTable> loadHuangliTable() => HuangliTable.load(
      readAsset: () => rootBundle.loadString(kHuangliAssetPath),
    );
