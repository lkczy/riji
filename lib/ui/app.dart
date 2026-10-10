import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/diary_location.dart';
import '../data/release_info.dart';
import '../state/diary_controller.dart';
import '../state/settings_controller.dart';
import 'app_lock_screen.dart';
import 'home_page.dart';
import 'idle_lock.dart';
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

  /// 该不该先显示"程序锁"界面。
  ///
  /// 三个条件缺一不可：**开了程序锁**、**确实有保险库**、**当前没解锁**。
  /// 中间那条很要紧：保险库文件没了的时候如果还锁着，人就被关在自己的日记外面了
  /// ——那种情况锁屏本身会给出直接进入的口子（见 `AppLockScreen`）。
  bool get _locked {
    final vault = controller.vault;
    return settings.appLockEnabled &&
        vault != null &&
        vault.isConfigured &&
        !vault.isUnlocked;
  }

  Widget _buildHome(BuildContext context) {
    final vault = controller.vault;
    if (_locked && vault != null) {
      return AppLockScreen(controller: controller, vault: vault);
    }
    return DiaryHomePage(
      controller: controller,
      settings: settings,
      onSwitchDiaryRoot: onSwitchDiaryRoot,
      releaseInfo: releaseInfo,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅偏好控制器：改外观不该导致日记数据被重新读取。
    // 同时订阅控制器：保险库解锁/锁定是**控制器**在监听并转发的，
    // 只订阅 settings 的话，解锁之后界面不会换成主界面。
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[settings, controller]),
      builder: (context, _) => MaterialApp(
        title: 'riji',
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: settings.materialThemeMode,
        // 没有这一段，输入框右键菜单里的"粘贴/全选"会是英文——
        // 那些字符串来自 Flutter 自己的 MaterialLocalizations。
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
        locale: const Locale('zh'),
        // 闲置自动重新锁定：包在最外层，吃所有指针/键盘事件，
        // 不用去改任何现有界面的嵌套
        builder: (context, child) => IdleLock(
          idleLimit: settings.appLockEnabled && settings.appLockIdleMinutes > 0
              ? Duration(minutes: settings.appLockIdleMinutes)
              : null,
          onIdle: controller.lockApp,
          child: child ?? const SizedBox.shrink(),
        ),
        home: _buildHome(context),
      ),
    );
  }
}
