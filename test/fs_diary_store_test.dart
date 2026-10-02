import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/diary_codec.dart';
import 'package:riji/core/history.dart';
import 'package:riji/core/models/diary_entry.dart';
import 'package:riji/data/fs_diary_store.dart';
import 'package:path/path.dart' as p;

/// 文件系统实现的集成测试：真的在临时目录里读写文件。
/// 这一层最容易出问题的地方是 Windows 语义（rename 能否覆盖）和
/// 「哪些文件不该被当成日记」，所以必须用真实文件验证，不能只靠内存桩。
///
/// ⚠️ 这里必须用普通 `test()`，**绝不能改成 `testWidgets()`**。
/// testWidgets 跑在假异步环境里，dart:io 的 Future 由真实事件循环完成，
/// 假异步不驱动它，`await` 真实 I/O 会永远不返回，而且 --timeout 也拦不住。
/// 界面层如何响应这些结果，由 ui_test.dart 用测试替身覆盖。
void main() {
  late Directory root;
  late FsDiaryStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mydiary_test_');
    store = FsDiaryStore(rootPath: root.path, deviceName: 'test-device');
  });

  tearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录删不掉不影响测试结论
    }
  });

  DiaryEntry entry(
    DateTime date,
    String body, {
    String? mood,
    List<String> tags = const <String>[],
  }) =>
      DiaryEntry.create(
        date: date,
        device: 'test-device',
        body: body,
        mood: mood,
        tags: tags,
      );

  File dayFile(DateTime date) =>
      File(p.joinAll(<String>[root.path, '${date.year}', '${_name(date)}.md']));

  group('基本读写', () {
    test('保存后能原样读回', () async {
      const body = '今天把数据格式定下来了。\n\n第二段。';
      await store.save(entry(DateTime(2026, 2, 14), body));

      final loaded = await store.loadByDate(DateTime(2026, 2, 14));
      expect(loaded, isNotNull);
      expect(loaded!.body, body);
    });

    test('文件落在 年/日期.md 上', () async {
      await store.save(entry(DateTime(2026, 2, 14), 'x'));
      expect(dayFile(DateTime(2026, 2, 14)).existsSync(), isTrue);
    });

    test('心情和标签能往返', () async {
      await store.save(
        entry(DateTime(2026, 2, 14), '正文', mood: '平静', tags: ['工作', '阅读']),
      );
      final loaded = await store.loadByDate(DateTime(2026, 2, 14));
      expect(loaded!.mood, '平静');
      expect(loaded.tags, <String>['工作', '阅读']);
    });

    test('不存在的日期返回 null', () async {
      expect(await store.loadByDate(DateTime(1999, 1, 1)), isNull);
    });

    test('根目录不存在时 loadAll 返回空列表而不是抛异常', () async {
      final missing = FsDiaryStore(
        rootPath: p.join(root.path, '根本不存在'),
        deviceName: 'test',
      );
      expect(await missing.loadAll(), isEmpty);
    });
  });

  group('写入语义', () {
    test('同一天再次保存会覆盖（验证 Windows 上 rename 能替换已存在文件）', () async {
      final date = DateTime(2026, 2, 14);
      await store.save(entry(date, '第一版'));
      await store.save(entry(date, '第二版'));

      final loaded = await store.loadByDate(date);
      expect(loaded!.body, '第二版');
    });

    test('只改天气也必须写盘', () async {
      // 「内容没变就不写盘」这个优化最容易漏掉新字段：
      // 漏了的话，用户改了天气却什么都没发生，而且完全无声。
      final date = DateTime(2026, 2, 14);
      await store.save(entry(date, '正文'));
      final before = dayFile(date).statSync().modified;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final loaded = await store.loadByDate(date);
      await store.save(loaded!.copyWith(weather: '晴'));

      final after = dayFile(date).statSync().modified;
      expect(after.isAfter(before), isTrue,
          reason: '天气改了却没写盘，说明保存前的比较条件漏了 weather');
      expect((await store.loadByDate(date))!.weather, '晴');
    });

    test('只改心情也必须写盘', () async {
      final date = DateTime(2026, 2, 14);
      await store.save(entry(date, '正文'));
      final before = dayFile(date).statSync().modified;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final loaded = await store.loadByDate(date);
      await store.save(loaded!.copyWith(mood: '平静'));

      expect(dayFile(date).statSync().modified.isAfter(before), isTrue);
      expect((await store.loadByDate(date))!.mood, '平静');
    });

    test('天气能经真实文件往返', () async {
      final date = DateTime(2026, 2, 14);
      await store.save(entry(date, '正文').copyWith(weather: '多云: 转#晴'));

      final loaded = await store.loadByDate(date);
      expect(loaded!.weather, '多云: 转#晴');
    });

    test('内容没变时不重复写盘，避免刷新文件修改时间', () async {
      final date = DateTime(2026, 2, 14);
      final same = entry(date, '不变的正文');
      await store.save(same);

      final before = dayFile(date).statSync().modified;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await store.save(same);
      final after = dayFile(date).statSync().modified;

      expect(after, before,
          reason: '自动保存会反复触发，内容未变时不该写盘');
    });

    test('写入不留临时文件', () async {
      await store.save(entry(DateTime(2026, 2, 14), 'x'));

      final leftovers = root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => p.basename(f.path).contains('.tmp-'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('临时文件即使残留也不会被当成日记读进来', () async {
      final dir = Directory(p.join(root.path, '2026'))..createSync(recursive: true);
      File(p.join(dir.path, '.2026-02-14.md.tmp-123-0')).writeAsStringSync('半截内容');

      expect(await store.loadAll(), isEmpty);
    });
  });

  group('外部改动检测：绝不静默覆盖', () {
    /// 模拟一次"程序还开着的时候，这一天被别处改了"。
    Future<DiaryEntry> seedThenModifyExternally(DateTime date) async {
      await store.save(entry(date, '电脑上写的第一版'));
      final loaded = await store.loadByDate(date);
      dayFile(date).writeAsStringSync(DiaryCodec.encode(
        loaded!.copyWith(body: '手机上补的一段很重要的话'),
      ));
      return loaded;
    }

    test('发现被别人改过：两边的版本都保住，并如实报告冲突', () async {
      final date = DateTime(2026, 2, 14);
      final loaded = await seedThenModifyExternally(date);

      final outcome = await store.save(loaded.copyWith(body: '电脑上又加了一句'));

      expect(outcome.hadConflict, isTrue, reason: '必须报告，不能悄悄覆盖');
      expect(outcome.conflictPath, isNotNull);

      // 对方的版本原样躺在冲突文件里
      expect(
        File(outcome.conflictPath!).readAsStringSync(),
        contains('手机上补的一段很重要的话'),
      );
      // 我们正在写的版本留在正式文件里
      expect(
        dayFile(date).readAsStringSync(),
        contains('电脑上又加了一句'),
      );
    });

    test('产生的冲突文件能被 findConflicts 列出来，供用户合并', () async {
      final date = DateTime(2026, 2, 14);
      final loaded = await seedThenModifyExternally(date);

      await store.save(loaded.copyWith(body: 'x'));

      final conflicts = await store.findConflicts();
      expect(conflicts, hasLength(1));
      expect(conflicts.single.date, date);
      // 冲突文件不能被当成正常日记加载
      final entries = await store.loadAll();
      expect(entries, hasLength(1));
    });

    test('没有外部改动时正常写入，不产生冲突文件', () async {
      final date = DateTime(2026, 2, 14);
      await store.save(entry(date, '第一版'));
      final loaded = await store.loadByDate(date);

      final outcome = await store.save(loaded!.copyWith(body: '第二版'));

      expect(outcome.hadConflict, isFalse);
      expect(outcome.conflictPath, isNull);
      expect(await store.findConflicts(), isEmpty);
      expect((await store.loadByDate(date))!.body, '第二版');
    });

    test('第一次写入本来就没有文件，不算冲突', () async {
      final outcome = await store.save(entry(DateTime(2026, 2, 14), '新的一天'));

      expect(outcome.hadConflict, isFalse);
      expect(outcome.conflictPath, isNull);
    });

    test('冲突处理之后继续保存不会反复报警', () async {
      final date = DateTime(2026, 2, 14);
      final loaded = await seedThenModifyExternally(date);

      final first = await store.save(loaded.copyWith(body: '合并后的内容'));
      expect(first.hadConflict, isTrue);

      // 处理冲突时我们的版本已经落盘，"我们读到的那一份"也更新了，
      // 所以紧跟着的保存不该再报一次
      final second = await store.save(loaded.copyWith(body: '合并后的内容'));
      expect(second.hadConflict, isFalse);
      expect(second.wrote, isFalse, reason: '内容没变，不该重复写盘');
      expect(await store.findConflicts(), hasLength(1),
          reason: '不该每次保存都多出一个冲突文件');
    });

    test('程序没读过这一天的文件、但它突然出现了：也算冲突', () async {
      // 启动之后 Syncthing 才把这一天同步过来
      final date = DateTime(2026, 2, 15);
      final dir = Directory(p.join(root.path, '2026'))..createSync(recursive: true);
      File(p.join(dir.path, '2026-02-15.md')).writeAsStringSync(
        DiaryCodec.encode(DiaryEntry.create(
          date: date,
          device: 'phone',
          body: '手机上新写的一天',
        )),
      );

      // 用户此刻在电脑上给这一天新建了内容
      final outcome = await store.save(
        DiaryEntry.create(date: date, device: 'test-device', body: '电脑上也写了这一天'),
      );

      expect(outcome.hadConflict, isTrue);
      expect(
        File(outcome.conflictPath!).readAsStringSync(),
        contains('手机上新写的一天'),
      );
    });
  });

  group('前向兼容', () {
    test('改写正文时不会抹掉程序不认识的字段', () async {
      // 多设备同步时，跑旧版本的设备会走到这条路径。
      // 它若把新字段抹掉，再同步回去就是无声的永久丢失。
      final dir = Directory(p.join(root.path, '2026'))..createSync(recursive: true);
      final file = File(p.join(dir.path, '2026-02-14.md'));
      file.writeAsStringSync('---\n'
          'id: 01JQX8K2M4P7R9T3V6W8Y0AB2C\n'
          'date: 2026-02-14\n'
          'weather: 晴\n'
          '---\n'
          '\n'
          '原来的正文');

      final loaded = await store.loadByDate(DateTime(2026, 2, 14));
      await store.save(loaded!.copyWith(body: '改过的正文'));

      final content = file.readAsStringSync();
      expect(content, contains('weather: 晴'));
      expect(content, contains('改过的正文'));
      expect(content, isNot(contains('原来的正文')));
    });

    test('连续两次保存不改变文件内容', () async {
      final dir = Directory(p.join(root.path, '2026'))..createSync(recursive: true);
      final file = File(p.join(dir.path, '2026-02-14.md'));
      file.writeAsStringSync('---\n'
          'id: 01JQX8K2M4P7R9T3V6W8Y0AB2C\n'
          'date: 2026-02-14\n'
          'weather: 晴\n'
          '---\n'
          '\n'
          '正文');

      final first = await store.loadByDate(DateTime(2026, 2, 14));
      await store.save(first!.copyWith(body: '正文二'));
      final afterFirst = file.readAsStringSync();

      final second = await store.loadByDate(DateTime(2026, 2, 14));
      await store.save(second!);

      expect(file.readAsStringSync(), afterFirst);
    });
  });

  group('不该被当成日记的文件', () {
    test('手写、没有 front matter 的文件照样能读', () async {
      final dir = Directory(p.join(root.path, '2026'))..createSync(recursive: true);
      File(p.join(dir.path, '2026-02-14.md'))
          .writeAsStringSync('就是一段手写文字，没有 front matter。');

      final entries = await store.loadAll();
      expect(entries, hasLength(1));
      expect(entries.single.body, '就是一段手写文字，没有 front matter。');
      expect(entries.single.date, DateTime(2026, 2, 14));
      expect(entries.single.hasLegacyId, isTrue);
    });

    test('点目录被跳过：已删除的日记不会复活', () async {
      final trash = Directory(p.join(root.path, '.trash'))..createSync(recursive: true);
      File(p.join(trash.path, '2026-02-14.md')).writeAsStringSync('已经删掉的');

      expect(await store.loadAll(), isEmpty);
    });

    test('草稿目录不会被当成日记加载', () async {
      await store.writeDraft(DateTime(2026, 2, 14), '写了一半');
      expect(await store.loadAll(), isEmpty);
    });

    test('非 UTF-8 编码的文件不会让整个库读不出来', () async {
      final dir = Directory(p.join(root.path, '2026'))..createSync(recursive: true);
      // GBK 编码的「中文」，不是合法 UTF-8
      File(p.join(dir.path, '2026-02-14.md'))
          .writeAsBytesSync(<int>[0xD6, 0xD0, 0xCE, 0xC4]);

      final entries = await store.loadAll();
      expect(entries, hasLength(1), reason: '一个坏文件不该毁掉整次加载');
    });

    test('文件名不是日期的 Markdown 被忽略', () async {
      final dir = Directory(p.join(root.path, '2026'))..createSync(recursive: true);
      File(p.join(dir.path, '随手记.md')).writeAsStringSync('内容');

      expect(await store.loadAll(), isEmpty);
    });
  });

  group('排序与列表', () {
    test('按日期倒序，最新的在前', () async {
      await store.save(entry(DateTime(2026, 2, 10), 'a'));
      await store.save(entry(DateTime(2026, 2, 14), 'b'));
      await store.save(entry(DateTime(2025, 12, 31), 'c'));

      final entries = await store.loadAll();
      expect(
        entries.map((e) => e.date).toList(),
        <DateTime>[
          DateTime(2026, 2, 14),
          DateTime(2026, 2, 10),
          DateTime(2025, 12, 31),
        ],
      );
    });
  });

  group('软删除', () {
    test('删除后读不到，但文件被保留在 .trash 里', () async {
      final date = DateTime(2026, 2, 14);
      await store.save(entry(date, '要删掉的'));

      await store.deleteEntry(date);

      expect(await store.loadByDate(date), isNull);
      expect(await store.loadAll(), isEmpty);

      final trashed = Directory(p.join(root.path, '.trash')).listSync();
      expect(trashed, hasLength(1), reason: '软删除必须留下可恢复的副本');
    });

    test('删除不存在的日期不报错', () async {
      await expectLater(store.deleteEntry(DateTime(1999, 1, 1)), completes);
    });
  });

  group('草稿', () {
    test('写入、读取、清理', () async {
      final date = DateTime(2026, 2, 14);
      expect(await store.readDraft(date), isNull);

      await store.writeDraft(date, '写了一半');
      expect(await store.readDraft(date), '写了一半');
      expect(await store.datesWithDrafts(), <DateTime>[date]);

      await store.clearDraft(date);
      expect(await store.readDraft(date), isNull);
      expect(await store.datesWithDrafts(), isEmpty);
    });

    test('没有草稿时返回空列表', () async {
      expect(await store.datesWithDrafts(), isEmpty);
    });
  });

  group('冲突检测', () {
    test('识别 Syncthing 产生的冲突文件', () async {
      final dir = Directory(p.join(root.path, '2026'))..createSync(recursive: true);
      File(p.join(dir.path, '2026-02-14.sync-conflict-20260214-214002-ABCDEFG.md'))
          .writeAsStringSync('冲突版本');

      final conflicts = await store.findConflicts();
      expect(conflicts, hasLength(1));
      expect(conflicts.single.date, DateTime(2026, 2, 14));
      expect(conflicts.single.fileName,
          '2026-02-14.sync-conflict-20260214-214002-ABCDEFG.md');
    });

    test('冲突文件不会被当成正常日记加载', () async {
      final dir = Directory(p.join(root.path, '2026'))..createSync(recursive: true);
      File(p.join(dir.path, '2026-02-14.sync-conflict-20260214-214002-ABCDEFG.md'))
          .writeAsStringSync('冲突版本');

      expect(await store.loadAll(), isEmpty);
    });

    test('没有冲突时返回空列表', () async {
      await store.save(entry(DateTime(2026, 2, 14), '正常内容'));
      expect(await store.findConflicts(), isEmpty);
    });
  });

  group('历史快照', () {
    final day = DateTime(2026, 2, 14);

    test('留一份快照，能列出来也能读回原样', () async {
      await store.save(entry(day, '第一版内容'));
      final raw = await store.readRawEntry(day);
      expect(raw, isNotNull);

      await store.writeSnapshot(
        day,
        raw!,
        reason: SnapshotReason.opened,
        at: DateTime(2026, 2, 14, 21, 30, 45, 123),
      );

      final snapshots = await store.listSnapshots(day);
      expect(snapshots, hasLength(1));
      expect(snapshots.single.reason, SnapshotReason.opened);
      expect(snapshots.single.savedAt, DateTime(2026, 2, 14, 21, 30, 45, 123));
      expect(await store.readSnapshot(snapshots.single), raw);
    });

    test('快照存在 .history 里，不会被当成日记加载', () async {
      await store.save(entry(day, '内容'));
      await store.writeSnapshot(
        day,
        '快照内容',
        reason: SnapshotReason.auto,
        at: DateTime(2026, 2, 14, 22),
      );

      expect(await store.loadAll(), hasLength(1));
      final snapshotDir = Directory(
        p.join(root.path, '.history', '2026-02-14'),
      );
      expect(await snapshotDir.exists(), isTrue);
      expect((await snapshotDir.list().toList()), hasLength(1));
    });

    test('文件名自带时刻和原因，单独拷出来也能看懂', () async {
      await store.writeSnapshot(
        day,
        '内容',
        reason: SnapshotReason.beforeRestore,
        at: DateTime(2026, 2, 14, 9, 5, 3, 7),
      );

      final files = await Directory(p.join(root.path, '.history', '2026-02-14'))
          .list()
          .toList();
      expect(p.basename(files.single.path), '090503007-before-restore.md');
    });

    test('列表按时间从新到旧', () async {
      for (final hour in <int>[9, 12, 21]) {
        await store.writeSnapshot(
          day,
          '第 $hour 点的内容',
          reason: SnapshotReason.auto,
          at: DateTime(2026, 2, 14, hour),
        );
      }

      final snapshots = await store.listSnapshots(day);
      expect(snapshots.map((s) => s.savedAt.hour).toList(), <int>[21, 12, 9]);
    });

    test('超出上限时自动丢掉一份，保住最早的那份', () async {
      // 上限由 SnapshotPolicy 决定，这里刻意多写一份触发清理
      for (var i = 0; i <= SnapshotPolicy.maxPerDay; i++) {
        await store.writeSnapshot(
          day,
          '第 $i 版',
          reason: SnapshotReason.auto,
          // 每次隔一分钟，保证时刻各不相同
          at: DateTime(2026, 2, 14).add(Duration(minutes: i)),
        );
      }

      final snapshots = await store.listSnapshots(day);
      expect(snapshots, hasLength(SnapshotPolicy.maxPerDay));
      expect(snapshots.last.savedAt, DateTime(2026, 2, 14),
          reason: '最早那一份要保住');

      final kept = await store.readSnapshot(snapshots.last);
      expect(kept, '第 0 版');
    });

    test('删除快照', () async {
      await store.writeSnapshot(
        day,
        '内容',
        reason: SnapshotReason.manual,
        at: DateTime(2026, 2, 14, 10),
      );
      final snapshot = (await store.listSnapshots(day)).single;

      await store.deleteSnapshot(snapshot);
      expect(await store.listSnapshots(day), isEmpty);
    });

    test('没有历史时返回空列表', () async {
      expect(await store.listSnapshots(day), isEmpty);
    });

    test('恢复原始内容：正文和前置字段都按当时的样子写回', () async {
      await store.save(entry(day, '原始正文', mood: '平静'));
      final original = await store.readRawEntry(day);

      await store.save(entry(day, '被改坏的正文'));
      expect((await store.loadByDate(day))!.body, '被改坏的正文');

      await store.restoreRaw(day, original!);
      final restored = await store.loadByDate(day);
      expect(restored!.body, '原始正文');
      expect(restored.mood, '平静');
    });

    test('快照里保留手工加过的注释（存的是原始字节，不是重新编码）', () async {
      final file = dayFile(day)..createSync(recursive: true);
      const handWritten = '---\n'
          'id: 01M3VS6KWNR0CHFRCGC509ZQ7J\n'
          'date: 2026-02-14\n'
          '# 这一行是我自己加的笔记\n'
          '---\n\n'
          '正文\n';
      await file.writeAsString(handWritten);

      final raw = await store.readRawEntry(day);
      expect(raw, handWritten, reason: 'readRawEntry 必须一个字节都不动');
    });
  });

  group('回收站', () {
    final day = DateTime(2026, 2, 14);

    test('删除是软删除：移进 .trash，内容还在，也能列出来', () async {
      await store.save(entry(day, '这篇被误删了'));
      await store.deleteEntry(day);

      expect(await store.loadByDate(day), isNull);
      expect(await store.loadAll(), isEmpty);

      final trash = await store.listTrash();
      expect(trash, hasLength(1));
      expect(trash.single.date, day);
      expect(await store.readTrashedContent(trash.single), contains('这篇被误删了'));
    });

    test('回收站里的文件不会被当成日记加载', () async {
      await store.save(entry(day, '内容'));
      await store.deleteEntry(day);

      expect(await store.loadAll(), isEmpty);
      expect(await store.findConflicts(), isEmpty);
    });

    test('恢复：文件回到原位', () async {
      await store.save(entry(day, '要恢复的内容', mood: '开心'));
      await store.deleteEntry(day);

      final outcome = await store.restoreFromTrash((await store.listTrash()).single);
      expect(outcome.wrote, isTrue);
      expect(outcome.hadConflict, isFalse);

      final restored = await store.loadByDate(day);
      expect(restored!.body, '要恢复的内容');
      expect(restored.mood, '开心');
      expect(await store.listTrash(), isEmpty);
    });

    test('那一天已经有内容时，绝不覆盖：另存为冲突文件', () async {
      await store.save(entry(day, '旧的版本'));
      await store.deleteEntry(day);
      // 删掉之后又写了新的
      await store.save(entry(day, '新的版本'));

      final outcome =
          await store.restoreFromTrash((await store.listTrash()).single);

      expect(outcome.hadConflict, isTrue);
      expect(outcome.conflictPath, isNotNull);
      // 当前文件保持"新的版本"
      expect((await store.loadByDate(day))!.body, '新的版本');
      // 回收站里那份被原样另存
      final conflict = File(outcome.conflictPath!);
      expect(await conflict.exists(), isTrue);
      expect(await conflict.readAsString(), contains('旧的版本'));
      // 而且它能被冲突列表找到，用户才有机会处理
      expect(await store.findConflicts(), hasLength(1));
    });

    test('永久删除才真的抹掉', () async {
      await store.save(entry(day, '内容'));
      await store.deleteEntry(day);
      final item = (await store.listTrash()).single;

      await store.purgeTrashEntry(item);
      expect(await store.listTrash(), isEmpty);
    });

    test('删除不存在的日期不出错', () async {
      await store.deleteEntry(DateTime(1999, 1, 1));
      expect(await store.listTrash(), isEmpty);
    });

    test('同一天删两次不会互相覆盖', () async {
      await store.save(entry(day, '第一次内容'));
      await store.deleteEntry(day);
      await store.save(entry(day, '第二次内容'));
      await store.deleteEntry(day);

      expect(await store.listTrash(), hasLength(2));
    });
  });
}

String _name(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
