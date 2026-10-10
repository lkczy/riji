import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/diary_codec.dart';
import 'package:riji/core/models/diary_entry.dart';
import 'package:riji/core/vault_crypto.dart';
import 'package:riji/core/vault_format.dart';

/// 造一条带锁的条目（密文内容是假的，这一层只关心格式，不关心密码学）。
DiaryEntry _entry({
  String body = '',
  DayLock? lock,
  String? mood = '平静',
  String? weather = '晴',
  List<String> tags = const <String>['日常'],
}) =>
    DiaryEntry(
      id: '01M4A3EMFRK1XZN0GD5GFEMSDR',
      date: DateTime(2026, 10, 8),
      created: DateTime(2026, 10, 8, 9),
      updated: DateTime(2026, 10, 8, 21),
      device: 'test-pc',
      body: body,
      mood: mood,
      weather: weather,
      tags: tags,
      lock: lock,
    );

const KdfParams _params = KdfParams(memoryKib: 64 * 1024, iterations: 3, parallelism: 1);

DiaryEntry _roundTrip(DiaryEntry entry) => DiaryCodec.decode(
      DiaryCodec.encode(entry),
      fallbackDate: entry.date,
      fallbackTimestamp: entry.updated,
      fallbackDevice: 'fallback',
    );

void main() {
  group('黑条行', () {
    test('整行全是方块才算', () {
      expect(isRedactionLine(redactionBar), isTrue);
      expect(isRedactionLine('  $redactionBar  '), isTrue, reason: '两边的空白不算数');
      expect(isRedactionLine('████'), isTrue, reason: '手打四个也该认');
      // 一个方块也算（黑条要和原文等长，一个字的段落就是 1 个方块）
      expect(isRedactionLine('█'), isTrue);
      expect(isRedactionLine('$redactionBar 后来说了'), isFalse,
          reason: '黑条旁边写了字，就不再是黑条行（否则会出现"看着像锁着、底下其实没密文"）');
      expect(isRedactionLine('后来说了 $redactionBar'), isFalse);
      expect(isRedactionLine(''), isFalse);
      expect(isRedactionLine('■■■■■■■■'), isFalse, reason: '别的方法块不算');
    });

    test('数行数、取行号', () {
      const body = '今天去了医院。\n$redactionBar\n回来买了菜。\n$redactionBar';
      expect(redactionLineCount(body), 2);
      expect(redactionLineIndexes(body), <int>[1, 3]);
      expect(redactionLineCount('没有黑条'), 0);
    });

    test('黑条和原文**等长**（按码点算，emoji 不会算成两个）', () {
      expect(barForRunLength(1), '█');
      expect(barForRunLength(5), '█████');
      expect(barForRunLength(0), '█', reason: '至少一个，否则识别不出来');
      // 一个字的段落：1 个方块，而且仍然被认成黑条（这正是"最少 1 个"的由来）
      final one = barForLineAt('只有一行', 0, '字'.runes.length);
      expect(one, '█');
      expect(isRedactionLine(one), isTrue);
      // emoji 是 1 个码点、2 个 UTF-16 单元：按码点算才是等长
      expect('🌧️'.length, greaterThan('🌧️'.runes.length));
      expect(barForRunLength('🌧️'.runes.length).runes.length, '🌧️'.runes.length);
    });

    test('锁上一行：那一行变成黑条，其它行一字不动', () {
      const body = '第一行\n第二行\n第三行';
      expect(barForLine(body, 1), '第一行\n$redactionBar\n第三行');
      // 越界不动
      expect(barForLine(body, 9), body);
      expect(barForLine(body, -1), body);
    });

    test('解开一行：黑条换回明文；本来不是黑条的行不动', () {
      const body = '第一行\n$redactionBar\n第三行';
      expect(revealLine(body, 1, '原来是这样'), '第一行\n原来是这样\n第三行');
      expect(revealLine(body, 0, '替换'), body, reason: '不是黑条行就不该被替换');
    });

    test('黑条比密文多 → 明确报错（这是最坏的一种谎：看着锁着、其实搜得到）', () {
      const body = '$redactionBar\n$redactionBar\n普通一行';
      final error = barsMismatchError(body, 1);
      expect(error, isNotNull);
      expect(error, contains('2 行黑条'));
      expect(error, contains('1 段密文'));

      expect(barsMismatchError(body, 2), isNull);
      // 密文多出来是允许的（用户删掉了一行黑条），多余的密文保留不删
      expect(barsMismatchError(body, 5), isNull);
    });
  });

  group('格式往返', () {
    test('整天锁：正文留空，密文和字数进 front matter', () {
      final entry = _entry(
        // 整天锁的正文是占位符（由 lockWholeDay 写进去，这里手工构造同样的形态）
        body: wholeDayPlaceholder,
        lock: DayLock(params: _params, bodyCipher: 'v1:QUJD', characters: 2297),
      );
      final text = DiaryCodec.encode(entry);
      expect(text, contains('enc: v1'));
      expect(text, contains('enc-params: "m=64MiB,t=3,p=1"'));
      expect(text, contains('chars: 2297'), reason: '数字不加引号，人和程序都一眼看出是数字');
      expect(text, contains(wholeDayPlaceholder), reason: '占位符要写进文件（手机端能看懂这天锁着）');
      expect(text, contains('enc-body: "v1:QUJD"'));

      final back = _roundTrip(entry);
      expect(back.lock, isNotNull);
      expect(back.lock!.isWholeDay, isTrue);
      expect(back.lock!.bodyCipher, 'v1:QUJD');
      expect(back.lock!.characters, 2297);
      expect(back.lock!.params, _params);
      // 正文是**占位符**（不是空的）：手机和记事本打开都能看懂这天锁着
      expect(back.body, wholeDayPlaceholder);
      // 元数据是明文，所以不解锁也能按心情天气标签搜
      expect(back.mood, '平静');
      expect(back.weather, '晴');
      expect(back.tags, <String>['日常']);
    });

    test('按段锁：正文是带黑条的骨架，每段密文按顺序对应', () {
      final entry = _entry(
        body: '今天去了医院复查。\n$redactionBar\n回来路上买了点菜。\n$redactionBar',
        lock: DayLock(
          params: _params,
          redactions: const <String, String>{'r1': 'v1:QUJD', 'r2': 'v1:REVG'},
          characters: 412,
        ),
      );
      final text = DiaryCodec.encode(entry);
      expect(text, contains('enc-redactions:'));
      expect(text, contains('  r1: "v1:QUJD"'));
      expect(text, contains('  r2: "v1:REVG"'));
      expect(text, isNot(contains('enc-body')));

      final back = _roundTrip(entry);
      expect(back.lock!.isParagraphs, isTrue);
      expect(back.lock!.redactions, <String, String>{'r1': 'v1:QUJD', 'r2': 'v1:REVG'});
      expect(back.body, '今天去了医院复查。\n$redactionBar\n回来路上买了点菜。\n$redactionBar');
      expect(redactionLineCount(back.body), 2);
    });

    test('每个键只出现一次（knownFrontMatterKeys 漏加的经典症状）', () {
      final entry = _entry(
        body: redactionBar,
        lock: DayLock(
          params: _params,
          redactions: const <String, String>{'r1': 'v1:QUJD'},
          characters: 10,
        ),
      );
      final text = DiaryCodec.encode(_roundTrip(entry));
      for (final key in <String>['enc:', 'enc-params:', 'enc-body:', 'enc-redactions:', 'chars:']) {
        final pattern = '^${RegExp.escape(key)}';
        final count = RegExp(pattern, multiLine: true).allMatches(text).length;
        expect(count, lessThanOrEqualTo(1), reason: '$key 出现了 $count 次');
      }
      // 嵌套的密文键也只该有一份
      expect(RegExp(r'^\s+r1:', multiLine: true).allMatches(text).length, 1);
    });

    test('多余一段密文时保留不删（程序不替用户销毁东西）', () {
      final entry = _entry(
        body: redactionBar,
        lock: DayLock(
          params: _params,
          redactions: const <String, String>{'r1': 'v1:A', 'r2': 'v1:B'},
          characters: 5,
        ),
      );
      final back = _roundTrip(entry);
      expect(back.lock!.redactions.length, 2, reason: 'r2 没有黑条对应，但也不能删');
      expect(barsMismatchError(back.body, back.lock!.redactions.length), isNull);
    });

    test('参数写坏了：锁照样建起来，但 params 为 null（界面好如实说"不认识"）', () {
      const text = '''
---
id: "01M4A3EMFRK1XZN0GD5GFEMSDR"
date: 2026-10-08
created: 2026-10-08T09:00:00+08:00
updated: 2026-10-08T21:00:00+08:00
device: test-pc
tags: []
enc: v1
enc-params: m=4096MiB,t=3,p=1
enc-body: v1:QUJD
---

''';
      final entry = DiaryCodec.decode(
        text,
        fallbackDate: DateTime(2026, 10, 8),
        fallbackTimestamp: DateTime(2026, 10, 8),
        fallbackDevice: 'fallback',
      );
      expect(entry.lock, isNotNull);
      expect(entry.lock!.params, isNull, reason: '内存炸弹参数要被拒绝');
      expect(entry.lock!.bodyCipher, 'v1:QUJD', reason: '密文本身不能丢');
      expect(entry.isLocked, isTrue);
    });

    test('明文的天一个字段都不多（老文件重新保存后仍然一样）', () {
      final entry = _entry(body: '普通的一天');
      final text = DiaryCodec.encode(entry);
      expect(text.contains('enc'), isFalse);
      expect(text.contains('chars:'), isFalse);
      expect(_roundTrip(entry).lock, isNull);
      expect(_roundTrip(entry).body, '普通的一天');
    });
  });

  group('列表里的锁标记', () {
    test('整天锁显示 🔒，部分黑条显示 ⬛ 加段数，两者**能分清**', () {
      final whole = _entry(
        body: wholeDayPlaceholder,
        lock: DayLock(params: _params, bodyCipher: 'v1:QUJD', characters: 100),
      );
      final partial = _entry(
        body: '今天去了医院。\n███████████\n回来买了菜。',
        lock: DayLock(
          params: _params,
          redactions: const <String, String>{'r1': 'v1:QUJD'},
        ),
      );
      final plain = _entry(body: '普通的一天');

      expect(whole.listPreview, '🔒 已加密');
      expect(partial.listPreview, '⬛ 1 段黑条 · 今天去了医院。');
      expect(plain.listPreview, '普通的一天');
      // 两种锁的标记必须不一样：否则会让人以为"整篇都锁了"
      expect(whole.listPreview, isNot(contains('⬛')));
      expect(partial.listPreview, isNot(contains('🔒')));
    });

    test('第一行本身就是黑条时，不把黑条当标题重复一遍', () {
      final entry = _entry(
        body: '███████████\n下面还有明文',
        lock: DayLock(
          params: _params,
          redactions: const <String, String>{'r1': 'v1:QUJD'},
        ),
      );
      expect(entry.listPreview, '⬛ 1 段黑条');
    });
  });

  group('"写过没有"的判定', () {
    test('锁着的天**算有内容**（不然日历和每日提醒会把它当成没写）', () {
      final locked = _entry(
        lock: DayLock(params: _params, bodyCipher: 'v1:QUJD', characters: 100),
        mood: null,
        weather: null,
        tags: const <String>[],
      );
      expect(locked.isEmpty, isFalse);
      expect(locked.isLocked, isTrue);

      // 对照：真空白的一天仍然是空的
      final blank = _entry(mood: null, weather: null, tags: const <String>[]);
      expect(blank.isEmpty, isTrue);
    });

    test('字数：锁着的天用锁里存的，明文的天按正文算', () {
      final locked = _entry(
        lock: DayLock(params: _params, bodyCipher: 'v1:QUJD', characters: 2297),
      );
      expect(locked.characterCount, 2297);

      final plain = _entry(body: '一二三四五');
      expect(plain.characterCount, 5);

      // 没存字数（旧文件）→ 退回正文长度，不崩、也不瞎编
      final noChars = _entry(lock: DayLock(params: _params, bodyCipher: 'v1:QUJD'));
      expect(noChars.characterCount, 0);
    });
  });
}
