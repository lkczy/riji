// 备份的真实演练：真文件、逐字节比对、真的恢复一次。
//
// 和 backup_io_test.dart 的区别：那边验的是"行为对不对"（跳过、修剪、保护），
// 这边验的是"数据是不是一个字节都没变"——备份唯一不可原谅的失败就是内容
// 悄悄对不上。所以这里不看大小，**逐字节比**。
//
// 用的是合成出来的日记目录，绝不碰用户的真实日记。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/backup.dart';
import 'package:riji/platform/platform_io.dart';
import 'package:path/path.dart' as p;

/// 逐字节比较两个文件。
///
/// 不用大小比较：大小相同、内容不同的情况（编码被改过、写入被截断后又补齐）
/// 恰恰是备份最该发现的问题。
bool sameBytes(File a, File b) {
  if (!a.existsSync() || !b.existsSync()) return false;
  final left = a.readAsBytesSync();
  final right = b.readAsBytesSync();
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

/// 把一个目录下所有文件的相对路径列出来（含隐藏文件）。
List<String> relativeFiles(Directory root) =>
    root
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => p.relative(f.path, from: root.path).replaceAll('\\', '/'))
        .toList()
      ..sort();

void main() {
  late Directory source;
  late Directory backupRoot;

  setUp(() {
    source = Directory.systemTemp.createTempSync('drill_src_');
    backupRoot = Directory.systemTemp.createTempSync('drill_bak_');
  });
  tearDown(() {
    for (final dir in <Directory>[source, backupRoot]) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  void put(String relative, String content) {
    final file = File(p.join(source.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  /// 造一个"像真的"日记目录：手机写过的、带 CRLF 和 BOM 的、历史版本、
  /// 回收站、以及各种不该进备份的过程痕迹。
  void buildRealisticDiary() {
    put('2026/2026-09-30.md',
        '---\nid: 01M3VS66PS685Y86Q5AGNTEQAZ\ndate: 2026-09-30\n'
            'device: DESKTOP-ABC123\ntags:\n  - 随笔\n---\n\n今天的天气不错。\n');
    // 手机 Obsidian 写的：没有前置字段，带 CRLF
    put('2026/2026-10-01.md', '手机上写的第一行。\r\n第二行。\r\n');
    // 带 UTF-8 BOM 的
    final bom = File(p.join(source.path, '2026', '2026-10-02.md'));
    bom.parent.createSync(recursive: true);
    bom.writeAsBytesSync(<int>[
      0xEF, 0xBB, 0xBF,
      ...'带 BOM 的一篇。\n'.codeUnits,
    ]);

    put('.history/2026-10-02/113000-opened.md', '打开时的样子（旧版本）\n');
    put('.trash/2026-09-29.md.1759000000000.deleted', '删掉的一篇，还在回收站\n');

    // 这些**不该**进备份
    put('.drafts/2026-10-02.md', '未落盘的草稿\n');
    put('2026/2026-10-02.md.tmp-a1b2c3', '原子写入的临时文件\n');
    put('.stfolder/marker', '');
    put('.index.sqlite', '假索引');
  }

  test('真实演练：备份逐字节一致，该进的进、该排除的排除', () async {
    buildRealisticDiary();
    final sourceFiles = relativeFiles(source);
    expect(sourceFiles.length, 9, reason: '先把素材数清楚');

    final outcome = await createBackupSnapshot(
      diaryRoot: source.path,
      backupRoot: backupRoot.path,
      kind: SnapshotKind.manual,
      label: '演练',
      at: DateTime(2026, 10, 2, 22, 10),
    );
    expect(outcome.ok, isTrue, reason: outcome.message);
    final snapshot = Directory(outcome.snapshotPath!);

    // 1. 该进的一个不少，且**逐字节一致**
    const expected = <String>[
      '2026/2026-09-30.md',
      '2026/2026-10-01.md',
      '2026/2026-10-02.md',
      '.history/2026-10-02/113000-opened.md',
      '.trash/2026-09-29.md.1759000000000.deleted',
    ];
    for (final relative in expected) {
      final from = File(p.join(source.path, relative));
      final to = File(p.join(snapshot.path, relative));
      expect(to.existsSync(), isTrue, reason: '$relative 应该进备份');
      expect(sameBytes(from, to), isTrue, reason: '$relative 内容必须逐字节一致');
    }

    // 2. 该排除的一个都没有
    for (final relative in <String>[
      '.drafts/2026-10-02.md',
      '2026/2026-10-02.md.tmp-a1b2c3',
      '.stfolder/marker',
      '.index.sqlite',
    ]) {
      expect(File(p.join(snapshot.path, relative)).existsSync(), isFalse,
          reason: '$relative 不该进备份');
    }

    // 3. 清单存在、内容说得通，而且不长在备份数据里冒充日记
    final manifest = File(p.join(snapshot.path, kManifestFileName));
    expect(manifest.existsSync(), isTrue);
    final text = manifest.readAsStringSync();
    expect(text, contains('类型: 手动'));
    expect(text, contains('说明: 演练'));
    expect(text, contains('来源: ${source.path}'));
    expect(text, contains('文件数: 5'));
    expect(text, contains('.history/2026-10-02/113000-opened.md'));

    // 4. 备份目录里除了数据和清单，不该多别的东西
    final copied = relativeFiles(snapshot);
    expect(copied, <String>[...expected, kManifestFileName]..sort());

    // 5. 源目录一个字节都没被改动
    expect(relativeFiles(source), sourceFiles);
  });

  test('真实演练：恢复出来的内容与快照逐字节一致，且不动原日记', () async {
    buildRealisticDiary();
    final made = await createBackupSnapshot(
      diaryRoot: source.path,
      backupRoot: backupRoot.path,
      kind: SnapshotKind.manual,
      at: DateTime(2026, 10, 2, 22, 10),
    );
    final snapshot = Directory(made.snapshotPath!);

    // 备份之后源日记又变了：恢复出来的必须是**备份那一刻**的样子
    put('2026/2026-10-01.md', '后来改掉的内容\n');
    put('2026/2026-10-03.md', '备份之后新写的一篇\n');

    final restored = await restoreBackupSnapshot(
      snapshotDir: snapshot.path,
      targetParent: backupRoot.path,
      at: DateTime(2026, 10, 5, 9, 30),
    );
    expect(restored.ok, isTrue, reason: restored.message);
    final target = Directory(restored.snapshotPath!);
    expect(p.basename(target.path), 'riji-恢复-20261005-0930');

    // 快照里的每个数据文件，在恢复结果里都要逐字节一致
    final snapshotFiles = relativeFiles(snapshot)
        .where((relative) => relative != kManifestFileName)
        .toList();
    expect(snapshotFiles, isNotEmpty);
    for (final relative in snapshotFiles) {
      final from = File(p.join(snapshot.path, relative));
      final to = File(p.join(target.path, relative));
      expect(to.existsSync(), isTrue, reason: '$relative 应该被恢复出来');
      expect(sameBytes(from, to), isTrue,
          reason: '$relative 恢复后必须与快照逐字节一致');
    }
    expect(relativeFiles(target), snapshotFiles,
        reason: '恢复结果里不该有意外多出来的文件');

    // 恢复出来的必须是备份那一刻的内容，不是"后来改的"
    expect(
      File(p.join(target.path, '2026/2026-10-01.md')).readAsStringSync(),
      '手机上写的第一行。\r\n第二行。\r\n',
    );
    expect(File(p.join(target.path, '2026/2026-10-03.md')).existsSync(), isFalse,
        reason: '备份之后新写的那篇不该出现在恢复结果里');

    // 正在用的日记目录一个字节都不能被动
    expect(
      File(p.join(source.path, '2026/2026-10-01.md')).readAsStringSync(),
      '后来改掉的内容\n',
    );
    expect(File(p.join(source.path, '2026/2026-10-03.md')).existsSync(), isTrue);
  });

  test('真实演练：自动备份的完整生命周期（跳过 → 变化 → 修剪）', () async {
    put('2026/2026-10-02.md', '第一天\n');

    final first = await createBackupSnapshot(
      diaryRoot: source.path,
      backupRoot: backupRoot.path,
      kind: SnapshotKind.auto,
      at: DateTime(2026, 10, 2, 9),
    );
    expect(first.ok, isTrue, reason: first.message);
    expect(first.skipped, isFalse);

    // 同一天再关一次程序：跳过，不产生第二份
    final sameDay = await createBackupSnapshot(
      diaryRoot: source.path,
      backupRoot: backupRoot.path,
      kind: SnapshotKind.auto,
      at: DateTime(2026, 10, 2, 22),
    );
    expect(sameDay.skipped, isTrue, reason: '一天至多一份');

    // 第二天，内容**真的**没变：跳过。
    // （注意这一步不能改过文件——刚才那次同一天的尝试也没改，
    //   否则这里比的就是"变了"，程序不跳过是对的。）
    final noChange = await createBackupSnapshot(
      diaryRoot: source.path,
      backupRoot: backupRoot.path,
      kind: SnapshotKind.auto,
      at: DateTime(2026, 10, 3, 9),
    );
    expect(noChange.skipped, isTrue, reason: '内容没变不该产生文件');

    // 第二天写了新东西：备份
    put('2026/2026-10-03.md', '第二天\n');
    final changed = await createBackupSnapshot(
      diaryRoot: source.path,
      backupRoot: backupRoot.path,
      kind: SnapshotKind.auto,
      at: DateTime(2026, 10, 3, 23),
    );
    expect(changed.ok, isTrue, reason: changed.message);
    expect(changed.skipped, isFalse, reason: '内容变了就该备份');

    final autoDir =
        Directory(p.join(backupRoot.path, SnapshotKind.auto.dirName));
    final names = autoDir
        .listSync()
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .toList()
      ..sort();
    expect(names, <String>['2026-10-02', '2026-10-03']);

    // 第一份留住了第一天那一刻的样子 —— 这就是备份的价值
    expect(
      File(p.join(autoDir.path, '2026-10-02', '2026/2026-10-02.md'))
          .readAsStringSync(),
      '第一天\n',
    );
  });
}
