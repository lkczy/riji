import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/diary_location.dart';
import 'package:riji/core/models/diary_entry.dart';
import 'package:riji/data/diary_store.dart';
import 'package:riji/state/diary_controller.dart';
import 'package:riji/ui/diary_location_dialog.dart';

/// 对话框行为的测试。
///
/// 探测函数全部注入假实现：真实实现会去写临时文件、还会起 PowerShell 查询
/// 磁盘类型，在测试的假异步环境里起外部进程会直接挂住。
typedef Inspect = Future<DiaryLocationFacts> Function({
  required String rawPath,
  required String currentRoot,
  required int currentEntryCount,
});

void main() {
  // MemoryDiaryStore 的位置描述
  const memoryRoot = '内存（未持久化）';
  const targetPath = r'D:\日记';

  DiaryLocationFacts factsFor(
    String raw, {
    String? normalized,
    int entryCount = 0,
    bool writable = true,
    bool exists = true,
    bool isDirectory = true,
    required int currentEntryCount,
  }) {
    return DiaryLocationFacts(
      rawPath: raw,
      normalizedPath: normalized ?? raw,
      currentRoot: memoryRoot,
      currentEntryCount: currentEntryCount,
      exists: exists,
      isDirectory: isDirectory,
      writable: writable,
      entryCount: entryCount,
      subdirectoryCount: 2,
    );
  }

  Future<DiaryController> makeController({int entries = 3}) async {
    final store = MemoryDiaryStore();
    for (var i = 0; i < entries; i++) {
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 10 + i),
        device: 'test',
        body: '第 $i 篇',
      ));
    }
    final controller = DiaryController(store: store, deviceName: 'test');
    await controller.load(preferredDate: DateTime(2026, 2, 10));
    addTearDown(controller.close);
    return controller;
  }

  Future<DiaryCopyOutcome> shouldNotBeCalled(
    String root, {
    required bool copyExisting,
  }) async {
    fail('这个用例不该真的去切换位置');
  }

  Future<void> openDialog(
    WidgetTester tester, {
    required DiaryController controller,
    required Inspect inspect,
    SwitchDiaryRootCallback? onSwitch,
  }) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<String>(
              context: context,
              builder: (_) => DiaryLocationDialog(
                controller: controller,
                onSwitch: onSwitch ?? shouldNotBeCalled,
                inspect: inspect,
                listDrives: () => const <String>[r'C:\', r'D:\'],
                listSubdirectories: (path) async => const <String>[],
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    // 刻意**不用** pumpAndSettle：加载态的 CircularProgressIndicator 是无限动画，
    // pumpAndSettle 会一直等下去直到超时（之前界面预览脚本就是这样挂住的）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump();
  }

  Future<void> enterPath(WidgetTester tester, String path) async {
    await tester.enterText(find.byType(TextField).first, path);
    // 越过 400ms 的防抖，再让探测的 Future 完成
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('打开时显示当前位置和篇数', (tester) async {
    final controller = await makeController(entries: 3);

    await openDialog(
      tester,
      controller: controller,
      inspect: ({required rawPath, required currentRoot, required currentEntryCount}) async =>
          factsFor(rawPath, currentEntryCount: currentEntryCount),
    );

    expect(find.text('日记保存位置'), findsOneWidget);
    expect(find.text('当前位置'), findsOneWidget);
    expect(find.text('共 3 篇日记'), findsOneWidget);

    // 当前位置既展示在文本里、又预填在输入框里（方便用户就地修改），
    // 所以不能用 find.text 查——那样会命中两处。这里精确查展示控件。
    final currentLocation =
        tester.widget<SelectableText>(find.byType(SelectableText).first);
    expect(currentLocation.data, memoryRoot);

    final pathField = tester.widget<TextField>(find.byType(TextField).first);
    expect(pathField.controller?.text, memoryRoot,
        reason: '输入框应该预填当前位置，用户多半只是想改最后一段');
  });

  testWidgets('目标为空而当前有内容：给出警告并默认勾选复制', (tester) async {
    final controller = await makeController(entries: 3);

    await openDialog(
      tester,
      controller: controller,
      inspect: ({required rawPath, required currentRoot, required currentEntryCount}) async =>
          factsFor(rawPath, entryCount: 0, currentEntryCount: currentEntryCount),
    );
    await enterPath(tester, targetPath);

    expect(find.textContaining('一篇日记都没有'), findsOneWidget);
    expect(find.textContaining('没有被删除'), findsOneWidget);

    final checkbox =
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(checkbox.value, isTrue, reason: '这种情况默认应该复制，绝大多数人是要搬走');
  });

  testWidgets('目标不可写：报错并且禁用切换按钮', (tester) async {
    final controller = await makeController();

    await openDialog(
      tester,
      controller: controller,
      inspect: ({required rawPath, required currentRoot, required currentEntryCount}) async =>
          factsFor(rawPath, writable: false, currentEntryCount: currentEntryCount),
    );
    await enterPath(tester, targetPath);

    expect(find.textContaining('没有写入权限'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '切换位置'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('目标已有日记：说明会显示哪些内容，且不再提供复制选项', (tester) async {
    final controller = await makeController(entries: 3);

    await openDialog(
      tester,
      controller: controller,
      inspect: ({required rawPath, required currentRoot, required currentEntryCount}) async =>
          factsFor(rawPath, entryCount: 7, currentEntryCount: currentEntryCount),
    );
    await enterPath(tester, targetPath);

    expect(find.textContaining('已经有 7 篇日记'), findsOneWidget);
    // 目标已有内容时不允许复制，避免覆盖掉目标位置的东西
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('确认时把规范化路径和复制选择一起传给回调', (tester) async {
    final controller = await makeController(entries: 3);
    String? receivedRoot;
    bool? receivedCopy;

    await openDialog(
      tester,
      controller: controller,
      inspect: ({required rawPath, required currentRoot, required currentEntryCount}) async =>
          factsFor(rawPath, normalized: targetPath, entryCount: 0, currentEntryCount: currentEntryCount),
      onSwitch: (root, {required copyExisting}) async {
        receivedRoot = root;
        receivedCopy = copyExisting;
        return const DiaryCopyOutcome(ok: true, filesCopied: 2, message: '已切换');
      },
    );
    await enterPath(tester, targetPath);
    await tester.tap(find.widgetWithText(FilledButton, '切换位置'));
    await tester.pump();
    await tester.pump();

    expect(receivedRoot, targetPath);
    expect(receivedCopy, isTrue);
  });

  testWidgets('用户取消勾选后，回调收到 copyExisting=false', (tester) async {
    final controller = await makeController(entries: 3);
    bool? receivedCopy;

    await openDialog(
      tester,
      controller: controller,
      inspect: ({required rawPath, required currentRoot, required currentEntryCount}) async =>
          factsFor(rawPath, normalized: targetPath, entryCount: 0, currentEntryCount: currentEntryCount),
      onSwitch: (root, {required copyExisting}) async {
        receivedCopy = copyExisting;
        return const DiaryCopyOutcome(ok: true, filesCopied: 0, message: '已切换');
      },
    );
    await enterPath(tester, targetPath);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '切换位置'));
    await tester.pump();
    await tester.pump();

    expect(receivedCopy, isFalse, reason: '用户明确取消了复制就必须尊重');
  });

  testWidgets('切换失败时显示错误，并且不关闭对话框', (tester) async {
    final controller = await makeController(entries: 3);

    await openDialog(
      tester,
      controller: controller,
      inspect: ({required rawPath, required currentRoot, required currentEntryCount}) async =>
          factsFor(rawPath, normalized: targetPath, entryCount: 0, currentEntryCount: currentEntryCount),
      onSwitch: (root, {required copyExisting}) async => const DiaryCopyOutcome(
        ok: false,
        filesCopied: 0,
        message: '复制失败：目标磁盘空间不足。日记位置没有被改动。',
      ),
    );
    await enterPath(tester, targetPath);
    await tester.tap(find.widgetWithText(FilledButton, '切换位置'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('空间不足'), findsOneWidget);
    expect(find.textContaining('没有被改动'), findsOneWidget);
    expect(find.text('切换位置'), findsOneWidget, reason: '失败了要留在对话框里，让用户能改路径重试');
  });

  testWidgets('切换成功后对话框关闭并返回结果说明', (tester) async {
    final controller = await makeController(entries: 3);

    await openDialog(
      tester,
      controller: controller,
      inspect: ({required rawPath, required currentRoot, required currentEntryCount}) async =>
          factsFor(rawPath, normalized: targetPath, entryCount: 0, currentEntryCount: currentEntryCount),
      onSwitch: (root, {required copyExisting}) async => const DiaryCopyOutcome(
        ok: true,
        filesCopied: 4,
        message: '已复制 4 个文件。',
      ),
    );
    await enterPath(tester, targetPath);
    await tester.tap(find.widgetWithText(FilledButton, '切换位置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('日记保存位置'), findsNothing);
  });
}
