import 'package:flutter/material.dart';

import '../core/editor_typography.dart';
import '../data/settings.dart';

/// 主题种子色。
///
/// **整个界面只有这一处硬编码颜色**，其余 30 处全部走 `colorScheme` 令牌。
/// 这正是深色模式几乎"白送"的原因：换一个 ColorScheme，
/// 所有组件自动跟着变，一个都不用改。
const Color kSeedColor = Color(0xFF4A6FA5);

ThemeData buildLightTheme() => _build(Brightness.light);

ThemeData buildDarkTheme() => _build(Brightness.dark);

ThemeData _build(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: kSeedColor,
    brightness: brightness,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    // 提示条一律**浮起来、右下角留出空隙**。
    //
    // 默认的贴底样式会盖住右下角那一列图标（更多、定位），而"按钮被挡住"
    // 和"按钮点不到"在用户那里是同一件事。留在主题里是为了让**所有**提示
    // 都这样，而不是只有我记得改过的那几处。
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      insetPadding: EdgeInsets.fromLTRB(16, 0, 88, 12),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.5),
      space: 1,
      thickness: 1,
    ),
  );
}

IconData themeModeIcon(AppThemeMode mode) => switch (mode) {
      AppThemeMode.system => Icons.brightness_auto_outlined,
      AppThemeMode.light => Icons.light_mode_outlined,
      AppThemeMode.dark => Icons.dark_mode_outlined,
    };

String themeModeLabel(AppThemeMode mode) => switch (mode) {
      AppThemeMode.system => '跟随系统',
      AppThemeMode.light => '浅色',
      AppThemeMode.dark => '深色',
    };

/// 把 [EditorTypography.fontWeightValue]（400/500/600）映射成 [FontWeight]。
FontWeight fontWeightFor(int value) {
  final index = (value ~/ 100 - 1).clamp(0, FontWeight.values.length - 1);
  return FontWeight.values[index];
}

String fontWeightLabel(int value) => switch (value) {
      400 => '常规',
      500 => '中等',
      600 => '加粗',
      _ => '常规',
    };
