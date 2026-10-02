import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/history.dart';

void main() {
  const auto = SnapshotReason.auto;

  group('什么时候留快照', () {
    final now = DateTime(2026, 10, 4, 12, 0);

    test('内容没变就不留——快照的价值在于记录「另一个样子」', () {
      for (final reason in SnapshotReason.values) {
        expect(
          SnapshotPolicy.shouldSnapshot(
            reason: reason,
            now: now,
            contentDiffers: false,
            newestAt: null,
          ),
          isFalse,
          reason: '$reason 在内容相同时也该跳过',
        );
      }
    });

    test('「打开时的样子」不受时间间隔限制', () {
      expect(
        SnapshotPolicy.shouldSnapshot(
          reason: SnapshotReason.opened,
          now: now,
          contentDiffers: true,
          newestAt: now,
        ),
        isTrue,
      );
    });

    test('自动快照至少间隔 10 分钟', () {
      expect(
        SnapshotPolicy.shouldSnapshot(
          reason: auto,
          now: now,
          contentDiffers: true,
          newestAt: now.subtract(const Duration(minutes: 9, seconds: 59)),
        ),
        isFalse,
      );
      expect(
        SnapshotPolicy.shouldSnapshot(
          reason: auto,
          now: now,
          contentDiffers: true,
          newestAt: now.subtract(const Duration(minutes: 10)),
        ),
        isTrue,
      );
    });

    test('完全没有历史时，第一次自动快照立刻留', () {
      expect(
        SnapshotPolicy.shouldSnapshot(
          reason: auto,
          now: now,
          contentDiffers: true,
          newestAt: null,
        ),
        isTrue,
      );
    });

    test('恢复前那一份必须无条件留下', () {
      // 哪怕一秒前刚留过也必须再留：否则"恢复"会覆盖掉用户此刻的内容，
      // 而那一份恰恰是他最可能想反悔的。
      expect(
        SnapshotPolicy.shouldSnapshot(
          reason: SnapshotReason.beforeRestore,
          now: now,
          contentDiffers: true,
          newestAt: now,
        ),
        isTrue,
      );
    });

    test('手动留版本不受时间限制', () {
      expect(
        SnapshotPolicy.shouldSnapshot(
          reason: SnapshotReason.manual,
          now: now,
          contentDiffers: true,
          newestAt: now,
        ),
        isTrue,
      );
    });
  });

  group('数量上限', () {
    test('没超上限就不删', () {
      expect(SnapshotPolicy.pruneIndex(0), isNull);
      expect(SnapshotPolicy.pruneIndex(1), isNull);
      expect(SnapshotPolicy.pruneIndex(SnapshotPolicy.maxPerDay), isNull);
    });

    test('超上限时从第二份开始丢，保住第一份', () {
      // 索引 0 通常是「打开时的样子」，是整条历史里最有用的一份
      expect(
        SnapshotPolicy.pruneIndex(SnapshotPolicy.maxPerDay + 1),
        1,
      );
    });

    test('上限不能太小，否则一小时能写满', () {
      // 自动快照 10 分钟一份，写 5 小时就是 30 份。上限至少要比这大。
      expect(SnapshotPolicy.maxPerDay, greaterThanOrEqualTo(30));
    });
  });

  group('原因标签', () {
    test('每个原因都有中文名和 ASCII 标识', () {
      for (final reason in SnapshotReason.values) {
        expect(reason.label, isNotEmpty);
        expect(reason.tag, matches(RegExp(r'^[a-z\-]+$')),
            reason: '${reason.name} 的标识要能安全地进文件名');
      }
    });

    test('标识能还原成原因', () {
      for (final reason in SnapshotReason.values) {
        expect(SnapshotReason.fromTag(reason.tag), reason);
      }
      expect(SnapshotReason.fromTag('不认识'), isNull);
    });

    test('四个原因的标识互不相同', () {
      final tags = SnapshotReason.values.map((r) => r.tag).toSet();
      expect(tags.length, SnapshotReason.values.length);
    });
  });
}
