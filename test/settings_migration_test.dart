// 设置迁移：程序从 myDiary 改名为 riji 时，不能让用户以为日记丢了。
//
// 这条路径为什么必须有测试盯着：
//
// 改名那次批量替换把 `_legacyAppDirName` 从 `'myDiary'` 一起改成了 `'riji'`，
// 于是迁移会去**新**目录里找一个并不在那儿的旧设置——**静默失效**：
// 不报错、不崩、483 个测试全过，只会在某次重启后让用户发现程序打开的是
// 一个空白日记（数据其实一个字节都没少，只是程序不知道该去哪找）。
//
// 所以这里既钉住那个字面量，也直接测迁移函数本身。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:riji/platform/platform_io.dart';

void main() {
  late Directory sandbox;
  late String legacyDir;
  late String newDir;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('riji_migrate_');
    legacyDir = p.join(sandbox.path, 'myDiary');
    newDir = p.join(sandbox.path, 'riji');
  });

  tearDown(() {
    try {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  void writeLegacy(String content) {
    final file = File(p.join(legacyDir, 'settings.json'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  File target() => File(p.join(newDir, 'settings.json'));

  const legacyJson =
      '{"version":1,"diaryRoot":"D:\\\\someone\\\\MyData","themeMode":"dark"}';

  test('常量必须指向旧名字 myDiary（改名时最容易把它一起改掉）', () {
    expect(
      legacyAppDirName,
      'myDiary',
      reason: '它指向的是"程序改名之前"的目录。改成 riji 会让迁移静默失效。',
    );
  });

  test('旧目录有设置、新目录没有 → 搬过来，内容逐字节一致', () async {
    writeLegacy(legacyJson);
    expect(target().existsSync(), isFalse);
    expect(Directory(newDir).existsSync(), isFalse, reason: '目标目录一开始也不存在');

    final migrated = await migrateLegacySettings(
      legacyDir: legacyDir,
      target: target(),
    );

    expect(migrated, isTrue);
    expect(target().existsSync(), isTrue, reason: '目标目录不存在时应该被创建出来');
    expect(target().readAsStringSync(), legacyJson, reason: '内容必须原样搬运');
    expect(
      File(p.join(legacyDir, 'settings.json')).existsSync(),
      isTrue,
      reason: '旧文件不动（复制而不是移动）—— 迁移失败也不该让原始设置消失',
    );
  });

  test('新目录已经有设置 → 绝不动它（不覆盖）', () async {
    writeLegacy(legacyJson);
    target().parent.createSync(recursive: true);
    target().writeAsStringSync('{"version":1,"diaryRoot":"E:\\\\新位置"}');

    final migrated = await migrateLegacySettings(
      legacyDir: legacyDir,
      target: target(),
    );

    expect(migrated, isFalse);
    expect(
      target().readAsStringSync(),
      '{"version":1,"diaryRoot":"E:\\\\新位置"}',
      reason: '已经在用的设置绝不能被旧设置覆盖',
    );
  });

  test('旧目录没有设置 → 什么都不做，也不报错', () async {
    final migrated = await migrateLegacySettings(
      legacyDir: legacyDir,
      target: target(),
    );

    expect(migrated, isFalse);
    expect(target().existsSync(), isFalse);
  });

  test('只生效一次：连跑两次，第二次什么都不做', () async {
    writeLegacy(legacyJson);

    expect(
      await migrateLegacySettings(legacyDir: legacyDir, target: target()),
      isTrue,
    );
    // 第二次时新目录里已经有设置，于是走"不覆盖"那条路
    expect(
      await migrateLegacySettings(legacyDir: legacyDir, target: target()),
      isFalse,
    );
  });

  test('旧设置再怎么坏也只是搬过去，不会让迁移抛异常', () async {
    // 内容不是合法 JSON。迁移只负责搬字节，解析是上层的事——
    // 上层解析失败时会退回默认值，程序照样能开。
    writeLegacy('这不是 json');

    final migrated = await migrateLegacySettings(
      legacyDir: legacyDir,
      target: target(),
    );

    expect(migrated, isTrue);
    expect(target().readAsStringSync(), '这不是 json');
  });
}
