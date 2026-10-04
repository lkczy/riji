import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/app_version.dart';

/// 版本号解析与「该不该弹本版更新」。
///
/// 这一层值得单独测：它错起来是**静默**的——弹窗该弹不弹，或者每次都弹，
/// 两种都不会有任何报错。
void main() {
  AppVersion v(String raw) {
    final parsed = AppVersion.tryParse(raw);
    expect(parsed, isNotNull, reason: '测试自己写错了：$raw 应该是能解析的');
    return parsed!;
  }

  group('解析', () {
    test('认得「主.次.修订」', () {
      expect(AppVersion.tryParse('1.1.0'), const AppVersion(1, 1, 0));
      expect(AppVersion.tryParse(' 1.1.0 '), const AppVersion(1, 1, 0));
    });

    test('带 +构建号 也认', () {
      expect(AppVersion.tryParse('1.1.0+3'), const AppVersion(1, 1, 0, 3));
    });

    test('认不出来的形式一律返回 null，而不是猜一个', () {
      // 这些都会被 shouldAnnounceVersion 判成"不弹"。
      // 宁可少弹一次，也不要拿猜出来的版本去比。
      for (final raw in <String>[
        'v1.1.0',
        '1.1',
        '1',
        '',
        '1.1.0-beta',
        'released',
        '1.1.0.4',
      ]) {
        expect(AppVersion.tryParse(raw), isNull, reason: '「$raw」不该被当成版本号');
      }
    });
  });

  group('比较', () {
    test('逐段比较，不是字符串比较', () {
      // 字符串比较会得出 1.10.0 < 1.9.0，正好相反
      expect(v('1.10.0').compareTo(v('1.9.0')), greaterThan(0));
    });

    test('三段都比完才轮到构建号', () {
      expect(v('1.1.1').compareTo(v('1.2.0')), lessThan(0));
      expect(v('1.1.0+2').compareTo(v('1.1.0+1')), greaterThan(0));
      expect(v('1.1.0+1').compareTo(v('1.1.0')), greaterThan(0));
    });

    test('相同版本相等', () {
      expect(v('1.1.0'), const AppVersion(1, 1, 0));
      expect(v('1.1.0+2'), v('1.1.0+2'));
    });
  });

  group('该不该弹本版更新', () {
    test('第一次装（没有上一版可比）不弹', () {
      expect(shouldAnnounceVersion(current: '1.1.0', lastSeen: null), isFalse);
    });

    test('同一个版本不弹', () {
      expect(
        shouldAnnounceVersion(current: '1.1.0', lastSeen: '1.1.0'),
        isFalse,
      );
    });

    test('升上来了就弹', () {
      expect(
        shouldAnnounceVersion(current: '1.1.0', lastSeen: '1.0.0'),
        isTrue,
      );
      expect(
        shouldAnnounceVersion(current: '1.10.0', lastSeen: '1.9.0'),
        isTrue,
      );
    });

    test('回退到旧版不弹', () {
      // 用户装回旧版时，给他看一份"未来的更新记录"没有意义
      expect(
        shouldAnnounceVersion(current: '1.0.0', lastSeen: '1.1.0'),
        isFalse,
      );
    });

    test('任一边读不懂就不弹', () {
      expect(
        shouldAnnounceVersion(current: 'dev', lastSeen: '1.0.0'),
        isFalse,
      );
      expect(
        shouldAnnounceVersion(current: '1.1.0', lastSeen: '看过的版本'),
        isFalse,
      );
      expect(shouldAnnounceVersion(current: '', lastSeen: ''), isFalse);
    });
  });

  group('从 pubspec 文本里取版本', () {
    test('真实的 pubspec.yaml 能取出可用的版本号', () {
      // 这条同时守着一个更重要的性质：**程序显示的版本号必须来自 pubspec**。
      // 如果哪天把 version 写成解析不了的形式，这个功能会整个静默消失，
      // 所以在这里挡住。
      final text = File('pubspec.yaml').readAsStringSync();
      final version = versionFromPubspecText(text);

      expect(version, isNotNull, reason: 'pubspec.yaml 里必须有 version 字段');
      expect(
        AppVersion.tryParse(version!),
        isNotNull,
        reason: 'version 必须是「主.次.修订」形式，否则「本版更新」永远不出现',
      );
    });

    test('注释里出现 version: 不算数', () {
      const text = '''
# version: 9.9.9 这是注释
name: riji
version: 1.2.3
''';
      expect(versionFromPubspecText(text), '1.2.3');
    });

    test('解析不了就返回 null，不抛异常', () {
      expect(versionFromPubspecText('这不是 YAML: ['), isNull);
      expect(versionFromPubspecText('name: riji'), isNull);
      expect(versionFromPubspecText('version:'), isNull);
      expect(versionFromPubspecText('version: 123'), isNull);
    });
  });
}
