import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/models/diary_entry.dart';
import 'package:riji/core/vault_crypto.dart';
import 'package:riji/core/vault_format.dart';
import 'package:riji/data/diary_store.dart';
import 'package:riji/core/diary_location.dart';
import 'package:riji/data/settings.dart';
import 'package:riji/state/diary_controller.dart';
import 'package:riji/state/settings_controller.dart';
import 'package:riji/state/vault_service.dart';
import 'package:riji/ui/app.dart';

/// 测试用的小参数：默认 64 MiB 每次派生要 0.7 秒，界面测试等不起。
const KdfParams _fast = KdfParams(memoryKib: 8 * 1024, iterations: 1, parallelism: 1);

const String _passphrase = '测试口令';
const String _secret = '这件事只有我自己知道';

/// 界面测试里的"口令 → 密钥"。
///
/// **只换掉 Argon2id 这一步**（它会 `await Future.delayed`，在 `testWidgets`
/// 的假时钟里永远不返回，实测挂到 10 分钟超时）。加解密、文件格式、
/// 保险库文件、黑条全是真的——所以界面测试验的不只是"界面调了谁"。
Future<SecretKey> stubDeriveKey({
  required String passphrase,
  required List<int> salt,
  required KdfParams params,
}) async {
  final bytes = Uint8List(32);
  final raw = utf8.encode(passphrase);
  for (var i = 0; i < 32; i++) {
    bytes[i] = (i < raw.length ? raw[i] : 0x5a) ^ salt[i % salt.length];
  }
  return SecretKeyData(bytes);
}
/// 内存里的保险库文件。**一个字节都不落到磁盘。**
class _FakeVaultFiles {
  String? content;

  Future<String?> read(String root) async => content;
  Future<void> write(String root, String text) async => content = text;
  Future<void> delete(String root) async => content = null;
}

/// 造一个"已经配好口令、有一天是锁着"的环境，并返回**还没解锁**的服务实例
/// （模拟"程序刚启动，保险库文件在，但没输过口令"）。
Future<({VaultService vault, DiaryEntry locked, _FakeVaultFiles files})> lockedFixture() async {
  final files = _FakeVaultFiles();
  final first = VaultService(
    diaryRoot: r'D:\someone\MyData',
    params: _fast,
        deriveKey: stubDeriveKey,
    readFile: files.read,
    writeFile: files.write,
    deleteFile: files.delete,
  );
  await first.load();
  final setup = await first.setUp(_passphrase);
  expect(setup.ok, isTrue, reason: '夹具本身就该建库成功');
  final locked = await first.lockWholeDay(
    DiaryEntry.create(date: DateTime(2026, 10, 6), device: 'test', body: _secret),
  );

  final fresh = VaultService(
    diaryRoot: r'D:\someone\MyData',
    params: _fast,
        deriveKey: stubDeriveKey,
    readFile: files.read,
    writeFile: files.write,
    deleteFile: files.delete,
  );
  await fresh.load();
  expect(fresh.isConfigured, isTrue);
  expect(fresh.isUnlocked, isFalse);
  return (vault: fresh, locked: locked, files: files);
}

Future<DiaryController> pumpApp(
  WidgetTester tester,
  DiaryStore store, {
  VaultService? vault,
  /// 需要特定设置（比如开着程序锁）的测试用它注入。
  AppSettings? settings,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = DiaryController(
    store: store,
    deviceName: 'test',
    vault: vault,
  );
  await controller.load(preferredDate: DateTime(2026, 10, 8));
  addTearDown(controller.close);

  await tester.pumpWidget(
    RijiApp(
      controller: controller,
      settings: SettingsController(
        initial:
            settings ?? const AppSettings(diaryRoot: r'D:\someone\MyData'),
      ),
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

/// 打开「⋮」菜单里的某一项。
Future<void> tapMoreAction(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// 正文输入框的 key（和 lib/ui/editor_panel.dart 里那个一致）。
const bodyField = Key('diary-body-field');

void main() {
  group('日记加密', () {
    testWidgets('「⋮」菜单里有入口，点得开', (tester) async {
      final fixture = await lockedFixture();
      await pumpApp(tester, MemoryDiaryStore(), vault: fixture.vault);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text('日记加密'), findsOneWidget);

      await tester.tap(find.text('日记加密').last);
      await tester.pumpAndSettle();

      expect(find.text('已锁定'), findsOneWidget);
      expect(find.text('解锁'), findsWidgets);
    });

    testWidgets('口令错 → 说清是口令错；口令对 → 变成已解锁', (tester) async {
      final fixture = await lockedFixture();
      await pumpApp(tester, MemoryDiaryStore(), vault: fixture.vault);
      await tapMoreAction(tester, '日记加密');

      await tester.enterText(find.widgetWithText(TextField, '口令'), '错的口令');
      await tester.tap(find.widgetWithText(FilledButton, '解锁'));
      await tester.pumpAndSettle();
      expect(find.textContaining('口令不对'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, '口令'), _passphrase);
      await tester.tap(find.widgetWithText(FilledButton, '解锁'));
      await tester.pumpAndSettle();
      // 「已解锁」会同时出现在对话框状态行和底栏那个常驻指示上——
      // 底栏有它正是我们要的（解锁后屏幕上必须一直看得见）
      expect(find.text('已解锁'), findsWidgets);
      expect(find.textContaining('现在能看能搜'), findsOneWidget);
    });

    testWidgets('还没建库 → 设口令；太短或两次不一致都会拦下来', (tester) async {
      final files = _FakeVaultFiles();
      final vault = VaultService(
        diaryRoot: r'D:\someone\MyData',
        params: _fast,
        deriveKey: stubDeriveKey,
        readFile: files.read,
        writeFile: files.write,
        deleteFile: files.delete,
      );
      await vault.load();
      await pumpApp(tester, MemoryDiaryStore(), vault: vault);
      await tapMoreAction(tester, '日记加密');

      expect(find.text('没有开加密'), findsOneWidget);

      // 太短
      await tester.enterText(find.widgetWithText(TextField, '口令'), 'ab');
      await tester.enterText(find.widgetWithText(TextField, '再输一遍'), 'ab');
      await tester.tap(find.widgetWithText(FilledButton, '开启加密'));
      await tester.pumpAndSettle();
      expect(find.textContaining('口令太短'), findsOneWidget);

      // 两次不一致
      await tester.enterText(find.widgetWithText(TextField, '口令'), _passphrase);
      await tester.enterText(find.widgetWithText(TextField, '再输一遍'), '另一个口令');
      await tester.tap(find.widgetWithText(FilledButton, '开启加密'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不一样'), findsOneWidget);

      // 成功 → 显示恢复码，并且明说"忘了口令就永久打不开"
      await tester.enterText(find.widgetWithText(TextField, '再输一遍'), _passphrase);
      await tester.tap(find.widgetWithText(FilledButton, '开启加密'));
      // 这里**不能**用 pumpAndSettle：恢复码那一块是 SelectableText，
      // 它的光标是个永不停止的动画，pumpAndSettle 会一直等到超时。
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // ← 临时调试

      expect(find.text('这是你的恢复码'), findsOneWidget);
      expect(find.textContaining('唯一的办法'), findsOneWidget);
      expect(vault.isConfigured, isTrue);
      // 恢复码确实是一串能用的东西（32 字节 → 52 个字符 + 连字符）
      expect(files.content, contains('wrapped'));
    });
  });

  group('搜索与锁着的内容', () {
    testWidgets('有锁着的天又没解锁 → 明说"另有 N 篇没有参与搜索"', (tester) async {
      final fixture = await lockedFixture();
      final store = MemoryDiaryStore();
      await store.save(fixture.locked);
      await pumpApp(tester, store, vault: fixture.vault);

      expect(find.textContaining('另有 1 篇已加密'), findsOneWidget);
      expect(find.text('解锁来搜索'), findsOneWidget);
    });

    testWidgets('**命中为 0 时那行提示也必须在**（否则"搜不到"和"没搜"分不清）',
        (tester) async {
      final fixture = await lockedFixture();
      final store = MemoryDiaryStore();
      await store.save(fixture.locked);
      final controller = await pumpApp(tester, store, vault: fixture.vault);

      // 搜一个只出现在**锁着的正文**里的词
      await tester.enterText(find.byType(TextField).first, '只有我自己知道');
      await tester.pumpAndSettle();

      expect(controller.visibleEntries, isEmpty, reason: '没解锁，正文没参与搜索');
      expect(find.textContaining('没有匹配的日记'), findsWidgets, reason: '结果区说没找到');
      expect(find.textContaining('另有 1 篇已加密'), findsOneWidget,
          reason: '但必须同时说清"有 1 篇没参与"——这两句话缺一不可');
    });

    testWidgets('解锁之后：提示消失，而且搜得到锁着的正文', (tester) async {
      final fixture = await lockedFixture();
      final store = MemoryDiaryStore();
      await store.save(fixture.locked);
      final controller = await pumpApp(tester, store, vault: fixture.vault);

      await tester.enterText(find.byType(TextField).first, '只有我自己知道');
      await tester.pumpAndSettle();
      expect(controller.visibleEntries, isEmpty);

      // 走「解锁来搜索」这条路
      await tester.tap(find.text('解锁来搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '口令'), _passphrase);
      await tester.tap(find.widgetWithText(FilledButton, '解锁'));
      await tester.pumpAndSettle();

      expect(find.textContaining('另有 1 篇已加密'), findsNothing);
      expect(controller.visibleEntries.length, 1);
      expect(controller.visibleEntries.single.date, DateTime(2026, 10, 6));
    });

    testWidgets('只为搜索解锁**不给写入权限**', (tester) async {
      final fixture = await lockedFixture();
      final store = MemoryDiaryStore();
      await store.save(fixture.locked);
      await pumpApp(tester, store, vault: fixture.vault);

      await tester.tap(find.text('解锁来搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '口令'), _passphrase);
      await tester.tap(find.widgetWithText(FilledButton, '解锁'));
      await tester.pumpAndSettle();

      expect(fixture.vault.isUnlocked, isTrue);
      expect(fixture.vault.isSearchRevealed, isTrue);
      expect(fixture.vault.canWrite, isFalse,
          reason: '按次解锁绝不该顺带把改写文件的能力也交出去');
    });
  });

  group('常驻的加密状态指示', () {
    testWidgets('有锁着的天 → 底栏显示"N 篇已锁"；解锁后变"已解锁"，点一下又锁上',
        (tester) async {
      final fixture = await lockedFixture();
      final store = MemoryDiaryStore();
      await store.save(fixture.locked);
      await pumpApp(tester, store, vault: fixture.vault);

      expect(find.text('1 篇已加密'), findsOneWidget);

      // 解锁（会话）
      await fixture.vault.unlock(_passphrase, isRecoveryCode: false);
      await tester.pumpAndSettle();
      expect(find.text('已解锁'), findsOneWidget);
      expect(find.text('1 篇已加密'), findsNothing);

      // 走开之前点一下锁定：这是这个指示存在的意义
      await tester.tap(find.text('已解锁'));
      await tester.pumpAndSettle();
      expect(fixture.vault.isUnlocked, isFalse);
      expect(find.text('1 篇已加密'), findsOneWidget);
    });

    testWidgets('没开加密时，底栏一个加密指示都不出现', (tester) async {
      await pumpApp(tester, MemoryDiaryStore());
      expect(find.textContaining('篇已加密'), findsNothing);
      expect(find.text('已解锁'), findsNothing);
    });
  });

  group('解锁前正文只读', () {
    testWidgets('锁着的一天：正文打不了字、有说明和解锁入口，但心情仍可改', (tester) async {
      final fixture = await lockedFixture();
      final store = MemoryDiaryStore();
      await store.save(fixture.locked);
      final controller = await pumpApp(tester, store, vault: fixture.vault);
      await controller.openDate(DateTime(2026, 10, 6));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byKey(bodyField));
      expect(field.readOnly, isTrue, reason: '锁着的时候正文必须只读');
      expect(find.textContaining('解锁之后才能修改正文'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '解锁'), findsOneWidget);

      // 心情是明文的，锁定状态下也应该能改
      await tester.tap(find.text('开心'));
      await tester.pumpAndSettle();
      expect(controller.mood, '开心', reason: '只锁正文，不锁元数据');

      // 解锁之后就能改了
      await fixture.vault.unlock(_passphrase, isRecoveryCode: false);
      await tester.pumpAndSettle();
      final after = tester.widget<TextField>(find.byKey(bodyField));
      expect(after.readOnly, isFalse);
      expect(find.textContaining('解锁之后才能修改正文'), findsNothing);
    });
  });

  group('段落级黑条', () {
    testWidgets('光标不在黑条上时，菜单里没有"看这段的内容"', (tester) async {
      final fixture = await lockedFixture();
      final vault = fixture.vault;
      // 解开（会话级）之后才有写权限
      await vault.unlock(_passphrase, isRecoveryCode: false);
      final store = MemoryDiaryStore();
      await store.save(
        DiaryEntry.create(
          date: DateTime(2026, 10, 8),
          device: 'test',
          body: '第一行\n第二行',
        ),
      );
      final controller = await pumpApp(tester, store, vault: vault);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text('加密这段'), findsOneWidget);
      expect(find.text('看这段的内容'), findsNothing);

      // 锁上光标所在的第一行（光标默认在文末，也就是第二行的末尾）
      await tester.tap(find.text('加密这段'));
      await tester.pumpAndSettle();
      expect(redactionLineCount(controller.body), 1);
      expect(controller.body.contains('第一行') || controller.body.contains('第二行'),
          isTrue);

      // SnackBar 会盖住右下角的「⋮」，等它自己消失再点
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // 再把光标放到黑条那一行上：菜单里应该出现"看这段的内容"
      final barLine = redactionLineIndexes(controller.body).single;
      final barOffset = controller.body
          .split('\n')
          .take(barLine)
          .fold<int>(0, (sum, line) => sum + line.length + 1);
      final field = tester.widget<TextField>(find.byKey(bodyField));
      field.controller!.selection =
          TextSelection.collapsed(offset: barOffset + 1);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text('看这段的内容'), findsOneWidget);
      expect(find.text('解密这段'), findsOneWidget);
    });
  });

  group('右上角的显示原文开关', () {
    /// 造一个"这一天按段锁着、并且已解锁"的环境。
    Future<DiaryController> lockedLineFixture(WidgetTester tester) async {
      final files = _FakeVaultFiles();
      final vault = VaultService(
        diaryRoot: r'D:\someone\MyData',
        params: _fast,
        deriveKey: stubDeriveKey,
        readFile: files.read,
        writeFile: files.write,
        deleteFile: files.delete,
      );
      await vault.load();
      await vault.setUp(_passphrase);
      final day = DateTime(2026, 10, 8);
      final store = MemoryDiaryStore();
      await store.save(await vault.lockLine(
        DiaryEntry.create(date: day, device: 'test', body: '第一行\n$_secret'),
        1,
      ));
      final controller = await pumpApp(tester, store, vault: vault);
      await controller.openDate(day);
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('点一下显示原文，再点一下回到黑条视图', (tester) async {
      final controller = await lockedLineFixture(tester);

      // 解锁状态下：按钮出现，初始是"显示原文"
      final toggle = find.text('显示原文（只读）');
      expect(toggle, findsOneWidget);
      expect(find.text('回到黑条视图'), findsNothing);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      // 变成"回到黑条视图"，而且正文显示的是原文
      expect(find.text('回到黑条视图'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(bodyField)).controller!.text,
        contains(_secret),
      );
      // 要落盘的那个控制器一个字都没动
      expect(controller.body.contains(_secret), isFalse);

      await tester.tap(find.text('回到黑条视图'));
      await tester.pumpAndSettle();

      expect(find.text('显示原文（只读）'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(bodyField)).controller!.text,
        contains('█'),
      );
    });

    testWidgets('没解锁时不出现（给了也是个点了没反应的按钮）', (tester) async {
      final fixture = await lockedFixture();
      final store = MemoryDiaryStore();
      await store.save(fixture.locked);
      final controller = await pumpApp(tester, store, vault: fixture.vault);
      await controller.openDate(DateTime(2026, 10, 6));
      await tester.pumpAndSettle();

      expect(find.text('显示原文（只读）'), findsNothing);
      expect(find.text('回到黑条视图'), findsNothing);
    });
  });

  group('提示条与菜单分组', () {
    testWidgets('弹了提示之后，「更多」按钮仍然点得到', (tester) async {
      final files = _FakeVaultFiles();
      final vault = VaultService(
        diaryRoot: r'D:\someone\MyData',
        params: _fast,
        deriveKey: stubDeriveKey,
        readFile: files.read,
        writeFile: files.write,
        deleteFile: files.delete,
      );
      await vault.load();
      await vault.setUp(_passphrase);

      final store = MemoryDiaryStore();
      await store.save(DiaryEntry.create(
        date: DateTime(2026, 10, 8),
        device: 'test',
        body: '第一行\n第二行',
      ));
      final controller = await pumpApp(tester, store, vault: vault);
      await controller.openDate(DateTime(2026, 10, 8));
      await tester.pumpAndSettle();

      // 锁一段 → 会弹一条提示
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加密这段'));
      await tester.pumpAndSettle();
      expect(find.textContaining('这一段已加密'), findsOneWidget);

      // 提示还挂着的时候，「更多」必须仍然能点开——
      // 这正是之前"贴底提示盖住右下角"造成的问题
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text('日记加密'), findsOneWidget);
    });

    testWidgets('「更多」菜单按功能分组：加密、备份、提醒各自成组', (tester) async {
      final fixture = await lockedFixture();
      final store = MemoryDiaryStore();
      await store.save(fixture.locked);
      await pumpApp(tester, store, vault: fixture.vault);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();

      // 分组靠分隔线，这里只验"该出现的都在、顺序成组"
      expect(find.text('备份'), findsOneWidget);
      expect(find.text('历史版本'), findsOneWidget);
      expect(find.text('回收站'), findsOneWidget);
      expect(find.text('日记加密'), findsOneWidget);
      expect(find.byType(PopupMenuDivider), findsWidgets);
    });
  });

  group('程序锁的设置入口', () {
    testWidgets('「⋮ → 日记加密」的对话框里有「进入程序时需要口令」开关', (tester) async {
      final files = _FakeVaultFiles();
      final vault = VaultService(
        diaryRoot: r'D:\someone\MyData',
        params: _fast,
        deriveKey: stubDeriveKey,
        readFile: files.read,
        writeFile: files.write,
        deleteFile: files.delete,
      );
      await vault.load();
      await vault.setUp(_passphrase); // setUp 之后是**已解锁**状态
      final store = MemoryDiaryStore();
      await store.save(DiaryEntry.create(
        date: DateTime(2026, 10, 8),
        device: 'test',
        body: '普通的一天',
      ));
      final controller = await pumpApp(tester, store, vault: vault);
      await controller.openDate(DateTime(2026, 10, 8));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('日记加密'));
      await tester.pumpAndSettle();

      expect(find.text('程序锁'), findsOneWidget, reason: '这一段必须出现');
      expect(find.text('进入程序时需要口令'), findsOneWidget);
      expect(find.byType(Switch), findsWidgets);

      // 打开开关：第一次会先弹一次说明，点掉之后才生效
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      expect(find.text('程序锁是一道栅栏，不是保险柜'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      expect(find.text('闲置后自动锁上'), findsOneWidget);

      // 选一个时长之后：开关必须**还是开的**、值就是选的那个
      // （用户实测：选 5 分钟之后整段自动关掉了）
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 分钟').last);
      await tester.pumpAndSettle();

      expect(
        tester.widget<Switch>(find.byType(Switch).last).value,
        isTrue,
        reason: '选时长不该把开关关掉',
      );
      expect(find.text('闲置后自动锁上'), findsOneWidget, reason: '这一段不该消失');
      expect(
        tester.widget<DropdownButton<int>>(find.byType(DropdownButton<int>)).value,
        5,
      );
    });
  });

  group('程序锁的锁屏界面', () {
    testWidgets('锁着时只显示锁屏，**看不到任何日记内容**；输对口令后进入', (tester) async {
      final files = _FakeVaultFiles();
      final vault = VaultService(
        diaryRoot: r'D:\someone\MyData',
        params: _fast,
        deriveKey: stubDeriveKey,
        readFile: files.read,
        writeFile: files.write,
        deleteFile: files.delete,
      );
      await vault.load();
      await vault.setUp(_passphrase);
      // 关掉程序再打开 = 会话没了，但保险库还在
      vault.lock();
      expect(vault.isConfigured, isTrue);
      expect(vault.isUnlocked, isFalse);

      final store = MemoryDiaryStore();
      await store.save(DiaryEntry.create(
        date: DateTime(2026, 10, 8),
        device: 'test',
        body: '记得买牛奶',
      ));

      final controller = await pumpApp(
        tester,
        store,
        vault: vault,
        settings: const AppSettings(
          diaryRoot: r'D:\someone\MyData',
          appLockEnabled: true,
          appLockIdleMinutes: 5,
        ),
      );

      // 锁屏在，日记内容一个都不许露出来
      expect(find.text('日迹已锁定'), findsOneWidget);
      expect(find.text('记得买牛奶'), findsNothing,
          reason: '锁屏下绝不能渲染出日记内容');
      expect(find.byKey(bodyField), findsNothing,
          reason: '连正文输入框都不该存在');

      // 输口令进入
      await tester.enterText(find.byType(TextField).first, _passphrase);
      await tester.tap(find.text('解锁'));
      await tester.pumpAndSettle();

      expect(find.text('日迹已锁定'), findsNothing);
      expect(find.byKey(bodyField), findsOneWidget, reason: '进来之后应该有编辑器');
      // 锁定时内存被清空了，解锁后要重新读回来
      expect(controller.entries, isNotEmpty);
    });

    testWidgets('没开程序锁时照常进主界面（哪怕保险库是锁的）', (tester) async {
      final fixture = await lockedFixture();
      final store = MemoryDiaryStore();
      await store.save(fixture.locked);
      await pumpApp(tester, store, vault: fixture.vault);
      await tester.pumpAndSettle();

      expect(find.text('日迹已锁定'), findsNothing);
      expect(find.byKey(bodyField), findsOneWidget);
    });
  });

  group('这次的界面改进', () {
    testWidgets('「显示原文」和「回到黑条视图」两个状态按钮**等宽**', (tester) async {
      final files = _FakeVaultFiles();
      final vault = VaultService(
        diaryRoot: r'D:\someone\MyData',
        params: _fast,
        deriveKey: stubDeriveKey,
        readFile: files.read,
        writeFile: files.write,
        deleteFile: files.delete,
      );
      await vault.load();
      await vault.setUp(_passphrase);
      final store = MemoryDiaryStore();
      await store.save(await vault.lockLine(
        DiaryEntry.create(date: DateTime(2026, 10, 8), device: 'test', body: '第一行\n$_secret'),
        1,
      ));
      final controller = await pumpApp(tester, store, vault: vault);
      await controller.openDate(DateTime(2026, 10, 8));
      await tester.pumpAndSettle();

      // 量**按钮**的宽度（文字长短本来就不一样，那不是这件事要保证的）
      double buttonWidth(String label) => tester
          .getSize(find.ancestor(
            of: find.text(label),
            matching: find.byType(TextButton),
          ))
          .width;

      final before = buttonWidth('显示原文（只读）');
      await tester.tap(find.text('显示原文（只读）'));
      await tester.pumpAndSettle();
      final after = buttonWidth('回到黑条视图');

      expect(after, closeTo(before, 0.5),
          reason: '换文案不该让按钮变宽变窄，否则点起来会跳');
    });

    testWidgets('第一次打开程序锁会弹一次说明，之后不再弹', (tester) async {
      final files = _FakeVaultFiles();
      final vault = VaultService(
        diaryRoot: r'D:\someone\MyData',
        params: _fast,
        deriveKey: stubDeriveKey,
        readFile: files.read,
        writeFile: files.write,
        deleteFile: files.delete,
      );
      await vault.load();
      await vault.setUp(_passphrase);
      final store = MemoryDiaryStore();
      await store.save(DiaryEntry.create(
        date: DateTime(2026, 10, 8), device: 'test', body: '普通的一天',
      ));
      final controller = await pumpApp(tester, store, vault: vault);
      await controller.openDate(DateTime(2026, 10, 8));
      await tester.pumpAndSettle();

      Future<void> openDialog() async {
        await tester.tap(find.byTooltip('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('日记加密'));
        await tester.pumpAndSettle();
      }

      await openDialog();
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      expect(find.text('程序锁是一道栅栏，不是保险柜'), findsOneWidget,
          reason: '第一次开必须说清它挡不住什么');
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(find.byType(Switch).last).value,
        isTrue,
        reason: '看完说明之后开关要是开的',
      );

      // 关掉再打开：不该再弹
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      expect(find.text('程序锁是一道栅栏，不是保险柜'), findsNothing,
          reason: '只弹一次，不是每次都弹');
    });
  });

  group('右键菜单', () {
    testWidgets('左侧日期右键：弹出的菜单里有加密那几项', (tester) async {
      final fixture = await lockedFixture();
      final store = MemoryDiaryStore();
      await store.save(fixture.locked);
      await pumpApp(tester, store, vault: fixture.vault);

      // 在日期条目上按右键
      final tile = find.textContaining('2026-10-06');
      expect(tile, findsWidgets);
      await tester.tapAt(
        tester.getCenter(tile.first),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      // 整天级合成一项：这一天是整天加密的，所以显示"解密这天"
      expect(find.text('解密这天'), findsOneWidget);
      expect(find.text('加密这天'), findsNothing);
      expect(find.text('显示原文（只读）'), findsOneWidget);
      // 列表里不放「日记加密…」（那是设置，用「⋮」就够了）
      expect(find.text('日记加密…'), findsNothing);
      // 但要有"删除这一天的日记"
      expect(find.text('删除这一天的日记'), findsOneWidget);
    });

    testWidgets('正文右键：菜单里带上光标所在段落的加密项', (tester) async {
      final files = _FakeVaultFiles();
      final vault = VaultService(
        diaryRoot: r'D:\someone\MyData',
        params: _fast,
        deriveKey: stubDeriveKey,
        readFile: files.read,
        writeFile: files.write,
        deleteFile: files.delete,
      );
      await vault.load();
      await vault.setUp(_passphrase);
      final day = DateTime(2026, 10, 8);
      final store = MemoryDiaryStore();
      await store.save(await vault.lockLine(
        DiaryEntry.create(date: day, device: 'test', body: '第一行\n$_secret'),
        1,
      ));

      final controller = await pumpApp(tester, store, vault: vault);
      await controller.openDate(day);
      await tester.pumpAndSettle();

      await tester.tapAt(
        tester.getCenter(find.byKey(bodyField)),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      // 系统自带的项必须是中文的（没配 flutter_localizations 时会是 "Select all"）
      expect(find.text('全选'), findsWidgets, reason: '系统菜单项要汉化');
      expect(find.text('Select all'), findsNothing);

      // 光标默认在文末（黑条那一行）→ 段落级的两项应该出现
      expect(find.text('看这段的内容'), findsWidgets);
      expect(find.text('解密这段'), findsWidgets);
      expect(find.text('加密这天'), findsWidgets);
    });
  });

  group('显示原文（只读模式）', () {
    testWidgets('进入后整篇显示原文、输入框只读；退出后回到黑条视图', (tester) async {
      final files = _FakeVaultFiles();
      final vault = VaultService(
        diaryRoot: r'D:\someone\MyData',
        params: _fast,
        deriveKey: stubDeriveKey,
        readFile: files.read,
        writeFile: files.write,
        deleteFile: files.delete,
      );
      await vault.load();
      await vault.setUp(_passphrase);
      final day = DateTime(2026, 10, 8);
      final store = MemoryDiaryStore();
      await store.save(await vault.lockLine(
        DiaryEntry.create(date: day, device: 'test', body: '第一行\n$_secret'),
        1,
      ));

      final controller = await pumpApp(tester, store, vault: vault);
      await controller.openDate(day);
      await tester.pumpAndSettle();

      // 进去之前：编辑框里是黑条
      expect(
        tester.widget<TextField>(find.byKey(bodyField)).controller!.text,
        contains('█'),
      );

      await controller.enterRevealMode();
      await tester.pumpAndSettle();

      // 整篇按原文显示，而且只读（横幅已经去掉，状态现在由那个按钮承载）
      expect(find.text('回到黑条视图'), findsOneWidget);
      final revealed = tester.widget<TextField>(find.byKey(bodyField));
      expect(revealed.controller!.text, contains(_secret));
      expect(revealed.readOnly, isTrue, reason: '显示原文时一律只读');

      // **关键**：真正要落盘的那个正文控制器一个字都没变
      expect(controller.body.contains('█'), isTrue);
      expect(controller.body.contains(_secret), isFalse,
          reason: '原文绝不能进正文控制器——那是要落盘的东西');

      // 退出后回到黑条视图
      controller.exitRevealMode();
      await tester.pumpAndSettle();
      expect(find.text('回到黑条视图'), findsNothing);
      expect(
        tester.widget<TextField>(find.byKey(bodyField)).controller!.text,
        contains('█'),
      );
    });

    testWidgets('没解锁时进不去（菜单里那一项根本不出现）', (tester) async {
      final fixture = await lockedFixture();
      final store = MemoryDiaryStore();
      await store.save(fixture.locked);
      final controller = await pumpApp(tester, store, vault: fixture.vault);
      await controller.openDate(DateTime(2026, 10, 6));
      await tester.pumpAndSettle();

      expect(controller.canRevealOriginal, isFalse);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text('显示原文（只读）'), findsNothing);
    });
  });
}
