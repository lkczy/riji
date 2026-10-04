import 'dart:convert';

import '../core/editor_typography.dart';
import '../platform/platform.dart' as platform;

/// 界面外观偏好。
///
/// 刻意在这里自定义枚举、而不是直接用 Flutter 的 `ThemeMode`：
/// 这样 data 层依然不需要依赖 Flutter，偏好逻辑可以用纯 Dart 测试。
enum AppThemeMode {
  system('system'),
  light('light'),
  dark('dark');

  const AppThemeMode(this.storageValue);

  final String storageValue;

  /// 读到不认识的值（例如更高版本的程序写入的）时退回「跟随系统」，
  /// 而不是抛异常导致程序打不开。
  static AppThemeMode fromStorage(Object? value) {
    for (final mode in values) {
      if (mode.storageValue == value) return mode;
    }
    return AppThemeMode.system;
  }
}

/// 程序设置。与日记数据分开存放，因为日记根目录本身就是可配置的。
///
/// 刻意只存「程序需要知道、而日记文件本身不包含」的东西。
/// 例如「上次看到哪一天」就不存：启动本来就该打开今天，
/// 存了只是多一处可能写坏的状态，也多一个测试会污染真实配置的入口。
///
/// 唯一一处按这条标准仍然要存的是 [lastSeenVersion]：它没有别的来源，
/// 而"只在升级后弹一次"这件事离开持久化就做不到。见那个字段的注释。
class AppSettings {
  const AppSettings({
    required this.diaryRoot,
    this.themeMode = AppThemeMode.system,
    this.typography = EditorTypography.defaults,
    this.backupRoot,
    this.lastBackupAt,
    this.lastBackupError,
    this.lastSeenVersion,
  });

  final String diaryRoot;
  final AppThemeMode themeMode;
  final EditorTypography typography;

  /// 备份目标目录。null 表示**还没设置**——界面必须据此说清"为什么还不能备份"，
  /// 而不是给一个点了没反应的按钮，也不能偷偷用默认值：
  /// 备份落在哪里是用户该知道的事。
  final String? backupRoot;

  final DateTime? lastBackupAt;

  /// 上一次备份失败的原因。
  ///
  /// 存在的意义是**跨启动可见**：自动备份在关程序时跑，那时候弹不出提示；
  /// 如果只写进日志，用户会以为备份一直是好的。
  final String? lastBackupError;

  /// 上一次启动时见到的版本号。用来判断"这次是不是刚从旧版升上来"。
  ///
  /// 为什么这一个字段值得破例存下来（见类注释里那条标准）：
  /// 「本版更新」只在**升级后的第一次启动**弹一次，而"上次见到的是哪一版"
  /// 没有第二个来源——不存就只能每次都弹，那比不弹更糟（用户会学会无脑点掉，
  /// 真正的提示反而被忽略）。
  ///
  /// null 表示**第一次装**：此时不弹（没有"上一版"可比），只把当前版本记下来。
  final String? lastSeenVersion;

  AppSettings copyWith({
    String? diaryRoot,
    AppThemeMode? themeMode,
    EditorTypography? typography,
    String? backupRoot,
    DateTime? lastBackupAt,
    String? lastBackupError,
    String? lastSeenVersion,
    bool clearBackupError = false,
  }) =>
      AppSettings(
        diaryRoot: diaryRoot ?? this.diaryRoot,
        themeMode: themeMode ?? this.themeMode,
        typography: typography ?? this.typography,
        backupRoot: backupRoot ?? this.backupRoot,
        lastBackupAt: lastBackupAt ?? this.lastBackupAt,
        lastBackupError:
            clearBackupError ? null : (lastBackupError ?? this.lastBackupError),
        lastSeenVersion: lastSeenVersion ?? this.lastSeenVersion,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'diaryRoot': diaryRoot,
        'themeMode': themeMode.storageValue,
        'typography': typography.toJson(),
        if (backupRoot != null) 'backupRoot': backupRoot,
        if (lastBackupAt != null)
          'lastBackupAt': lastBackupAt!.toIso8601String(),
        if (lastBackupError != null) 'lastBackupError': lastBackupError,
        if (lastSeenVersion != null) 'lastSeenVersion': lastSeenVersion,
      };

  static AppSettings fromJson(
    Map<String, dynamic> json, {
    required String fallbackRoot,
  }) {
    final root = json['diaryRoot'];
    final typographyJson = json['typography'];

    // 备份相关的字段全部按"读不动就当没有"处理。
    // 设置文件是程序自己写的，但它可能来自更高版本、也可能被手改过——
    // **绝不能因为一个字段解析失败就让程序打不开。**
    final backupRoot = json['backupRoot'];
    final backupAt = json['lastBackupAt'];
    final backupError = json['lastBackupError'];
    final lastSeen = json['lastSeenVersion'];

    return AppSettings(
      diaryRoot:
          root is String && root.trim().isNotEmpty ? root : fallbackRoot,
      themeMode: AppThemeMode.fromStorage(json['themeMode']),
      typography: EditorTypography.fromJson(
        typographyJson is Map<String, dynamic> ? typographyJson : null,
      ),
      backupRoot: backupRoot is String && backupRoot.trim().isNotEmpty
          ? backupRoot
          : null,
      lastBackupAt: backupAt is String ? DateTime.tryParse(backupAt) : null,
      lastBackupError:
          backupError is String && backupError.trim().isNotEmpty
              ? backupError
              : null,
      // 读不懂就当第一次装：**少弹一次**永远比弹错好
      lastSeenVersion:
          lastSeen is String && lastSeen.trim().isNotEmpty ? lastSeen : null,
    );
  }
}

class SettingsRepository {
  const SettingsRepository();

  Future<AppSettings> load() async {
    final fallbackRoot = platform.defaultDiaryRoot;
    final raw = await platform.readSettingsJson();
    if (raw == null) return AppSettings(diaryRoot: fallbackRoot);

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return AppSettings.fromJson(decoded, fallbackRoot: fallbackRoot);
      }
    } catch (_) {
      // 设置文件损坏时退回默认值。绝不能因为设置坏了就打不开程序。
    }
    return AppSettings(diaryRoot: fallbackRoot);
  }

  Future<void> save(AppSettings settings) async {
    try {
      await platform.writeSettingsJson(jsonEncode(settings.toJson()));
    } catch (_) {
      // 设置存不下来不影响写日记
    }
  }
}
