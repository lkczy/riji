import 'package:flutter/material.dart';

import '../core/diary_location.dart';
import '../data/release_info.dart';
import '../state/diary_controller.dart';
import '../state/settings_controller.dart';
import 'home_page.dart';
import 'theme.dart';

class RijiApp extends StatelessWidget {
  const RijiApp({
    super.key,
    required this.controller,
    required this.settings,
    required this.onSwitchDiaryRoot,
    this.releaseInfo,
  });

  final DiaryController controller;
  final SettingsController settings;
  final SwitchDiaryRootCallback onSwitchDiaryRoot;

  /// 版本与更新记录。**可空**：读不到就当这个功能不存在，程序照常启动
  /// （`loadReleaseInfo` 里解释了为什么它不该挡住"打开即写"）。
  final ReleaseInfo? releaseInfo;

  @override
  Widget build(BuildContext context) {
    // 只订阅偏好控制器：改外观不该导致日记数据被重新读取。
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: 'riji',
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: settings.materialThemeMode,
        home: DiaryHomePage(
          controller: controller,
          settings: settings,
          onSwitchDiaryRoot: onSwitchDiaryRoot,
          releaseInfo: releaseInfo,
        ),
      ),
    );
  }
}
