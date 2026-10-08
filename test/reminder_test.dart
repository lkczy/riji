import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/models/diary_entry.dart';
import 'package:riji/core/reminder.dart';

/// 每日提醒里**能纯逻辑验证**的那部分。
///
/// 这里断言的是"到底往用户系统里写了什么命令"。那些命令会改注册表和计划任务，
/// 测试里当然不能真跑——但正因为不能真跑，它们就更需要被逐字钉住：
/// 拼错一个键名不会报错，只会安静地写到一个没人看的地方。
void main() {
  group('提醒时间', () {
    test('解析合法写法', () {
      expect(ReminderTime.tryParse('21:00'), const ReminderTime(21, 0));
      expect(ReminderTime.tryParse('9:5'), const ReminderTime(9, 5));
      expect(ReminderTime.tryParse(' 21:00 '), const ReminderTime(21, 0));
      expect(ReminderTime.tryParse('00:00'), const ReminderTime(0, 0));
      expect(ReminderTime.tryParse('23:59'), const ReminderTime(23, 59));
    });

    test('非法写法返回 null，而不是抛异常、也不是猜', () {
      // 一个坏的时间字符串不该让整个设置读不出来——那样用户的日记目录也会丢
      expect(ReminderTime.tryParse(null), isNull);
      expect(ReminderTime.tryParse(''), isNull);
      expect(ReminderTime.tryParse('21'), isNull);
      expect(ReminderTime.tryParse('21:60'), isNull);
      expect(ReminderTime.tryParse('24:00'), isNull);
      expect(ReminderTime.tryParse('-1:00'), isNull);
      expect(ReminderTime.tryParse('晚上九点'), isNull);
    });

    test('label 补零，直接能喂给计划任务', () {
      expect(const ReminderTime(9, 5).label, '09:05');
      expect(const ReminderTime(21, 0).label, '21:00');
      expect(ReminderTime.defaultTime.label, '21:00');
    });
  });

  group('指纹', () {
    test('时间、提醒日、日记目录、程序路径任一变了，指纹就变', () {
      const base = 'v1|21:00|1,2,3,4,5,6,7|D:\\diary|D:\\app\\riji.exe';
      String fp(
        ReminderTime t,
        String root,
        String exe, {
        List<int> days = allWeekdays,
      }) =>
          reminderFingerprint(
            time: t,
            weekdays: days,
            diaryRoot: root,
            exePath: exe,
          );

      expect(fp(const ReminderTime(21, 0), r'D:\diary', r'D:\app\riji.exe'),
          base);
      expect(fp(const ReminderTime(22, 0), r'D:\diary', r'D:\app\riji.exe'),
          isNot(base));
      expect(fp(const ReminderTime(21, 0), r'E:\diary', r'D:\app\riji.exe'),
          isNot(base));
      expect(fp(const ReminderTime(21, 0), r'D:\diary', r'E:\app\riji.exe'),
          isNot(base));
      // 改了提醒日也得重装：不然系统里的任务还是旧的几天
      expect(
        fp(const ReminderTime(21, 0), r'D:\diary', r'D:\app\riji.exe',
            days: <int>[1, 2, 3, 4, 5]),
        isNot(base),
      );
    });
  });

  group('提醒日', () {
    test('默认是每天', () {
      expect(normalizeWeekdays(null), allWeekdays);
      expect(reminderScheduleLabel(const ReminderTime(21, 0), allWeekdays),
          '每天 21:00');
    });

    test('整理：去重、排序、丢掉非法值', () {
      expect(normalizeWeekdays(<int>[5, 1, 5, 3]), <int>[1, 3, 5]);
      expect(normalizeWeekdays(<int>[0, 8, -1, 2]), <int>[2]);
    });

    test('什么都没剩下时退回"每天"，而不是"永不提醒"', () {
      // 设置文件被手改坏了也不能让提醒变成哑的
      expect(normalizeWeekdays(<int>[]), allWeekdays);
      expect(normalizeWeekdays(<int>[0, 9]), allWeekdays);
    });

    test('说得出一句人话', () {
      const time = ReminderTime(21, 0);
      expect(reminderScheduleLabel(time, <int>[1, 2, 3, 4, 5]), '工作日 21:00');
      expect(reminderScheduleLabel(time, <int>[6, 7]), '周末 21:00');
      expect(reminderScheduleLabel(time, <int>[1, 3]), '周一、周三 21:00');
      expect(reminderScheduleLabel(time, <int>[7]), '周日 21:00');
    });

    test('今天是不是提醒日', () {
      // 2026-10-08 是周四（weekday = 4）
      final thursday = DateTime(2026, 10, 8);
      expect(thursday.weekday, 4);
      expect(isReminderDay(<int>[1, 2, 3, 4, 5], thursday), isTrue);
      expect(isReminderDay(<int>[6, 7], thursday), isFalse);
    });
  });

  group('程序在运行时该不该弹程序内提醒', () {
    DateTime at(int hour, int minute) => DateTime(2026, 10, 8, hour, minute);

    bool ask({
      required DateTime now,
      required DateTime startedAt,
      bool enabled = true,
      bool written = false,
      DateTime? lastShown,
      List<int> days = allWeekdays,
      ReminderTime time = const ReminderTime(21, 0),
    }) =>
        shouldRemindInApp(
          now: now,
          appStartedAt: startedAt,
          time: time,
          weekdays: days,
          enabled: enabled,
          todayWritten: written,
          lastShownDay: lastShown,
        );

    test('到点了、还没写、程序一直在跑 → 提醒', () {
      expect(ask(now: at(21, 0), startedAt: at(9, 0)), isTrue);
      expect(
        ask(now: at(23, 59), startedAt: at(9, 0)),
        isTrue,
        reason: '到点之后一直没写，当天之内仍该提醒（"只提醒一次"由 lastShown 管）',
      );
    });

    test('还没到点 → 不提醒', () {
      expect(ask(now: at(20, 59), startedAt: at(9, 0)), isFalse);
    });

    test('程序是到点之后才打开的 → 不提醒', () {
      // 22 点才打开程序的人，打开就是为了写东西；一开就弹"今天还没写"是噪音
      expect(ask(now: at(22, 0), startedAt: at(22, 0)), isFalse);
      expect(ask(now: at(23, 30), startedAt: at(22, 0)), isFalse);
    });

    test('已经写过了 → 不提醒', () {
      expect(ask(now: at(21, 30), startedAt: at(9, 0), written: true), isFalse);
    });

    test('关着开关 → 不提醒', () {
      expect(ask(now: at(21, 30), startedAt: at(9, 0), enabled: false), isFalse);
    });

    test('今天已经提醒过一次 → 当天不再弹，第二天照旧', () {
      // 轮询每几秒一次，"到点了"这个条件会一直成立到当天结束
      expect(
        ask(
          now: at(21, 30),
          startedAt: at(9, 0),
          lastShown: DateTime(2026, 10, 8),
        ),
        isFalse,
      );
      expect(
        ask(
          now: DateTime(2026, 10, 9, 21, 30),
          startedAt: DateTime(2026, 10, 9, 9, 0),
          lastShown: DateTime(2026, 10, 8),
        ),
        isTrue,
      );
    });

    test('今天不是提醒日 → 什么都不做', () {
      // 计划任务那天本来也不会触发；程序开着时也要一致，否则会"提前"提醒
      expect(
        ask(now: at(21, 30), startedAt: at(9, 0), days: <int>[1, 2, 3]),
        isFalse,
        reason: '2026-10-08 是周四，不在 [1,2,3] 里',
      );
      expect(
        ask(now: at(21, 30), startedAt: at(9, 0), days: <int>[4]),
        isTrue,
      );
    });

    test('一天的键是日期，跟时分无关', () {
      expect(reminderDayKey(DateTime(2026, 1, 5, 23, 59)), '2026-01-05');
      expect(reminderDayKey(DateTime(2026, 12, 31)), '2026-12-31');
    });
  });

  group('今天写过没有', () {
    final today = DateTime(2026, 10, 8);
    DiaryEntry entry(DateTime date, {String body = '', String? mood}) =>
        DiaryEntry.create(date: date, device: 'test', body: body, mood: mood);

    bool asks({
      DateTime? selected,
      bool currentEmpty = true,
      List<DiaryEntry> entries = const <DiaryEntry>[],
    }) =>
        dayHasContent(
          day: today,
          selectedDate: selected ?? today,
          currentEntryEmpty: currentEmpty,
          entries: entries,
        );

    test('编辑器里正在写今天 → 算写过', () {
      expect(asks(currentEmpty: false), isTrue);
    });

    test('今天有一条有正文的 → 算写过', () {
      expect(asks(entries: <DiaryEntry>[entry(today, body: '写了一句')]), isTrue);
    });

    test('今天那条只有心情/天气/标签 → 也算写过（和 DiaryEntry.isEmpty 一致）', () {
      expect(asks(entries: <DiaryEntry>[entry(today, mood: '平静')]), isTrue);
    });

    test('今天那条是空的 → 不算写过', () {
      // 以前的实现用的是"有没有这一条"，那会让一个空文件把提醒永久压掉
      expect(asks(entries: <DiaryEntry>[entry(today)]), isFalse);
    });

    test('今天根本没有这一条 → 不算写过', () {
      expect(asks(), isFalse);
    });

    test('用户正在翻别的日子时，不拿那一天的内容当今天', () {
      expect(
        asks(
          selected: DateTime(2026, 10, 1),
          currentEmpty: false, // 10-01 正在写
          entries: <DiaryEntry>[entry(DateTime(2026, 10, 1), body: '上星期的')],
        ),
        isFalse,
        reason: '今天仍然没写，该提醒',
      );
    });
  });

  group('提醒脚本', () {
    test('把日记目录、AppID、协议地址都填进去了，没留下占位符', () {
      final script = buildReminderScript(diaryRoot: r'D:\MyDiary', exeName: 'riji');
      expect(script, contains(r"'D:\MyDiary'"));
      expect(script, contains(reminderAppId));
      expect(script, contains(reminderActivationUrl));
      // 占位符漏填比报错更难发现：脚本照样能跑，只是永远判断错
      expect(script, isNot(contains('__ROOT__')));
      expect(script, isNot(contains('__APP_ID__')));
      expect(script, isNot(contains('__URL__')));
      expect(script, isNot(contains('__DATE__')));
    });

    test('路径里有单引号也不会把脚本拼坏', () {
      final script = buildReminderScript(diaryRoot: r"D:\it's\diary", exeName: 'riji');
      // PowerShell 单引号字符串里，单引号要写两遍
      expect(script, contains(r"'D:\it''s\diary'"));
    });

    test('判定"写过"的函数和不发通知的开关都在', () {
      final script = buildReminderScript(diaryRoot: r'D:\d', exeName: 'riji');
      // 这个函数是 DiaryEntry.isEmpty 在 PowerShell 侧的镜像，
      // DryRun 是唯一能验证它的入口
      expect(script, contains('function Test-RijiWritten'));
      expect(script, contains('-DryRun'));
      expect(script, contains('CreateToastNotifier'));
    });

    test('程序在跑的时候不发通知（交给程序自己提醒，两边不许都响）', () {
      final script = buildReminderScript(diaryRoot: r'D:\d', exeName: 'riji');
      // 进程名要拼成一个合法的 PowerShell 单引号字符串：`'riji'`
      expect(script, contains("Get-Process -Name 'riji'"));
      expect(script, isNot(contains("''riji''")));
      // 判不出来时按"没在跑"处理：宁可多一条通知，也不要一条都不弹
      expect(script, contains(r'$appRunning = $false'));
      expect(script, contains(r'if ($appRunning) { exit 0 }'));
      // DryRun 要能把这个判断也报出来，否则真机上没法验
      expect(script, contains('appRunning='));
    });

    test('日期用固定区域格式化（某些区域会给出非公历年份）', () {
      final script = buildReminderScript(diaryRoot: r'D:\d', exeName: 'riji');
      expect(script, contains('InvariantCulture'));
      expect(script, isNot(contains("Get-Date -Format")));
    });
  });

  group('注册计划任务的命令', () {
    test('任务名、时间、脚本路径、补跑开关都在', () {
      final cmd = buildRegisterTaskCommand(
        time: const ReminderTime(21, 30),
        weekdays: allWeekdays,
        scriptPath: r'C:\Users\me\AppData\Roaming\riji\remind.ps1',
      );

      expect(cmd, contains(reminderTaskName));
      expect(cmd, contains("'21:30'"));
      expect(cmd, contains(r'C:\Users\me\AppData\Roaming\riji\remind.ps1'));
      // 睡眠错过 21:00 之后要补跑——笔记本上这是常态
      expect(cmd, contains('-StartWhenAvailable'));
      expect(cmd, contains('-Weekly'));
      // 隐藏窗口 + 绕过执行策略（本项目的 .ps1 都是 Bypass 跑的）
      expect(cmd, contains('-WindowStyle Hidden'));
      expect(cmd, contains('-ExecutionPolicy Bypass'));
      // 用完删掉，别留一个每天都跑的任务
      expect(buildUnregisterTaskCommand(), contains(reminderTaskName));
      expect(buildUnregisterTaskCommand(), contains('Unregister-ScheduledTask'));
    });
  });

  group('注册表命令', () {
    test('生成的命令里不许出现 \\\$', () {
      // ⚠️ 踩过一次：Dart 的 raw string **不转义**，所以 `r'...\$key'` 里的
      // 反斜杠是字面量，PowerShell 拿到的路径就成了 `\HKCU:\...`——于是那一步
      // 静默失败（或者更糟：写到一个谁都不看的键上去）。
      final commands = <String>[
        buildAppModelIdCommand(
          appId: reminderAppId,
          displayName: '日迹',
          iconPath: r'C:\i.ico',
        ),
        buildProtocolHandlerCommand(
          protocol: reminderProtocol,
          exePath: r'C:\a\riji.exe',
          description: '日迹',
        ),
        buildRegisterTaskCommand(
          time: ReminderTime.defaultTime,
          weekdays: allWeekdays,
          scriptPath: r'C:\s.ps1',
        ),
        buildUnregisterTaskCommand(),
        buildRemoveAppModelIdCommand(appId: reminderAppId),
        buildRemoveProtocolHandlerCommand(protocol: reminderProtocol),
      ];

      for (final command in commands) {
        expect(command, isNot(contains(r'\$')), reason: command);
      }
    });

    test('通知归属：键名带 AppID，DisplayName 和图标都是实值', () {
      final cmd = buildAppModelIdCommand(
        appId: reminderAppId,
        displayName: '日迹',
        iconPath: r'C:\Users\me\AppData\Roaming\riji\reminder.ico',
      );

      expect(cmd, contains('AppUserModelId\\$reminderAppId'));
      // 不能把 Interpolation 写丢了——否则会创建名为 "$appId" 的键
      expect(cmd, isNot(contains(r'AppUserModelId\$appId')));
      expect(cmd, contains("'日迹'"));
      expect(cmd, contains('IconUri'));
      expect(cmd, contains(r'C:\Users\me\AppData\Roaming\riji\reminder.ico'));
    });

    test('协议注册：URL Protocol 是空值，命令行指向程序本体', () {
      final cmd = buildProtocolHandlerCommand(
        protocol: reminderProtocol,
        exePath: r'C:\Program Files\riji\riji.exe',
        description: '日迹提醒',
      );

      expect(cmd, contains(r'HKCU:\SOFTWARE\Classes\riji'));
      expect(cmd, contains("'URL Protocol'"));
      expect(cmd, contains(r'"C:\Program Files\riji\riji.exe" "%1"'));
      // ⚠️ 子键路径必须靠 `$base + ...` 拼出来。放进单引号里的话
      // PowerShell 不展开 $base，会去创建一个名字里带 "$base" 的键——
      // 不报错、注册表里也确实多了一个键，但点通知不会有任何反应。
      expect(cmd, contains(r"$base + '\shell\open\command'"));
      expect(cmd, isNot(contains(r"'$base\shell")));
    });

    test('停用时删的是同一批键', () {
      expect(buildRemoveAppModelIdCommand(appId: reminderAppId),
          contains('AppUserModelId\\$reminderAppId'));
      expect(buildRemoveProtocolHandlerCommand(protocol: reminderProtocol),
          contains(r'HKCU:\SOFTWARE\Classes\riji'));
    });
  });

  group('从命令行认出"通知点回来的"', () {
    test('认得出来，大小写和引号都不计较', () {
      expect(activationFromArgs(<String>['riji://today']), 'riji://today');
      expect(activationFromArgs(<String>['"riji://today"']), 'riji://today');
      expect(activationFromArgs(<String>['RIJI://today']), 'RIJI://today');
      expect(
        activationFromArgs(<String>[r'D:\riji.exe', 'riji://today']),
        'riji://today',
      );
    });

    test('别的参数一律不认，也绝不因此不启动', () {
      expect(activationFromArgs(<String>[]), isNull);
      expect(activationFromArgs(<String>['--remind']), isNull);
      expect(activationFromArgs(<String>[r'D:\some\path']), isNull);
      // 长得像但不是：别的协议不能当成我们的
      expect(activationFromArgs(<String>['https://example.com']), isNull);
      expect(activationFromArgs(<String>['riji:']), isNull);
    });
  });
}
