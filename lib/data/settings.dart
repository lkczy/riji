import 'dart:convert';

import '../core/editor_typography.dart';
import '../core/reminder.dart';
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
    this.reminderEnabled = false,
    this.reminderTime = '21:00',
    this.reminderWeekdays = allWeekdays,
    this.reminderApplied,
    this.appLockEnabled = false,
    this.appLockIdleMinutes = 10,
    this.appLockNoticeShown = false,
    this.reminderLastShown,
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

  /// 每日提醒开关。**默认关**。
  ///
  /// 打开它意味着往用户系统里写东西（计划任务 + 两个注册表项 + 一个脚本），
  /// 这种事必须用户自己点，程序不能替他决定。
  final bool reminderEnabled;

  /// 提醒时间，`"21:00"` 这样的人能看懂的写法。
  ///
  /// 存字符串而不是存时分两个整数：settings.json 是给人看的，
  /// 而且时间格式坏了的时候要能一眼看出来是哪儿坏了。解析走
  /// `ReminderTime.tryParse`，非法就退回默认值（**不会让设置读不出来**）。
  final String reminderTime;

  /// 上一次**成功**装进系统时的指纹（时间 + 日记目录 + 程序路径）。
  ///
  /// 和当前值不一致就重装一遍：这样改了时间、换了日记目录、把程序挪了位置、
  /// 或者用户手工把计划任务删了，都能在下次启动时自己修好；
  /// 而一致的时候一次子进程都不用起。
  ///
  /// 只在**全部成功**之后才写它——写早了会让失败的那次被误认为"已经装好了"。
  final String? reminderApplied;

  /// 提醒日：一周里哪几天提醒，值是 `DateTime.weekday`（1=周一 … 7=周日）。
  ///
  /// 默认**每天**（七个都在）。`toJson` 里是完整七天时**不写这个字段**：
  /// 默认值不该占用户的配置文件，也让"手改过"一眼看得出来。
  ///
  /// 存成数组而不是位掩码或 `"1,2,3"` 字符串：settings.json 是给人看的，
  /// 数组在编辑器里能看懂，坏了一眼也看得出坏在哪。
  final List<int> reminderWeekdays;

  /// 进入程序时是否要求口令（"程序锁"）。**默认关**。
  ///
  /// 为什么它和加密是两件事：加密防的是"文件被拿走"，程序锁防的是
  /// "别人用你已登录的电脑点开这个程序"。**程序锁挡不住会绕过程序去翻文件的人**
  /// ——所以它是栅栏，不是保险柜，界面上必须写清。
  final bool appLockEnabled;

  /// 闲置多少分钟自动重新锁定。0 = 从不。
  final int appLockIdleMinutes;

  /// 「程序锁挡不住直接看文件的人」那段说明有没有弹过。
  /// 只弹一次：每次都弹就成了噪音，一次都不弹又会让人误以为它等于全盘加密。
  final bool appLockNoticeShown;

  /// 上一次**程序内**提醒是哪一天（`2026-10-08`）。
  ///
  /// 为什么需要它：程序内的检查是每几秒跑一次的轮询，"到点了"这个条件会一直
  /// 成立到当天结束——不记下来的话它会一直弹。记的是**日期**不是时间：
  /// 一天最多提醒一次，跟用户是几点看到的无关。
  final String? reminderLastShown;

  AppSettings copyWith({
    String? diaryRoot,
    AppThemeMode? themeMode,
    EditorTypography? typography,
    String? backupRoot,
    DateTime? lastBackupAt,
    String? lastBackupError,
    String? lastSeenVersion,
    bool? reminderEnabled,
    String? reminderTime,
    List<int>? reminderWeekdays,
    String? reminderApplied,
    bool? appLockEnabled,
    int? appLockIdleMinutes,
    bool? appLockNoticeShown,
    String? reminderLastShown,
    bool clearReminderApplied = false,
    bool clearReminderLastShown = false,
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
        reminderEnabled: reminderEnabled ?? this.reminderEnabled,
        reminderTime: reminderTime ?? this.reminderTime,
        reminderWeekdays: normalizeWeekdays(reminderWeekdays ?? this.reminderWeekdays),
        reminderApplied: clearReminderApplied
            ? null
            : (reminderApplied ?? this.reminderApplied),
        // 这里必须是 `?? this.xxx`。写成 fromJson 那种 `== true` / `: 10`，
        // 会让**任何** copyWith（改主题、改备份目录……）都把程序锁重置掉——
        // 用户实测到的"选了 5 分钟，整段自己关掉"就是这么来的。
        appLockEnabled: appLockEnabled ?? this.appLockEnabled,
        appLockIdleMinutes: appLockIdleMinutes ?? this.appLockIdleMinutes,
        appLockNoticeShown: appLockNoticeShown ?? this.appLockNoticeShown,
        reminderLastShown: clearReminderLastShown
            ? null
            : (reminderLastShown ?? this.reminderLastShown),
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
        if (reminderEnabled) 'reminderEnabled': true,
        if (reminderTime != '21:00') 'reminderTime': reminderTime,
        // 七天都在就是默认值，不写进文件
        if (normalizeWeekdays(reminderWeekdays).length != allWeekdays.length)
          'reminderWeekdays': normalizeWeekdays(reminderWeekdays),
        if (reminderApplied != null) 'reminderApplied': reminderApplied,
        if (appLockEnabled) 'appLockEnabled': true,
        if (appLockIdleMinutes != 10) 'appLockIdleMinutes': appLockIdleMinutes,
        if (appLockNoticeShown) 'appLockNoticeShown': true,
        if (reminderLastShown != null) 'reminderLastShown': reminderLastShown,
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
    final reminderOn = json['reminderEnabled'];
    final reminderAt = json['reminderTime'];
    final reminderApplied = json['reminderApplied'];
    final reminderWeekdays = json['reminderWeekdays'];
    final appLockEnabled = json['appLockEnabled'];
    final appLockIdleMinutes = json['appLockIdleMinutes'];
    final appLockNoticeShown = json['appLockNoticeShown'];
    final reminderLastShown = json['reminderLastShown'];

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
      // 同样按"读不动就当没有"：开关只在明确是 true 时才开
      reminderEnabled: reminderOn == true,
      // 时间坏了退回默认值，**不要**因此丢掉其它设置
      reminderTime: ReminderTime.tryParse(reminderAt is String ? reminderAt : null)
              ?.label ??
          ReminderTime.defaultTime.label,
      // 读进来一堆垃圾（空数组、越界值、手改坏了）→ 退回"每天"，
      // **绝不**让提醒变成一个莫名其妙的状态（比如只提醒周日）
      reminderWeekdays: normalizeWeekdays(
        reminderWeekdays is List
            ? reminderWeekdays.whereType<int>()
            : null,
      ),
      reminderApplied: reminderApplied is String &&
              reminderApplied.trim().isNotEmpty
          ? reminderApplied
          : null,
      appLockEnabled: appLockEnabled == true,
      appLockIdleMinutes: appLockIdleMinutes is int && appLockIdleMinutes >= 0
          ? appLockIdleMinutes
          : 10,
      appLockNoticeShown: appLockNoticeShown == true,
      reminderLastShown: reminderLastShown is String &&
              reminderLastShown.trim().isNotEmpty
          ? reminderLastShown
          : null,
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
