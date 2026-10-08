import 'dart:async';

import 'package:flutter/material.dart';

import '../core/reminder.dart';
import '../platform/platform.dart' as platform;
import '../state/reminder_service.dart';
import '../state/settings_controller.dart';

/// 「每日提醒」设置。
///
/// 打开这个功能不只是改一个布尔值——它会往用户的系统里写东西（一个计划任务、
/// 一个脚本、两个注册表项）。所以这个对话框有一条**明示**：写什么、写在哪、
/// 停用会怎样。这是这个项目的一贯做法（例如「备份」也明说备份落到哪里）。
Future<void> showReminderDialog(
  BuildContext context,
  SettingsController settings, {
  ReminderOps? ops,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ReminderDialog(
      settings: settings,
      ops: ops ?? ReminderService(settings: settings),
    ),
  );
}

/// 程序**正在运行**时到点弹的那个提醒。
///
/// 和系统通知的分工见 `lib/core/reminder.dart` 的 [shouldRemindInApp]：
/// 程序开着就由程序自己说，不再发系统通知（两条路径只响一次）。
///
/// 两个按钮就够了：「现在写」把光标放进正文（用户点它是为了写），
/// 「今天算了」关掉并且**记下今天**——不然轮询每几秒就会再弹一次。
Future<void> showInAppReminder(
  BuildContext context, {
  required SettingsController settings,
  required VoidCallback onWrite,
}) async {
  final write = await showDialog<bool>(
    context: context,
    // 和草稿恢复那条同一个理由：需要用户做个选择的弹窗，不该被"点一下旁边"
    // 悄悄关掉——那样这一天的提醒就被一次误点吃掉了。
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('今天还没写日记'),
      content: Text(
        '现在是 ${settings.reminderTime.label}，这一天还是空的。',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('今天算了'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('现在写'),
        ),
      ],
    ),
  );

  // 无论点了哪个都算"今天提醒过了"
  await settings.noteReminderShown(DateTime.now());
  if (write == true) onWrite();
}

/// 时间下拉里可选的分钟：**每 5 分钟一档**。
///
/// 提醒不需要精确到分；给 60 个选项只会让人找半天。
const List<int> _minuteSteps = <int>[0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55];

class _ReminderDialog extends StatefulWidget {
  const _ReminderDialog({required this.settings, required this.ops});

  final SettingsController settings;
  final ReminderOps ops;

  @override
  State<_ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<_ReminderDialog> {
  late bool _on = widget.settings.reminderEnabled;
  late ReminderTime _time = widget.settings.reminderTime;
  late List<int> _days = widget.settings.reminderWeekdays;

  bool _busy = false;
  String? _message;

  /// 已保存的设置（用来判断"改过没有、要不要重新应用"）。
  ReminderTime get _savedTime => widget.settings.reminderTime;
  List<int> get _savedDays => widget.settings.reminderWeekdays;

  bool get _timeChanged => _on && _time != _savedTime;
  bool get _daysChanged =>
      _on && _days.join(',') != normalizeWeekdays(_savedDays).join(',');

  /// 有东西改了、需要用户按一下才生效。
  ///
  /// 不做成"改一下立刻重装"：每动一次选择都要起四个 PowerShell 进程
  /// （注册表两项 + 任务 + 文件），拖动分钟就会卡。
  bool get _changed => _timeChanged || _daysChanged;

  @override
  void initState() {
    super.initState();
    // 听设置的变化：启用/停用真的落到设置里之后，这个对话框要跟着反映。
    // 不听的话，"改了时间 → 应用成功"之后「改成 HH:MM」这个按钮还挂在那儿，
    // 看起来像没生效。
    widget.settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    // **不覆盖 _time**：用户可能正在调时间、还没点应用
    setState(() => _on = widget.settings.reminderEnabled);
  }

  Future<void> _run(Future<ReminderOutcome> Function() action,
      {required bool nowOn}) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final outcome = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = outcome.message;
      // ⚠️ 只有成功才动开关。失败还把开关拨过去的话，界面会显示"已启用"，
      // 而系统里其实什么都没有——到点不提醒，用户却以为已经开了。
      if (outcome.ok) _on = nowOn;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!platform.supportsReminder) {
      return AlertDialog(
        title: const Text('每日提醒'),
        content: const Text('每日提醒用 Windows 的计划任务和通知，目前只在 Windows 上提供。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    }

    final timeChanged = _on && _time != _savedTime;

    return AlertDialog(
      title: Row(
        children: <Widget>[
          const Text('每日提醒'),
          const Spacer(),
          Switch(
            value: _on,
            onChanged: _busy
                ? null
                : (value) {
                    if (value) {
                      unawaited(_run(
                        () => widget.ops.enable(_time, _days),
                        nowOn: true,
                      ));
                    } else {
                      unawaited(_run(widget.ops.disable, nowOn: false));
                    }
                  },
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('时间', style: theme.textTheme.bodyMedium),
                  const SizedBox(width: 12),
                  _hourDropdown(theme),
                  Text(' : ', style: theme.textTheme.bodyMedium),
                  _minuteDropdown(theme),
                  const Spacer(),
                  if (_changed)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => unawaited(_run(
                                () => widget.ops.enable(_time, _days),
                                nowOn: true,
                              )),
                      child: Text(
                        // 只改了时间就说具体时间，改的是哪几天就说"提醒日"——
                        // 一个泛泛的"应用"用户还得自己回想改了什么
                        timeChanged && !_daysChanged
                            ? '改成 ${_time.label}'
                            : '应用新的提醒日',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    // 和时间那一行的标签对齐（chip 自己有内边距）
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('提醒日', style: theme.textTheme.bodyMedium),
                  ),
                  const SizedBox(width: 12),
                  // Wrap 而不是 Row：窄窗口下换行，而不是横向溢出。
                  // showCheckmark 关掉：7 个 chip 各带一个勾会让这一行宽出 100 多像素，
                  // 而且选中状态本来就靠底色看得出来。
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final day in allWeekdays)
                          FilterChip(
                            label: Text(weekdayLabels[day - 1]),
                            selected: _days.contains(day),
                            showCheckmark: false,
                            visualDensity: VisualDensity.compact,
                            // 一天都不选的话这个功能就永远不会触发。与其让它变成
                            // 一个哑掉的状态，不如不让人取消最后一个。
                            onSelected: _busy
                                ? null
                                : (selected) => setState(() {
                                      if (selected) {
                                        _days = normalizeWeekdays(<int>[
                                          ..._days,
                                          day,
                                        ]);
                                      } else if (_days.length > 1) {
                                        _days = normalizeWeekdays(
                                          _days.where((d) => d != day),
                                        );
                                      }
                                    }),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_days.length == 1) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  '至少要选一天。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                // 「写过」到底是哪个定义，这里必须说清楚——本项目有两套定义，
                // 而提醒用的是"有内容"那一套（和日历一致）。
                '只在那天还没写的时候提醒。「写过」= 那天有正文、心情、天气或标签。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const Divider(height: 24),
              // 这一段只保留"要不要动系统"这一个信息。写进哪儿、叫什么名字
              // 都留给详细说明和系统本身——对话框是来做一个决定的，
              // 不是来读说明书的。
              Text(
                '打开后会在系统里留一个计划任务和两个注册表项'
                '（通知显示成「日迹」、点通知回到日记），关掉时一并删掉。\n'
                '程序不常驻：到点是 Windows 自己把它拉起来。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              if (_busy) ...<Widget>[
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text('正在写入系统…', style: theme.textTheme.bodySmall),
                  ],
                ),
              ],
              if (_message != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  _message!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _on
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _hourDropdown(ThemeData theme) => DropdownButton<int>(
        value: _time.hour,
        underline: const SizedBox.shrink(),
        style: theme.textTheme.bodyMedium,
        items: <DropdownMenuItem<int>>[
          for (var hour = 0; hour < 24; hour++)
            DropdownMenuItem<int>(
              value: hour,
              child: Text(hour.toString().padLeft(2, '0')),
            ),
        ],
        onChanged: _busy
            ? null
            : (value) {
                if (value == null) return;
                setState(() => _time = ReminderTime(value, _time.minute));
              },
      );

  Widget _minuteDropdown(ThemeData theme) => DropdownButton<int>(
        // 已保存的时间可能不在 5 分钟档上（手改过 settings.json），
        // 那就把它自己也列进去，免得下拉框显示一个不属于它的值。
        value: _minuteSteps.contains(_time.minute) ? _time.minute : null,
        hint: Text(_time.minute.toString().padLeft(2, '0')),
        underline: const SizedBox.shrink(),
        style: theme.textTheme.bodyMedium,
        items: <DropdownMenuItem<int>>[
          for (final minute in _minuteSteps)
            DropdownMenuItem<int>(
              value: minute,
              child: Text(minute.toString().padLeft(2, '0')),
            ),
        ],
        onChanged: _busy
            ? null
            : (value) {
                if (value == null) return;
                setState(() => _time = ReminderTime(_time.hour, value));
              },
      );
}
