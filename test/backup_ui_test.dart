// 备份的界面接线与设置字段。
//
// ⚠️ widget 测试跑在假异步环境里，`await` 真实 `dart:io` 的 Future **永远不会
// 返回**。所以这里只验证「图标出不出来」「菜单项在不在」，**绝不点开备份
// 对话框**——那条路径会去列快照（真实 I/O），留到真实演练里验证。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/backup.dart';
import 'package:riji/core/diary_location.dart';
import 'package:riji/core/huangli.dart';
import 'package:riji/data/diary_store.dart';
import 'package:riji/data/settings.dart';
import 'package:riji/state/diary_controller.dart';
import 'package:riji/state/settings_controller.dart';
import 'package:riji/ui/app.dart';
import 'package:path/path.dart' as p;

class _FakeSettingsRepository extends SettingsRepository {
  AppSettings? saved;

  @override
  Future<void> save(AppSettings settings) async => saved = settings;
}

void main() {
  setUpAll(() {
    // 和 ui_test.dart 同样处理：黄历表按需从资源包读，先塞进缓存，
    // 免得界面在假异步里去 await 资源包。
    HuangliTable.seedCache(
      HuangliTable.parse(File('assets/huangli.tsv').readAsStringSync()),
    );
  });

  Future<DiaryController> pumpApp(
    WidgetTester tester, {
    required SettingsController settings,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller =
        DiaryController(store: MemoryDiaryStore(), deviceName: 'test');
    await controller.load();
    addTearDown(controller.close);

    await tester.pumpWidget(
      RijiApp(
        controller: controller,
        settings: settings,
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

  SettingsController settingsWith({
    String? backupRoot,
    DateTime? lastBackupAt,
    String? lastBackupError,
  }) =>
      SettingsController(
        initial: AppSettings(
          diaryRoot: 'memory',
          backupRoot: backupRoot,
          lastBackupAt: lastBackupAt,
          lastBackupError: lastBackupError,
        ),
        repository: _FakeSettingsRepository(),
      );

  group('该不该提醒备份', () {
    final now = DateTime(2026, 10, 2, 12);

    test('没设置位置 → 不提醒（用户需要的是先设位置，不是一个顶着下不去的警告）',
        () {
      expect(
        isBackupStale(backupRoot: null, lastBackupAt: null, now: now),
        isFalse,
      );
      expect(
        isBackupStale(backupRoot: '  ', lastBackupAt: null, now: now),
        isFalse,
      );
    });

    test('设置了位置但从没备份过 → 要提醒（"配好了"和"真的在跑"是两件事）', () {
      expect(
        isBackupStale(backupRoot: r'E:\备份', lastBackupAt: null, now: now),
        isTrue,
      );
    });

    test('7 天是界线', () {
      expect(
        isBackupStale(
          backupRoot: r'E:\备份',
          lastBackupAt: now.subtract(const Duration(days: 6)),
          now: now,
        ),
        isFalse,
      );
      expect(
        isBackupStale(
          backupRoot: r'E:\备份',
          lastBackupAt: now.subtract(const Duration(days: 7)),
          now: now,
        ),
        isTrue,
      );
    });

    test('天数能算出来', () {
      expect(daysSinceBackup(null, now), isNull);
      expect(daysSinceBackup(now.subtract(const Duration(days: 3)), now), 3);
    });
  });

  group('设置里的备份字段', () {
    test('往返：位置、时间、错误都能存下来再读回来', () {
      final at = DateTime(2026, 10, 2, 22, 10);
      final settings = AppSettings(
        diaryRoot: 'memory',
        backupRoot: r'E:\日记备份',
        lastBackupAt: at,
        lastBackupError: '磁盘满了',
      );

      final back = AppSettings.fromJson(
        settings.toJson(),
        fallbackRoot: 'fallback',
      );
      expect(back.backupRoot, r'E:\日记备份');
      expect(back.lastBackupAt, at);
      expect(back.lastBackupError, '磁盘满了');
    });

    test('没设置过时三个字段都是 null，不会被写成空字符串', () {
      const settings = AppSettings(diaryRoot: 'memory');
      final json = settings.toJson();
      expect(json.containsKey('backupRoot'), isFalse);
      expect(json.containsKey('lastBackupAt'), isFalse);

      final back = AppSettings.fromJson(json, fallbackRoot: 'fallback');
      expect(back.backupRoot, isNull);
      expect(back.lastBackupAt, isNull);
      expect(back.lastBackupError, isNull);
    });

    test('坏数据不让程序崩（设置可能来自更高版本或被人手改过）', () {
      final back = AppSettings.fromJson(<String, dynamic>{
        'diaryRoot': 'memory',
        'backupRoot': 12345,
        'lastBackupAt': '不是时间',
        'lastBackupError': <String>['也不是字符串'],
      }, fallbackRoot: 'fallback');

      expect(back.backupRoot, isNull);
      expect(back.lastBackupAt, isNull, reason: '解析不了就当没有，不能抛异常');
      expect(back.lastBackupError, isNull);
    });

    test('成功会清掉上次的错误；失败不会抹掉上次成功的时间', () async {
      final repository = _FakeSettingsRepository();
      final controller = SettingsController(
        initial: const AppSettings(diaryRoot: 'memory'),
        repository: repository,
      );

      await controller.noteBackupFailed('第一次失败');
      expect(controller.lastBackupError, '第一次失败');
      expect(controller.lastBackupAt, isNull);

      final at = DateTime(2026, 10, 2, 9);
      await controller.noteBackupSucceeded(at);
      expect(controller.lastBackupAt, at);
      expect(controller.lastBackupError, isNull, reason: '错误提示必须反映"现在还有没有问题"');

      await controller.noteBackupFailed('第二次失败');
      expect(
        controller.lastBackupAt,
        at,
        reason: '上一次成功的时间仍然是事实，抹掉它会让"多久没备份了"失真',
      );
      expect(repository.saved?.lastBackupError, '第二次失败');
    });
  });

  group('界面接线', () {
    testWidgets('从没设置过备份位置：没有警告图标', (tester) async {
      await pumpApp(tester, settings: settingsWith());

      expect(find.byTooltip('还没有备份过，点这里去备份'), findsNothing);
      expect(find.byTooltip('更多'), findsOneWidget);
    });

    testWidgets('设置了位置但从没备份过：出现警告图标', (tester) async {
      await pumpApp(tester, settings: settingsWith(backupRoot: r'E:\备份'));

      expect(find.byTooltip('还没有备份过，点这里去备份'), findsOneWidget);
    });

    testWidgets('刚备份过：图标完全不出现（平时不占地方）', (tester) async {
      await pumpApp(
        tester,
        settings: settingsWith(
          backupRoot: r'E:\备份',
          lastBackupAt: DateTime.now().subtract(const Duration(days: 1)),
        ),
      );

      expect(find.byTooltip('还没有备份过，点这里去备份'), findsNothing);
      expect(find.byTooltip('已经 1 天没备份了'), findsNothing);
    });

    testWidgets('超过 7 天：图标出现，tooltip 说明多久了', (tester) async {
      await pumpApp(
        tester,
        settings: settingsWith(
          backupRoot: r'E:\备份',
          lastBackupAt: DateTime.now().subtract(const Duration(days: 10)),
        ),
      );

      expect(find.byTooltip('已经 10 天没备份了'), findsOneWidget);
    });

    testWidgets('「更多」菜单里有「备份」', (tester) async {
      await pumpApp(tester, settings: settingsWith());

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();

      expect(find.text('备份'), findsOneWidget);
      // 不要点它：对话框会去列快照（真实 I/O），在假异步里永远不返回
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    });

    // 下面四条刻意只在**不触发真实 I/O** 的路径上走：
    // 没设备份位置时对话框不会去列快照，所以可以安全打开。
    // 一旦设了位置，打开对话框就会列目录——那条路径只能留到真实演练里验证。
    Future<void> openBackupDialog(WidgetTester tester) async {
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('备份'));
      await tester.pumpAndSettle();
    }

    testWidgets('没设备份位置：说明为什么还不能备份，「立即备份」是禁用的', (tester) async {
      await pumpApp(tester, settings: settingsWith());
      await openBackupDialog(tester);

      expect(find.text('还没设置 —— 不设置就没法备份，因为日记是唯一一份'),
          findsOneWidget);
      expect(find.text('先设置备份位置，才能开始备份。'), findsOneWidget);

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '立即备份'),
      );
      expect(button.onPressed, isNull, reason: '禁用而不是隐藏：要让用户看到这个功能存在，只差一步');
    });

    testWidgets('备份位置填成日记目录的子目录 → 拒绝保存并解释原因', (tester) async {
      await pumpApp(tester, settings: settingsWith());
      await openBackupDialog(tester);

      await tester.tap(find.text('设置备份位置…'));
      await tester.pumpAndSettle();

      // 日记根目录是 '内存（未持久化）'，往里写就是"嵌套"。
      // 用 .last：备份对话框还开着，树里有两个 TextField，
      // 路径框是后压上来的那个。
      await tester.enterText(
        find.byType(TextField).last,
        '内存（未持久化）\\备份',
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('互相包含'), findsOneWidget);
      expect(find.textContaining('Syncthing'), findsOneWidget,
          reason: '要说清真实原因：会递归复制，而且会被同步到手机');

      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '保存'),
      );
      expect(save.onPressed, isNull, reason: '嵌套必须**拒绝**，不是警告');
    });

    testWidgets('备份位置和日记同盘 → 允许，但明确警告挡不住盘坏', (tester) async {
      await pumpApp(tester, settings: settingsWith());
      await openBackupDialog(tester);

      await tester.tap(find.text('设置备份位置…'));
      await tester.pumpAndSettle();

      // 和日记同盘、但不是它的子目录
      final sameVolumePath = p.join(Directory.current.path, '备份');
      await tester.enterText(find.byType(TextField).last, sameVolumePath);
      await tester.pumpAndSettle();

      expect(find.textContaining('同一个盘'), findsOneWidget);
      expect(find.textContaining('挡不住这块盘坏掉'), findsOneWidget);
      expect(find.textContaining('两个盘符也可能是同一块物理盘'), findsOneWidget,
          reason: '不许给虚假安心：判断不了的事要如实说');

      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '保存'),
      );
      expect(save.onPressed, isNotNull, reason: '同盘是警告不是禁止');
    });
  });
}
