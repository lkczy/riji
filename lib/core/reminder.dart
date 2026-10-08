/// 每日提醒：时间、发给系统的命令、以及那个要落地的 PowerShell 脚本。
///
/// 这一层**只生成文本，不执行任何东西**——真正跑命令的是 `lib/platform/`。
/// 分开的理由很实际：跑命令会改用户的系统（注册表、计划任务），测试里不能跑；
/// 而"到底发了什么命令"恰恰是最该被断言的东西，所以命令得能从纯函数里拿出来。
library;

import 'day.dart';
import 'models/diary_entry.dart';

/// 计划任务的名字。
///
/// ⚠️ **必须是 ASCII**：任务名会被 `schtasks`/PowerShell 的输出带回来，
/// 而子进程的 stdout 是按系统 ANSI 代码页解码的，中文会变成乱码。
/// 程序自己写进去的时候是好的，读回来的时候是坏的——所以两边只用 ASCII。
const String reminderTaskName = 'riji-reminder';

/// 通知的归属 ID（AppUserModelID）。
///
/// 通知显示成「日迹」而不是某个进程名，靠的就是这个名字对应的注册表项。
/// 实测过：写 `HKCU\SOFTWARE\Classes\AppUserModelId\lkczy.riji` 形状照
/// PowerToys / 罗技那两个项抄，通知左上角就显示「日迹」+ 程序图标。
const String reminderAppId = 'lkczy.riji';

/// 自定义协议：点通知能回到日记。
const String reminderProtocol = 'riji';

/// 点通知时打开的地址。
const String reminderActivationUrl = 'riji://today';

/// 提醒装进 / 撤出系统的结果。`message` 是直接给用户看的一句话。
class ReminderOutcome {
  const ReminderOutcome({required this.ok, required this.message});

  final bool ok;
  final String message;

  @override
  String toString() => 'ReminderOutcome(ok: $ok, $message)';
}

/// 提醒时间，存成 `"21:00"` 这样人能看懂的字符串（settings.json 是给人看的）。
class ReminderTime {
  const ReminderTime(this.hour, this.minute);

  final int hour;
  final int minute;

  /// 默认 21:00。晚上九点：一天还没过完，但已经过了"等会儿再写"的时间。
  static const ReminderTime defaultTime = ReminderTime(21, 0);

  /// 解析 `"21:00"`、`"9:5"`、`" 21:00 "`；非法返回 null。
  ///
  /// **不抛异常、也不猜**：调用方自己决定是退回默认值还是提示用户。
  /// 一个坏的时间字符串不该让设置整个读不出来（那样用户的日记目录也会丢）。
  static ReminderTime? tryParse(String? text) {
    if (text == null) return null;
    final match = RegExp(r'^\s*(\d{1,2})\s*:\s*(\d{1,2})\s*$').firstMatch(text);
    if (match == null) return null;
    final hour = int.tryParse(match.group(1)!);
    final minute = int.tryParse(match.group(2)!);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return ReminderTime(hour, minute);
  }

  /// `"21:00"`。补零，喂给计划任务的 `/ST` 也用它。
  String get label =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) =>
      other is ReminderTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() => label;
}

/// 一周七天，按**周一到周日**的顺序，值就是 `DateTime.weekday`（1–7）。
///
/// 全项目统一用这个顺序和这套值：日历表头、提醒日的选择、"今天写过没有"。
/// 别的地方出现 0=周日 的写法（比如 .NET 的 `DayOfWeek`）只许在**拼命令**那一刻出现。
const List<int> allWeekdays = <int>[1, 2, 3, 4, 5, 6, 7];

/// 星期几的单字标签，和 [allWeekdays] 一一对应。
const List<String> weekdayLabels = <String>['一', '二', '三', '四', '五', '六', '日'];

/// `.NET DayOfWeek` 的名字，按 [allWeekdays] 的顺序。
///
/// 拼计划任务命令时才用：`New-ScheduledTaskTrigger -DaysOfWeek Monday,Tuesday`。
/// ⚠️ 这个名字和界面上那一行**不是一回事**：.NET 里 0 是周日，顺序也不一样，
/// 所以中间必须有这个映射，不能直接拿 `DateTime.weekday` 去索引。
const List<String> _psWeekdayNames = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// 某一天是不是提醒日。空集合按"没选"处理（不该发生，但比默认全提醒安全）。
bool isReminderDay(Iterable<int> weekdays, DateTime day) =>
    weekdays.contains(day.weekday);

/// 把提醒日整理成能存进设置、能比较的形式：去重、排序、丢掉非法值。
///
/// **设置文件可能被手改**，所以这里必须容错：读进来一堆垃圾时宁可退回"每天"，
/// 也不要让提醒变成一个莫名其妙的状态（比如只提醒周日）。
List<int> normalizeWeekdays(Iterable<int>? raw) {
  if (raw == null) return List<int>.from(allWeekdays);
  final picked = raw.where((day) => day >= 1 && day <= 7).toSet().toList()
    ..sort();
  // 一个都没剩下（空数组、全是垃圾值）→ 按默认的"每天"
  return picked.isEmpty ? List<int>.from(allWeekdays) : picked;
}

/// 把"时间 + 提醒日"说成一句人能读的话。
///
/// `每天 21:00` / `工作日 21:00` / `周末 21:00` / `周一、周三 21:00`。
/// 放在纯逻辑层是因为它是**从数据推出来的文案**，界面和平台层的成功消息
/// 都用它——两处各写一遍迟早会不一致。
String reminderScheduleLabel(ReminderTime time, Iterable<int> weekdays) {
  final days = normalizeWeekdays(weekdays);
  final String when;
  if (days.length == allWeekdays.length) {
    when = '每天';
  } else if (days.length == 5 && days.every((day) => day <= 5)) {
    when = '工作日';
  } else if (days.length == 2 && days.contains(6) && days.contains(7)) {
    when = '周末';
  } else {
    when = days.map((day) => '周${weekdayLabels[day - 1]}').join('、');
  }
  return '$when ${time.label}';
}

/// 提醒装进系统时的"指纹"。
///
/// 存进设置里，启动时比一下：不一致就重装。这样日记目录改了、程序换了位置、
/// **提醒日改了**、或者用户手工把任务删了，都能自己修好——而一致的时候
/// 一次子进程都不用起。
String reminderFingerprint({
  required ReminderTime time,
  required Iterable<int> weekdays,
  required String diaryRoot,
  required String exePath,
}) =>
    'v1|${time.label}|${normalizeWeekdays(weekdays).join(',')}|$diaryRoot|$exePath';

/// 某一天的键，`2026-10-08`。用来记"这一天已经提醒过了"。
///
/// 自己拼而不是用 `DateTime.toIso8601String().substring(0,10)`：后者在
/// 意图上不明显，而且时区一变就悄悄错一天。这里只要年月日。
String reminderDayKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// 某一天**写过没有**。
///
/// 定义来自 `DiaryEntry.isEmpty`（正文去空白、心情、天气、标签**全都**空才算空），
/// 和面板、日历用的是同一套。⚠️ 和侧栏那个「今天（已写）」徽标不一样——那个看的是
/// "有没有这个文件"，一个空 `.md` 会让两者答案相反（见 docs/详细说明.md）。
///
/// 为什么要 [currentEntryEmpty] 这个参数：正在写的那一天，内容还在编辑器里、
/// 未必已经落盘。所以"当前打开的就是今天"时要先问编辑器。
bool dayHasContent({
  required DateTime day,
  required DateTime selectedDate,
  required bool currentEntryEmpty,
  required Iterable<DiaryEntry> entries,
}) {
  if (isSameDay(selectedDate, day) && !currentEntryEmpty) return true;
  for (final entry in entries) {
    if (isSameDay(entry.date, day)) return !entry.isEmpty;
  }
  return false;
}

/// 程序**正在运行**时该不该弹程序内提醒。
///
/// 两条路径的分工（这也是计划任务里那个 `Get-Process riji` 判断的依据）：
/// - 程序开着 → 由程序自己提醒。不用为了发条通知再交接一次进程。
/// - 程序没开 → 由计划任务发 Windows 通知。这时候没人能弹窗，只有系统通知
///   能留在通知中心等你回来。
///
/// 条件里最值得注意的是 [appStartedAt]：**只有"到点的那一刻程序已经在跑"
/// 才提醒**。如果程序是 22:00 才打开的（那时候 21:00 早就过了），不该一开就
/// 弹一个"今天还没写"——用户打开程序本来就是为了写。
bool shouldRemindInApp({
  required DateTime now,
  required DateTime appStartedAt,
  required ReminderTime time,
  required Iterable<int> weekdays,
  required bool enabled,
  required bool todayWritten,
  required DateTime? lastShownDay,
}) {
  if (!enabled) return false;
  // 今天不在提醒日里 → 什么都不做（计划任务那天也不会触发，两条路径要一致）
  if (!isReminderDay(normalizeWeekdays(weekdays), now)) return false;
  if (todayWritten) return false;
  if (lastShownDay != null &&
      reminderDayKey(lastShownDay) == reminderDayKey(now)) {
    return false;
  }

  final due = DateTime(now.year, now.month, now.day, time.hour, time.minute);
  if (now.isBefore(due)) return false;
  // 程序是在到点之后才起来的 → 这次不由程序提醒（打开程序就是为了写东西）
  return appStartedAt.isBefore(due);
}

// -----------------------------------------------------------------------------
// 要落地的那个 PowerShell 脚本
// -----------------------------------------------------------------------------

/// 生成提醒脚本的正文。
///
/// 脚本只做一件事：**今天还没写、而且程序没在跑的时候**发一条 Windows 通知。
/// 判断留给它自己，是因为计划任务到点就触发，而"今天写没写""程序在不在"
/// 只有到那一刻才知道。
///
/// 占位符用 `__XXX__` 而不是 Dart 插值：正文里全是 PowerShell 的 `$变量`，
/// 用 `$` 插值会打成一团。占位符替换也顺便让"路径里有单引号"这种边角可控。
String buildReminderScript({required String diaryRoot, required String exeName}) {
  var script = _scriptTemplate;
  script = script.replaceAll('__ROOT__', _psSingleQuoted(diaryRoot));
  script = script.replaceAll('__APP_ID__', reminderAppId);
  script = script.replaceAll('__URL__', reminderActivationUrl);
  script = script.replaceAll('__DATE__', _scriptDateLiteral);
  script = script.replaceAll('__EXE_NAME__', _psSingleQuoted(exeName));
  return script;
}

/// 脚本里取当天日期用的格式化字符串。
///
/// **不走 `Get-Date -Format`**：那个用的当前区域设置，某些区域（比如泰历）
/// 会给出非公历年份，于是拼出来的文件名永远不存在——而"文件不存在"在提醒
/// 逻辑里的含义是"今天没写"，表现就是**每天都提醒，无论写没写**。
const String _scriptDateLiteral = 'yyyy-MM-dd';

/// 拼进 PowerShell 单引号字符串里。
String _psSingleQuoted(String value) => "'${value.replaceAll("'", "''")}'";

/// 脚本体。`__XXX__` 是占位符，见 [buildReminderScript]。
const String _scriptTemplate = r'''
# 日迹 · 每日提醒。这个文件由程序生成，改动会在下次启用时被覆盖。
#
# 用法：
#   powershell -File remind.ps1              正常执行（计划任务就是这么调的）
#   powershell -File remind.ps1 -DryRun       只打印"今天写没写"，不发通知
#   powershell -File remind.ps1 -DryRun -Root D:\some\where   换一个日记目录来验
param(
  [switch]$DryRun,
  [string]$Root
)

$ErrorActionPreference = 'Stop'
$appId = '__APP_ID__'
$url = '__URL__'
$root = if ($Root) { $Root } else { __ROOT__ }

# 「今天写没写」的判定。**必须和程序里的 DiaryEntry.isEmpty 对齐**：
# 正文（去掉空白后）非空，或者 mood / weather / tags 有一项非空。
function Test-RijiWritten([string]$dir, [string]$date) {
  $file = Join-Path (Join-Path $dir $date.Substring(0, 4)) ($date + '.md')
  if (-not (Test-Path -LiteralPath $file)) { return $false }

  $text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
  $front = ''
  $body = $text
  if ($text.StartsWith('---')) {
    # 文件是手工写的就可能没有 front matter，所以认不出就整篇当正文
    $end = $text.IndexOf("`n---", 3)
    if ($end -ge 0) {
      $front = $text.Substring(0, $end)
      $next = $text.IndexOf("`n", $end + 1)
      if ($next -ge 0) { $body = $text.Substring($next + 1) }
    }
  }
  if ($body.Trim().Length -gt 0) { return $true }

  foreach ($key in @('mood', 'weather')) {
    $m = [regex]::Match($front, '(?m)^' + $key + ':\s*(.+)$')
    if ($m.Success -and $m.Groups[1].Value.Trim().Length -gt 0) { return $true }
  }
  $tags = [regex]::Match($front, '(?m)^tags:\s*(.*)$')
  if ($tags.Success) {
    if ($tags.Groups[1].Value.Trim().Length -gt 0) { return $true }
    # tags: 后面换行跟一串 "  - xxx"
    if ([regex]::IsMatch($front, '(?m)^\s+-\s*\S')) { return $true }
  }
  return $false
}

try {
  # 日期一定用固定区域格式化：见程序里 _scriptDateLiteral 的注释
  $today = (Get-Date).ToString('__DATE__', [System.Globalization.CultureInfo]::InvariantCulture)
  $written = Test-RijiWritten $root $today

  # 程序正在跑吗？在跑就**不发通知**，交给程序自己弹提醒（见程序里
  # shouldRemindInApp 的注释：两条路径只能响一次）。
  #
  # 查不出来时按"没在跑"处理——**宁可多弹一条通知，也不要一条都不弹**。
  $appRunning = $false
  try {
    $appRunning = @(Get-Process -Name __EXE_NAME__ -ErrorAction SilentlyContinue).Count -gt 0
  } catch {
    $appRunning = $false
  }

  if ($DryRun) {
    Write-Output ('date=' + $today + ' written=' + $written + ' appRunning=' + $appRunning)
    exit 0
  }
  if ($written) { exit 0 }
  if ($appRunning) { exit 0 }

  # 真的发通知。归属显示成「日迹」靠的是 AppUserModelId 注册表项。
  [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
  [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime] | Out-Null

  $xml = @"
<toast activationType="protocol" launch="$url">
  <visual>
    <binding template="ToastGeneric">
      <text>今天还没写日记</text>
      <text>点一下打开今天的日记</text>
    </binding>
  </visual>
  <actions>
    <action content="打开日记" activationType="protocol" arguments="$url" />
  </actions>
</toast>
"@

  $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
  $doc.LoadXml($xml)
  $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
  # 同一天万一触发了两次，第二条顶掉第一条，而不是叠两条
  $toast.Tag = 'riji-daily'
  $toast.Group = 'riji'
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
} catch {
  # 提醒失败绝不弹错、绝不打扰。留一行日志，够排查就行。
  try {
    $log = Join-Path $env:TEMP 'riji-remind.log'
    ('{0}  {1}' -f (Get-Date).ToString('s'), $_.Exception.Message) |
      Out-File -FilePath $log -Append -Encoding utf8
  } catch { }
  exit 0
}
''';

// -----------------------------------------------------------------------------
// 发给系统的命令
// -----------------------------------------------------------------------------
//
// 这些函数只拼字符串。测试断言的就是它们——"到底往用户系统里写了什么"
// 不能靠人肉 review。

/// 注册/更新计划任务的那段 PowerShell（放进 `-Command` 里跑）。
///
/// **按周指定提醒日**，而不是每天触发 + 脚本自己判断星期几：
/// ① 没选的那天 Windows 根本不会启动它——省一次进程，而且"哪天会提醒"
///    在任务计划程序里**一眼看得见**，不用去读脚本；
/// ② 提醒日就只有这一个真相来源，脚本里不必再存一份。
///
/// 用 ScheduledTasks 模块而不是 `schtasks.exe`：只有它能设
/// `StartWhenAvailable`（**睡眠错过 21:00 之后补跑**，笔记本上这是常态），
/// 也才方便按周选日；非管理员就能注册，实测过。
String buildRegisterTaskCommand({
  required ReminderTime time,
  required Iterable<int> weekdays,
  required String scriptPath,
}) {
  // 计划任务的动作：起一个隐藏窗口的 PowerShell 跑提醒脚本。
  // 路径用双引号包住，因为日记目录/程序目录都可能带空格。
  final actionArgument = '-NoProfile -NonInteractive -WindowStyle Hidden '
      '-ExecutionPolicy Bypass -File "$scriptPath"';

  final days = normalizeWeekdays(weekdays)
      .map((day) => _psSingleQuoted(_psWeekdayNames[day - 1]))
      .join(',');

  return <String>[
    r"$ErrorActionPreference = 'Stop'",
    r'$action = New-ScheduledTaskAction -Execute ' +
        _psSingleQuoted('powershell.exe') +
        r' -Argument ' +
        _psSingleQuoted(actionArgument),
    r'$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek ' +
        days +
        r' -At ' +
        _psSingleQuoted(time.label),
    r'$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable '
        r'-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries',
    r'Register-ScheduledTask -TaskName ' +
        _psSingleQuoted(reminderTaskName) +
        r' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null',
  ].join('; ');
}

/// 删除计划任务。
String buildUnregisterTaskCommand() =>
    r"Unregister-ScheduledTask -TaskName " +
    _psSingleQuoted(reminderTaskName) +
    r' -Confirm:$false -ErrorAction SilentlyContinue';

/// 通知归属：让 Windows 知道 `lkczy.riji` 这个 AppID 叫什么、用什么图标。
///
/// 形状照本机 PowerToys / 罗技那两个项抄的：`DisplayName` + `IconUri`
/// （指向一个 **.ico/.png 文件**，不是 exe）+ `IconBackgroundColor`。
String buildAppModelIdCommand({
  required String appId,
  required String displayName,
  required String iconPath,
}) {
  final key = _psSingleQuoted('HKCU:\\SOFTWARE\\Classes\\AppUserModelId\\$appId');
  return <String>[
    r'$ErrorActionPreference = ' + _psSingleQuoted('Stop'),
    r'$key = ' + key,
    r'New-Item -Path $key -Force | Out-Null',
    r"New-ItemProperty -Path $key -Name 'DisplayName' -Value " +
        _psSingleQuoted(displayName) +
        r' -PropertyType String -Force | Out-Null',
    r"New-ItemProperty -Path $key -Name 'IconUri' -Value " +
        _psSingleQuoted(iconPath) +
        r' -PropertyType String -Force | Out-Null',
    r"New-ItemProperty -Path $key -Name 'IconBackgroundColor' -Value '00000000'"
        r' -PropertyType String -Force | Out-Null',
  ].join('; ');
}

/// 删除通知归属项（停用提醒时）。
String buildRemoveAppModelIdCommand({required String appId}) =>
    r'Remove-Item -Path ' +
    _psSingleQuoted('HKCU:\\SOFTWARE\\Classes\\AppUserModelId\\$appId') +
    r' -Recurse -Force -ErrorAction SilentlyContinue';

/// 注册 `riji://` 协议：点通知才能回到日记。
///
/// `URL Protocol` 的值必须是**空字符串**（这就是它的写法，不是占位）。
String buildProtocolHandlerCommand({
  required String protocol,
  required String exePath,
  required String description,
}) {
  final basePath = 'HKCU:\\SOFTWARE\\Classes\\$protocol';
  // ⚠️ 这里必须用 `$base + '\shell\...'` 拼接，**不能**把 `$base` 放进
  // PowerShell 的单引号里——单引号里 `$base` 不展开，会真的去创建一个
  // 名字叫 `$base\shell\open\command` 的键。
  final commandPath = r"$base + '\shell\open\command'";

  return <String>[
    r'$ErrorActionPreference = ' + _psSingleQuoted('Stop'),
    r'$base = ' + _psSingleQuoted(basePath),
    r'New-Item -Path $base -Force | Out-Null',
    r"New-ItemProperty -Path $base -Name '(Default)' -Value " +
        _psSingleQuoted(description) +
        r' -PropertyType String -Force | Out-Null',
    // `URL Protocol` 的值就是空字符串，这是它的写法，不是占位
    r"New-ItemProperty -Path $base -Name 'URL Protocol' -Value ''"
        r' -PropertyType String -Force | Out-Null',
    r'$cmd = ' + commandPath,
    r'New-Item -Path $cmd -Force | Out-Null',
    r"New-ItemProperty -Path $cmd -Name '(Default)' -Value " +
        _psSingleQuoted('"$exePath" "%1"') +
        r' -PropertyType String -Force | Out-Null',
  ].join('; ');
}

/// 删除协议注册（停用提醒时）。
String buildRemoveProtocolHandlerCommand({required String protocol}) =>
    r'Remove-Item -Path ' +
    _psSingleQuoted('HKCU:\\SOFTWARE\\Classes\\$protocol') +
    r' -Recurse -Force -ErrorAction SilentlyContinue';

// -----------------------------------------------------------------------------
// 命令行
// -----------------------------------------------------------------------------

/// 从命令行参数里认出"是通知点回来的"。
/// 命令行可能是 `riji://today`、`riji://today/`，也可能带引号，所以宽松匹配。
/// 认不出就返回 null——**绝不因为一个看不懂的参数就不启动程序**。
String? activationFromArgs(List<String> args) {
  final prefix = '$reminderProtocol://'.toLowerCase();
  for (final arg in args) {
    final trimmed = arg.trim().replaceAll('"', '');
    if (trimmed.toLowerCase().startsWith(prefix)) {
      return trimmed;
    }
  }
  return null;
}
