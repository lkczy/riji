// 备份的平台层：真实文件 I/O。必须用普通 test()。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/backup.dart';
import 'package:riji/platform/platform_io.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory diary;
  late Directory backup;

  setUp(() {
    diary = Directory.systemTemp.createTempSync('bk_diary_');
    backup = Directory.systemTemp.createTempSync('bk_target_');
  });
  tearDown(() {
    for (final dir in <Directory>[diary, backup]) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  void writeDiary(String relative, String content) {
    final file = File(p.join(diary.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  List<String> autoDirs() => Directory(p.join(backup.path, '自动'))
      .existsSync()
      ? (Directory(p.join(backup.path, '自动'))
              .listSync()
              .whereType<Directory>()
              .map((d) => p.basename(d.path))
              .toList()
          ..sort())
      : <String>[];

  Future<BackupOutcome> runAuto({DateTime? at}) => createBackupSnapshot(
        diaryRoot: diary.path,
        backupRoot: backup.path,
        kind: SnapshotKind.auto,
        at: at,
      );

  test('备份包含日记本体、历史和回收站，排除草稿和临时文件', () async {
    writeDiary('2026/2026-10-02.md', '正文');
    writeDiary('.history/2026-10-02/113000-opened.md', '旧版本');
    writeDiary('.trash/2026-10-01.md.1.deleted', '删掉的');
    writeDiary('.drafts/2026-10-02.md', '草稿');
    writeDiary('2026/2026-10-02.md.tmp-abc', '临时');
    writeDiary('.stfolder/marker', '同步标记');

    final outcome = await runAuto(at: DateTime(2026, 10, 2, 22, 10));
    expect(outcome.ok, isTrue, reason: outcome.message);
    expect(outcome.skipped, isFalse);

    final snapshot = outcome.snapshotPath!;
    expect(p.basename(snapshot), '2026-10-02');

    File inSnapshot(String relative) => File(p.join(snapshot, relative));
    expect(inSnapshot('2026/2026-10-02.md').readAsStringSync(), '正文');
    expect(
      inSnapshot('.history/2026-10-02/113000-opened.md').readAsStringSync(),
      '旧版本',
      reason: '出错后最想要的就是历史版本，必须进备份',
    );
    expect(inSnapshot('.trash/2026-10-01.md.1.deleted').existsSync(), isTrue);
    expect(inSnapshot('.drafts/2026-10-02.md').existsSync(), isFalse);
    expect(inSnapshot('2026/2026-10-02.md.tmp-abc').existsSync(), isFalse);
    expect(inSnapshot('.stfolder').existsSync(), isFalse);

    final manifest = inSnapshot(kManifestFileName);
    expect(manifest.existsSync(), isTrue);
    expect(manifest.readAsStringSync(), contains('文件数: 3'));
    expect(manifest.readAsStringSync(), contains('类型: 自动'));
  });

  test('自动备份：今天已经有一份就跳过', () async {
    writeDiary('2026/2026-10-02.md', '一');
    final first = await runAuto(at: DateTime(2026, 10, 2, 9));
    expect(first.ok, isTrue);
    expect(first.skipped, isFalse);

    writeDiary('2026/2026-10-02.md', '二');
    final second = await runAuto(at: DateTime(2026, 10, 2, 22));
    expect(second.ok, isTrue);
    expect(second.skipped, isTrue, reason: '一天至多一份');
    expect(autoDirs().length, 1);
  });

  test('自动备份：内容没变就跳过（只是打开看看不该产生文件）', () async {
    writeDiary('2026/2026-10-02.md', '一');
    await runAuto(at: DateTime(2026, 10, 2, 9));

    final next = await runAuto(at: DateTime(2026, 10, 3, 9));
    expect(next.skipped, isTrue, reason: '内容自上次备份以来没有变化');
    expect(autoDirs().length, 1);

    writeDiary('2026/2026-10-03.md', '新的');
    final third = await runAuto(at: DateTime(2026, 10, 4, 9));
    expect(third.skipped, isFalse, reason: '内容变了就该备份');
    expect(autoDirs().length, 2);
  });

  test('回收站里的内容变了也算内容变了', () async {
    writeDiary('2026/2026-10-02.md', '一');
    await runAuto(at: DateTime(2026, 10, 2, 9));

    writeDiary('.trash/2026-10-01.md.9.deleted', '刚删的');
    final next = await runAuto(at: DateTime(2026, 10, 3, 9));
    expect(next.skipped, isFalse);
  });

  test('修剪：只保留 30 份自动备份，从最旧的开始删', () async {
    final kindDir = Directory(p.join(backup.path, '自动'));
    kindDir.createSync(recursive: true);

    // 预先造 35 份旧的自动快照（每份带清单，才算"认得出的一份"）
    for (var i = 0; i < 35; i++) {
      final day = DateTime(2026, 1, 1).add(Duration(days: i));
      final dir = Directory(p.join(
        kindDir.path,
        '${day.year}-${day.month.toString().padLeft(2, '0')}-'
            '${day.day.toString().padLeft(2, '0')}',
      ));
      dir.createSync(recursive: true);
      File(p.join(dir.path, kManifestFileName)).writeAsStringSync('riji 备份清单\n---\n');
    }

    // 用户自己的目录和手动快照：**绝不能被碰**
    final manualDir = Directory(p.join(backup.path, '手动', '2026-01-01 0900 重要'))
      ..createSync(recursive: true);
    final unknownDir = Directory(p.join(kindDir.path, '我的照片'))
      ..createSync(recursive: true);

    writeDiary('2026/2026-10-02.md', '正文');
    final outcome = await runAuto(at: DateTime(2026, 12, 1, 20));

    expect(outcome.ok, isTrue, reason: outcome.message);
    expect(outcome.pruned, 6, reason: '35 旧的 + 1 新的 = 36，超出 30 的部分要删');
    // 只数认得出来的：`我的照片` 那个目录本来就该留下
    expect(
      autoDirs().where((n) => SnapshotName.parse(n) != null).length,
      30,
    );
    expect(autoDirs(), isNot(contains('2026-01-01')), reason: '删的应该是最旧的');
    expect(manualDir.existsSync(), isTrue, reason: '手动快照永不删除');
    expect(unknownDir.existsSync(), isTrue, reason: '认不出的目录永不删除');
  });

  test('没有清单的目录不会被当成可删的快照', () async {
    final kindDir = Directory(p.join(backup.path, '自动'))..createSync(recursive: true);
    // 名字合法，但**里面没有清单** —— 像是别的程序留下的同名目录。
    //
    // 必须造出**超过 30 个不重复**的日期。这里原先写的是 `i % 28`，35 次
    // 循环只产生 28 个目录，根本没到上限，于是修剪逻辑压根没被触发——
    // 那条测试是**空转**的。反向验证（去掉保护后它依然通过）才发现。
    for (var i = 0; i < 35; i++) {
      final day = DateTime(2026, 1, 1).add(Duration(days: i));
      Directory(p.join(
        kindDir.path,
        '${day.year}-${day.month.toString().padLeft(2, '0')}-'
            '${day.day.toString().padLeft(2, '0')}',
      )).createSync(recursive: true);
    }
    expect(kindDir.listSync().length, 35,
        reason: '先确认素材真的超过上限，否则这条测试会退化成空转');

    writeDiary('2026/2026-10-02.md', '正文');
    final outcome = await runAuto(at: DateTime(2026, 12, 1, 20));
    expect(outcome.ok, isTrue);
    expect(outcome.pruned, 0, reason: '没有清单的目录一个都不该删');
    expect(kindDir.listSync().length, 36,
        reason: '35 个没清单的 + 1 份新备份，一个都不该被删');
  });

  test('恢复落到新目录，绝不碰正在用的日记目录', () async {
    writeDiary('2026/2026-10-02.md', '备份时的内容');
    final made = await runAuto(at: DateTime(2026, 10, 2, 22));

    // 备份之后日记又变了
    writeDiary('2026/2026-10-02.md', '后来改的');

    final restored = await restoreBackupSnapshot(
      snapshotDir: made.snapshotPath!,
      targetParent: backup.path,
      at: DateTime(2026, 10, 5, 10),
    );
    expect(restored.ok, isTrue, reason: restored.message);

    final target = restored.snapshotPath!;
    expect(p.basename(target), 'riji-恢复-20261005-1000');
    expect(
      File(p.join(target, '2026/2026-10-02.md')).readAsStringSync(),
      '备份时的内容',
    );
    expect(File(p.join(target, kManifestFileName)).existsSync(), isFalse,
        reason: '清单不是日记内容，不参与恢复');
    expect(
      File(p.join(diary.path, '2026/2026-10-02.md')).readAsStringSync(),
      '后来改的',
      reason: '恢复绝不能覆盖正在用的日记目录',
    );
  });

  test('恢复两次不会互相覆盖，也不会写到日记目录里', () async {
    writeDiary('2026/2026-10-02.md', '内容');
    final made = await runAuto(at: DateTime(2026, 10, 2, 22));

    final first = await restoreBackupSnapshot(
      snapshotDir: made.snapshotPath!, targetParent: backup.path,
      at: DateTime(2026, 10, 5, 10));
    final second = await restoreBackupSnapshot(
      snapshotDir: made.snapshotPath!, targetParent: backup.path,
      at: DateTime(2026, 10, 5, 10));

    expect(first.snapshotPath, isNot(second.snapshotPath));
    expect(Directory(first.snapshotPath!).existsSync(), isTrue);
    expect(Directory(second.snapshotPath!).existsSync(), isTrue);
  });

  test('清单能被读回来，用于判断内容有没有变', () async {
    writeDiary('2026/2026-10-02.md', '一');
    final made = await runAuto(at: DateTime(2026, 10, 2, 9));
    final stamps = parseManifestStamps(
      File(p.join(made.snapshotPath!, kManifestFileName)).readAsStringSync(),
    );
    expect(stamps.map((s) => s.path), contains('2026/2026-10-02.md'));
    expect(hasChanges(stamps, await Future.value(stamps)), isFalse);
  });
}
