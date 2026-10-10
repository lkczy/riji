import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/day.dart';
import 'package:riji/core/diary_filter.dart';
import 'package:riji/core/history.dart';
import 'package:riji/core/models/diary_entry.dart';
import 'package:riji/core/vault_crypto.dart';
import 'package:riji/core/vault_format.dart';
import 'package:riji/core/writing_prompts.dart';
import 'package:riji/data/diary_store.dart';
import 'package:riji/data/fs_diary_store.dart';
import 'package:riji/state/diary_controller.dart';
import 'package:path/path.dart' as p;

import 'vault_test_helpers.dart';

void main() {
  group('自动保存', () {
    test('输入后会在防抖时间之后自动落盘', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      final today = controller.selectedDate;

      controller.updateBody('自动保存测试');
      expect(controller.saveState, SaveState.dirty);

      await Future<void>.delayed(
        DiaryController.saveDelay + const Duration(milliseconds: 500),
      );

      final saved = await store.loadByDate(today);
      expect(saved, isNotNull);
      expect(saved!.body, '自动保存测试');
      expect(controller.saveState, SaveState.saved);
      controller.dispose();
    });

    test('切换日期前会把还没落盘的内容写下去', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      final today = controller.selectedDate;
      final yesterday = today.subtract(const Duration(days: 1));

      controller.updateBody('切走之前写下的内容');
      // 不等防抖，立刻切日期——这是最容易丢内容的一条路径
      await controller.openDate(yesterday);

      final saved = await store.loadByDate(today);
      expect(saved, isNotNull, reason: '切换日期绝不能丢掉还没落盘的内容');
      expect(saved!.body, '切走之前写下的内容');
      controller.dispose();
    });

    test('翻看空白日期不会生成空日记文件', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      final blank = controller.selectedDate.subtract(const Duration(days: 5));

      await controller.openDate(blank);
      controller.updateBody('   \n  \n');
      await controller.saveNow();

      expect(await store.loadByDate(blank), isNull,
          reason: '光是翻日历不该在硬盘上留下一堆空日记');
      expect(await store.loadAll(), isEmpty);
      controller.dispose();
    });

    test('内容没变时重复保存是幂等的', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      final today = controller.selectedDate;

      controller.updateBody('稳定内容');
      await controller.saveNow();
      final first = await store.loadByDate(today);

      await controller.saveNow();
      final second = await store.loadByDate(today);

      expect(second!.id, first!.id);
      expect(second.body, '稳定内容');
      controller.dispose();
    });
  });

  group('天气与自定义心情', () {
    test('设置天气会写进日记文件', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      final today = controller.selectedDate;

      controller.setWeather('小雨转阴');
      await controller.saveNow();

      expect((await store.loadByDate(today))?.weather, '小雨转阴');
      controller.dispose();
    });

    test('清空天气会把字段去掉，而不是留一个空串', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      final today = controller.selectedDate;

      controller.setWeather('晴');
      await controller.saveNow();
      controller.setWeather(null);
      await controller.saveNow();

      final saved = await store.loadByDate(today);
      expect(saved?.weather, isNull);
      controller.dispose();
    });

    test('只填天气、不写正文，也算写过这一天', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      final today = controller.selectedDate;

      controller.setWeather('晴');
      await controller.saveNow();

      expect(await store.loadByDate(today), isNotNull,
          reason: '天气是用户主动记下的信息，不该被当成"什么都没写"');
      controller.dispose();
    });

    test('自定义心情（不在预设里的值）能存下来', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      final today = controller.selectedDate;

      controller.setMood('有点恍惚');
      await controller.saveNow();

      expect((await store.loadByDate(today))?.mood, '有点恍惚');
      controller.dispose();
    });

    test('心情和天气互不干扰', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      final today = controller.selectedDate;

      controller.setMood('平静');
      controller.setWeather('晴');
      await controller.saveNow();
      controller.setMood(null);
      await controller.saveNow();

      final saved = await store.loadByDate(today);
      expect(saved?.mood, isNull);
      expect(saved?.weather, '晴', reason: '改心情不能把天气一起清掉');
      controller.dispose();
    });

    test('切到别的日期会读到那一天的天气', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();

      final first = DateTime(2026, 2, 14);
      await controller.openDate(first);
      controller.setWeather('晴');
      await controller.saveNow();

      final second = DateTime(2026, 2, 15);
      await controller.openDate(second);
      expect(controller.weather, isNull);

      controller.setWeather('雪');
      await controller.saveNow();

      await controller.openDate(first);
      expect(controller.weather, '晴', reason: '切回来要看到原来记的天气');
      controller.dispose();
    });
  });

  group('筛选与标签统计', () {
    Future<DiaryController> seeded() async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 2, 10),
          device: 'test',
          body: '一',
          mood: '平静',
          weather: '晴',
          tags: <String>['工作']));
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 2, 11),
          device: 'test',
          body: '二',
          mood: '疲惫',
          weather: '雨',
          tags: <String>['工作', '加班']));
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 2, 12),
          device: 'test',
          body: '三',
          mood: '平静',
          weather: '晴',
          tags: <String>['生活']));

      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 10));
      return controller;
    }

    test('标签按使用次数排序，常用的排前面', () async {
      final controller = await seeded();
      expect(controller.allTags, <String>['工作', '加班', '生活']);
      controller.dispose();
    });

    test('心情和天气也能列出可选值，同样按次数排序', () async {
      final controller = await seeded();
      expect(controller.allMoods.first, '平静', reason: '平静出现两次，应排最前');
      expect(controller.allMoods, containsAll(<String>['平静', '疲惫']));
      expect(controller.allWeathers, containsAll(<String>['晴', '雨']));
      expect(controller.allWeathers.first, '晴');
      controller.dispose();
    });

    test('按标签筛选', () async {
      final controller = await seeded();
      controller.setFilter(const DiaryFilter(tag: '工作'));

      expect(
        controller.visibleEntries.map((e) => e.date).toList(),
        <DateTime>[DateTime(2026, 2, 11), DateTime(2026, 2, 10)],
      );
      controller.dispose();
    });

    test('按心情筛选', () async {
      final controller = await seeded();
      controller.setFilter(const DiaryFilter(mood: '平静'));

      expect(
        controller.visibleEntries.map((e) => e.date).toList(),
        <DateTime>[DateTime(2026, 2, 12), DateTime(2026, 2, 10)],
      );
      controller.dispose();
    });

    test('按天气筛选', () async {
      final controller = await seeded();
      controller.setFilter(const DiaryFilter(weather: '雨'));

      expect(
        controller.visibleEntries.map((e) => e.date).toList(),
        <DateTime>[DateTime(2026, 2, 11)],
      );
      controller.dispose();
    });

    test('筛选和搜索叠加生效', () async {
      final controller = await seeded();
      controller.setFilter(const DiaryFilter(tag: '工作'));
      controller.setQuery('二');

      // 「工作」有两篇，其中正文含「二」的只有一篇
      expect(controller.visibleEntries, hasLength(1));
      expect(controller.visibleEntries.single.date, DateTime(2026, 2, 11));

      // 只保留筛选时又回到两篇
      controller.setQuery('');
      expect(controller.visibleEntries, hasLength(2));
      controller.dispose();
    });

    test('清除筛选', () async {
      final controller = await seeded();
      controller.setFilter(const DiaryFilter(tag: '工作', mood: '疲惫'));
      expect(controller.visibleEntries, hasLength(1));

      controller.clearFilter();

      expect(controller.filter.isActive, isFalse);
      expect(controller.visibleEntries, hasLength(3));
      controller.dispose();
    });

    test('筛选不会影响总篇数统计', () async {
      final controller = await seeded();
      controller.setFilter(const DiaryFilter(tag: '工作'));

      expect(controller.totalEntries, 3, reason: '总篇数描述的是全部日记，不是筛选结果');
      controller.dispose();
    });
  });

  group('每日一问', () {
    Future<DiaryController> fresh() async {
      final controller = DiaryController(
        store: MemoryDiaryStore(),
        deviceName: 'test',
      );
      await controller.load(preferredDate: DateTime(2026, 2, 14));
      return controller;
    }

    test('同一天稳定：切走再回来还是同一条', () async {
      final controller = await fresh();
      final first = controller.dailyPrompt.text;

      await controller.openDate(DateTime(2026, 2, 15));
      await controller.openDate(DateTime(2026, 2, 14));

      expect(controller.dailyPrompt.text, first);
      controller.dispose();
    });

    test('换一个会给出不同的引子，并记下已经换过', () async {
      final controller = await fresh();
      final original = controller.dailyPrompt.text;
      expect(controller.promptWasRerolled, isFalse);

      controller.nextPrompt();

      expect(controller.dailyPrompt.text, isNot(original));
      expect(controller.promptWasRerolled, isTrue);
      controller.dispose();
    });

    test('换了日期就回到默认那条，不把「换一个」带过去', () async {
      final controller = await fresh();
      controller.nextPrompt();
      controller.nextPrompt();
      expect(controller.promptWasRerolled, isTrue);

      await controller.openDate(DateTime(2026, 2, 20));

      expect(controller.promptWasRerolled, isFalse);
      expect(
        controller.dailyPrompt.text,
        promptForDate(DateTime(2026, 2, 20)).text,
      );
      controller.dispose();
    });

    test('换满一圈回到起点', () async {
      final controller = await fresh();
      final original = controller.dailyPrompt.text;

      for (var i = 0; i < kWritingPrompts.length; i++) {
        controller.nextPrompt();
      }

      expect(controller.dailyPrompt.text, original);
      controller.dispose();
    });

    test('空白判断覆盖全部字段', () async {
      final controller = await fresh();
      expect(controller.isCurrentEntryEmpty, isTrue);

      controller.setWeather('晴');
      expect(controller.isCurrentEntryEmpty, isFalse);

      controller.setWeather(null);
      controller.setMood('平静');
      expect(controller.isCurrentEntryEmpty, isFalse);

      controller.setMood(null);
      controller.setTags(<String>['工作']);
      expect(controller.isCurrentEntryEmpty, isFalse);

      controller.setTags(<String>[]);
      controller.updateBody('   ');
      expect(controller.isCurrentEntryEmpty, isTrue, reason: '纯空白不算写了');

      controller.updateBody('写了一句');
      expect(controller.isCurrentEntryEmpty, isFalse);
      controller.dispose();
    });
  });

  group('时光机', () {
    test('只挑正文非空的条目，且避开当前这一天', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 2, 10), device: 'test', body: '有内容'));
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 2, 11), device: 'test', body: '   ')); // 空白
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 2, 12), device: 'test', body: '也有内容'));

      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 10));

      final picked = controller.pickRandomEntry();

      expect(picked, isNotNull);
      expect(picked!.date, DateTime(2026, 2, 12),
          reason: '当前这一天和空白的那一天都不该被翻到');
      controller.dispose();
    });

    test('没有可翻的条目时返回 null，而不是抛异常', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 2, 10), device: 'test', body: '唯一一篇'));

      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 10));

      expect(controller.pickRandomEntry(), isNull);
      controller.dispose();
    });

    test('反复翻不会连续翻到同一条', () async {
      final store = MemoryDiaryStore();
      for (var day = 1; day <= 5; day++) {
        store.seed(DiaryEntry.create(
            date: DateTime(2026, 2, day + 10),
            device: 'test',
            body: '第 $day 篇'));
      }

      final controller = DiaryController(store: store, deviceName: 'test');
      // 当前日期不在候选里
      await controller.load(preferredDate: DateTime(2026, 2, 20));

      DateTime? previous;
      for (var i = 0; i < 30; i++) {
        final picked = controller.pickRandomEntry();
        expect(picked, isNotNull);
        if (previous != null) {
          expect(
            isSameDay(picked!.date, previous),
            isFalse,
            reason: '第 $i 次翻到了和上一次同一条，观感像"点了一下没反应"',
          );
        }
        previous = picked!.date;
      }
      controller.dispose();
    });

    test('候选覆盖多个日期（确实在随机，而不是总挑第一条）', () async {
      final store = MemoryDiaryStore();
      for (var day = 1; day <= 6; day++) {
        store.seed(DiaryEntry.create(
            date: DateTime(2026, 2, day + 10),
            device: 'test',
            body: '第 $day 篇'));
      }

      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 20));

      final seen = <DateTime>{};
      for (var i = 0; i < 60; i++) {
        final picked = controller.pickRandomEntry();
        if (picked != null) seen.add(picked.date);
      }

      expect(seen.length, greaterThan(1));
      controller.dispose();
    });
  });

  group('草稿保护', () {
    test('连续打字时草稿仍会按时落盘（节流，不是防抖）', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      final today = controller.selectedDate;

      // 每 200ms 敲一次，一直敲 3 秒。
      // 防抖保存（900ms）会因为不断被重置而**永不触发**——
      // 这正是"连写十分钟等于十分钟没有保护"的场景。
      // 草稿节流必须在这种输入节奏下仍然写盘。
      for (var i = 0; i < 15; i++) {
        controller.updateBody('第 $i 次输入');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      final draft = await store.readDraft(today);
      expect(draft, isNotNull, reason: '连续输入期间必须有草稿兜底');
      expect(draft, contains('第'));
      controller.dispose();
    });

    test('保存成功后草稿被清理', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      final today = controller.selectedDate;

      controller.updateBody('会被保存的内容');
      await controller.saveNow();

      expect(await store.readDraft(today), isNull);
      controller.dispose();
    });
  });

  group('草稿恢复', () {
    late Directory parent;
    late FsDiaryStore store;

    setUp(() {
      parent = Directory.systemTemp.createTempSync('mydiary_ctrl_');
      store = FsDiaryStore(
        rootPath: p.join(parent.path, 'diary'),
        deviceName: 'test',
      );
    });

    tearDown(() {
      try {
        if (parent.existsSync()) parent.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('草稿与已保存内容一致时不提示恢复', () async {
      final date = DateTime(2026, 2, 14);
      await store.save(
        DiaryEntry.create(date: date, device: 'test', body: '已保存的内容'),
      );
      await store.writeDraft(date, '已保存的内容');

      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: date);

      expect(controller.recoverableDrafts, isEmpty,
          reason: '内容一样就不该弹窗骚扰，否则用户会学会无脑点掉');
      controller.dispose();
    });

    test('草稿比正式文件新时提示恢复，并真的能恢复', () async {
      final date = DateTime(2026, 2, 14);
      await store.save(
        DiaryEntry.create(date: date, device: 'test', body: '旧的内容'),
      );
      await store.writeDraft(date, '新写但没保存的内容');

      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: date);

      expect(controller.recoverableDrafts, <DateTime>[date]);

      await controller.recoverDraft(date);

      final restored = await store.loadByDate(date);
      expect(restored!.body, '新写但没保存的内容');
      expect(controller.recoverableDrafts, isEmpty);
      controller.dispose();
    });

    test('丢弃草稿不会动正式文件', () async {
      final date = DateTime(2026, 2, 14);
      await store.save(
        DiaryEntry.create(date: date, device: 'test', body: '正式内容'),
      );
      await store.writeDraft(date, '草稿内容');

      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: date);
      await controller.discardDraft(date);

      expect(await store.readDraft(date), isNull);
      expect((await store.loadByDate(date))!.body, '正式内容');
      controller.dispose();
    });
  });

  group('搜索', () {
    test('能命中正文、标签、心情和日期', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');

      final reading = DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '今天读了一本书',
        mood: '平静',
        tags: <String>['阅读'],
      );
      final work = DiaryEntry.create(
        date: DateTime(2026, 3, 1),
        device: 'test',
        body: '加班到很晚',
        mood: '疲惫',
        tags: <String>['工作'],
      );
      store.seed(reading);
      store.seed(work);

      await controller.load(preferredDate: DateTime(2026, 2, 14));

      controller.setQuery('读');
      expect(controller.visibleEntries.map((e) => e.date),
          <DateTime>[DateTime(2026, 2, 14)]);

      controller.setQuery('工作');
      expect(controller.visibleEntries.map((e) => e.date),
          <DateTime>[DateTime(2026, 3, 1)]);

      controller.setQuery('疲惫');
      expect(controller.visibleEntries.map((e) => e.date),
          <DateTime>[DateTime(2026, 3, 1)]);

      controller.setQuery('2026-02');
      expect(controller.visibleEntries.map((e) => e.date),
          <DateTime>[DateTime(2026, 2, 14)]);

      controller.setQuery('   ');
      expect(controller.visibleEntries, hasLength(2));

      controller.dispose();
    });

    test('天气也能被搜到', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');

      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '出门了',
        weather: '小雨转阴',
      ));
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 15),
        device: 'test',
        body: '在家',
        weather: '晴',
      ));

      await controller.load(preferredDate: DateTime(2026, 2, 14));

      controller.setQuery('小雨');
      expect(controller.visibleEntries.map((e) => e.date),
          <DateTime>[DateTime(2026, 2, 14)]);

      controller.setQuery('晴');
      expect(controller.visibleEntries.map((e) => e.date),
          <DateTime>[DateTime(2026, 2, 15)]);

      controller.dispose();
    });
  });

  group('往年的今天', () {
    test('找得到同月同日但年份不同的条目', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');

      store.seed(DiaryEntry.create(
          date: DateTime(2025, 2, 14), device: 'test', body: '去年的今天'));
      store.seed(DiaryEntry.create(
          date: DateTime(2024, 2, 14), device: 'test', body: '前年的今天'));
      store.seed(DiaryEntry.create(
          date: DateTime(2026, 2, 14), device: 'test', body: '今天'));
      store.seed(DiaryEntry.create(
          date: DateTime(2025, 3, 3), device: 'test', body: '别的日子'));

      await controller.load(preferredDate: DateTime(2026, 2, 14));

      expect(controller.onThisDay, hasLength(2));
      expect(
        controller.onThisDay.map((e) => e.date.year).toList(),
        <int>[2025, 2024],
        reason: '应按年份倒序，最近的排最前',
      );
      controller.dispose();
    });
  });

  group('导出', () {
    test('生成包含全部条目的 Markdown 文件', () async {
      final parent = Directory.systemTemp.createTempSync('mydiary_export_');
      final exportDir = Directory(p.join(parent.path, 'riji-导出'));
      addTearDown(() {
        try {
          if (parent.existsSync()) parent.deleteSync(recursive: true);
        } catch (_) {}
      });

      final store = FsDiaryStore(
        rootPath: p.join(parent.path, 'diary'),
        deviceName: 'test',
      );
      await store.save(DiaryEntry.create(
          date: DateTime(2026, 2, 14),
          device: 'test',
          body: '第一篇',
          tags: <String>['阅读']));
      await store.save(DiaryEntry.create(
          date: DateTime(2026, 2, 15), device: 'test', body: '第二篇'));

      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));

      final path = await controller.exportAsMarkdown();
      final file = File(path);

      expect(file.existsSync(), isTrue);
      expect(file.parent.path, exportDir.path);

      final content = file.readAsStringSync();
      expect(content, contains('第一篇'));
      expect(content, contains('第二篇'));
      expect(content, contains('2026-02-14'));
      expect(content, contains('2026-02-15'));
      // 时间正序：导出稿读起来应该像一本书
      expect(content.indexOf('第一篇'), lessThan(content.indexOf('第二篇')));

      controller.dispose();
    });
  });

  group('历史版本', () {
    test('打开一天时留一份「打开时的样子」', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '原本的内容',
      ));

      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));

      expect(controller.snapshots, hasLength(1));
      expect(controller.snapshots.single.reason, SnapshotReason.opened);

      final content = await controller.snapshotContent(controller.snapshots.single);
      expect(content, contains('原本的内容'));

      controller.dispose();
    });

    test('空白的一天不会留下快照', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));

      expect(controller.snapshots, isEmpty);
      controller.dispose();
    });

    test('反复打开同一天不会堆出重复快照', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '内容',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));

      // 来回去别的日子再回来
      await controller.openDate(DateTime(2026, 2, 13));
      await controller.openDate(DateTime(2026, 2, 14));
      await controller.openDate(DateTime(2026, 2, 13));
      await controller.openDate(DateTime(2026, 2, 14));

      expect(controller.snapshots, hasLength(1),
          reason: '内容没变就不该重复留');
      controller.dispose();
    });

    test('内容变了之后再次打开会新增一份', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '第一版',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));
      expect(controller.snapshots, hasLength(1));

      controller.updateBody('第二版');
      await controller.saveNow();

      await controller.openDate(DateTime(2026, 2, 13));
      await controller.openDate(DateTime(2026, 2, 14));

      expect(controller.snapshots.length, greaterThanOrEqualTo(2));
      controller.dispose();
    });

    test('自动快照受 10 分钟间隔限制，但手动留版本不受限', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '第一版',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));
      final openedCount = controller.snapshots.length;

      // 连续改几次并保存：间隔没到，不该留下自动快照
      for (final text in <String>['第二版', '第三版', '第四版']) {
        controller.updateBody(text);
        await controller.saveNow();
      }
      expect(controller.snapshots.length, openedCount,
          reason: '10 分钟没到，自动快照不该触发');

      // 手动留一份则立刻生效
      final saved = await controller.saveVersionNow();
      expect(saved, isTrue);
      expect(controller.snapshots.length, openedCount + 1);

      controller.dispose();
    });

    test('和最新一版完全相同时，手动留版本也不会重复', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '内容',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));

      final saved = await controller.saveVersionNow();
      expect(saved, isFalse);
      controller.dispose();
    });

    test('恢复历史版本：正文回到当时的样子', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '原始内容',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));
      final originalSnapshot = controller.snapshots.single;

      controller.updateBody('被改坏的内容');
      await controller.saveNow();
      expect(controller.body, '被改坏的内容');

      await controller.restoreSnapshot(originalSnapshot);

      expect(controller.body, '原始内容');
      expect((await store.loadByDate(DateTime(2026, 2, 14)))!.body, '原始内容');
      controller.dispose();
    });

    test('恢复之前会先把当前内容留一份——「恢复」本身不能成为丢内容', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '原始内容',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));
      final originalSnapshot = controller.snapshots.single;

      controller.updateBody('改坏之前的重要内容');
      await controller.saveNow();
      await controller.restoreSnapshot(originalSnapshot);

      // 现在应该能找回"改坏之前"那一份
      final contents = <String>[];
      for (final snapshot in controller.snapshots) {
        contents.add(await controller.snapshotContent(snapshot));
      }
      expect(contents.any((c) => c.contains('改坏之前的重要内容')), isTrue,
          reason: '恢复前的当前内容必须被留成快照');
      controller.dispose();
    });

    test('恢复之后界面用的正文版本号会变，输入框才会跟着刷新', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '原始内容',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));
      final snapshot = controller.snapshots.single;
      final before = controller.bodyRevision;

      controller.updateBody('改了');
      await controller.saveNow();
      await controller.restoreSnapshot(snapshot);

      expect(controller.bodyRevision, greaterThan(before));
      controller.dispose();
    });
  });

  group('删除与回收站', () {
    test('删除当前这一天：内容清空、列表里也没了', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '要被删掉的内容',
        mood: '平静',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));

      await controller.deleteCurrentEntry();

      expect(controller.body, isEmpty);
      expect(controller.mood, isNull);
      expect(controller.hasEntry, isFalse);
      expect(controller.entries, isEmpty);
      expect(await store.loadByDate(DateTime(2026, 2, 14)), isNull);
      controller.dispose();
    });

    test('删除后能在回收站里找到并恢复', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '误删的内容',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));

      await controller.deleteCurrentEntry();
      expect(await store.loadByDate(DateTime(2026, 2, 14)), isNull);

      final trash = await controller.listTrash();
      expect(trash, hasLength(1));
      expect(await controller.readTrashedContent(trash.single),
          contains('误删的内容'));

      await controller.restoreFromTrash(trash.single);

      expect((await store.loadByDate(DateTime(2026, 2, 14)))!.body, '误删的内容');
      expect(controller.entries, hasLength(1));
      controller.dispose();
    });

    test('那天已经有新内容时，恢复不会覆盖它，而是产出冲突文件', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '旧版本',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));

      await controller.deleteCurrentEntry();
      // 删完又写了新的
      controller.updateBody('新版本');
      await controller.saveNow();

      final trash = await controller.listTrash();
      final outcome = await controller.restoreFromTrash(trash.single);

      expect(outcome.hadConflict, isTrue);
      expect(controller.lastConflictPath, isNotNull,
          reason: '界面必须能告诉用户对方那份去哪了');
      expect((await store.loadByDate(DateTime(2026, 2, 14)))!.body, '新版本');
      controller.dispose();
    });

    test('永久删除之后回收站就空了', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '内容',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));

      await controller.deleteCurrentEntry();
      final trash = await controller.listTrash();
      await controller.purgeTrashEntry(trash.single);

      expect(await controller.listTrash(), isEmpty);
      controller.dispose();
    });

    test('删除留下的草稿也会被清掉，否则下次启动会提示恢复一篇已删的日记', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));

      controller.updateBody('刚打的字');
      await controller.deleteCurrentEntry();

      expect(await store.readDraft(DateTime(2026, 2, 14)), isNull);
      controller.dispose();
    });

    test('删除保留历史快照——那是这一天另一层独立的保护', () async {
      final store = MemoryDiaryStore();
      store.seed(DiaryEntry.create(
        date: DateTime(2026, 2, 14),
        device: 'test',
        body: '内容',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load(preferredDate: DateTime(2026, 2, 14));
      expect(controller.snapshots, isNotEmpty);

      await controller.deleteCurrentEntry();

      expect(controller.snapshots, isNotEmpty);
      controller.dispose();
    });
  });

  group('另一台设备同步过来的改动', () {
    test('没有未保存的内容时自动重新载入，并留下提示', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'PC');
      await controller.load();
      final today = controller.selectedDate;

      // 手机上写的那一份同步过来了：磁盘变了，程序记着的那份还是旧的
      store.simulateExternalWrite(today, '手机上写的内容\n');
      await controller.checkExternalChange();

      expect(controller.body, '手机上写的内容\n', reason: '应该换成磁盘上的那一份');
      expect(controller.externalReloadNotice, isNotNull);
      expect(controller.saveState, SaveState.idle);
      controller.dispose();
    });

    test('有未保存的内容时绝不重新载入', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'PC');
      await controller.load();
      final today = controller.selectedDate;

      controller.updateBody('我正在写的东西');
      expect(controller.saveState, SaveState.dirty);

      store.simulateExternalWrite(today, '手机上写的内容\n');
      await controller.checkExternalChange();

      expect(controller.body, '我正在写的东西', reason: '用户正在写的东西必须原样保留');
      expect(controller.externalReloadNotice, isNull);
      expect(
        controller.saveState,
        SaveState.dirty,
        reason: '状态不能被动过——保存那条路还要靠它去生成冲突文件',
      );
      controller.dispose();
    });

    test('程序自己刚写下的内容不会被当成外部改动', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'PC');
      await controller.load();

      controller.updateBody('刚写下的');
      await controller.saveNow();
      expect(controller.saveState, SaveState.saved);

      // 连查两次都不该触发重载，否则会陷入「重载—检查—再重载」
      await controller.checkExternalChange();
      await controller.checkExternalChange();

      expect(controller.externalReloadNotice, isNull, reason: '自己写的不算外部改动');
      expect(controller.body, '刚写下的');
      controller.dispose();
    });

    test('磁盘上的文件不见了（被另一台设备删掉）时编辑器跟着清空', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'PC');
      await controller.load();
      final today = controller.selectedDate;

      controller.updateBody('待会儿会被删掉');
      await controller.saveNow();

      store.simulateExternalWrite(today, null);
      await controller.checkExternalChange();

      expect(controller.body, '');
      expect(controller.externalReloadNotice, contains('不见了'));
      controller.dispose();
    });

    test('换天会清掉上一天留下的提示', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'PC');
      await controller.load();
      final today = controller.selectedDate;

      store.simulateExternalWrite(today, '手机写的\n');
      await controller.checkExternalChange();
      expect(controller.externalReloadNotice, isNotNull);

      await controller.openDate(today.subtract(const Duration(days: 1)));
      expect(controller.externalReloadNotice, isNull);
      controller.dispose();
    });

    test('提示关掉之后，内容没再变就不再出现', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'PC');
      await controller.load();
      final today = controller.selectedDate;

      store.simulateExternalWrite(today, '手机写的\n');
      await controller.checkExternalChange();
      expect(controller.externalReloadNotice, isNotNull);

      controller.dismissExternalReloadNotice();
      expect(controller.externalReloadNotice, isNull);

      await controller.checkExternalChange();
      expect(controller.externalReloadNotice, isNull, reason: '内容没变就不该再报一次');
      controller.dispose();
    });

    test('真实文件：同步工具保留了原修改时间，也能发现改动', () async {
      // 这条说明**为什么必须比内容而不是比时间戳**：同步工具会保留文件
      // 原本的修改时间，只看 mtime 会把已经改过的文件当成没变。
      final root = Directory.systemTemp.createTempSync('reload_');
      final store = FsDiaryStore(rootPath: root.path, deviceName: 'PC');
      final controller = DiaryController(store: store, deviceName: 'PC');
      await controller.load();
      final today = controller.selectedDate;

      controller.updateBody('电脑上写的');
      await controller.saveNow();

      final file = File(p.join(
        root.path,
        '${today.year}',
        '${formatIsoDate(today)}.md',
      ));
      expect(file.existsSync(), isTrue, reason: '保存之后文件应该存在');
      final before = file.lastModifiedSync();

      file.writeAsStringSync(
        '---\nid: 01M3VS66PS685Y86Q5AGNTEQAZ\n'
        'date: ${formatIsoDate(today)}\n'
        'device: PHONE\n'
        '---\n\n手机上写的\n',
      );
      // 关键一步：把修改时间改回去，模拟「同步工具保留了原本的时间」
      file.setLastModifiedSync(before);

      await controller.checkExternalChange();

      expect(controller.body, contains('手机上写的'), reason: '内容变了就该被发现');
      expect(controller.externalReloadNotice, isNotNull);
      controller.dispose();
      root.deleteSync(recursive: true);
    });
  });
  // ---------------------------------------------------------------------------
  // 加密护栏
  // ---------------------------------------------------------------------------

  group('程序锁：锁定要清掉内存里的内容', () {
    test('lockApp 之后：条目没了、正文空了、密钥也没了', () async {
      final store = MemoryDiaryStore();
      await store.save(DiaryEntry.create(
        date: DateTime(2026, 10, 8),
        device: 'test',
        body: '记得买牛奶',
      ));
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      // load() 之后没有打开任何一天（这一点以前踩过坑），所以先明确打开
      await controller.openDate(DateTime(2026, 10, 8));

      expect(controller.entries, isNotEmpty, reason: '先确认本来是有内容的');
      expect(controller.body, contains('牛奶'));

      await controller.lockApp();

      // 这一条是**反向可验证**的核心：把清空那几行删掉，这个测试必须变红。
      // 只丢密钥是不够的——明文的日子本来就以明文读进了内存，
      // 不清掉的话"锁上"只是屏幕上看不见而已。
      expect(controller.entries, isEmpty, reason: '内存里的日记必须一起消失');
      expect(controller.body, isEmpty);
      expect(controller.currentDayIsLocked, isFalse, reason: '不再停在任何一天上');
      expect(controller.isCurrentEntryEmpty, isTrue);
    });

    test('没配置保险库时 lockApp 也不炸（预览模式没有加密）', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      await controller.lockApp();
      expect(controller.entries, isEmpty);
    });
  });

  group('加密：保存护栏', () {
    /// 一条"按段锁着"的条目：正文有一行黑条，密文里对应一段。
    /// 这里只关心**数量**，密文本身是假的。
    DiaryEntry lockedEntry({int redactions = 1}) => DiaryEntry(
          id: '01M4A3EMFRK1XZN0GD5GFEMSDR',
          date: DateTime(2026, 10, 8),
          created: DateTime(2026, 10, 8, 9),
          updated: DateTime(2026, 10, 8, 9),
          device: 'test',
          body: '第一行\n████████',
          lock: DayLock(
            params: const KdfParams(memoryKib: 8 * 1024, iterations: 1, parallelism: 1),
            redactions: <String, String>{
              for (var i = 0; i < redactions; i++) 'r${i + 1}': 'v1:QUJD',
            },
          ),
        );

    test('黑条比密文多时**拒绝保存**，并说明原因', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await controller.load();
      // 直接把一条"对不上"的条目塞进控制器（真实路径是手打方块、或恢复
      // 了黑条数不匹配的草稿）
      final entry = lockedEntry();
      await store.save(entry);
      await controller.load(preferredDate: DateTime(2026, 10, 8));

      // 正文里手动多加一行黑条（模拟用户手打）
      controller.updateBody('第一行\n████████\n████████');
      await controller.saveNow();

      expect(controller.saveState, SaveState.failed);
      expect(controller.saveError, isNotNull);
      expect(controller.saveError, contains('黑条'));
      // 磁盘上仍然是原来那一份，没有被写坏
      final onDisk = await store.loadByDate(DateTime(2026, 10, 8));
      expect(onDisk!.body, '第一行\n████████');
      controller.dispose();
    });

    test('黑条和密文对得上时正常保存', () async {
      final store = MemoryDiaryStore();
      final controller = DiaryController(store: store, deviceName: 'test');
      await store.save(lockedEntry());
      await controller.load(preferredDate: DateTime(2026, 10, 8));

      controller.updateBody('改过的第一行\n████████');
      await controller.saveNow();

      expect(controller.saveState, SaveState.saved);
      expect((await store.loadByDate(DateTime(2026, 10, 8)))!.body, '改过的第一行\n████████');
      controller.dispose();
    });
  });
  // ---------------------------------------------------------------------------
  // 加密：四个缺口的护栏（2026-10-08 补）
  // ---------------------------------------------------------------------------

  group('加密：关闭加密与解锁联动', () {
    final root = r'D:\someone\MyData';
    final day = DateTime(2026, 10, 8);
    final second = DateTime(2026, 10, 9);
    const passphrase = '口令口令';

    test('关闭加密：全部解开之后才删保险库文件', () async {
      final files = FakeVaultFiles();
      final vault = makeVault(files, root: root);
      await vault.load();
      await vault.setUp(passphrase);

      final store = MemoryDiaryStore();
      await store.save(await vault.lockWholeDay(entryFor(day, '整天锁起来的秘密')));
      await store.save(await vault.lockLine(entryFor(second, '第一行\n按段锁的秘密'), 1));

      final controller = DiaryController(
        store: store,
        deviceName: 'test',
        vault: vault,
      );
      await controller.load();
      expect(controller.lockedEntriesCount, 2);

      final message = await controller.disableVaultSafely();
      expect(message, contains('明文'));

      // 磁盘上一天都不能剩锁
      final onDisk = await store.loadAll();
      expect(onDisk.every((e) => !e.isLocked), isTrue);
      expect(onDisk.firstWhere((e) => sameDate(e.date, day)).body, '整天锁起来的秘密');
      expect(
        onDisk.firstWhere((e) => sameDate(e.date, second)).body,
        '第一行\n按段锁的秘密',
      );
      // 保险库文件被删掉了，而且只删了一次
      expect(files.deletes, 1);
      expect(files.content, isNull);
      expect(vault.isConfigured, isFalse);
      controller.dispose();
    });

    test('关闭加密：有一天解不开就**拒绝关闭**，保险库文件必须还在', () async {
      final files = FakeVaultFiles();
      final vault = makeVault(files, root: root);
      await vault.load();
      await vault.setUp(passphrase);

      final store = MemoryDiaryStore();
      await store.save(await vault.lockWholeDay(entryFor(day, '能解开的')));
      // 这一天的密文是坏的（模拟文件被改过、或者根本不是这把密钥锁的）
      final broken = (await vault.lockWholeDay(entryFor(second, '解不开的')))
          .copyWith(
        lock: (await vault.lockWholeDay(entryFor(second, 'x'))).lock!.copyWith(
              bodyCipher: 'v1:QUJDREVG',
            ),
      );
      await store.save(broken);

      final controller = DiaryController(
        store: store,
        deviceName: 'test',
        vault: vault,
      );
      await controller.load();

      await expectLater(
        controller.disableVaultSafely(),
        throwsA(isA<VaultAuthException>()),
      );
      // 关键：保险库文件绝不能被删——删了那天的内容就永久没了
      expect(files.content, isNotNull);
      expect(files.deletes, 0);
      expect(vault.isConfigured, isTrue);
      // 磁盘上那天的密文也原样还在
      expect((await store.loadByDate(second))!.isLocked, isTrue);
      controller.dispose();
    });

    test('从保险库那条路解锁之后，搜索自动包含锁着的正文', () async {
      final files = FakeVaultFiles();
      final vault = makeVault(files, root: root);
      await vault.load();
      await vault.setUp(passphrase);

      final store = MemoryDiaryStore();
      await store.save(await vault.lockWholeDay(entryFor(day, '只有我知道的秘密')));

      final controller = DiaryController(
        store: store,
        deviceName: 'test',
        vault: vault,
      );
      await controller.load();

      // 还锁着：这一天不参与搜索
      expect(controller.lockedNotSearchedCount, 1);
      controller.setQuery('只有我知道');
      expect(controller.visibleEntries, isEmpty);

      // 从**保险库**这条路解锁（不是侧栏那个按钮）——控制器应当自己跟上
      await vault.unlock(passphrase, isRecoveryCode: false);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(controller.lockedNotSearchedCount, 0,
          reason: '解锁之后不该还挂着"没有参与搜索"');
      controller.setQuery('只有我知道');
      expect(controller.visibleEntries.length, 1,
          reason: '解锁之后搜索必须能命中锁着的正文');
      controller.dispose();
    });

    test('关闭加密：保存悄悄失败时，磁盘上仍有锁着的内容 → 照样拒绝', () async {
      final files = FakeVaultFiles();
      final vault = makeVault(files, root: root);
      await vault.load();
      await vault.setUp(passphrase);

      // 这个存储**假装保存成功**、其实什么都没写。真实世界里对应的是
      // "save 报成功但字段被写丢了"（本项目真出过这类 bug：编码时漏了
      // 新字段，于是保存后再读回来就少东西）。
      final store = _SilentlyFailingStore();
      await store.save(await vault.lockWholeDay(entryFor(day, '锁着的')));
      final written = await store.loadByDate(day);
      expect(written!.isLocked, isTrue, reason: '先确认这份存储确实有内容');

      final controller = DiaryController(
        store: store,
        deviceName: 'test',
        vault: vault,
      );
      await controller.load();

      await expectLater(
        controller.disableVaultSafely(),
        throwsA(isA<VaultAuthException>()),
      );
      expect(files.content, isNotNull, reason: '磁盘上还有锁着的内容时，保险库文件不能删');
      expect(files.deletes, 0);
      expect(vault.isConfigured, isTrue);
      controller.dispose();
    });

    test('按次解锁是"用完即丢"：搜索框一清空，密钥和明文都没了', () async {
      final files = FakeVaultFiles();
      final vault = makeVault(files, root: root);
      await vault.load();
      await vault.setUp(passphrase);
      final store = MemoryDiaryStore();
      await store.save(await vault.lockWholeDay(entryFor(day, '只有我知道的秘密')));
      vault.lock();

      final controller = DiaryController(
        store: store,
        deviceName: 'test',
        vault: vault,
      );
      await controller.load();

      await vault.unlock(passphrase, isRecoveryCode: false, forSearchOnly: true);
      await controller.prepareVaultForSearch();
      expect(vault.isSearchRevealed, isTrue);
      expect(controller.lockedNotSearchedCount, 0);

      // 真的搜一下，然后清空 = 这次搜索结束
      controller.setQuery('秘密');
      controller.setQuery('');
      expect(vault.isSearchRevealed, isFalse, reason: '按次解锁的密钥必须真的丢掉');
      expect(vault.isUnlocked, isFalse);
      expect(controller.lockedNotSearchedCount, 1, reason: '提示也该回来');
      controller.dispose();
    });

    test('解锁状态下保存，字数会跟着更新（不再停在锁上那一刻）', () async {
      final files = FakeVaultFiles();
      final vault = makeVault(files, root: root);
      await vault.load();
      await vault.setUp(passphrase);
      final store = MemoryDiaryStore();
      await store.save(await vault.lockLine(entryFor(day, '第一行\n秘密一段'), 1));

      final controller = DiaryController(
        store: store,
        deviceName: 'test',
        vault: vault,
      );
      await controller.load(preferredDate: day);
      await controller.openDate(day);
      // 锁上那一刻记下的字数
      expect(controller.currentCharacterCount, '第一行\n秘密一段'.runes.length);

      // 在解锁状态下往这一天的正文里补一句
      controller.updateBody('第一行改长了一点点\n████████');
      await controller.saveNow();

      final onDisk = await store.loadByDate(day);
      expect(onDisk!.lock!.characters, '第一行改长了一点点\n秘密一段'.runes.length,
          reason: '解锁状态下保存要重算完整字数');
      controller.dispose();
    });

    test('整天锁的那天可以只读查看，磁盘上仍然是密文', () async {
      final files = FakeVaultFiles();
      final vault = makeVault(files, root: root);
      await vault.load();
      await vault.setUp(passphrase);

      final store = MemoryDiaryStore();
      await store.save(await vault.lockWholeDay(entryFor(day, '只想看一眼的内容')));
      // 建完库本来就是解锁状态；这里先锁上，模拟"程序刚启动、还没输口令"
      vault.lock();

      final controller = DiaryController(
        store: store,
        deviceName: 'test',
        vault: vault,
      );
      await controller.load();
      await controller.openDate(day);

      expect(controller.canReadLocked, isFalse, reason: '没解锁时不许读');
      await vault.unlock(passphrase, isRecoveryCode: false);
      final text = await controller.revealCurrentDayText();
      expect(text, '只想看一眼的内容');
      // 只读就是只读：磁盘上不能变成明文
      expect((await store.loadByDate(day))!.isLocked, isTrue);
      controller.dispose();
    });
  });
}
/// 只在**第一次**写入时真的落盘，之后就假装成功——用来验证
/// "保存悄悄失败"时那条最后防线。
class _SilentlyFailingStore extends MemoryDiaryStore {
  bool _wroteOnce = false;

  @override
  Future<DiarySaveOutcome> save(DiaryEntry entry) async {
    if (_wroteOnce) return const DiarySaveOutcome(wrote: false);
    _wroteOnce = true;
    return super.save(entry);
  }
}