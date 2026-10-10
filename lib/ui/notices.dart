import 'package:flutter/material.dart';

/// 统一弹一条提示。
///
/// 三件事必须一起做，少一件都会让人烦：
///
/// 1. **先清掉上一条**。连着点几下不该堆成一摞，也不该排队等着一条条播。
/// 2. **短一点**。默认 4 秒是在"一句话"上停留得太久了——频繁操作时，
///    窗口下方会一直挂着一条提示。
/// 3. **浮起来、右边留出空隙**。默认的贴底样式会盖住右下角的「⋮」按钮；
///    而"按钮被挡住"和"按钮点不到"在用户那里是同一件事（实测：测试里
///    点不动「⋮」，报 "another widget is obscuring it"）。
void showNotice(
  BuildContext context,
  String message, {
  SnackBarAction? action,
  Duration duration = const Duration(milliseconds: 2200),
}) =>
    showNoticeOn(ScaffoldMessenger.of(context), message,
        action: action, duration: duration);

/// 同上，但**接收已经拿到的 messenger**。
///
/// `await` 之后再用 `context` 会被 lint 拦下（而且确实有风险），所以异步流程里
/// 一律在 await 之前把 messenger 取好，然后调这个。
void showNoticeOn(
  ScaffoldMessengerState messenger,
  String message, {
  SnackBarAction? action,
  Duration duration = const Duration(milliseconds: 2200),
}) {
  messenger
    ..removeCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        behavior: SnackBarBehavior.floating,
        // 右边留出 88：右下角那一列图标（更多、定位）要一直点得到
        margin: const EdgeInsets.fromLTRB(16, 0, 88, 12),
        action: action,
      ),
    );
}