import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/reminder.dart';
import 'package:riji/data/settings.dart';
import 'package:riji/state/reminder_service.dart';
import 'package:riji/state/settings_controller.dart';

/// `ReminderService`：**装进系统**和**把状态记进设置**这两件事的先后顺序。
///
/// 这一层最值得测的不是"命令拼得对不对"（那在 reminder_test.dart 里），
/// 而是**失败时的行为**：设置里的开关代表的是"系统里真的有这个提醒"，
/// 记早了、记晚了，都会让用户以为已经开了而其实没有。
class _Repo extends SettingsRepository {
  AppSettings? saved;
  int saves = 0;

  @override
  Future<void> save(AppSettings settings) async {
    saved = settings;
    saves++;
  }
}

void main() {
  late _Repo repo;
  late SettingsController settings;

  /// 假装的系统：记录被要求做了什么，并按剧本回答成功还是失败。
  late List<String> calls;
  bool applyOk = true;
  bool removeOk = true;

  ReminderService build({String exe = r'D:\app\riji.exe'}) => ReminderService(
        settings: settings,
        exePath: exe,
        loadIcon: () async => <int>[1, 2, 3],
        apply: (time, weekdays, diaryRoot, iconBytes) async {
          calls.add(
            'apply ${time.label} ${weekdays.join(',')} $diaryRoot '
            '${iconBytes.length}',
          );
          return ReminderOutcome(
            ok: applyOk,
            message: applyOk ? '已启用：每天 ${time.label}' : '建计划任务失败',
          );
        },
        remove: () async {
          calls.add('remove');
          return ReminderOutcome(
            ok: removeOk,
            message: removeOk ? '已关闭' : '有几样没确认到',
          );
        },
      );

  setUp(() {
    repo = _Repo();
    calls = <String>[];
    applyOk = true;
    removeOk = true;
    settings = SettingsController(
      initial: const AppSettings(diaryRoot: r'D:\diary'),
      repository: repo,
    );
  });

  test('装成功了才把开关和指纹记下来', () async {
    final service = build();
    final outcome = await service.enable(const ReminderTime(22, 30), allWeekdays);

    expect(outcome.ok, isTrue);
    expect(calls, <String>[r'apply 22:30 1,2,3,4,5,6,7 D:\diary 3']);
    expect(settings.reminderEnabled, isTrue);
    expect(settings.reminderTime, const ReminderTime(22, 30));
    // 指纹要带上程序路径：程序挪了位置，下次启动就该重新注册
    expect(settings.reminderApplied,
        reminderFingerprint(
          time: const ReminderTime(22, 30),
          weekdays: allWeekdays,
          diaryRoot: r'D:\diary',
          exePath: r'D:\app\riji.exe',
        ));
  });

  test('装失败时设置一点不动（否则界面会显示一个不存在的提醒）', () async {
    applyOk = false;
    final service = build();
    final outcome = await service.enable(const ReminderTime(22, 30), allWeekdays);

    expect(outcome.ok, isFalse);
    expect(settings.reminderEnabled, isFalse);
    expect(settings.reminderApplied, isNull);
    expect(repo.saves, 0, reason: '失败不该往设置里写任何东西');
  });

  test('停用：系统那边没删干净，开关也照样关上', () async {
    // 反过来的错误同样要命：用户点了关闭，界面还显示"已启用"
    removeOk = false;
    await build().enable(ReminderTime.defaultTime, allWeekdays);
    // 先制造一个"今天已经提醒过"的状态，再停用
    await settings.noteReminderShown(DateTime(2026, 10, 8));
    final outcome = await build().disable();

    expect(outcome.ok, isFalse);
    expect(settings.reminderEnabled, isFalse);
    expect(settings.reminderApplied, isNull);
    expect(
      settings.reminderLastShown,
      isNull,
      reason: '当天关掉又开回来，到点该照样提醒',
    );
  });

  test('切了时间之后指纹跟着变（否则启动时不会重装）', () async {
    final service = build();
    await service.enable(const ReminderTime(21, 0), allWeekdays);
    final first = settings.reminderApplied;

    await service.enable(const ReminderTime(7, 30), allWeekdays);
    expect(settings.reminderApplied, isNot(first));
    expect(settings.reminderTime, const ReminderTime(7, 30));
  });

  group('启动时对账', () {
    test('指纹一致：一次系统调用都不发', () async {
      final service = build();
      await service.enable(ReminderTime.defaultTime, allWeekdays);
      calls.clear();

      final outcome = await service.syncOnStartup();

      expect(outcome, isNull);
      expect(calls, isEmpty, reason: '一致时不该为了提醒拖慢启动');
    });

    test('没开提醒：什么都不做', () async {
      expect(await build().syncOnStartup(), isNull);
      expect(calls, isEmpty);
    });

    test('程序换了位置（指纹不一致）就重新装一遍', () async {
      await build(exe: r'D:\old\riji.exe').enable(ReminderTime.defaultTime, allWeekdays);
      calls.clear();

      final outcome = await build(exe: r'E:\new\riji.exe').syncOnStartup();

      expect(outcome?.ok, isTrue);
      expect(calls.single, startsWith('apply 21:00'));
      expect(settings.reminderApplied, contains(r'E:\new\riji.exe'));
    });

    test('重装失败：不打扰用户，但设置里的指纹也不会被写成"已装好"', () async {
      await build().enable(ReminderTime.defaultTime, allWeekdays);
      // 用户手工把计划任务删了 → 指纹仍然一致，所以这里模拟"换了位置又装不上"
      final moved = build(exe: r'E:\new\riji.exe');
      applyOk = false;

      final outcome = await moved.syncOnStartup();

      expect(outcome?.ok, isFalse);
      expect(settings.reminderApplied, isNot(contains(r'E:\new')));
      // 开关仍然是开的：用户没关它，不该因为一次重装失败就悄悄关掉
      expect(settings.reminderEnabled, isTrue);
    });
  });
}
