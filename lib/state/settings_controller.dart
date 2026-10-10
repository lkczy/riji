import 'package:flutter/material.dart';

import '../core/editor_typography.dart';
import '../core/reminder.dart';
import '../data/settings.dart';

/// 程序级偏好的持有者。
///
/// 刻意**不放进 [DiaryController]**：那个类负责日记内容、自动保存、草稿，
/// 已经够忙了。外观、以后的字号、起始视图这类偏好是另一件事，
/// 混在一起会让 DiaryController 慢慢变成一个杂物间。
class SettingsController extends ChangeNotifier {
  SettingsController({
    required AppSettings initial,
    this.repository = const SettingsRepository(),
  }) : _settings = initial;

  final SettingsRepository repository;
  AppSettings _settings;

  AppSettings get settings => _settings;

  AppThemeMode get themeMode => _settings.themeMode;

  EditorTypography get typography => _settings.typography;

  /// 映射成 Flutter 认识的模式。界面只跟这个值打交道。
  ThemeMode get materialThemeMode => switch (_settings.themeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };

  Future<void> setThemeMode(AppThemeMode mode) async {
    if (mode == _settings.themeMode) return;
    _settings = _settings.copyWith(themeMode: mode);
    // 先通知再落盘：界面立刻响应，磁盘写入不该让用户等
    notifyListeners();
    await repository.save(_settings);
  }

  /// 记下新的日记位置。
  ///
  /// 只负责持久化——真正换存储、重新加载发生在引导层，
  /// 因为那需要重建 DiaryController，不是偏好设置该管的事。
  Future<void> setDiaryRoot(String root) async {
    final normalized = root.trim();
    if (normalized.isEmpty || normalized == _settings.diaryRoot) return;
    _settings = _settings.copyWith(diaryRoot: normalized);
    notifyListeners();
    await repository.save(_settings);
  }

  /// 调整编辑器排版。拖动滑块时会连续调用，所以每次都要落盘——
  /// 中途关掉程序也不该丢掉刚调好的字号。
  Future<void> setTypography(EditorTypography typography) async {
    if (typography == _settings.typography) return;
    _settings = _settings.copyWith(typography: typography);
    notifyListeners();
    await repository.save(_settings);
  }

  Future<void> resetTypography() =>
      setTypography(EditorTypography.defaults);

  // ---------------------------------------------------------------------------
  // 备份
  // ---------------------------------------------------------------------------

  String? get backupRoot => _settings.backupRoot;
  DateTime? get lastBackupAt => _settings.lastBackupAt;
  String? get lastBackupError => _settings.lastBackupError;

  /// 设置备份位置。传 null 表示"取消设置"。
  Future<void> setBackupRoot(String? root) async {
    final normalized = root?.trim();
    if (normalized == null || normalized.isEmpty) {
      if (_settings.backupRoot == null) return;
      _settings = AppSettings(
        diaryRoot: _settings.diaryRoot,
        themeMode: _settings.themeMode,
        typography: _settings.typography,
      );
    } else {
      if (normalized == _settings.backupRoot) return;
      _settings = _settings.copyWith(backupRoot: normalized);
    }
    notifyListeners();
    await repository.save(_settings);
  }

  /// 记下一次成功的备份。
  ///
  /// 顺带**清掉上次的错误**：错误提示必须反映"现在还有没有问题"，
  /// 一直挂着一条已经消失的失败，用户下次就会开始无视它。
  Future<void> noteBackupSucceeded(DateTime at) async {
    _settings = _settings.copyWith(
      lastBackupAt: at,
      clearBackupError: true,
    );
    notifyListeners();
    await repository.save(_settings);
  }

  /// 记下一次失败的备份。**不动 [lastBackupAt]**——上一次成功的时间仍然是
  /// 事实，把它抹掉只会让"多久没备份了"这个判断失真。
  Future<void> noteBackupFailed(String message) async {
    _settings = _settings.copyWith(lastBackupError: message);
    notifyListeners();
    await repository.save(_settings);
  }

  /// 用户看过了失败原因，关掉它。备份位置还在，只是不再顶着。
  Future<void> dismissBackupError() async {
    if (_settings.lastBackupError == null) return;
    _settings = _settings.copyWith(clearBackupError: true);
    notifyListeners();
    await repository.save(_settings);
  }

  // ---------------------------------------------------------------------------
  // 「本版更新」
  // ---------------------------------------------------------------------------

  /// 上一次启动时见到的版本号。null 表示第一次装。
  String? get lastSeenVersion => _settings.lastSeenVersion;

  /// 记下「这个版本已经见过了」。
  ///
  /// **无论弹窗弹没弹都要记**：记不下来的话用户每次启动都会被问一遍——
  /// 那是最糟的失败方式，因为用户会学会无脑点掉，真正的提示反而被忽略。
  Future<void> noteVersionSeen(String version) async {
    final normalized = version.trim();
    if (normalized.isEmpty || normalized == _settings.lastSeenVersion) return;
    _settings = _settings.copyWith(lastSeenVersion: normalized);
    notifyListeners();
    await repository.save(_settings);
  }

  // ---------------------------------------------------------------------------
  // 每日提醒
  // ---------------------------------------------------------------------------

  bool get reminderEnabled => _settings.reminderEnabled;

  /// 提醒时间。**存坏了就退回默认值**，不会让整个设置读不出来。
  ReminderTime get reminderTime =>
      ReminderTime.tryParse(_settings.reminderTime) ?? ReminderTime.defaultTime;

  /// 提醒日（1=周一 … 7=周日），默认每天。
  List<int> get reminderWeekdays => _settings.reminderWeekdays;

  /// 进入程序时是否要求口令。
  bool get appLockEnabled => _settings.appLockEnabled;

  /// 闲置多少分钟自动重新锁定（0 = 从不）。
  int get appLockIdleMinutes => _settings.appLockIdleMinutes;

  /// 「程序锁挡不住直接看文件的人」那段说明弹过没有。
  bool get appLockNoticeShown => _settings.appLockNoticeShown;

  Future<void> setAppLock({
    bool? enabled,
    int? idleMinutes,
    bool? noticeShown,
  }) async {
    _settings = _settings.copyWith(
      appLockEnabled: enabled,
      appLockIdleMinutes: idleMinutes,
      appLockNoticeShown: noticeShown,
    );
    notifyListeners();
    await repository.save(_settings);
  }

  /// 上一次成功装进系统时的指纹。见 [AppSettings.reminderApplied]。
  String? get reminderApplied => _settings.reminderApplied;

  /// 上一次程序内提醒是哪一天（`2026-10-08`）。见 [AppSettings.reminderLastShown]。
  DateTime? get reminderLastShown {
    final raw = _settings.reminderLastShown;
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// 记下"今天已经在程序里提醒过了"。
  ///
  /// 记的是日期字符串：一天最多提醒一次，跟用户几点看到的无关。
  Future<void> noteReminderShown(DateTime day) async {
    final key = reminderDayKey(day);
    if (_settings.reminderLastShown == key) return;
    _settings = _settings.copyWith(reminderLastShown: key);
    notifyListeners();
    await repository.save(_settings);
  }

  /// 记下开关、时间和指纹。
  ///
  /// 三样一起写是因为它们**必须同时改变**：开关动了而指纹没动，启动时就不会
  /// 重装；时间动了而指纹没动，系统里跑的还是旧时间。
  Future<void> noteReminder({
    required bool enabled,
    required ReminderTime time,
    required List<int> weekdays,
    required String? applied,
    bool clearLastShown = false,
  }) async {
    _settings = _settings.copyWith(
      reminderEnabled: enabled,
      reminderTime: time.label,
      reminderWeekdays: normalizeWeekdays(weekdays),
      reminderApplied: applied,
      clearReminderApplied: applied == null,
      // 停用时把"今天提醒过"也清掉：当天重新启用的话，到点该照样提醒
      clearReminderLastShown: clearLastShown,
    );
    notifyListeners();
    await repository.save(_settings);
  }
}
