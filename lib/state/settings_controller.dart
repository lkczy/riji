import 'package:flutter/material.dart';

import '../core/editor_typography.dart';
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
}
