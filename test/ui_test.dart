import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/chinese_calendar.dart';
import 'package:riji/core/day.dart';
import 'package:riji/core/diary_codec.dart';
import 'package:riji/core/diary_filter.dart';
import 'package:riji/core/diary_location.dart';
import 'package:riji/core/editor_typography.dart';
import 'package:riji/core/huangli.dart';
import 'package:riji/core/models/diary_entry.dart';
import 'package:riji/core/release_notes.dart';
import 'package:riji/core/reminder.dart';
import 'package:riji/data/diary_store.dart';
import 'package:riji/data/release_info.dart';
import 'package:riji/data/settings.dart';
import 'package:riji/state/diary_controller.dart';
import 'package:riji/state/reminder_service.dart';
import 'package:riji/state/settings_controller.dart';
import 'package:riji/state/vault_service.dart';
import 'package:riji/ui/app.dart';
import 'package:riji/ui/reminder_dialog.dart';

/// 记录被写下来的设置，用于验证偏好真的持久化了。
class _FakeSettingsRepository extends SettingsRepository {
  AppSettings? saved;

  @override
  Future<void> save(AppSettings settings) async => saved = settings;
}

/// 提醒的假实现。
///
/// 真实现会起 PowerShell 往用户系统里写计划任务和注册表——测试里绝不能碰。
/// 这个假货只记录"被要求做了什么"，并允许指定失败，好验证失败时界面怎么办。
class _FakeReminderOps implements ReminderOps {
  bool failEnable = false;

  final List<ReminderTime> enabled = <ReminderTime>[];
  List<int>? enabledDays;
  int disableCalls = 0;

  @override
  Future<ReminderOutcome> enable(ReminderTime time, List<int> weekdays) async {
    enabled.add(time);
    enabledDays = weekdays;
    if (failEnable) {
      return const ReminderOutcome(
        ok: false,
        message: '建计划任务失败，所以到点不会提醒。可以再试一次。',
      );
    }
    return ReminderOutcome(
      ok: true,
      message: '已启用：${reminderScheduleLabel(time, weekdays)}，只在那天还没写的时候提醒。',
    );
  }

  @override
  Future<ReminderOutcome> disable() async {
    disableCalls++;
    return const ReminderOutcome(ok: true, message: '已关闭，系统里没留东西。');
  }
}

/// 界面测试。全部用内存存储和假设置仓库，绝不碰真实文件系统和用户配置。
void main() {
  setUpAll(() {
    // 黄历数据在程序里是按需从资源包读的，测试环境不保证读得到。
    // 先把解析好的表塞进缓存，界面就会直接命中缓存，不去碰资源包。
    //
    // 这里用同步读文件：testWidgets 跑在假异步环境里，await 真实 I/O 不会返回。
    HuangliTable.seedCache(
      HuangliTable.parse(File('assets/huangli.tsv').readAsStringSync()),
    );
  });

  const bodyField = Key('diary-body-field');

  const baseSettings = AppSettings(diaryRoot: 'memory');

  /// 正文输入框有没有焦点。多个测试组都要用（焦点归还那条），所以放在这里。
  bool bodyHasFocus(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(bodyField)).focusNode?.hasFocus ??
      false;

  Future<DiaryController> pumpApp(
    WidgetTester tester,
    DiaryStore store, {
    DateTime? date,
    Size size = const Size(1400, 900),
    SettingsController? settings,
    ReleaseInfo? releaseInfo,
    VaultService? vault,
  }) async {
    // 显式指定窗口尺寸：默认的 800x600 会让标题栏走窄屏分支，
    // 日期格式随之改变，断言就会对不上。桌面 App 的典型尺寸是宽屏。
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = DiaryController(
      store: store,
      deviceName: 'test',
      vault: vault,
    );
    await controller.load(preferredDate: date);
    // 取消控制器里所有挂起的定时器，否则测试结束会报 "Timer is still pending"
    addTearDown(controller.close);

    await tester.pumpWidget(
      RijiApp(
        controller: controller,
        settings:
            settings ?? SettingsController(initial: baseSettings),
        // 不传就当作"读不到版本信息"：此时「本版更新」整个功能不出现。
        // 现有测试全部走这条路，所以它们的行为一点没变。
        releaseInfo: releaseInfo,
        onSwitchDiaryRoot: (newRoot, {required copyExisting}) async =>
            const DiaryCopyOutcome(
          ok: false,
          filesCopied: 0,
          message: '测试环境不实际切换位置。',
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('窗口拖窄时布局不会溢出', (tester) async {
    // 布局溢出会让测试直接失败（RenderFlex overflow 会抛异常），
    // 所以这里能正常找到关键控件，就说明窄窗口下布局撑住了。
    await pumpApp(tester, MemoryDiaryStore(), size: const Size(700, 620));

    expect(find.byKey(bodyField), findsOneWidget);
    expect(find.text('搜索日记…'), findsOneWidget);
  });

  testWidgets('启动后显示今天的日期和写作提示', (tester) async {
    final controller = await pumpApp(tester, MemoryDiaryStore());

    expect(find.text(formatChineseDate(controller.selectedDate)), findsOneWidget);
    expect(find.text('今天发生了什么？'), findsOneWidget);
    expect(find.text('还没写'), findsOneWidget);
  });

  // 这条守的是一个很容易漏掉的时序问题：控制器可能在界面创建之前
  // 就已经加载完了，那次通知没人听。表现是「重开已有内容的一天，
  // 正文框却空着」——用户会以为自己的日记没了。
  testWidgets('重开已有内容的一天，正文必须显示出来', (tester) async {
    const saved = '这是已经写好并存下来的内容。\n\n还有第二段。';

    final store = MemoryDiaryStore();
    store.seed(DiaryEntry.create(
      date: DateTime(2026, 2, 14),
      device: 'test',
      body: saved,
      mood: '平静',
      tags: <String>['阅读'],
    ));

    // 注意：load() 在 pumpWidget 之前就已经完成——这正是最容易出错的时序
    await pumpApp(tester, store, date: DateTime(2026, 2, 14));

    // 直接查输入框里的文本：用 find.text 会和左侧列表的预览文字撞车
    final field = tester.widget<TextField>(find.byKey(bodyField));
    expect(field.controller?.text, saved,
        reason: '重开已有内容的一天，正文框不能是空的');

    // 这里刻意**不**断言 find.text('今天发生了什么？') 不存在：
    // InputDecoration 的提示语在输入框有内容时依然留在控件树里，
    // 只是透明度为 0，find.text 照样能找到它。用它会得出错误结论。
  });

  testWidgets('在编辑器里打字会自动保存，并把状态显示出来', (tester) async {
    final store = MemoryDiaryStore();
    final controller = await pumpApp(tester, store);
    final today = controller.selectedDate;

    await tester.enterText(find.byKey(bodyField), '界面里敲下的一句话');
    await tester.pump();

    expect(find.text('未保存…'), findsOneWidget);

    // 推进到防抖保存触发之后
    await tester.pump(DiaryController.saveDelay + const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    final saved = await store.loadByDate(today);
    expect(saved?.body, '界面里敲下的一句话');
    // 内存模式不能说"已保存"，否则就是在给用户虚假的安心感
    expect(find.textContaining('已存入内存'), findsWidgets);
    expect(find.textContaining('已保存'), findsNothing);
  });

  testWidgets('存储不落盘时必须明确警告，而不是假装保存成功', (tester) async {
    await pumpApp(tester, MemoryDiaryStore());

    expect(find.textContaining('预览模式'), findsOneWidget);
    expect(find.textContaining('关掉页面就没了'), findsOneWidget);
  });

  testWidgets('切换日期会把没保存的内容带走', (tester) async {
    final store = MemoryDiaryStore();
    final controller = await pumpApp(tester, store);
    final today = controller.selectedDate;

    await tester.enterText(find.byKey(bodyField), '这一天写的');
    await tester.pump();

    // 点"前一天"，不等自动保存
    await tester.tap(find.byTooltip('前一天'));
    await tester.pumpAndSettle();

    expect(controller.selectedDate, today.subtract(const Duration(days: 1)));
    expect((await store.loadByDate(today))?.body, '这一天写的');
    // 编辑器应该已经切到空白的那一天
    expect(find.text('今天发生了什么？'), findsOneWidget);
  });

  testWidgets('搜索会过滤左侧列表', (tester) async {
    final store = MemoryDiaryStore();
    store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14), device: 'test', body: '读了一本书'));
    store.seed(DiaryEntry.create(
        date: DateTime(2026, 3, 1), device: 'test', body: '加班到很晚'));

    final controller = await pumpApp(
      tester,
      store,
      date: DateTime(2026, 2, 14),
    );
    expect(controller.visibleEntries, hasLength(2));
    expect(find.text('2026-03-01'), findsOneWidget);

    // 第一个输入框是左侧的搜索框
    await tester.enterText(find.byType(TextField).first, '加班');
    await tester.pumpAndSettle();

    expect(find.text('2026-03-01'), findsOneWidget);
    expect(find.text('2026-02-14'), findsNothing);
  });

  testWidgets('点击列表里的日期会切换编辑器', (tester) async {
    final store = MemoryDiaryStore();
    store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14), device: 'test', body: '第一天'));
    store.seed(DiaryEntry.create(
        date: DateTime(2026, 3, 1), device: 'test', body: '第二天'));

    final controller = await pumpApp(
      tester,
      store,
      date: DateTime(2026, 2, 14),
    );

    await tester.tap(find.text('2026-03-01'));
    await tester.pumpAndSettle();

    expect(controller.selectedDate, DateTime(2026, 3, 1));
    expect(
      find.text(formatChineseDate(DateTime(2026, 3, 1))),
      findsOneWidget,
    );
  });

  testWidgets('专注模式能隐藏左侧列表', (tester) async {
    await pumpApp(tester, MemoryDiaryStore());

    expect(find.text('搜索日记…'), findsOneWidget);

    await tester.tap(find.byTooltip('专注模式（隐藏日记列表）'));
    await tester.pumpAndSettle();

    expect(find.text('搜索日记…'), findsNothing);
    expect(find.byKey(bodyField), findsOneWidget);
  });

  testWidgets('没有日记时给出引导，而不是一片空白', (tester) async {
    await pumpApp(tester, MemoryDiaryStore());

    expect(find.text('还没有日记'), findsOneWidget);
    expect(find.text('在右边写下第一句吧'), findsOneWidget);
  });

  testWidgets('搜索无结果时给出提示', (tester) async {
    final store = MemoryDiaryStore();
    store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14), device: 'test', body: '读了一本书'));
    await pumpApp(tester, store, date: DateTime(2026, 2, 14));

    await tester.enterText(find.byType(TextField).first, '压根不存在的内容');
    await tester.pumpAndSettle();

    expect(find.text('没有匹配的日记'), findsOneWidget);
  });

  group('心情与天气', () {
    Future<void> settleSave(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(
        DiaryController.saveDelay + const Duration(milliseconds: 200),
      );
      await tester.pump();
    }

    testWidgets('天气有预设可选，点了会保存', (tester) async {
      final store = MemoryDiaryStore();
      final controller = await pumpApp(tester, store);

      expect(find.text('晴'), findsOneWidget);
      expect(find.text('雨'), findsOneWidget);

      await tester.tap(find.text('晴'));
      await settleSave(tester);

      expect(controller.weather, '晴');
      expect((await store.loadByDate(controller.selectedDate))?.weather, '晴');
    });

    testWidgets('自定义心情：回车后生效、落盘，并成为一个可见选项', (tester) async {
      final store = MemoryDiaryStore();
      final controller = await pumpApp(tester, store);

      await tester.enterText(find.byKey(const Key('mood-input')), '有点恍惚');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleSave(tester);

      expect(controller.mood, '有点恍惚');
      expect(
        (await store.loadByDate(controller.selectedDate))?.mood,
        '有点恍惚',
      );
      // 自定义值必须变成一个可见的选项，否则用户会以为程序把它丢了
      expect(find.text('有点恍惚'), findsWidgets);
    });

    testWidgets('自定义天气：回车后生效并落盘', (tester) async {
      final store = MemoryDiaryStore();
      final controller = await pumpApp(tester, store);

      await tester.enterText(find.byKey(const Key('weather-input')), '小雨转阴');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleSave(tester);

      expect(controller.weather, '小雨转阴');
      expect(
        (await store.loadByDate(controller.selectedDate))?.weather,
        '小雨转阴',
      );
    });

    testWidgets('自定义输入心情不会顺手把天气清掉', (tester) async {
      final store = MemoryDiaryStore();
      final controller = await pumpApp(tester, store);

      await tester.tap(find.text('多云'));
      await settleSave(tester);

      await tester.enterText(find.byKey(const Key('mood-input')), '烦');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleSave(tester);

      expect(controller.weather, '多云');
      expect(controller.mood, '烦');
    });

    testWidgets('重开已有天气的一天，预设会显示为选中', (tester) async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '内容',
        mood: '平静',
        weather: '雪',
      ));

      await pumpApp(tester, store, date: DateTime(2026, 2, 14));

      final chip =
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '雪'));
      expect(chip.selected, isTrue);
    });

    testWidgets('自定义值重开后仍作为一个选项显示出来', (tester) async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '内容',
        weather: '闷热潮湿',
      ));

      await pumpApp(tester, store, date: DateTime(2026, 2, 14));

      final chip = tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '闷热潮湿'));
      expect(chip.selected, isTrue);
    });

    testWidgets('窄窗口下三行元数据不会溢出', (tester) async {
      // 心情、天气、标签现在是三行，比原来更容易撑破布局
      await pumpApp(tester, MemoryDiaryStore(), size: const Size(680, 600));

      expect(find.byKey(const Key('mood-input')), findsOneWidget);
      expect(find.byKey(const Key('weather-input')), findsOneWidget);
      expect(find.byKey(const Key('tag-input')), findsOneWidget);
    });
  });

  group('筛选、标签补全与冲突提示', () {
    Future<void> pumpFrames(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    MemoryDiaryStore twoTaggedDays() {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 10),
        device: 'test',
        body: '开会',
        mood: '疲惫',
        weather: '雨',
        tags: <String>['工作'],
      ));
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 11),
        device: 'test',
        body: '看书',
        mood: '平静',
        weather: '晴',
        tags: <String>['生活'],
      ));
      return store;
    }

    testWidgets('筛选：选标签后列表被过滤，条件显示出来', (tester) async {
      final controller = await pumpApp(
        tester,
        twoTaggedDays(),
        date: DateTime(2026, 2, 10),
      );
      expect(controller.visibleEntries, hasLength(2));

      await tester.tap(find.byTooltip('筛选'));
      await pumpFrames(tester);
      expect(find.text('筛选日记'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, '工作'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '应用'));
      await pumpFrames(tester);

      expect(controller.filter.tag, '工作');
      expect(
        controller.visibleEntries.map((e) => e.date).toList(),
        <DateTime>[DateTime(2026, 2, 10)],
      );
      // 筛选条件必须摆在明面上，否则用户会以为日记少了一大半
      expect(find.textContaining('标签「工作」'), findsWidgets);
    });

    testWidgets('筛选：一键清除', (tester) async {
      final controller = await pumpApp(
        tester,
        twoTaggedDays(),
        date: DateTime(2026, 2, 10),
      );
      controller.setFilter(const DiaryFilter(tag: '工作'));
      await tester.pump();
      expect(controller.visibleEntries, hasLength(1));

      await tester.tap(find.byTooltip('清除筛选'));
      await tester.pump();

      expect(controller.filter.isActive, isFalse);
      expect(controller.visibleEntries, hasLength(2));
    });

    testWidgets('筛选：三个维度都能设，且是「与」的关系', (tester) async {
      final controller = await pumpApp(
        tester,
        twoTaggedDays(),
        date: DateTime(2026, 2, 10),
      );

      controller.setFilter(
        const DiaryFilter(tag: '工作', mood: '平静'),
      );
      await tester.pump();

      // 标签和心情不是同一天，所以结果为空
      expect(controller.visibleEntries, isEmpty);
      expect(find.text('没有符合筛选的日记'), findsOneWidget);
      expect(
        find.textContaining('标签「工作」'),
        findsWidgets,
        reason: '筛不出东西时更要说明是什么条件导致的',
      );
    });

    testWidgets('标签输入会补全已用过的标签', (tester) async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 10),
        device: 'test',
        body: '之前的',
        tags: <String>['工作'],
      ));
      // 打开一个还没有标签的日子
      final controller = await pumpApp(
        tester,
        store,
        date: DateTime(2026, 2, 11),
      );
      expect(controller.tags, isEmpty);

      await tester.enterText(find.byKey(const Key('tag-input')), '工');
      await pumpFrames(tester);

      expect(find.widgetWithText(ListTile, '工作'), findsOneWidget);

      await tester.tap(find.widgetWithText(ListTile, '工作'));
      await pumpFrames(tester);

      expect(controller.tags, <String>['工作']);
    });

    testWidgets('已经加在这一天的标签不出现在补全列表里', (tester) async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 10),
        device: 'test',
        body: '之前的',
        tags: <String>['工作', '加班'],
      ));
      final controller = await pumpApp(
        tester,
        store,
        date: DateTime(2026, 2, 10),
      );
      expect(controller.tags, <String>['工作', '加班']);

      await tester.enterText(find.byKey(const Key('tag-input')), '');
      await pumpFrames(tester);

      // 「加班」已经在这一天上，不该再提示一次
      expect(find.widgetWithText(ListTile, '加班'), findsNothing);
    });

    // ⚠️ 本文件里的测试**不能碰真实文件系统**。
    //
    // testWidgets 跑在假异步环境里，而 dart:io 的 Future 由真实事件循环完成，
    // 假异步不会去驱动它 —— 于是 await 真实 I/O 会**永远不返回**。
    // 更糟的是 --timeout 也拦不住，因为超时本身就是异步实现的。
    // （这个坑已经实际踩过一次：界面测试里用 FsDiaryStore 直接把整个测试跑挂死。）
    //
    // 所以真实文件 I/O 的正确性由 fs_diary_store_test.dart 里的普通 test() 覆盖，
    // 这里只验证界面**拿到冲突结果之后**的反应，用注入结果的测试替身。
    testWidgets('检测到外部改动时顶出警告条，并说清两边都没丢', (tester) async {
      final store = MemoryDiaryStore();
      final date = DateTime(2026, 2, 14);
      store.seed(DiaryEntry.create(
        date: date,
        device: 'test',
        body: '电脑上写的第一版',
      ));

      const conflictPath =
          r'C:\diary\2026\2026-02-14.conflict-20260214T214002-test-device.md';
      // 模拟存储层报告：写入前发现磁盘上的内容被别处改过
      store.nextSaveOutcome =
          const DiarySaveOutcome(wrote: true, conflictPath: conflictPath);

      final controller = await pumpApp(tester, store, date: date);
      expect(find.textContaining('在别处被改过'), findsNothing);

      await tester.enterText(find.byKey(bodyField), '电脑上又加了一句');
      await tester.pump();
      await tester.pump(
        DiaryController.saveDelay + const Duration(milliseconds: 200),
      );
      await tester.pump();

      expect(controller.lastConflictPath, conflictPath);
      expect(find.textContaining('在别处被改过'), findsOneWidget);
      expect(find.textContaining('两边都没有丢'), findsOneWidget);
      // 这条提示必须一直留着，不能做成几秒后消失的提示——
      // 那等于把冲突埋起来，和静默覆盖只差一步。
      await tester.pump(const Duration(seconds: 30));
      expect(find.textContaining('在别处被改过'), findsOneWidget);

      // 用图标定位而不是 byTooltip：Tooltip 的渲染盒不是按钮本身，
      // 按它算出来的坐标点未必能命中按钮。
      await tester.tap(find.widgetWithIcon(IconButton, Icons.close));
      await tester.pump();
      expect(find.textContaining('在别处被改过'), findsNothing);
    });
  });

  group('每日一问与时光机', () {
    testWidgets('空白的一天显示写作引子，点「换一个」会换', (tester) async {
      final controller = await pumpApp(tester, MemoryDiaryStore());

      expect(find.text('换一个'), findsOneWidget);
      final first = controller.dailyPrompt.text;
      expect(find.text(first), findsOneWidget);
      expect(find.text(controller.dailyPrompt.category), findsOneWidget);

      await tester.tap(find.text('换一个'));
      await tester.pump();

      expect(controller.dailyPrompt.text, isNot(first));
      expect(find.text(controller.dailyPrompt.text), findsOneWidget);
    });

    testWidgets('开始写之后引子就不显示了', (tester) async {
      await pumpApp(tester, MemoryDiaryStore());
      expect(find.text('换一个'), findsOneWidget);

      await tester.enterText(find.byKey(bodyField), '写了点东西');
      await tester.pump();

      expect(find.text('换一个'), findsNothing,
          reason: '已经有内容了就不该再占着编辑区的高度');
    });

    testWidgets('只填了天气也算开始写了', (tester) async {
      await pumpApp(tester, MemoryDiaryStore());
      expect(find.text('换一个'), findsOneWidget);

      await tester.tap(find.text('晴'));
      await tester.pump();

      expect(find.text('换一个'), findsNothing);
    });

    testWidgets('有时光机入口，点了会跳到以前写过的一天', (tester) async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 2, 10), device: 'test', body: '旧的这一天'));
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 2, 11), device: 'test', body: '也写过'));

      final controller =
          await pumpApp(tester, store, date: DateTime(2026, 2, 12));

      await tester.tap(find.byTooltip('时光机：随机翻一篇以前写的日记'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(controller.selectedDate, isNot(DateTime(2026, 2, 12)),
          reason: '应该跳到别的某一天');
      expect(find.textContaining('时光机：翻到了'), findsOneWidget);
    });

    testWidgets('没有可翻的日记时给出提示，而不是静默失败', (tester) async {
      await pumpApp(tester, MemoryDiaryStore());

      await tester.tap(find.byTooltip('时光机：随机翻一篇以前写的日记'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('还没有以前写过的日记可以翻。'), findsOneWidget);
    });
  });

  group('字体与格式', () {
    Future<void> settleSave(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(
        DiaryController.saveDelay + const Duration(milliseconds: 200),
      );
      await tester.pump();
    }

    Future<void> selectBody(WidgetTester tester, int start, int end) async {
      final field = tester.widget<TextField>(find.byKey(bodyField));
      field.controller!.selection =
          TextSelection(baseOffset: start, extentOffset: end);
      await tester.pump();
    }

    testWidgets('字号、行距、字重会作用到正文输入框', (tester) async {
      final settings = SettingsController(
        initial: const AppSettings(
          diaryRoot: 'memory',
          typography: EditorTypography(
            fontSize: 24,
            lineHeight: 2.5,
            fontWeightValue: 600,
            lineWidth: 900,
          ),
        ),
        repository: _FakeSettingsRepository(),
      );
      await pumpApp(tester, MemoryDiaryStore(), settings: settings);

      final field = tester.widget<TextField>(find.byKey(bodyField));
      expect(field.style?.fontSize, 24);
      expect(field.style?.height, 2.5);
      expect(field.style?.fontWeight, FontWeight.w600);
    });

    testWidgets('改设置后正文立刻跟着变', (tester) async {
      final settings = SettingsController(
        initial: const AppSettings(diaryRoot: 'memory'),
        repository: _FakeSettingsRepository(),
      );
      await pumpApp(tester, MemoryDiaryStore(), settings: settings);

      expect(
        tester.widget<TextField>(find.byKey(bodyField)).style?.fontSize,
        EditorTypography.defaultFontSize,
      );

      await settings.setTypography(const EditorTypography(fontSize: 22));
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byKey(bodyField)).style?.fontSize,
        22,
      );
    });

    testWidgets('加粗按钮把选中文字包成 Markdown 标记，并且真的会被保存', (tester) async {
      final store = MemoryDiaryStore();
      final controller = await pumpApp(tester, store);

      await tester.enterText(find.byKey(bodyField), '今天很好');
      await tester.pump();
      await selectBody(tester, 2, 4);

      await tester.tap(find.byTooltip('加粗（Ctrl+B）'));
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byKey(bodyField)).controller!.text,
        '今天**很好**',
      );

      // 这一步是重点：直接改 controller 不会触发 onChanged，
      // 漏了手动通知的话格式改了却不会保存，下次打开就没了。
      await settleSave(tester);
      expect(
        (await store.loadByDate(controller.selectedDate))?.body,
        '今天**很好**',
      );
    });

    testWidgets('再点一次同一个按钮就取消格式', (tester) async {
      await pumpApp(tester, MemoryDiaryStore());

      await tester.enterText(find.byKey(bodyField), '今天很好');
      await tester.pump();
      await selectBody(tester, 2, 4);

      await tester.tap(find.byTooltip('加粗（Ctrl+B）'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byKey(bodyField)).controller!.text,
        '今天**很好**',
      );

      // 包完之后内容仍处于选中状态，所以再点一次应该拆掉标记
      await tester.tap(find.byTooltip('加粗（Ctrl+B）'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byKey(bodyField)).controller!.text,
        '今天很好',
      );
    });

    testWidgets('下划线按钮插入 <u> 标签', (tester) async {
      await pumpApp(tester, MemoryDiaryStore());

      await tester.enterText(find.byKey(bodyField), '重点');
      await tester.pump();
      await selectBody(tester, 0, 2);

      await tester.tap(find.byTooltip('下划线（Ctrl+U，会插入 <u> 标签）'));
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byKey(bodyField)).controller!.text,
        '<u>重点</u>',
      );
    });

    testWidgets('外观菜单里能打开字体与行距设置，改字重会落盘', (tester) async {
      final repository = _FakeSettingsRepository();
      final settings = SettingsController(
        initial: const AppSettings(diaryRoot: 'memory'),
        repository: repository,
      );
      await pumpApp(tester, MemoryDiaryStore(), settings: settings);

      await tester.tap(find.byTooltip('外观：跟随系统'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.textContaining('字体与行距'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('字体与行距'), findsOneWidget);
      expect(find.text('预览'), findsOneWidget);

      await tester.tap(find.text('加粗'));
      await tester.pump();

      expect(settings.typography.fontWeightValue, 600);
      expect(repository.saved?.typography.fontWeightValue, 600);
    });

    testWidgets('排版设置不会被写进日记文件', (tester) async {
      final store = MemoryDiaryStore();
      final settings = SettingsController(
        initial: const AppSettings(
          diaryRoot: 'memory',
          typography: EditorTypography(
            fontSize: 24,
            lineHeight: 2.5,
            fontWeightValue: 600,
          ),
        ),
        repository: _FakeSettingsRepository(),
      );
      final controller = await pumpApp(tester, store, settings: settings);

      await tester.enterText(find.byKey(bodyField), '内容');
      await settleSave(tester);

      final saved = await store.loadByDate(controller.selectedDate);
      final encoded = DiaryCodec.encode(saved!);

      expect(saved.body, '内容');
      for (final leaked in <String>[
        'fontSize',
        'lineHeight',
        'fontWeight',
        'typography',
      ]) {
        expect(encoded, isNot(contains(leaked)),
            reason: '排版是显示设置，绝不能进日记文件');
      }
    });

    testWidgets('窄窗口下格式条不会把布局挤坏', (tester) async {
      await pumpApp(tester, MemoryDiaryStore(), size: const Size(680, 600));

      expect(find.byKey(bodyField), findsOneWidget);
      expect(find.byTooltip('加粗（Ctrl+B）'), findsOneWidget);
      expect(find.byTooltip('下划线（Ctrl+U，会插入 <u> 标签）'), findsOneWidget);
    });
  });

  group('撤销不会跨日期', () {
    // 回归测试。曾经的行为：切到别的日期再切回来按 Ctrl+Z，会把**那一天**
    // 的内容灌进当前这天，并在 900ms 后自动保存落盘——原内容没有任何副本。
    //
    // 根因：Flutter 的撤销栈记录 controller 的每一次值变化，不区分是用户敲的
    // 还是程序赋的；而本程序所有日期共用一个 controller，所以撤销栈里混着
    // 好几天的内容。修法是让输入框子树随 bodyRevision 重建（撤销栈随之清空）。
    Future<void> pressCtrlZ(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    String bodyText(WidgetTester tester) =>
        tester.widget<TextField>(find.byKey(bodyField)).controller!.text;

    testWidgets('切到别的日期改一笔再回来，Ctrl+Z 不会灌入那一天的内容', (tester) async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 10, 4), device: 'test', body: '四号原本的内容'));
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 10, 3), device: 'test', body: '三号的内容'));
      await pumpApp(tester, store, date: DateTime(2026, 10, 4));

      // 去隔壁改一笔
      await tester.tap(find.byTooltip('前一天'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(bodyText(tester), '三号的内容');

      await tester.enterText(find.byKey(bodyField), '三号被我改了一笔');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));

      // 回来
      await tester.tap(find.byTooltip('后一天'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(bodyText(tester), '四号原本的内容');

      await pressCtrlZ(tester);
      await tester.pump(const Duration(milliseconds: 1500));

      expect(bodyText(tester), '四号原本的内容',
          reason: '撤销不该把别的日期的内容装进来');
      expect(
        (await store.loadByDate(DateTime(2026, 10, 4)))?.body,
        '四号原本的内容',
        reason: '更不能被自动保存写进磁盘',
      );
      expect(
        (await store.loadByDate(DateTime(2026, 10, 3)))?.body,
        '三号被我改了一笔',
        reason: '另一天的内容也要完好',
      );
    });

    testWidgets('只是来回翻看、按 Ctrl+Z，内容同样不受影响', (tester) async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 10, 4), device: 'test', body: '四号的内容'));
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 10, 3), device: 'test', body: '三号的内容'));
      await pumpApp(tester, store, date: DateTime(2026, 10, 4));

      await tester.tap(find.byTooltip('前一天'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.tap(find.byTooltip('后一天'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));

      await pressCtrlZ(tester);
      await tester.pump(const Duration(milliseconds: 1500));

      expect(bodyText(tester), '四号的内容');
      expect((await store.loadByDate(DateTime(2026, 10, 4)))?.body, '四号的内容');
    });
  });

  group('农历、节日与节气', () {
    MemoryDiaryStore withEntry(DateTime date, String body) {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(date: date, device: 'test', body: body));
      return store;
    }

    testWidgets('列表里显示农历日期', (tester) async {
      await pumpApp(tester, withEntry(DateTime(2026, 3, 10), '普通的一天'),
          date: DateTime(2026, 3, 10));

      // 2026-03-10 是农历正月廿二
      expect(find.textContaining('正月廿二'), findsOneWidget);
    });

    testWidgets('阳历节日显示在阳历日期那一行', (tester) async {
      await pumpApp(tester, withEntry(DateTime(2026, 10, 1), '国庆'),
          date: DateTime(2026, 10, 1));

      expect(find.text('国庆节'), findsOneWidget);

      // 位置验证：两者的纵坐标应该几乎一样
      final dateY = tester.getCenter(find.text('2026-10-01')).dy;
      final festivalY = tester.getCenter(find.text('国庆节')).dy;
      expect((festivalY - dateY).abs(), lessThan(6),
          reason: '阳历节日应该和阳历日期在同一行');
    });

    testWidgets('阴历节日显示在农历那一行，也就是阳历日期的下面', (tester) async {
      await pumpApp(tester, withEntry(DateTime(2026, 2, 17), '过年'),
          date: DateTime(2026, 2, 17));

      expect(find.textContaining('春节 · 正月初一'), findsOneWidget);

      final dateY = tester.getCenter(find.text('2026-02-17')).dy;
      final lunarLineY =
          tester.getCenter(find.textContaining('春节 · 正月初一')).dy;
      expect(lunarLineY, greaterThan(dateY),
          reason: '阴历节日不该出现在阳历日期那一行');
    });

    testWidgets('节气也在农历那一行，且排在农历日期后面', (tester) async {
      // 正文故意不含「立春」两个字：否则 find.textContaining 会同时命中
      // 列表行和编辑框，定位就失效了。
      await pumpApp(tester, withEntry(DateTime(2026, 2, 4), '春天来了'),
          date: DateTime(2026, 2, 4));

      final annotation = ChineseCalendar.annotate(DateTime(2026, 2, 4));
      expect(annotation.solarTerm, '立春');
      expect(annotation.lunarLine, endsWith('立春'));

      final dateY = tester.getCenter(find.text('2026-02-04')).dy;
      final lineY = tester.getCenter(find.textContaining('立春')).dy;
      expect(lineY, greaterThan(dateY), reason: '节气也在第二行');
    });

    testWidgets('同一天既是阳历节日又是阴历节日时，两边都显示', (tester) async {
      // 先找一天重合的
      DateTime? both;
      var probe = DateTime(1950, 1, 1);
      while (both == null && !probe.isAfter(DateTime(2100, 12, 31))) {
        final a = ChineseCalendar.annotate(probe);
        if (a.solarFestival != null && a.lunarFestival != null) both = probe;
        probe = DateTime(probe.year, probe.month, probe.day + 1);
      }
      expect(both, isNotNull);

      await pumpApp(tester, withEntry(both!, '重合的一天'), date: both);

      // 上面那个 `both!` 已经把 both 提升成非空类型了，这里不用再写 !
      final annotation = ChineseCalendar.annotate(both);
      // 阳历节日在第一行，阴历节日在第二行
      expect(find.text(annotation.solarFestival!), findsOneWidget);
      expect(
        find.textContaining(
            '${annotation.lunarFestival} · ${annotation.lunar!.text}'),
        findsOneWidget,
      );
    });

    testWidgets('普通日子只有农历，没有节日和节气', (tester) async {
      await pumpApp(tester, withEntry(DateTime(2026, 3, 10), '普通的一天'),
          date: DateTime(2026, 3, 10));

      final annotation = ChineseCalendar.annotate(DateTime(2026, 3, 10));
      expect(annotation.solarFestival, isNull);
      expect(annotation.lunarFestival, isNull);
      expect(annotation.solarTerm, isNull);
      expect(find.textContaining(annotation.lunar!.text), findsOneWidget);
    });

    testWidgets('范围外的日期不会显示农历（宁可空着也不显示错的）', (tester) async {
      await pumpApp(tester, withEntry(DateTime(1949, 3, 10), '很久以前'),
          date: DateTime(1949, 3, 10));

      final annotation = ChineseCalendar.annotate(DateTime(1949, 3, 10));
      expect(annotation.isEmpty, isTrue);

      // 正文在列表预览和编辑框里各出现一次，所以是 findsWidgets 而不是 findsOneWidget
      expect(find.textContaining('很久以前'), findsWidgets);
      // 真正要验证的是：没有多出农历那一行
      expect(find.textContaining('正月'), findsNothing);
      expect(find.textContaining('腊月'), findsNothing);
    });
  });

  group('右下角更多菜单', () {
    Future<void> pumpFrames(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    Future<void> openMoreMenu(WidgetTester tester) async {
      await tester.tap(find.byTooltip('更多'));
      await pumpFrames(tester);
    }

    MemoryDiaryStore storeWith(String body) {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 10, 4),
        device: 'test',
        body: body,
      ));
      return store;
    }

    testWidgets('菜单项齐全，顺序是打开文件夹 → 存储位置 → 导出 → 备份 → 历史 → 回收站 → 删除',
        (tester) async {
      await pumpApp(tester, storeWith('有内容'), date: DateTime(2026, 10, 4));
      await openMoreMenu(tester);

      const labels = <String>[
        '打开日记文件夹',
        '日记存储位置',
        '导出',
        '备份',
        '历史版本',
        '回收站',
        '删除这一天的日记',
      ];

      // 用纵坐标验证顺序，而不是只验证"文字存在"——
      // 顺序排错了，只查存在性的测试照样会通过。
      final tops = <String, double>{};
      for (final label in labels) {
        expect(find.text(label), findsOneWidget, reason: '菜单里应该有「$label」');
        tops[label] = tester.getCenter(find.text(label)).dy;
      }

      for (var i = 1; i < labels.length; i++) {
        expect(
          tops[labels[i]]!,
          greaterThan(tops[labels[i - 1]]!),
          reason: '「${labels[i]}」应该排在「${labels[i - 1]}」下面',
        );
      }
    });

    testWidgets('更多按钮在窗口右下角', (tester) async {
      const size = Size(1200, 800);
      await pumpApp(tester, storeWith('有内容'),
          date: DateTime(2026, 10, 4), size: size);

      final center = tester.getCenter(find.byTooltip('更多'));

      expect(center.dx, greaterThan(size.width * 0.9),
          reason: '要贴着右边，不能在偏中间的位置');
      expect(center.dy, greaterThan(size.height * 0.9),
          reason: '要贴着底部');
    });

    testWidgets('状态栏不再常驻「打开日记文件夹」和「导出」', (tester) async {
      await pumpApp(tester, storeWith('有内容'), date: DateTime(2026, 10, 4));

      // 这两个入口现在只在菜单里。菜单没打开时，界面上不该有它们。
      expect(find.byTooltip('打开日记文件夹'), findsNothing);
      expect(find.widgetWithText(TextButton, '导出'), findsNothing);
      expect(find.text('导出'), findsNothing);
    });

    testWidgets('左侧栏底部不再有「日记存储位置」按钮', (tester) async {
      await pumpApp(tester, storeWith('有内容'), date: DateTime(2026, 10, 4));

      expect(find.text('日记存储位置'), findsNothing);
      // 侧栏底部的篇数统计还在
      expect(find.textContaining('共 1 篇'), findsOneWidget);
    });

    testWidgets('从菜单里点「打开日记文件夹」不会崩', (tester) async {
      // 测试环境没有资源管理器，这里只验证这条路径不会抛异常
      // （真机上它调用 explorer /select）。
      await pumpApp(tester, storeWith('有内容'), date: DateTime(2026, 10, 4));
      await openMoreMenu(tester);
      await tester.tap(find.text('打开日记文件夹'));
      await pumpFrames(tester);

      expect(find.text('打开日记文件夹'), findsNothing, reason: '菜单应该已经关掉');
    });

    testWidgets('点「导出」走的是导出流程', (tester) async {
      // 内存存储下导出会抛 UnsupportedError，界面必须把它变成一句提示
      // 而不是崩掉——这条路径以前是常驻按钮，现在在菜单里，同样要成立。
      await pumpApp(tester, storeWith('要导出的内容'), date: DateTime(2026, 10, 4));
      await openMoreMenu(tester);
      await tester.tap(find.text('导出'));
      await pumpFrames(tester);

      expect(find.textContaining('导出'), findsWidgets);
    });
  });

  group('历史版本与回收站', () {
    Future<void> pumpFrames(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    Future<void> openMoreMenu(WidgetTester tester) async {
      await tester.tap(find.byTooltip('更多'));
      await pumpFrames(tester);
    }

    /// 等 SnackBar 自己消失。
    ///
    /// 删除之后会弹出 SnackBar，而它盖在状态栏上方——「更多」按钮就在那里。
    /// 不等它走，后面 tap('更多') 会打到 SnackBar 上，菜单根本不会打开。
    Future<void> dismissSnackBar(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await pumpFrames(tester);
    }

    MemoryDiaryStore storeWith(String body) {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 10, 4),
        device: 'test',
        body: body,
      ));
      return store;
    }

    String bodyText(WidgetTester tester) =>
        tester.widget<TextField>(find.byKey(bodyField)).controller!.text;

    testWidgets('更多菜单里有历史、回收站和删除三项', (tester) async {
      await pumpApp(tester, MemoryDiaryStore(), date: DateTime(2026, 10, 4));
      await openMoreMenu(tester);

      expect(find.text('历史版本'), findsOneWidget);
      expect(find.text('回收站'), findsOneWidget);
      // 空白的一天没什么可删的，这一项要禁用而不是隐藏——
      // 隐藏会让人以为"没这个功能"，禁用并说明原因才看得懂
      expect(find.text('这一天还没写东西'), findsOneWidget);
    });

    testWidgets('写了内容之后删除项才可用', (tester) async {
      await pumpApp(tester, storeWith('有内容'), date: DateTime(2026, 10, 4));
      await openMoreMenu(tester);

      expect(find.text('删除这一天的日记'), findsOneWidget);
    });

    testWidgets('历史面板列出「打开时的样子」', (tester) async {
      await pumpApp(tester, storeWith('原本的内容'), date: DateTime(2026, 10, 4));

      await openMoreMenu(tester);
      await tester.tap(find.text('历史版本'));
      await pumpFrames(tester);

      expect(find.textContaining('历史版本 · 2026-10-04'), findsOneWidget);
      expect(find.text('打开时的样子'), findsOneWidget);
      expect(find.textContaining('原本的内容'), findsWidgets);
    });

    testWidgets('在历史面板里留一份当前版本', (tester) async {
      await pumpApp(tester, storeWith('第一版'), date: DateTime(2026, 10, 4));

      await tester.enterText(find.byKey(bodyField), '第二版');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));

      await openMoreMenu(tester);
      await tester.tap(find.text('历史版本'));
      await pumpFrames(tester);

      await tester.tap(find.text('留一份当前版本'));
      await pumpFrames(tester);

      expect(find.text('手动保存的版本'), findsOneWidget);
      expect(find.textContaining('已经留了一份当前版本'), findsOneWidget);
    });

    testWidgets('恢复历史版本要确认，确认后正文变回去', (tester) async {
      await pumpApp(tester, storeWith('原始内容'), date: DateTime(2026, 10, 4));

      await tester.enterText(find.byKey(bodyField), '被改坏的内容');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(bodyText(tester), '被改坏的内容');

      await openMoreMenu(tester);
      await tester.tap(find.text('历史版本'));
      await pumpFrames(tester);

      await tester.tap(find.text('恢复'));
      await pumpFrames(tester);
      expect(find.text('恢复这一版？'), findsOneWidget);
      expect(find.textContaining('不会丢'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '恢复'));
      await pumpFrames(tester);

      expect(bodyText(tester), '原始内容');
      expect(find.textContaining('已恢复到'), findsOneWidget);
    });

    testWidgets('删除要走确认，确认后列表里消失、回收站里能找到', (tester) async {
      await pumpApp(tester, storeWith('要被删掉的内容'), date: DateTime(2026, 10, 4));

      await openMoreMenu(tester);
      await tester.tap(find.text('删除这一天的日记'));
      await pumpFrames(tester);
      expect(find.text('删除这一天的日记？'), findsOneWidget);
      expect(find.textContaining('不会被抹掉'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await pumpFrames(tester);

      expect(bodyText(tester), isEmpty);
      expect(find.textContaining('要被删掉的内容'), findsNothing);
      expect(find.textContaining('可在「回收站」里找回'), findsOneWidget);

      await dismissSnackBar(tester);
      await openMoreMenu(tester);
      await tester.tap(find.text('回收站'));
      await pumpFrames(tester);
      expect(find.text('回收站'), findsOneWidget);
      expect(find.textContaining('要被删掉的内容'), findsWidgets);
    });

    testWidgets('从回收站恢复：内容回到那一天', (tester) async {
      final store = storeWith('误删的内容');
      await pumpApp(tester, store, date: DateTime(2026, 10, 4));

      await openMoreMenu(tester);
      await tester.tap(find.text('删除这一天的日记'));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await pumpFrames(tester);

      await dismissSnackBar(tester);
      await openMoreMenu(tester);
      await tester.tap(find.text('回收站'));
      await pumpFrames(tester);
      await tester.tap(find.text('恢复'));
      await pumpFrames(tester);

      expect(find.textContaining('已恢复'), findsOneWidget);
      expect((await store.loadByDate(DateTime(2026, 10, 4)))!.body, '误删的内容');
    });

    testWidgets('永久删除要二次确认，取消之后内容还在', (tester) async {
      final store = storeWith('不该被抹掉的内容');
      await pumpApp(tester, store, date: DateTime(2026, 10, 4));

      await openMoreMenu(tester);
      await tester.tap(find.text('删除这一天的日记'));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await pumpFrames(tester);

      await dismissSnackBar(tester);
      await openMoreMenu(tester);
      await tester.tap(find.text('回收站'));
      await pumpFrames(tester);

      await tester.tap(find.byTooltip('永久删除'));
      await pumpFrames(tester);
      expect(find.text('永久删除？'), findsOneWidget);
      expect(find.textContaining('无法恢复'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await pumpFrames(tester);

      // 取消之后一条都不能少
      expect(await store.listTrash(), hasLength(1));
      expect(find.textContaining('不该被抹掉的内容'), findsWidgets);
    });

    testWidgets('回收站为空时给出说明，而不是一个空白面板', (tester) async {
      await pumpApp(tester, storeWith('有内容'), date: DateTime(2026, 10, 4));

      await openMoreMenu(tester);
      await tester.tap(find.text('回收站'));
      await pumpFrames(tester);

      expect(find.text('回收站是空的。'), findsOneWidget);
    });
  });

  group('黄历悬浮卡片', () {
    Future<void> pumpFrames(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    MemoryDiaryStore storeWith(DateTime date, String body) {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(date: date, device: 'test', body: body));
      return store;
    }

    testWidgets('鼠标悬停一会儿之后弹出黄历卡片', (tester) async {
      final date = DateTime(2026, 10, 4);
      await pumpApp(tester, storeWith(date, '内容'), date: date);

      // 2026-10-04：丙午年 丁酉月 辛亥日，冲巳（蛇），煞西
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.text('2026-10-04')));
      await pumpFrames(tester);

      // 延迟没到之前不该出现
      expect(find.textContaining('传统历注'), findsNothing,
          reason: '鼠标刚移上去就弹卡片会很吵');

      await tester.pump(const Duration(milliseconds: 800));
      await pumpFrames(tester);

      expect(find.text('丙午年 丁酉月 辛亥日'), findsOneWidget);
      expect(find.textContaining('冲蛇'), findsOneWidget);
      expect(find.textContaining('煞西'), findsOneWidget);
      expect(find.text('宜'), findsOneWidget);
      expect(find.text('忌'), findsOneWidget);
      expect(find.textContaining('传统历注'), findsOneWidget,
          reason: '宜忌必须标注它不是事实');
    });

    testWidgets('长按也能弹出（手机上没有 hover）', (tester) async {
      final date = DateTime(2026, 10, 4);
      await pumpApp(tester, storeWith(date, '内容'), date: date);

      await tester.longPress(find.text('2026-10-04'));
      await pumpFrames(tester);

      expect(find.text('丙午年 丁酉月 辛亥日'), findsOneWidget);
      expect(find.textContaining('冲蛇'), findsOneWidget);
    });

    testWidgets('卡片显示具体的宜忌词', (tester) async {
      final date = DateTime(2026, 10, 4);
      await pumpApp(tester, storeWith(date, '内容'), date: date);

      await tester.longPress(find.text('2026-10-04'));
      await pumpFrames(tester);

      // 这一天 lunar_python 给的宜里有「出行」，忌里有「嫁娶」
      expect(find.text('出行'), findsWidgets);
      expect(find.text('嫁娶'), findsWidgets);
    });

    testWidgets('超出黄历范围（2000–2060）不弹卡片', (tester) async {
      final date = DateTime(1990, 5, 1);
      await pumpApp(tester, storeWith(date, '很久以前'), date: date);

      await tester.longPress(find.text('1990-05-01'));
      await pumpFrames(tester);

      // 宁可什么都不显示，也不显示错的。
      // 注意不能拿「年 」当判断依据——编辑器标题里的中文日期
      // （1990 年 5 月 1 日）也含这个，会误判。
      expect(find.textContaining('传统历注'), findsNothing);
      expect(find.text('宜'), findsNothing);
      expect(find.text('忌'), findsNothing);
    });

    testWidgets('鼠标移开之后卡片会消失', (tester) async {
      final date = DateTime(2026, 10, 4);
      await pumpApp(tester, storeWith(date, '内容'), date: date);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.text('2026-10-04')));
      await tester.pump(const Duration(milliseconds: 800));
      await pumpFrames(tester);
      expect(find.text('丙午年 丁酉月 辛亥日'), findsOneWidget);

      // 移到列表外面
      await gesture.moveTo(const Offset(5, 5));
      await pumpFrames(tester);
      await tester.pump(const Duration(milliseconds: 300));
      await pumpFrames(tester);

      expect(find.text('丙午年 丁酉月 辛亥日'), findsNothing);
    });

    testWidgets('卡片不会挡住点击（它是只读的）', (tester) async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 10, 3), device: 'test', body: '前一天'));
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 10, 4), device: 'test', body: '当天'));
      await pumpApp(tester, store, date: DateTime(2026, 10, 4));

      await tester.longPress(find.text('2026-10-04'));
      await pumpFrames(tester);
      expect(find.text('丙午年 丁酉月 辛亥日'), findsOneWidget);

      // 卡片浮在写作区上面，但它是 IgnorePointer，所以点击照样生效
      await tester.tap(find.byKey(bodyField));
      await pumpFrames(tester);
      expect(find.byKey(bodyField), findsOneWidget);
    });
  });

  group('深色模式', () {
    Brightness brightnessOf(WidgetTester tester) =>
        Theme.of(tester.element(find.byKey(bodyField))).brightness;

    SettingsController withMode(AppThemeMode mode) => SettingsController(
          initial: AppSettings(diaryRoot: 'memory', themeMode: mode),
        );

    testWidgets('深色模式下界面真的是深色', (tester) async {
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: withMode(AppThemeMode.dark),
      );

      expect(brightnessOf(tester), Brightness.dark);
    });

    testWidgets('浅色模式下界面是浅色', (tester) async {
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: withMode(AppThemeMode.light),
      );

      expect(brightnessOf(tester), Brightness.light);
    });

    testWidgets('跟随系统时会跟着系统亮度走', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      // 默认就是「跟随系统」
      await pumpApp(tester, MemoryDiaryStore());

      expect(brightnessOf(tester), Brightness.dark);
    });

    testWidgets('通过外观菜单切换，并且真的写进了设置', (tester) async {
      final repository = _FakeSettingsRepository();
      final settings = SettingsController(
        initial: const AppSettings(diaryRoot: 'memory'),
        repository: repository,
      );
      await pumpApp(tester, MemoryDiaryStore(), settings: settings);

      expect(brightnessOf(tester), Brightness.light);

      await tester.tap(find.byTooltip('外观：跟随系统'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();

      expect(settings.themeMode, AppThemeMode.dark);
      expect(brightnessOf(tester), Brightness.dark);
      expect(repository.saved?.themeMode, AppThemeMode.dark,
          reason: '切换后必须落盘，否则重启就白切了');
    });

    testWidgets('再切回浅色也能生效', (tester) async {
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: withMode(AppThemeMode.dark),
      );
      expect(brightnessOf(tester), Brightness.dark);

      await tester.tap(find.byTooltip('外观：深色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('浅色'));
      await tester.pumpAndSettle();

      expect(brightnessOf(tester), Brightness.light);
    });

    testWidgets('深色模式下窄窗口布局同样不溢出', (tester) async {
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        size: const Size(700, 620),
        settings: withMode(AppThemeMode.dark),
      );

      expect(find.byKey(bodyField), findsOneWidget);
      expect(brightnessOf(tester), Brightness.dark);
    });
  });

  group('命令面板', () {
    const queryField = Key('command-palette-query');

    Brightness brightnessOf(WidgetTester tester) =>
        Theme.of(tester.element(find.byKey(bodyField))).brightness;

    Finder searchField() => find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.hintText == '搜索日记…',
        );

    bool searchHasFocus(WidgetTester tester) =>
        tester.widget<TextField>(searchField()).focusNode?.hasFocus ?? false;


    /// 面板输入框用的是 `autofocus`，所以 `TextField.focusNode` 是 null。
    /// 要判断它有没有焦点，得问真正持有焦点的那个 `EditableText`。
    bool queryHasFocus(WidgetTester tester) => tester
        .widget<EditableText>(find.descendant(
          of: find.byKey(queryField),
          matching: find.byType(EditableText),
        ))
        .focusNode
        .hasFocus;

    /// 按 Ctrl+K。
    ///
    /// 用真实的按键事件而不是直接调 `_openCommandPalette`：这一条要验的正是
    /// "键事件能不能从当前有焦点的控件冒泡到根部那一层"。
    Future<void> pressCtrlK(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    /// 在面板的输入框里按回车。
    ///
    /// 必须走 `receiveAction` 而不是发一个 Enter 按键：单行文本框的提交是
    /// 输入法动作（`TextInputAction`），不是键事件——测试环境里没有真的输入法，
    /// 发按键不会有任何反应。
    Future<void> pressEnter(WidgetTester tester) async {
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    Future<void> typeQuery(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(queryField), text);
      await tester.pumpAndSettle();
    }

    testWidgets('Ctrl+K 能唤出面板，输入筛选后回车就真的执行了', (tester) async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 10, 3), device: 'test', body: '三号的内容'));
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 10, 4), device: 'test', body: '四号的内容'));
      await pumpApp(tester, store, date: DateTime(2026, 10, 4));

      expect(find.byKey(queryField), findsNothing);

      await pressCtrlK(tester);
      expect(find.byKey(queryField), findsOneWidget);
      // 面板一开，光标应该在它自己的输入框里，用户可以直接打字
      expect(queryHasFocus(tester), isTrue);

      await typeQuery(tester, '前一天');
      await pressEnter(tester);

      // 面板关掉，并且命令真的执行了：翻到了前一天
      expect(find.byKey(queryField), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(bodyField))
            .controller
            ?.text,
        '三号的内容',
      );
    });

    testWidgets('面板的输入框不和正文共用一个 controller，关掉后焦点回到正文', (tester) async {
      await pumpApp(tester, MemoryDiaryStore());
      await tester.enterText(find.byKey(bodyField), '正文里的字');
      await tester.pump();

      await pressCtrlK(tester);
      await typeQuery(tester, '今天');

      // 在面板里打字，正文一个字都不该变
      expect(
        tester.widget<TextField>(find.byKey(bodyField)).controller?.text,
        '正文里的字',
        reason: '面板有它自己的输入框，不能和正文共用 controller',
      );

      // Esc 关掉（这条也顺带说明：Esc 能关面板）
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(queryField), findsNothing);

      // 关掉之后必须能接着写：焦点要回到正文，否则用户打的第一句会掉进空气里
      await tester.pumpAndSettle();
      expect(bodyHasFocus(tester), isTrue);
    });

    testWidgets('方向键能移动选择：向下一次再回车，执行的是第二条', (tester) async {
      await pumpApp(tester, MemoryDiaryStore());

      await pressCtrlK(tester);
      // 「外观：」命中三条，按相关度排是 浅色 → 深色 → 跟随系统
      // （浅色和深色同分，按注册顺序）
      await typeQuery(tester, '外观：');

      // 先确认默认落在第一条：直接回车应该是浅色
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await pressEnter(tester);

      expect(brightnessOf(tester), Brightness.dark,
          reason: '按了一次下键，执行的应该是第二条（深色）而不是第一条（浅色）');
    });

    testWidgets('按钮也是入口：只留快捷键等于没有入口', (tester) async {
      await pumpApp(tester, MemoryDiaryStore());

      await tester.tap(find.byTooltip('命令面板（Ctrl+K）'));
      await tester.pumpAndSettle();

      expect(find.byKey(queryField), findsOneWidget);
    });

    testWidgets('侧栏搜索框有焦点时，Ctrl+K 照样能唤出面板', (tester) async {
      // 这一条守的是面板挂在 HomePage 而不是 EditorPanel 的决定：
      // 键事件只向上冒泡，挂在写作区里面就够不到侧栏。
      await pumpApp(tester, MemoryDiaryStore());

      await tester.tap(searchField());
      await tester.pumpAndSettle();
      expect(searchHasFocus(tester), isTrue);

      await pressCtrlK(tester);
      expect(find.byKey(queryField), findsOneWidget);
    });

    testWidgets('「搜索日记」把光标送进搜索框，而不是还回正文', (tester) async {
      await pumpApp(tester, MemoryDiaryStore());

      await pressCtrlK(tester);
      await typeQuery(tester, '搜索日记');
      await pressEnter(tester);

      expect(searchHasFocus(tester), isTrue);
      expect(bodyHasFocus(tester), isFalse);
    });

    testWidgets('禁用的命令看得见、点不动，并且写着原因', (tester) async {
      // 空日记那一天，「删除这一天的日记」是禁用的。
      // 项目原则是**禁用而不是隐藏**，所以它必须出现在搜索结果里，
      // 而且"为什么不能点"要写在它自己那一行上。
      await pumpApp(tester, MemoryDiaryStore());

      await pressCtrlK(tester);
      await typeQuery(tester, '删除');

      expect(find.byKey(const ValueKey<String>('command-data.delete')),
          findsOneWidget);
      expect(find.text('这一天还没写东西'), findsOneWidget);

      await pressEnter(tester);

      // 禁用项按回车什么都不该发生：面板还开着，更不能弹出删除确认框
      expect(find.byKey(queryField), findsOneWidget);
      expect(find.text('删除这一天的日记？'), findsNothing);
    });

    testWidgets('面板开着时再按 Ctrl+K 不会叠出第二层', (tester) async {
      // 对话框是另一条路由，键事件不会冒泡回 HomePage 那一层，所以这一条
      // 验的是两层保护都在：路由的隔离 + `_paletteOpen` 那个守卫。
      await pumpApp(tester, MemoryDiaryStore());

      await pressCtrlK(tester);
      expect(find.byKey(queryField), findsOneWidget);

      await pressCtrlK(tester);
      expect(find.byKey(queryField), findsOneWidget,
          reason: '叠出两层的话，关掉上面那层会露出下面那层，很难受');
    });

    testWidgets('禁用项点不动：鼠标点它同样不执行', (tester) async {
      // 回车那条路径已经测过了（`_run` 里的判断）。这一条补上鼠标那条：
      // 行的 `onTap` 是 null，而不是"点了之后在别处被拦下来"。
      await pumpApp(tester, MemoryDiaryStore());

      await pressCtrlK(tester);
      await typeQuery(tester, '删除');

      await tester.tap(find.byKey(const ValueKey<String>('command-data.delete')));
      await tester.pumpAndSettle();

      expect(find.byKey(queryField), findsOneWidget);
      expect(find.text('删除这一天的日记？'), findsNothing);
    });

    testWidgets('从面板删除这一天，确认框照样会拦一道', (tester) async {
      // 命令面板是"第二道门"，不是"后门"：删除必须仍然走确认。
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 10, 4), device: 'test', body: '要被删掉的内容'));
      final controller =
          await pumpApp(tester, store, date: DateTime(2026, 10, 4));

      await pressCtrlK(tester);
      await typeQuery(tester, '删除');
      await pressEnter(tester);

      expect(find.text('删除这一天的日记？'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(controller.body, '要被删掉的内容');
      expect(await store.loadByDate(DateTime(2026, 10, 4)), isNotNull);
    });
  });

  group('本版更新', () {
    /// 一份小的合成更新记录。用合成文本而不是真实 CHANGELOG：
    /// 真实文件的内容会变，而这些测试要固定的是**行为**。
    const changelog = '''
# 更新记录

## 1.1.0 — 2026-10-03

### 新功能

- 命令面板：按 `Ctrl+K` 唤起
- 行尾显示**快捷键**

### 修复

- 修好了切日期时正文被清空

### 内部

- 这条不该进弹窗

## 1.0.0 — 2026-10-02

### 写作

- 这节不是给用户看的
''';

    ReleaseInfo infoFor(String version) =>
        ReleaseInfo(version: version, changeLog: ChangeLog.parse(changelog));

    SettingsController settingsWith(
      String? lastSeen, {
      SettingsRepository? repository,
    }) =>
        SettingsController(
          initial: AppSettings(
            diaryRoot: 'memory',
            lastSeenVersion: lastSeen,
          ),
          repository: repository ?? _FakeSettingsRepository(),
        );


    testWidgets('从旧版升上来时弹一次，四项信息都在', (tester) async {
      final repository = _FakeSettingsRepository();
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: settingsWith('1.0.0', repository: repository),
        releaseInfo: infoFor('1.1.0'),
      );

      expect(find.text('本版更新'), findsOneWidget);
      // 当前版本 + 发布时间
      expect(find.text('日迹 1.1.0'), findsOneWidget);
      expect(find.text('2026-10-03 发布'), findsOneWidget);
      // 新功能与 bug 修复
      expect(find.text('新功能'), findsOneWidget);
      expect(find.text('修复'), findsOneWidget);
      expect(find.textContaining('命令面板'), findsOneWidget);
      expect(find.textContaining('正文被清空'), findsOneWidget);

      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      expect(find.text('本版更新'), findsNothing);
      expect(repository.saved?.lastSeenVersion, '1.1.0',
          reason: '关掉之后必须把版本记下来，否则每次启动都会再弹一遍');
    });

    testWidgets('弹窗里不出现 Markdown 标记，也不出现内部小节', (tester) async {
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: settingsWith('1.0.0'),
        releaseInfo: infoFor('1.1.0'),
      );

      // `Ctrl+K` 的反引号和 **加粗** 的星号都该在解析时就去掉
      expect(find.text('命令面板：按 Ctrl+K 唤起'), findsOneWidget);
      expect(find.text('行尾显示快捷键'), findsOneWidget);
      expect(find.textContaining('`'), findsNothing);
      expect(find.textContaining('**'), findsNothing);
      // 「内部」那节一句都不该出现
      expect(find.textContaining('不该进弹窗'), findsNothing);
    });

    testWidgets('同一个版本第二次启动不再弹', (tester) async {
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: settingsWith('1.1.0'),
        releaseInfo: infoFor('1.1.0'),
      );

      expect(find.text('本版更新'), findsNothing);
    });

    testWidgets('第一次装不弹，但要把版本记下来', (tester) async {
      final repository = _FakeSettingsRepository();
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: settingsWith(null, repository: repository),
        releaseInfo: infoFor('1.1.0'),
      );

      expect(find.text('本版更新'), findsNothing,
          reason: '刚装上的人不需要看"这一版更新了什么"');

      // 这条是很多人会漏掉的：不记的话，下次升级时程序还认为这是首次安装，
      // 弹窗就永远不会出现了。
      expect(repository.saved?.lastSeenVersion, '1.1.0');
    });

    testWidgets('回退到旧版不弹', (tester) async {
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: settingsWith('2.0.0'),
        releaseInfo: infoFor('1.1.0'),
      );

      expect(find.text('本版更新'), findsNothing);
    });

    testWidgets('这一版没有写给用户看的内容时，绝不弹空框', (tester) async {
      // 1.0.0 那节只有「写作」，两节都没有
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: settingsWith('0.9.0'),
        releaseInfo: infoFor('1.0.0'),
      );

      expect(find.text('本版更新'), findsNothing);
    });

    testWidgets('读不到版本信息时，这个功能整个不出现（也不该崩）', (tester) async {
      // releaseInfo 不传＝null
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: settingsWith('1.0.0'),
      );

      expect(find.text('本版更新'), findsNothing);
      expect(find.byKey(bodyField), findsOneWidget);
    });

    testWidgets('关掉弹窗之后焦点回到正文，接着就能写', (tester) async {
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: settingsWith('1.0.0'),
        releaseInfo: infoFor('1.1.0'),
      );

      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      // 弹窗在启动时抢走了焦点，关掉之后必须还回来，
      // 否则用户打的第一句话会掉进空气里（「打开即写」那条）。
      expect(bodyHasFocus(tester), isTrue);
    });

    testWidgets('命令面板里的「本版更新」随时能再打开一次', (tester) async {
      // 弹窗只在升级后弹一次，所以必须留一个找得到的入口——
      // 做得出来却找不到等于没做。
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: settingsWith('1.1.0'),
        releaseInfo: infoFor('1.1.0'),
      );

      expect(find.text('本版更新'), findsNothing, reason: '同版本，启动时不弹');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('command-palette-query')),
        '更新',
      );
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('本版更新'), findsOneWidget);
      expect(find.text('日迹 1.1.0'), findsOneWidget);
    });

    testWidgets('这一版没内容时，「本版更新」这条命令置灰并写明原因', (tester) async {
      await pumpApp(
        tester,
        MemoryDiaryStore(),
        settings: settingsWith('1.1.0'),
        releaseInfo: infoFor('1.0.0'),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('command-palette-query')),
        '本版更新',
      );
      await tester.pumpAndSettle();

      expect(find.text('这一版没有写给用户看的更新内容'), findsOneWidget);
    });
  });

  group('写作日历', () {
    // 年视图的年份：用"今年"而不是写死 2026，否则这个测试到了明年就会红。
    final year = DateTime.now().year;
    DateTime day(int month, int dayOfMonth) => DateTime(year, month, dayOfMonth);

    // 月视图用的是"当前所在的那一天"所在的月份，所以可以写死日期，与今天无关。
    final march = DateTime(2026, 3, 14);

    Finder yearCell(DateTime date) =>
        find.byKey(ValueKey<String>('calendar-cell-${formatIsoDate(date)}'));

    Finder monthCell(DateTime date) =>
        find.byKey(ValueKey<String>('calendar-day-${formatIsoDate(date)}'));

    /// 只在对话框里找。
    ///
    /// 需要它是因为主界面上有一堆长得像的东西：编辑区标题里写着
    /// 「2026 年 1 月 15 日 星期四」（含「2026 年 1 月」），侧栏那个按钮也可能
    /// 正好叫「今天」（今天还没写时标签就是「今天」）。
    Finder inDialog(Finder matching) =>
        find.descendant(of: find.byType(AlertDialog), matching: matching);

    /// 某一格的实际颜色。用它验证"深浅真的按字数分"，而不是断言像素值。
    Color yearCellColor(WidgetTester tester, DateTime date) {
      final container = tester.widget<Container>(yearCell(date));
      return (container.decoration! as BoxDecoration).color!;
    }

    MemoryDiaryStore storeWith(List<DiaryEntry> entries) {
      final store = MemoryDiaryStore();
      for (final entry in entries) {
        store.seed(entry);
      }
      return store;
    }

    DiaryEntry written(DateTime date, String body, {String? mood}) =>
        DiaryEntry.create(date: date, device: 'test', body: body, mood: mood);

    /// 侧栏那个日历图标开在月视图。
    ///
    /// ⚠️ 这里是**按 tooltip 找按钮**的，所以改 `EntryListPanel` 里那句 tooltip
    /// 必须同步改这里，否则这一组测试全红（改代码位置见 docs/详细说明.md 的「写作日历」一节）。
    Future<void> openMonthView(WidgetTester tester) async {
      await tester.tap(find.byTooltip('月视图/年视图'));
      await tester.pumpAndSettle();
    }

    /// 打开年视图。
    ///
    /// 界面上**没有专门的按钮**了（右下角那个和侧栏图标重复，已删），
    /// 所以走"侧栏日历图标 → 切到年"这条真实路径；命令面板那条另有专门一条测试。
    Future<void> openYearView(WidgetTester tester) async {
      await openMonthView(tester);
      await tester.tap(find.text('年'));
      await tester.pumpAndSettle();
    }

    // -------------------------------------------------------------------------
    // 年视图
    // -------------------------------------------------------------------------

    testWidgets('状态栏按钮打开年视图：汇总、图例、星期列都在', (tester) async {
      await pumpApp(
        tester,
        storeWith(<DiaryEntry>[
          written(day(3, 14), 'a' * 382, mood: '平静'),
          written(day(3, 15), 'b' * 50),
          written(day(5, 1), 'c'),
        ]),
      );

      await openYearView(tester);

      expect(find.text('写作日历'), findsOneWidget);
      expect(find.textContaining('写了 3 天'), findsOneWidget);
      expect(find.textContaining('共 433 字'), findsOneWidget);
      expect(find.textContaining('最长连续 2 天'), findsOneWidget);
      // 档位写在图例上，别让用户猜"多少字算深色"
      expect(find.textContaining('按当天字数分档'), findsOneWidget);
      // 周一到周日的标签（单字，不会和别处的长文本撞）
      expect(find.text('一'), findsOneWidget);
      expect(find.text('日'), findsOneWidget);
    });

    testWidgets('深和浅真的按字数分：格子的颜色随档位变', (tester) async {
      await pumpApp(
        tester,
        storeWith(<DiaryEntry>[
          written(day(3, 14), 'a' * 800), // 最深
          written(day(3, 15), 'b' * 150), // 中间
        ]),
      );
      await openYearView(tester);

      final heavy = yearCellColor(tester, day(3, 14));
      final mid = yearCellColor(tester, day(3, 15));
      final none = yearCellColor(tester, day(3, 16)); // 没写过

      expect(heavy, isNot(mid));
      expect(mid, isNot(none));
      expect(heavy, isNot(none));
    });

    testWidgets('鼠标停在年视图的格子上，底下说出那一天', (tester) async {
      await pumpApp(
        tester,
        storeWith(<DiaryEntry>[
          written(day(3, 14), '今天把数据格式定下来了。', mood: '平静'),
        ]),
      );
      await openYearView(tester);

      expect(find.textContaining('鼠标停在格子上'), findsOneWidget);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(yearCell(day(3, 14))));
      await tester.pump();

      // 用「N 字 · 心情」这一整段来断言：单独一个「平静」会在心情预设里撞车。
      expect(find.textContaining('12 字 · 平静'), findsOneWidget);
      // 日期后面带「·」才是详情行；左侧列表里那一天是「2026-03-14 周六」。
      expect(
        find.textContaining('${formatIsoDate(day(3, 14))} · '),
        findsOneWidget,
      );
    });

    testWidgets('年视图点一下格子就跳到那一天，对话框关掉', (tester) async {
      final controller = await pumpApp(
        tester,
        storeWith(<DiaryEntry>[written(day(3, 14), '目标那天')]),
      );
      await openYearView(tester);

      await tester.tap(yearCell(day(3, 14)));
      await tester.pumpAndSettle();

      expect(find.text('写作日历'), findsNothing);
      expect(controller.selectedDate, day(3, 14));
    });

    testWidgets('这一年一天都没写时明说，而不是给一片空格子', (tester) async {
      await pumpApp(tester, MemoryDiaryStore());
      await openYearView(tester);

      expect(find.textContaining('还没有写过日记'), findsOneWidget);
      // 格子本身还是照画的——空年份也要看得出这是热力图
      expect(yearCell(day(3, 14)), findsOneWidget);
    });

    testWidgets('命令面板里搜「热力图」也能打开（落在年视图）', (tester) async {
      await pumpApp(
        tester,
        storeWith(<DiaryEntry>[written(day(3, 14), 'x')]),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('command-palette-query')),
        '热力图',
      );
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('写作日历'), findsOneWidget);
      expect(find.textContaining('最长连续'), findsOneWidget,
          reason: '年视图才有最长连续');
    });

    testWidgets('窄窗口下年视图不撑坏布局（格子横向滚动）', (tester) async {
      // 53 周 × 13px 约 690 宽，窄窗口必须还能用——溢出会让测试直接失败
      await pumpApp(
        tester,
        storeWith(<DiaryEntry>[written(day(3, 14), 'x')]),
        size: const Size(700, 620),
      );
      await openYearView(tester);

      expect(find.text('写作日历'), findsOneWidget);
      expect(yearCell(day(3, 14)), findsOneWidget);
    });

    // -------------------------------------------------------------------------
    // 月视图
    // -------------------------------------------------------------------------

    testWidgets('侧栏日历图标打开月视图：星期表头、日号、当月汇总都在', (tester) async {
      await pumpApp(
        tester,
        storeWith(<DiaryEntry>[
          written(march, '三月的这一天'),
          written(DateTime(2026, 3, 20), '三月二十号'),
          // 上个月的要被算在外，否则"只看这个月"就是假的
          written(DateTime(2026, 2, 28), '二月的'),
        ]),
        date: march,
      );

      await openMonthView(tester);

      expect(find.text('写作日历'), findsOneWidget);
      expect(monthCell(march), findsOneWidget);
      expect(monthCell(DateTime(2026, 3, 20)), findsOneWidget);
      expect(find.textContaining('2026 年 3 月 · 写了 2 天'), findsOneWidget);
      expect(find.textContaining('共 11 字'), findsOneWidget);
      // 上个月那一天不该出现在这个月的格子里
      expect(monthCell(DateTime(2026, 2, 28)), findsNothing);
    });

    testWidgets('没悬停时右侧已经显示当前打开的那一天（右边不留空）', (tester) async {
      await pumpApp(
        tester,
        storeWith(<DiaryEntry>[
          written(march, '今天把数据格式定下来了。', mood: '平静'),
        ]),
        date: march,
      );
      await openMonthView(tester);

      // 默认状态才是最常见的状态。如果这里只写"请把鼠标移上去"，
      // 那 300 多像素的右边在默认状态下就是纯浪费。
      expect(find.textContaining('12 字 · 平静'), findsOneWidget);
      expect(find.textContaining('鼠标停在格子上'), findsOneWidget);
    });

    testWidgets('月视图里当日简要放在格子右边，不是在底下', (tester) async {
      await pumpApp(
        tester,
        storeWith(<DiaryEntry>[
          written(march, '今天把数据格式定下来了。', mood: '平静'),
        ]),
        date: march,
      );
      await openMonthView(tester);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(monthCell(march)));
      await tester.pump();

      final facts = find.textContaining('12 字 · 平静');
      expect(facts, findsOneWidget);

      // 右边：简要的左边落在整个格子区右边之外
      // （2026-03-29 是周日，也就是最后一列）
      final factsRect = tester.getRect(facts);
      final lastColumn = tester.getRect(monthCell(DateTime(2026, 3, 29)));
      expect(factsRect.left, greaterThan(lastColumn.right),
          reason: '当日简要应该用上右边那片空白');

      // 而且和格子在同一段高度上——如果哪天有人把它挪回底下，这条会红
      expect(factsRect.top, lessThan(lastColumn.bottom));
    });

    testWidgets('月视图和年视图的对话框一样大（切换时不跳）', (tester) async {
      await pumpApp(tester, MemoryDiaryStore(), date: march);
      await openMonthView(tester);
      final monthSize = tester.getSize(find.byType(AlertDialog));

      await tester.tap(find.text('年'));
      await tester.pumpAndSettle();
      final yearSize = tester.getSize(find.byType(AlertDialog));

      expect(yearSize, monthSize,
          reason: '两个尺度共用同一块固定高度的格子区，切换时对话框不该跳');
    });

    // 两个尺度共用同一块「当日详细」，但两边都验一遍：
    // 万一以后有人给某一侧换了别的实现，这一条会立刻发现。
    for (final scale in <String>['月', '年']) {
      testWidgets('$scale视图的当日详细显示整篇正文，按能放下的行数截断', (tester) async {
        await pumpApp(
          tester,
          storeWith(<DiaryEntry>[
            written(
              march,
              '第一段。\n\n第二段也要能看见。\n\n第三段。',
              mood: '平静',
            ),
          ]),
          date: march,
        );
        await openMonthView(tester);
        if (scale == '年') {
          await tester.tap(find.text('年'));
          await tester.pumpAndSettle();
        }

        final body = tester.widget<Text>(
          inDialog(find.textContaining('第二段也要能看见')),
        );
        // 「整篇」——不是 DiaryEntry.preview 那种只有第一行的东西
        expect(body.data, contains('第一段'));
        expect(body.data, contains('第三段'));
        // 「尽量多显示」——能放几行放几行，而不是固定一行
        expect(body.maxLines, greaterThan(1));
        // 放不下的部分交给 Text 自己加省略号
        expect(body.overflow, TextOverflow.ellipsis);
      });
    }

    testWidgets('正文很长时按面板高度截断，窄窗口下也不溢出', (tester) async {
      // 300 段，肯定放不下——如果"能放几行"算错了，布局会直接溢出，
      // 而溢出在测试里就是一个异常，这条就会红。
      final longBody = List<String>.filled(300, '很长很长的一段正文内容').join('\n');
      await pumpApp(
        tester,
        storeWith(<DiaryEntry>[written(march, longBody)]),
        date: march,
        size: const Size(700, 620),
      );
      await openMonthView(tester);

      final body = tester.widget<Text>(
        inDialog(find.textContaining('很长很长的一段正文内容')),
      );
      expect(body.maxLines, greaterThan(1));
      expect(body.overflow, TextOverflow.ellipsis);
    });

    testWidgets('切换按钮能在月和年之间来回切', (tester) async {
      await pumpApp(
        tester,
        storeWith(<DiaryEntry>[written(day(3, 14), 'x')]),
        date: day(3, 14),
      );

      await openMonthView(tester);
      expect(monthCell(day(3, 14)), findsOneWidget);
      expect(yearCell(day(3, 14)), findsNothing);

      await tester.tap(find.text('年'));
      await tester.pumpAndSettle();

      expect(yearCell(day(3, 14)), findsOneWidget);
      expect(monthCell(day(3, 14)), findsNothing);
      expect(find.textContaining('最长连续'), findsOneWidget);

      await tester.tap(find.text('月'));
      await tester.pumpAndSettle();

      expect(monthCell(day(3, 14)), findsOneWidget);
      expect(yearCell(day(3, 14)), findsNothing);
    });

    testWidgets('月视图点一下某天就跳过去，对话框关掉', (tester) async {
      final controller = await pumpApp(
        tester,
        MemoryDiaryStore(),
        date: march,
      );

      await openMonthView(tester);
      await tester.tap(monthCell(DateTime(2026, 3, 20)));
      await tester.pumpAndSettle();

      expect(find.text('写作日历'), findsNothing);
      expect(controller.selectedDate, DateTime(2026, 3, 20));
    });

    testWidgets('月视图能翻上个月、下个月（跨年也对）', (tester) async {
      await pumpApp(tester, MemoryDiaryStore(), date: DateTime(2026, 1, 15));
      await openMonthView(tester);

      expect(inDialog(find.textContaining('2026 年 1 月')), findsOneWidget);

      await tester.tap(find.byTooltip('上个月'));
      await tester.pumpAndSettle();
      // 一月往前是去年十二月，年份要跟着退
      expect(inDialog(find.textContaining('2025 年 12 月')), findsOneWidget);

      await tester.tap(find.byTooltip('下个月'));
      await tester.pumpAndSettle();
      expect(inDialog(find.textContaining('2026 年 1 月')), findsOneWidget);
    });

    testWidgets('月视图里「今天」按钮跳到今天', (tester) async {
      final controller = await pumpApp(
        tester,
        MemoryDiaryStore(),
        date: march,
      );

      await openMonthView(tester);
      await tester.tap(inDialog(find.text('今天')));
      await tester.pumpAndSettle();

      expect(controller.selectedDate, dateOnly(DateTime.now()));
    });

    testWidgets('这一月一天都没写时也明说', (tester) async {
      await pumpApp(tester, MemoryDiaryStore(), date: march);
      await openMonthView(tester);

      expect(find.textContaining('还没有写过日记'), findsOneWidget);
      // 格子照画，否则就不知道这是一个日历
      expect(monthCell(march), findsOneWidget);
    });

    // -------------------------------------------------------------------------
    // 两个尺度共有的行为
    // -------------------------------------------------------------------------

    testWidgets('关掉之后焦点回到正文，接着就能写', (tester) async {
      await pumpApp(
        tester,
        storeWith(<DiaryEntry>[written(day(3, 14), 'x')]),
      );
      await openYearView(tester);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      expect(find.text('写作日历'), findsNothing);
      expect(bodyHasFocus(tester), isTrue);
    });
  });

  group('每日提醒', () {
    // 界面测试**绝不能真的去改系统**：真实现会起 PowerShell 写注册表、
    // 建计划任务。所以这里换一个假的进来，才能验证"成功/失败时界面显示什么"。
    late _FakeReminderOps ops;

    setUp(() => ops = _FakeReminderOps());

    SettingsController settingsWith({
      bool enabled = false,
      String time = '21:00',
      _FakeSettingsRepository? repository,
    }) =>
        SettingsController(
          initial: AppSettings(
            diaryRoot: 'memory',
            reminderEnabled: enabled,
            reminderTime: time,
          ),
          repository: repository ?? _FakeSettingsRepository(),
        );

    /// 单独架一个最小界面来开这个对话框。
    ///
    /// 不走主界面那条路（「⋮」菜单 → `openReminderSettingsAction`）：那条路会
    /// 构造**真的** ReminderService，测试点到开关上就真的会去改系统。
    /// 菜单入口单独有一条测试，只验证"能打开"，不碰开关。
    Future<void> pumpDialog(
      WidgetTester tester,
      SettingsController settings,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showReminderDialog(context, settings, ops: ops),
                  child: const Text('打开提醒设置'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开提醒设置'));
      await tester.pumpAndSettle();
    }

    testWidgets('打开时说明白它会往系统里写什么', (tester) async {
      await pumpDialog(tester, settingsWith());

      expect(find.text('每日提醒'), findsOneWidget);
      expect(find.textContaining('计划任务'), findsWidgets);
      expect(find.textContaining('打开后会在系统里留一个计划任务'), findsOneWidget);
      expect(find.textContaining('注册表'), findsWidgets);
      // 「写过」是哪个定义必须写出来——本项目有两套定义
      expect(find.textContaining('「写过」= 那天有正文、心情、天气或标签'),
          findsOneWidget);
    });

    testWidgets('打开开关：调用了启用，开关变成开', (tester) async {
      // 「成功后设置里记下了什么」由 reminder_service_test.dart 验证，
      // 这里只验界面自己的行为（调了谁、显示什么、开关什么状态）。
      await pumpDialog(tester, settingsWith());

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(ops.enabled, <ReminderTime>[const ReminderTime(21, 0)]);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.textContaining('已启用'), findsOneWidget);
    });

    testWidgets('启用失败时不许把开关拨过去', (tester) async {
      // 这是最要命的一种错：界面显示"已启用"，而系统里什么都没有——
      // 到点不提醒，用户却以为已经开了。
      ops.failEnable = true;
      await pumpDialog(tester, settingsWith());

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(find.textContaining('建计划任务失败'), findsOneWidget);
    });

    testWidgets('已启用时改时间：要按一下「改成 HH:MM」才生效', (tester) async {
      await pumpDialog(tester, settingsWith(enabled: true));

      // 只是选了个新时间，不该偷偷去改系统
      await tester.tap(find.byType(DropdownButton<int>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('22').last);
      await tester.pumpAndSettle();
      expect(ops.enabled, isEmpty);

      await tester.tap(find.text('改成 22:00'));
      await tester.pumpAndSettle();
      expect(ops.enabled, <ReminderTime>[const ReminderTime(22, 0)]);
    });

    testWidgets('关掉开关会停用', (tester) async {
      await pumpDialog(tester, settingsWith(enabled: true));

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(ops.disableCalls, 1);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(find.textContaining('已关闭'), findsOneWidget);
    });

    testWidgets('改提醒日：默认每天，按一下「应用新的提醒日」才生效', (tester) async {
      await pumpDialog(tester, settingsWith(enabled: true));

      final chips =
          tester.widgetList<FilterChip>(find.byType(FilterChip)).toList();
      expect(chips.length, 7);
      expect(chips.every((chip) => chip.selected), isTrue, reason: '默认每天');

      // 取消周六、周日
      await tester.tap(find.widgetWithText(FilterChip, '六'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '日'));
      await tester.pumpAndSettle();
      expect(ops.enabled, isEmpty, reason: '改选择不该立刻去改系统');

      await tester.tap(find.text('应用新的提醒日'));
      await tester.pumpAndSettle();

      expect(ops.enabledDays, <int>[1, 2, 3, 4, 5]);
      // 成功消息用日程文案说人话（不是"1,2,3,4,5"）
      expect(find.textContaining('工作日'), findsOneWidget);
    });

    testWidgets('不让把最后一天也取消掉（否则这个功能永远不会触发）', (tester) async {
      await pumpDialog(tester, settingsWith(enabled: true));

      for (final label in <String>['二', '三', '四', '五', '六', '日']) {
        await tester.tap(find.widgetWithText(FilterChip, label));
        await tester.pumpAndSettle();
      }
      expect(find.text('至少要选一天。'), findsOneWidget);

      // 只剩周一了，再点一次不该有任何变化
      await tester.tap(find.widgetWithText(FilterChip, '一'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '一'))
            .selected,
        isTrue,
      );
    });

    testWidgets('程序内提醒：点「现在写」会记下今天并把光标交给正文', (tester) async {
      final settings = settingsWith(enabled: true);
      var wrote = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showInAppReminder(
                    context,
                    settings: settings,
                    onWrite: () => wrote = true,
                  ),
                  child: const Text('弹提醒'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('弹提醒'));
      await tester.pumpAndSettle();

      expect(find.text('今天还没写日记'), findsOneWidget);
      expect(find.textContaining('这一天还是空的'), findsOneWidget);

      await tester.tap(find.text('现在写'));
      await tester.pumpAndSettle();

      expect(wrote, isTrue);
      // 记的是"今天"：下一次轮询就不该再弹了（判断本身在 reminder_test.dart 里测）
      expect(
        reminderDayKey(settings.reminderLastShown!),
        reminderDayKey(DateTime.now()),
      );
    });

    testWidgets('程序内提醒：点「今天算了」也记下今天，但不动光标', (tester) async {
      final settings = settingsWith(enabled: true);
      var wrote = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showInAppReminder(
                    context,
                    settings: settings,
                    onWrite: () => wrote = true,
                  ),
                  child: const Text('弹提醒'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('弹提醒'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('今天算了'));
      await tester.pumpAndSettle();

      expect(wrote, isFalse);
      // 关键：点了"今天算了"也必须记下来，否则轮询每几秒就再弹一次
      expect(
        reminderDayKey(settings.reminderLastShown!),
        reminderDayKey(DateTime.now()),
      );
    });

    testWidgets('「⋮」菜单里有入口，点得开', (tester) async {
      final controller = await pumpApp(tester, MemoryDiaryStore());
      // 这一条只验证"入口在、点得开"，不去碰开关——
      // 因为这条路上是**真的** ReminderService（见 pumpDialog 的注释）。
      expect(controller.selectedDate, isNotNull);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text('每日提醒'), findsOneWidget);

      await tester.tap(find.text('每日提醒'));
      await tester.pumpAndSettle();
      expect(find.text('每日提醒'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
    });

    testWidgets('命令面板里搜「提醒」也能打开', (tester) async {
      await pumpApp(tester, MemoryDiaryStore());

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('command-palette-query')),
        '提醒',
      );
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('每日提醒'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
    });
  });
}

