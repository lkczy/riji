import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/diary_codec.dart';
import 'package:riji/core/models/diary_entry.dart';

void main() {
  final fallbackDate = DateTime(2026, 2, 14);
  final fallbackTimestamp = DateTime(2026, 2, 14, 9, 0, 0);
  const device = 'test-device';

  DiaryEntry decode(String content) => DiaryCodec.decode(
        content,
        fallbackDate: fallbackDate,
        fallbackTimestamp: fallbackTimestamp,
        fallbackDevice: device,
      );

  DiaryEntry makeEntry({
    String? id,
    String body = '正文',
    String? mood,
    String? weather,
    List<String> tags = const <String>[],
  }) {
    return DiaryEntry(
      id: id ?? '01JQX8K2M4P7R9T3V6W8Y0AB2C',
      date: DateTime(2026, 2, 14),
      created: DateTime(2026, 2, 14, 8, 12, 33),
      updated: DateTime(2026, 2, 14, 21, 40, 2),
      device: 'desktop-abc123',
      body: body,
      mood: mood,
      weather: weather,
      tags: tags,
    );
  }

  group('编码', () {
    test('以 front matter 开头，正文在最后且原样结尾', () {
      final text = DiaryCodec.encode(makeEntry(body: '今天写日记了。'));

      expect(text.startsWith('---\n'), isTrue);
      expect(text, contains('id: 01JQX8K2M4P7R9T3V6W8Y0AB2C'));
      expect(text, contains('date: 2026-02-14'));
      expect(text, endsWith('今天写日记了。'));
    });

    test('用 \\n 换行，绝不产生 CRLF', () {
      // CRLF 会让 git diff 变脏、让 Syncthing 在双端产生假冲突
      final text = DiaryCodec.encode(makeEntry(body: '第一行\n第二行'));
      expect(text.contains('\r'), isFalse);
    });

    test('纯数字的 id 必须加引号，否则 YAML 会把它读成整数', () {
      const numericId = '0123456789012345678901234';
      final text = DiaryCodec.encode(makeEntry(id: numericId));
      expect(text, contains('id: "$numericId"'));
      expect(decode(text).id, numericId);
    });

    test('没有标签时写 tags: []，而不是留空', () {
      final text = DiaryCodec.encode(makeEntry());
      expect(text, contains('tags: []'));
    });

    test('标签逐个列出', () {
      final text = DiaryCodec.encode(makeEntry(tags: ['工作', '阅读']));
      expect(text, contains('tags:\n  - 工作\n  - 阅读'));
    });

    test('mood 为空或纯空白时不写该字段', () {
      expect(DiaryCodec.encode(makeEntry()), isNot(contains('mood:')));
      expect(DiaryCodec.encode(makeEntry(mood: '   ')), isNot(contains('mood:')));
    });

    test('含特殊字符的心情会被安全引用，且能解析回来', () {
      const tricky = '还行: 但#有点累';
      final text = DiaryCodec.encode(makeEntry(mood: tricky));
      expect(decode(text).mood, tricky);
    });
  });

  group('往返一致性：正文必须逐字节保留', () {
    const bodies = <String>[
      '',
      'foo',
      'foo\n',
      '\nfoo',
      '多行\n第二行\n\n第四行',
      '结尾有很多空行\n\n\n',
      '含 --- 分隔符\n---\n结束',
      '含 front matter 假象\n---\nid: 假的\n---\n',
      '  前导空格和\t制表符  ',
      r'反斜杠 \ 和引号 " 和单引号 ',
      'emoji 🙂 和中文混排',
    ];

    for (final body in bodies) {
      final label = body.replaceAll('\n', r'\n');
      test('正文 "$label" 原样保留', () {
        final entry = makeEntry(body: body);
        final back = decode(DiaryCodec.encode(entry));
        expect(back.body, body);
        expect(back.id, entry.id);
        expect(back.date, entry.date);
      });
    }

    test('心情与标签往返', () {
      final entry = makeEntry(mood: '平静', tags: ['工作', '阅读']);
      final back = decode(DiaryCodec.encode(entry));
      expect(back.mood, '平静');
      expect(back.tags, <String>['工作', '阅读']);
    });
  });

  group('weather 字段', () {
    test('往返一致', () {
      final entry = makeEntry(weather: '小雨转阴');
      expect(decode(DiaryCodec.encode(entry)).weather, '小雨转阴');
    });

    test('心情和天气可以同时存在，互不干扰', () {
      final entry = makeEntry(mood: '平静', weather: '晴');
      final back = decode(DiaryCodec.encode(entry));
      expect(back.mood, '平静');
      expect(back.weather, '晴');
    });

    test('没有天气时不写这个键', () {
      expect(DiaryCodec.encode(makeEntry()), isNot(contains('weather:')));
    });

    test('纯空白的天气不写', () {
      expect(
        DiaryCodec.encode(makeEntry(weather: '   ')),
        isNot(contains('weather:')),
      );
    });

    test('首尾空白会被去掉', () {
      final back = decode(DiaryCodec.encode(makeEntry(weather: '  晴  ')));
      expect(back.weather, '晴');
    });

    test('自由文本里含 YAML 特殊字符也能安全往返', () {
      // 天气是自由输入，用户完全可能打出这些字符
      for (final tricky in <String>[
        '多云: 转#晴',
        '26℃ / 体感 30℃',
        '[局部] 有雨',
        'true',
        '12345',
        '雨，风很大',
      ]) {
        final back = decode(DiaryCodec.encode(makeEntry(weather: tricky)));
        expect(back.weather, tricky, reason: '天气「$tricky」没有原样回来');
      }
    });

    test('手写文件里的天气会被读进来', () {
      final entry = decode('---\nid: X\ndate: 2026-02-14\nweather: 闷热\n---\n\n正文');
      expect(entry.weather, '闷热');
    });
  });

  group('解码宽容性：绝不能因为格式问题让用户看不见自己写的东西', () {
    test('完全没有 front matter 的纯文本文件也能读', () {
      final entry = decode('就是一段手写文字，没有任何元数据。');
      expect(entry.body, '就是一段手写文字，没有任何元数据。');
      expect(entry.date, fallbackDate);
      expect(entry.device, device);
      expect(entry.hasLegacyId, isTrue);
    });

    test('front matter 写坏了也不丢正文', () {
      final entry = decode('---\nid: [括号没闭合\ndate: {{{{\n---\n\n正文还在。');
      expect(entry.body, '正文还在。');
      expect(entry.date, fallbackDate);
    });

    test('只有起始分隔符没有结束分隔符时，整体当正文处理', () {
      const content = '---\nid: 没有结束分隔符\n正文';
      final entry = decode(content);
      expect(entry.body, content);
    });

    test('缺少字段时逐项回退到兜底值', () {
      final entry = decode('---\nid: 01JQX8K2M4P7R9T3V6W8Y0AB2C\n---\n\n正文');
      expect(entry.id, '01JQX8K2M4P7R9T3V6W8Y0AB2C');
      expect(entry.date, fallbackDate);
      expect(entry.created, fallbackTimestamp);
      expect(entry.device, device);
    });

    test('front matter 里的 date 优先于文件名日期', () {
      final entry = decode(
        '---\ndate: 2025-01-01\n---\n\n补写的往日日记',
      );
      expect(entry.date, DateTime(2025, 1, 1));
    });

    test('旧文件不带时区的时间戳仍可读', () {
      final entry = decode(
        '---\ncreated: 2026-02-14T08:12:33\nupdated: 2026-02-14T08:12:33\n---\n\nx',
      );
      expect(entry.created, DateTime(2026, 2, 14, 8, 12, 33));
    });

    test('容忍 CRLF 换行的文件', () {
      final entry = decode('---\r\nid: 01JQX8K2M4P7R9T3V6W8Y0AB2C\r\n---\r\n\r\n正文\r\n');
      expect(entry.body, '正文\r\n');
      expect(entry.id, '01JQX8K2M4P7R9T3V6W8Y0AB2C');
    });

    test('tags 写成逗号分隔也能读', () {
      final entry = decode('---\ntags: 工作, 阅读\n---\n\nx');
      expect(entry.tags, <String>['工作', '阅读']);
    });

    test('占位 id 是确定性的，重复读取不会变', () {
      final first = decode('没有元数据');
      final second = decode('没有元数据');
      expect(first.id, second.id);
      expect(first.id, DiaryEntry.legacyIdFor(fallbackDate));
    });

    test('空文件返回空条目而不是抛异常', () {
      final entry = decode('');
      expect(entry.body, '');
      expect(entry.date, fallbackDate);
      expect(entry.isEmpty, isTrue);
    });
  });

  group('DiaryEntry.preview', () {
    test('取正文首个非空行并去掉标题符号', () {
      expect(makeEntry(body: '\n\n## 今天的标题\n正文').preview, '今天的标题');
    });

    test('空正文返回空串', () {
      expect(makeEntry(body: '\n\n  \n').preview, '');
    });
  });

  // 这一组守的是一个很容易被忽略、后果又很严重的不变量：
  // 程序必须能安全地「不认识」某些字段。
  // 只要有一台设备跑着旧版本，它就可能把新版本写入的字段悄悄抹掉——
  // 而这种丢失是无声的，用户永远不知道自己的数据少了一块。
  group('前向兼容：绝不丢弃自己不认识的字段', () {
    test('未知字段在重新保存后必须原样还在', () {
      const content = '---\n'
          'id: 01JQX8K2M4P7R9T3V6W8Y0AB2C\n'
          'date: 2026-02-14\n'
          'moonphase: 上弦月\n'
          'location: 杭州\n'
          '---\n'
          '\n'
          '正文';

      final reencoded = DiaryCodec.encode(decode(content));

      expect(reencoded, contains('moonphase: 上弦月'));
      expect(reencoded, contains('location: 杭州'));
      expect(decode(reencoded).body, '正文');
    });

    test('未知字段里的注释和格式也要保留', () {
      const content = '---\n'
          'id: 01JQX8K2M4P7R9T3V6W8Y0AB2C\n'
          '# 这是我手写的备注\n'
          'moonphase: 上弦月\n'
          '---\n'
          '\n'
          '正文';

      final reencoded = DiaryCodec.encode(decode(content));
      expect(reencoded, contains('# 这是我手写的备注'));
      expect(reencoded, contains('moonphase: 上弦月'));
    });

    test('已知字段不会被重复写出（新增字段漏登记会在这里暴露）', () {
      const content = '---\n'
          'id: 01JQX8K2M4P7R9T3V6W8Y0AB2C\n'
          'date: 2026-02-14\n'
          'weather: 晴\n'
          'moonphase: 上弦月\n'
          '---\n'
          '\n'
          '正文';

      final entry = decode(content);

      // weather 已经登记成已知字段，必须被模型接管，不能同时留在 extra 里
      expect(entry.weather, '晴');
      expect(entry.extraFrontMatter, isNot(contains('weather')));
      // moonphase 没登记，必须原样保留
      expect(entry.extraFrontMatter, contains('moonphase'));

      final reencoded = DiaryCodec.encode(entry);
      expect(RegExp(r'^id:', multiLine: true).allMatches(reencoded).length, 1);
      expect(RegExp(r'^date:', multiLine: true).allMatches(reencoded).length, 1);
      expect(
          RegExp(r'^weather:', multiLine: true).allMatches(reencoded).length, 1,
          reason: '漏把 weather 加进 knownFrontMatterKeys 就会写出两个 weather');
      expect(
          RegExp(r'^moonphase:', multiLine: true).allMatches(reencoded).length, 1);
    });

    test('反复保存必须稳定，不能每次多长出一块', () {
      const content = '---\n'
          'id: 01JQX8K2M4P7R9T3V6W8Y0AB2C\n'
          'moonphase: 上弦月\n'
          '---\n'
          '\n'
          '正文';

      final once = DiaryCodec.encode(decode(content));
      final twice = DiaryCodec.encode(decode(once));
      final thrice = DiaryCodec.encode(decode(twice));

      expect(twice, once);
      expect(thrice, once);
    });

    test('解析不了的前言块也不能凭空消失', () {
      const content = '---\n'
          'weird: [括号没闭合\n'
          '---\n'
          '\n'
          '正文';

      final reencoded = DiaryCodec.encode(decode(content));

      // 原文必须以某种形式留下来，同时文件要重新变得可解析
      expect(reencoded, contains('weird: [括号没闭合'));
      expect(decode(reencoded).body, '正文');
      // 元数据要能正常读出来了，而不是永久坏掉
      expect(decode(reencoded).hasLegacyId, isTrue,
          reason: '修好之后应该走文件名兜底，而不是继续读不出任何字段');
    });

    test('坏掉的前言被修复后，再保存也不会再退化', () {
      const content = '---\nweird: [没闭合\n---\n\n正文';
      final repaired = DiaryCodec.encode(decode(content));
      expect(DiaryCodec.encode(decode(repaired)), repaired);
    });
  });
}
