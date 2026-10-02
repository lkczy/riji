/// 平台适配层的入口。
///
/// 默认走 web 实现；只要 `dart:io` 可用（桌面、手机）就换成真正的文件系统实现。
/// 这是「桌面端优先、将来扩展手机端」这个目标在代码里的落点：
/// **UI 和状态层完全不知道自己在哪个平台上。**
library;

export 'platform_web.dart' if (dart.library.io) 'platform_io.dart';
