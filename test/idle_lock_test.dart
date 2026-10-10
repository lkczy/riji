import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riji/ui/idle_lock.dart';

void main() {
  group('闲置自动锁定', () {
    testWidgets('到时间回调一次；没到时间不回调', (tester) async {
      var now = DateTime(2026, 10, 8, 12);
      var fired = 0;
      await tester.pumpWidget(MaterialApp(
        home: IdleLock(
          idleLimit: const Duration(minutes: 1),
          now: () => now,
          onIdle: () async => fired++,
          child: const Text('内容'),
        ),
      ));

      // 才过 30 秒
      now = now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 30));
      expect(fired, 0, reason: '没到 1 分钟不该锁');

      // 过了一分钟
      now = now.add(const Duration(seconds: 40));
      await tester.pump(const Duration(seconds: 10));
      expect(fired, 1, reason: '闲置到点必须锁');
    });

    testWidgets('中途动一下鼠标，计时重新开始', (tester) async {
      var now = DateTime(2026, 10, 8, 12);
      var fired = 0;
      await tester.pumpWidget(MaterialApp(
        home: IdleLock(
          idleLimit: const Duration(minutes: 1),
          now: () => now,
          onIdle: () async => fired++,
          child: const SizedBox.expand(),
        ),
      ));

      now = now.add(const Duration(seconds: 50));
      await tester.pump(const Duration(seconds: 50));
      // 动一下
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();

      // 再过 50 秒（从"动过"算起还没到 1 分钟）
      now = now.add(const Duration(seconds: 50));
      await tester.pump(const Duration(seconds: 50));
      expect(fired, 0, reason: '动过之后要重新计时');

      // 再过 20 秒就够 1 分钟了
      now = now.add(const Duration(seconds: 20));
      await tester.pump(const Duration(seconds: 10));
      expect(fired, 1);
    });

    testWidgets('idleLimit 为 null 时永远不锁', (tester) async {
      var now = DateTime(2026, 10, 8, 12);
      var fired = 0;
      await tester.pumpWidget(MaterialApp(
        home: IdleLock(
          idleLimit: null,
          now: () => now,
          onIdle: () async => fired++,
          child: const Text('内容'),
        ),
      ));
      now = now.add(const Duration(hours: 5));
      await tester.pump(const Duration(minutes: 1));
      expect(fired, 0);
    });
  });
}