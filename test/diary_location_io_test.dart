import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riji/platform/platform_io.dart' as io;
import 'package:path/path.dart' as p;

/// 真实文件系统实现的测试。
///
/// 这一层是整个「更改日记位置」功能里最要命的部分：它真的在搬数据。
/// 上面那些纯逻辑测试证明"判断对不对"，这里证明"动手动得对不对"。
void main() {
  late Directory sandbox;
  late String source;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('mydiary_loc_');
    source = p.join(sandbox.path, 'diary');
    Directory(source).createSync(recursive: true);
  });

  tearDown(() {
    try {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  void writeFile(String relativePath, String content) {
    final file = File(p.join(source, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void seedDiary() {
    writeFile(p.join('2026', '2026-02-14.md'), '第一天的内容');
    writeFile(p.join('2026', '2026-02-15.md'), '第二天的内容');
    writeFile(p.join('2025', '2025-12-31.md'), '去年的最后一天');
    writeFile(p.join('2026', '2026-02-14.sync-conflict-20260214-214002-ABC.md'), '冲突版本');
    writeFile(p.join('随手记.md'), '不是日记命名的文件');
    writeFile(p.join('.drafts', '2026-02-16.draft'), '写了一半的草稿');
    writeFile(p.join('.trash', '2026-02-01.md.123.deleted'), '已删除的内容');
  }

  group('normalizeDiaryPath', () {
    test('空输入返回空串，而不是当前工作目录', () {
      // 这条很关键：如果空输入被规范化成 CWD，界面就会把它当成一个"合法位置"
      expect(io.normalizeDiaryPath(''), '');
      expect(io.normalizeDiaryPath('   '), '');
    });

    test('相对路径会变成绝对路径', () {
      final result = io.normalizeDiaryPath('日记');
      expect(p.isAbsolute(result), isTrue);
      expect(result.endsWith('日记'), isTrue);
    });
  });

  group('gatherDiaryLocationFacts：实测而不是猜测', () {
    test('数得清各类文件', () async {
      seedDiary();

      final facts = await io.gatherDiaryLocationFacts(
        rawPath: source,
        currentRoot: r'C:\elsewhere',
        currentEntryCount: 0,
      );

      expect(facts.exists, isTrue);
      expect(facts.isDirectory, isTrue);
      expect(facts.writable, isTrue);
      expect(facts.entryCount, 3, reason: '三篇日记');
      expect(facts.conflictCount, 1, reason: '一个冲突文件');
      expect(facts.foreignMarkdownCount, 1, reason: '随手记.md 是别的 md');
      expect(facts.inspectionFailed, isFalse);
    });

    test('点目录里的东西不算日记', () async {
      seedDiary();

      final facts = await io.gatherDiaryLocationFacts(
        rawPath: source,
        currentRoot: r'C:\elsewhere',
        currentEntryCount: 0,
      );

      // .drafts 里的草稿和 .trash 里的已删除内容都不该被算进来
      expect(facts.entryCount, 3);
    });

    test('目录还不存在时，检查最近的已存在祖先能不能写', () async {
      final target = p.join(sandbox.path, '还不存在', '更深一层');

      final facts = await io.gatherDiaryLocationFacts(
        rawPath: target,
        currentRoot: r'C:\elsewhere',
        currentEntryCount: 0,
      );

      expect(facts.exists, isFalse);
      expect(facts.writable, isTrue, reason: '祖先目录可写，就能创建出来');
      expect(facts.entryCount, 0);
    });

    test('路径指向文件时说清楚它不是文件夹', () async {
      final file = File(p.join(sandbox.path, '一个文件.txt'))..writeAsStringSync('x');

      final facts = await io.gatherDiaryLocationFacts(
        rawPath: file.path,
        currentRoot: r'C:\elsewhere',
        currentEntryCount: 0,
      );

      expect(facts.exists, isTrue);
      expect(facts.isDirectory, isFalse);
    });

    test('空路径不会被规范化成当前工作目录', () async {
      final facts = await io.gatherDiaryLocationFacts(
        rawPath: '   ',
        currentRoot: r'C:\elsewhere',
        currentEntryCount: 0,
      );

      expect(facts.normalizedPath, '');
      expect(facts.exists, isFalse);
    });
  });

  group('copyDiaryTree：只复制，绝不破坏', () {
    test('连隐藏目录一起完整复制，内容逐字节一致', () async {
      seedDiary();
      final target = p.join(sandbox.path, '新位置');

      final outcome = await io.copyDiaryTree(from: source, to: target);

      expect(outcome.ok, isTrue, reason: outcome.message);
      expect(outcome.filesCopied, 7);

      // 日记、冲突文件、草稿、回收站都要在
      for (final relative in <String>[
        p.join('2026', '2026-02-14.md'),
        p.join('2026', '2026-02-15.md'),
        p.join('2025', '2025-12-31.md'),
        p.join('2026', '2026-02-14.sync-conflict-20260214-214002-ABC.md'),
        '随手记.md',
        p.join('.drafts', '2026-02-16.draft'),
        p.join('.trash', '2026-02-01.md.123.deleted'),
      ]) {
        final copied = File(p.join(target, relative));
        expect(copied.existsSync(), isTrue, reason: '缺少 $relative');
        expect(
          copied.readAsStringSync(),
          File(p.join(source, relative)).readAsStringSync(),
          reason: '$relative 内容不一致',
        );
      }
    });

    test('绝不改动源目录', () async {
      seedDiary();
      final before = <String, String>{};
      for (final entity in Directory(source).listSync(recursive: true)) {
        if (entity is File) {
          before[p.relative(entity.path, from: source)] =
              entity.readAsStringSync();
        }
      }

      await io.copyDiaryTree(from: source, to: p.join(sandbox.path, '新位置'));

      final after = <String, String>{};
      for (final entity in Directory(source).listSync(recursive: true)) {
        if (entity is File) {
          after[p.relative(entity.path, from: source)] =
              entity.readAsStringSync();
        }
      }
      expect(after, before, reason: '源目录必须一个字节都不变');
    });

    test('目标已有同名文件时中止，并且不覆盖它的内容', () async {
      seedDiary();
      final target = p.join(sandbox.path, '已有内容');
      final existing = File(p.join(target, '2026', '2026-02-14.md'));
      existing.parent.createSync(recursive: true);
      existing.writeAsStringSync('这是目标位置原有的内容，绝不能被覆盖');

      final outcome = await io.copyDiaryTree(from: source, to: target);

      expect(outcome.ok, isFalse);
      expect(outcome.message, contains('同名文件'));
      expect(existing.readAsStringSync(), '这是目标位置原有的内容，绝不能被覆盖');
    });

    test('源目录为空时算成功，只是没有文件可复制', () async {
      final outcome = await io.copyDiaryTree(
        from: source,
        to: p.join(sandbox.path, '新位置'),
      );

      expect(outcome.ok, isTrue);
      expect(outcome.filesCopied, 0);
    });

    test('源目录不存在时不会抛异常，只报失败', () async {
      final outcome = await io.copyDiaryTree(
        from: p.join(sandbox.path, '根本不存在'),
        to: p.join(sandbox.path, '新位置'),
      );

      expect(outcome.ok, isFalse);
      expect(outcome.message, isNotEmpty);
    });

    test('成功后的说明必须告诉用户原位置没被动过', () async {
      seedDiary();

      final outcome = await io.copyDiaryTree(
        from: source,
        to: p.join(sandbox.path, '新位置'),
      );

      expect(outcome.message, contains('没有做任何改动'));
    });

    test('进度回调按文件数递增', () async {
      seedDiary();
      final progress = <int>[];

      await io.copyDiaryTree(
        from: source,
        to: p.join(sandbox.path, '新位置'),
        onProgress: (copied, total) => progress.add(copied),
      );

      expect(progress, isNotEmpty);
      expect(progress.last, progress.length);
    });
  });

  group('目录枚举', () {
    test('子目录返回完整路径，界面不用自己拼', () async {
      Directory(p.join(source, 'aaa')).createSync(recursive: true);
      Directory(p.join(source, 'bbb')).createSync(recursive: true);

      final children = await io.listDiarySubdirectories(source);

      expect(children, hasLength(2));
      for (final child in children) {
        expect(p.isAbsolute(child), isTrue);
        expect(p.dirname(child), source);
      }
    });

    test('不可读的路径返回空列表而不是抛异常', () async {
      final children =
          await io.listDiarySubdirectories(p.join(sandbox.path, '不存在'));
      expect(children, isEmpty);
    });

    test('磁盘根目录列表包含当前卷', () {
      final roots = io.listDiaryDriveRoots();
      if (Platform.isWindows) {
        expect(roots, isNotEmpty);
        final systemDrive = p.rootPrefix(Directory.systemTemp.path);
        expect(
          roots.map((r) => r.toUpperCase()),
          contains(systemDrive.toUpperCase()),
        );
      }
    });

    test('上级目录：已经在根上时返回 null', () {
      if (!Platform.isWindows) return;
      expect(io.diaryParentDirectory(r'C:\'), isNull);
      expect(io.diaryParentDirectory(r'C:\日记'), r'C:\');
    });
  });
}
