import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/day.dart';

void main() {
  group('dateOnly', () {
    test('抹掉时分秒', () {
      expect(
        dateOnly(DateTime(2026, 2, 14, 23, 59, 59)),
        DateTime(2026, 2, 14),
      );
    });
  });

  group('formatIsoDate / parseIsoDate', () {
    test('往返一致', () {
      final date = DateTime(2026, 2, 14);
      expect(formatIsoDate(date), '2026-02-14');
      expect(parseIsoDate('2026-02-14'), date);
    });

    test('月份和日期补零', () {
      expect(formatIsoDate(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('拒绝不存在的日期，而不是静默滚动到下个月', () {
      expect(parseIsoDate('2026-02-30'), isNull);
      expect(parseIsoDate('2026-02-29'), isNull); // 2026 不是闰年
      expect(parseIsoDate('2024-02-29'), DateTime(2024, 2, 29)); // 闰年可以
      expect(parseIsoDate('2026-13-01'), isNull);
      expect(parseIsoDate('2026-00-10'), isNull);
    });

    test('拒绝松散写法', () {
      expect(parseIsoDate('2026-2-4'), isNull);
      expect(parseIsoDate('2026/02/14'), isNull);
      expect(parseIsoDate('20260214'), isNull);
      expect(parseIsoDate(''), isNull);
    });

    test('容忍首尾空白', () {
      expect(parseIsoDate('  2026-02-14  '), DateTime(2026, 2, 14));
    });
  });

  group('时间戳', () {
    test('编码带时区偏移，不是裸的本地时间', () {
      final text = formatIso8601WithOffset(DateTime(2026, 2, 14, 8, 12, 33));
      expect(
        text,
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$')),
        reason: '实际输出：$text',
      );
    });

    test('编码后能解析回同一时刻', () {
      final original = DateTime(2026, 2, 14, 8, 12, 33);
      final parsed = parseTimestamp(formatIso8601WithOffset(original));
      expect(parsed, isNotNull);
      expect(parsed!.isAtSameMomentAs(original), isTrue);
    });

    test('解析 UTC 时间会转换成本地时间', () {
      final parsed = parseTimestamp('2026-02-14T00:12:33Z');
      expect(parsed, isNotNull);
      expect(parsed!.isUtc, isFalse);
      expect(
        parsed.isAtSameMomentAs(DateTime.utc(2026, 2, 14, 0, 12, 33)),
        isTrue,
      );
    });

    test('不带时区的老格式按本地时间解释，仍可读', () {
      final parsed = parseTimestamp('2026-02-14T08:12:33');
      expect(parsed, DateTime(2026, 2, 14, 8, 12, 33));
    });

    test('无法解析时返回 null 而不是抛异常', () {
      expect(parseTimestamp(''), isNull);
      expect(parseTimestamp('昨天'), isNull);
    });
  });
}
