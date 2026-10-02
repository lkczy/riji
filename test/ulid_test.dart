import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/ulid.dart';

void main() {
  group('Ulid', () {
    test('长度是 26 且字符合法', () {
      final id = Ulid.generate();
      expect(id.length, 26);
      expect(Ulid.isValid(id), isTrue);
    });

    test('字符表排除了容易看错的 I、L、O、U', () {
      for (final confusing in ['I', 'L', 'O', 'U']) {
        expect(Ulid.alphabet.contains(confusing), isFalse,
            reason: 'Crockford Base32 不应包含 $confusing');
      }
      expect(Ulid.alphabet.length, 32);
    });

    test('一万次生成不重复', () {
      final seen = <String>{};
      for (var i = 0; i < 10000; i++) {
        expect(seen.add(Ulid.generate()), isTrue, reason: '第 $i 次生成发生重复');
      }
    });

    test('时间戳可还原，误差在一秒内', () {
      final at = DateTime.now();
      final id = Ulid.generate(at: at);
      final decoded = Ulid.timestamp(id);
      expect(decoded, isNotNull);
      expect(decoded!.difference(at).abs().inSeconds, lessThan(1));
    });

    test('字典序等于时间序', () {
      final early = Ulid.generate(at: DateTime(2020, 1, 1));
      final late = Ulid.generate(at: DateTime(2030, 1, 1));
      expect(early.compareTo(late), lessThan(0));
    });

    test('校验拒绝非法输入', () {
      expect(Ulid.isValid(''), isFalse);
      expect(Ulid.isValid('01JQX8K2M4P7R9T3V6W8Y0AB2'), isFalse); // 25 位
      expect(Ulid.isValid('01JQX8K2M4P7R9T3V6W8Y0AB2CC'), isFalse); // 27 位
      expect(Ulid.isValid('01JQX8K2M4P7R9T3V6W8Y0AB2I'), isFalse); // 含 I
      expect(Ulid.isValid('01jqx8k2m4p7r9t3v6w8y0ab2c'), isFalse); // 小写
    });
  });
}
