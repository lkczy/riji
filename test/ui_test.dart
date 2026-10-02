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
import 'package:riji/data/diary_store.dart';
import 'package:riji/data/settings.dart';
import 'package:riji/state/diary_controller.dart';
import 'package:riji/state/settings_controller.dart';
import 'package:riji/ui/app.dart';

/// 记录被写下来的设置，用于验证偏好真的持久化了。
class _FakeSettingsRepository extends SettingsRepository {
  AppSettings? saved;

  @override
  Future<void> save(AppSettings settings) async => saved = settings;
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

  Future<DiaryController> pumpApp(
    WidgetTester tester,
    DiaryStore store, {
    DateTime? date,
    Size size = const Size(1400, 900),
    SettingsController? settings,
  }) async {
    // 显式指定窗口尺寸：默认的 800x600 会让标题栏走窄屏分支，
    // 日期格式随之改变，断言就会对不上。桌面 App 的典型尺寸是宽屏。
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = DiaryController(store: store, deviceName: 'test');
    await controller.load(preferredDate: date);
    // 取消控制器里所有挂起的定时器，否则测试结束会报 "Timer is still pending"
    addTearDown(controller.close);

    await tester.pumpWidget(
      RijiApp(
        controller: controller,
        settings:
            settings ?? SettingsController(initial: baseSettings),
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
}
