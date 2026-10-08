import 'package:flutter/services.dart' show rootBundle;

import '../core/reminder.dart';
import '../platform/platform.dart' as platform;
import 'settings_controller.dart';

/// 「启用/停用提醒」这两件事的接口。
///
/// 存在的唯一理由：**界面测试不能真的去改系统**。真实现（[ReminderService]）
/// 会起 PowerShell 写注册表、建计划任务；测试换一个假的进来，就能验证
/// "界面在成功/失败时分别显示什么"，而一个字节都不落到用户的系统里。
abstract class ReminderOps {
  Future<ReminderOutcome> enable(ReminderTime time, List<int> weekdays);
  Future<ReminderOutcome> disable();
}

/// 「装进系统」这件事。默认就是平台层那个实现，测试换掉它。
typedef ReminderApplier = Future<ReminderOutcome> Function(
  ReminderTime time,
  List<int> weekdays,
  String diaryRoot,
  List<int> iconBytes,
);

/// 「从系统里撤掉」这件事。
typedef ReminderRemover = Future<ReminderOutcome> Function();

/// 真实现：调平台层，并维护设置里的开关和指纹。
/// 真实现：调平台层，并维护设置里的开关和指纹。
///
/// 装的是四样东西（脚本、通知归属、协议、计划任务），细节见
/// `lib/platform/platform_io.dart` 里那段注释。这个类只管**顺序、指纹和
/// 设置的一致性**——真正的系统调用在平台层，而"要发什么命令"在纯逻辑层。
///
/// 为什么需要它、而不是让界面直接调平台层：因为"启用"不是一次调用，
/// 是"装进系统 → 装成功了才把开关记下来"。这个先后顺序错了，
/// 界面就会显示一个系统里并不存在的提醒。
class ReminderService implements ReminderOps {
  ReminderService({
    required this.settings,
    Future<List<int>> Function()? loadIcon,
    ReminderApplier? apply,
    ReminderRemover? remove,
    String? exePath,
  })  : _loadIcon = loadIcon ?? loadBundledIcon,
        _apply = apply ?? _applyViaPlatform,
        _remove = remove ?? _removeViaPlatform,
        _exePath = exePath ?? platform.appExecutablePath;

  static Future<ReminderOutcome> _applyViaPlatform(
    ReminderTime time,
    List<int> weekdays,
    String diaryRoot,
    List<int> iconBytes,
  ) =>
      platform.applyReminder(
        time: time,
        weekdays: weekdays,
        diaryRoot: diaryRoot,
        iconBytes: iconBytes,
      );

  static Future<ReminderOutcome> _removeViaPlatform() =>
      platform.removeReminder();

  final SettingsController settings;
  final Future<List<int>> Function() _loadIcon;
  final ReminderApplier _apply;
  final ReminderRemover _remove;

  /// 当前程序本体的路径。指纹里要带上它（程序挪了位置就得重新注册）。
  final String _exePath;

  /// 打包进程序的那个 .ico。
  ///
  /// 注册表里的 `IconUri` 必须指向磁盘上的一个图标**文件**（exe 不行），
  /// 而程序自己的图标是编进 exe 资源里的、磁盘上没有这个文件——
  /// 所以要把它读出来写一份到设置目录。
  static const String iconAssetPath = 'windows/runner/resources/app_icon.ico';

  static Future<List<int>> loadBundledIcon() async {
    final data = await rootBundle.load(iconAssetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// 启用，或者改时间/改提醒日。**装成功了才把开关记下来**。
  @override
  Future<ReminderOutcome> enable(ReminderTime time, List<int> weekdays) async {
    final days = normalizeWeekdays(weekdays);
    final List<int> icon;
    try {
      icon = await _loadIcon();
    } catch (error) {
      return ReminderOutcome(ok: false, message: '读不到程序图标，无法启用：$error');
    }

    final outcome = await _apply(time, days, settings.settings.diaryRoot, icon);
    if (!outcome.ok) return outcome;

    await settings.noteReminder(
      enabled: true,
      time: time,
      weekdays: days,
      applied: fingerprintFor(time, days),
    );
    return outcome;
  }

  /// 停用。
  ///
  /// **不管系统那边删得顺不顺，设置里的开关都要关上**：否则界面会一直显示
  /// "已启用"，而用户已经点过关闭了。删不掉的部分会写进返回的消息里。
  @override
  Future<ReminderOutcome> disable() async {
    final outcome = await _remove();
    await settings.noteReminder(
      enabled: false,
      time: settings.reminderTime,
      weekdays: settings.reminderWeekdays,
      applied: null,
      // "今天提醒过"是跟着"开着"才有意义的：当天关掉又开回来，到点该照样提醒
      clearLastShown: true,
    );
    return outcome;
  }

  /// 启动时对一次账：指纹不一致就重装一遍。
  ///
  /// 会不一致的情况：改了时间或提醒日、换了日记目录、把程序挪了位置、用户手工把任务
  /// 删了。一致时**一次子进程都不起**，所以它对启动没有代价。
  ///
  /// 失败**不打扰用户**（返回出去由调用方决定要不要记）：下次启动会再试。
  /// 这里不重试到成功，是因为"提醒"不值得让启动卡住或者弹窗。
  Future<ReminderOutcome?> syncOnStartup() async {
    if (!platform.supportsReminder) return null;
    if (!settings.reminderEnabled) return null;

    final time = settings.reminderTime;
    final days = settings.reminderWeekdays;
    if (settings.reminderApplied == fingerprintFor(time, days)) return null;

    final List<int> icon;
    try {
      icon = await _loadIcon();
    } catch (_) {
      return const ReminderOutcome(ok: false, message: '读不到程序图标。');
    }

    final outcome = await _apply(time, days, settings.settings.diaryRoot, icon);
    if (outcome.ok) {
      await settings.noteReminder(
        enabled: true,
        time: time,
        weekdays: days,
        applied: fingerprintFor(time, days),
      );
    }
    return outcome;
  }

  /// 当前设置对应的指纹。见 `AppSettings.reminderApplied`。
  String fingerprintFor(ReminderTime time, Iterable<int> weekdays) =>
      reminderFingerprint(
        time: time,
        weekdays: weekdays,
        diaryRoot: settings.settings.diaryRoot,
        exePath: _exePath,
      );
}
