import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/release_notes.dart';

/// 从 CHANGELOG.md 里抽出「弹给用户看的那两句」。
///
/// 两段测试：**真实的 CHANGELOG.md**（守约定有没有被遵守）和**合成文本**
/// （守解析规则本身）。分开是有意的——合成文本不受真实文件写法变化影响，
/// 真实文件那几条又能在有人写错格式时立刻变红。
void main() {
  group('真实的 CHANGELOG.md', () {
    final log = ChangeLog.parse(File('CHANGELOG.md').readAsStringSync());
    final notes = log.forVersion('1.1.0');

    test('1.1.0 有给用户看的内容，日期取得出来', () {
      expect(notes, isNotNull);
      expect(notes!.version, '1.1.0');
      expect(notes.date, '2026-10-03');
      expect(notes.features, isNotEmpty);
    });

    test('1.1.0 没有修 bug，所以「修复」是空的（而不是有内容）', () {
      expect(notes!.fixes, isEmpty);
    });

    test('弹窗里不会出现 Markdown 标记', () {
      for (final item in notes!.features) {
        expect(item, isNot(contains('**')), reason: '加粗标记会露给用户：$item');
        expect(item, isNot(contains('`')), reason: '反引号会露给用户：$item');
        expect(item, isNot(contains('](')), reason: '链接语法会露给用户：$item');
      }
    });

    test('折行的条目被拼回一句完整的话', () {
      // 这是最容易坏的一条：CHANGELOG 里的长条目会折行，
      // 解析时漏掉续行的话，弹窗里会出现半句话。
      for (final item in notes!.features) {
        expect(item.trim(), item, reason: '首尾不该有空白');
        expect(item, isNot(contains('\n')));
        expect(item, isNot(contains('  ')), reason: '多余的空白说明拼接方式不对');
      }
    });

    test('只有「新功能」和「修复」两节会进弹窗', () {
      // 「内部」和「已知限制」里的内容一句都不该出现
      for (final item in notes!.features) {
        expect(item.contains('diary_actions'), isFalse);
        expect(item.contains('反向验证'), isFalse);
        expect(item.contains('纯逻辑'), isFalse);
      }
    });

    test('1.0.0 那节写在这些约定之前，所以取不到内容', () {
      // 返回 null（＝没有要给用户看的）而不是"空内容"：
      // 界面据此整个跳过，不会弹一个空框。
      expect(log.forVersion('1.0.0'), isNull);
    });

    test('查不到的版本返回 null', () {
      expect(log.forVersion('9.9.9'), isNull);
      expect(log.forVersion(''), isNull);
    });
  });

  group('解析规则', () {
    const sample = '''
# 更新记录

一些说明文字，不该被当成条目。

## 1.2.0 — 2026-11-01

### 新功能

- 第一件事，这一条
  折了一行，但还是一句话
- 第二件事，带一个**加粗**和一个`反引号`
- 带个链接 [说明文字](https://example.com/x) 收尾

### 修复

- 修好了某个 bug

### 内部

- 这条不该进弹窗

## 未发布

- 这节标题不是版本号，整节跳过

## 1.1.0+4

### 新功能

- 没有日期的一节

## 1.0.0 — 2026-10-02

### 写作

- 这节不是给用户看的
''';

    final log = ChangeLog.parse(sample);

    test('新功能与修复分开解析', () {
      final notes = log.forVersion('1.2.0')!;
      expect(notes.date, '2026-11-01');
      expect(notes.features, hasLength(3));
      expect(notes.fixes, <String>['修好了某个 bug']);
    });

    test('折行的条目拼成一条，不留下半句话', () {
      expect(
        log.forVersion('1.2.0')!.features.first,
        '第一件事，这一条 折了一行，但还是一句话',
      );
    });

    test('行内标记被去掉', () {
      final features = log.forVersion('1.2.0')!.features;
      expect(features[1], '第二件事，带一个加粗和一个反引号');
      expect(features[2], '带个链接 说明文字 收尾');
    });

    test('「内部」那节的内容一句都不进弹窗', () {
      for (final item in log.forVersion('1.2.0')!.features) {
        expect(item, isNot(contains('不该进弹窗')));
      }
    });

    test('标题不是版本号的小节整节跳过', () {
      // 「## 未发布」下面那条不该被算到任何版本头上
      expect(log.forVersion('未发布'), isNull);
      for (final item in log.forVersion('1.2.0')!.features) {
        expect(item, isNot(contains('整节跳过')));
      }
    });

    test('标题没写日期时 date 是 null，条目照常解析', () {
      final notes = log.forVersion('1.1.0')!;
      expect(notes.date, isNull);
      expect(notes.features, <String>['没有日期的一节']);
    });

    test('带构建号去查，能回退到不带构建号的标题', () {
      // pubspec 可能写成 1.1.0+4，而 CHANGELOG 标题一般只写 1.1.0
      expect(log.forVersion('1.1.0+4')?.features, <String>['没有日期的一节']);
      expect(log.forVersion('1.1.0')?.features, <String>['没有日期的一节']);
    });

    test('两节都空 → 取不到内容（而不是空内容）', () {
      expect(log.forVersion('1.0.0'), isNull);
    });

    test('空文本不会崩', () {
      final empty = ChangeLog.parse('');
      expect(empty.forVersion('1.1.0'), isNull);
    });
  });

  group('plainTextOf', () {
    test('去掉加粗、反引号，链接只留文字', () {
      expect(plainTextOf('**粗**和`码`'), '粗和码');
      expect(plainTextOf('[文字](http://x)'), '文字');
    });

    test('把换行和多余空白压成一格', () {
      expect(plainTextOf('  a\n   b  '), 'a b');
    });

    test('不碰单个星号和下划线', () {
      // 正文里出现一个 * 或下划线的可能性，远大于真的有人写斜体；
      // 宁可留着也不误删用户的字。
      expect(plainTextOf('2 * 3 = 6'), '2 * 3 = 6');
      expect(plainTextOf('file_name'), 'file_name');
    });
  });
}
