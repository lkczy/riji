import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/base32.dart';
import 'package:riji/core/vault_crypto.dart';

/// 测试里用**小参数**跑 Argon2id：默认参数（64 MiB）单次要几百毫秒到几秒，
/// 每个用例都跑会让整个测试套件慢得没法用。默认参数只在最后一个用例里
/// 实测一次。
const KdfParams _fast = KdfParams(memoryKib: 8 * 1024, iterations: 1, parallelism: 1);


Future<SecretKey> _rawKey() async => VaultCrypto.newMasterKey();

void main() {
  group('Crockford base32', () {
    test('往返：各种长度都对得上（覆盖末尾不足 5 位的补零）', () {
      for (final length in <int>[0, 1, 2, 3, 4, 5, 8, 16, 31, 32, 33]) {
        final bytes = List<int>.generate(length, (i) => (i * 37 + 11) & 0xff);
        final encoded = base32Encode(bytes);
        expect(base32Decode(encoded), bytes, reason: '$length 字节');
      }
    });

    test('字母表里去掉了 I / L / O / U', () {
      final encoded = base32Encode(List<int>.generate(64, (i) => i));
      for (final bad in <String>['I', 'L', 'O', 'U']) {
        expect(encoded.contains(bad), isFalse, reason: '不该出现 $bad');
      }
    });

    test('手抄容错：I/L 读作 1，O 读作 0，大小写和连字符都忽略', () {
      final bytes = List<int>.generate(20, (i) => (i * 5 + 3) & 0xff);
      final encoded = base32Encode(bytes);
      // 把 1 换成 I/L、0 换成 O、全部小写、插上连字符和空格
      final messy = encoded
          .replaceAll('1', 'I')
          .replaceAll('0', 'O')
          .toLowerCase()
          .split('')
          .join('-');
      expect(base32Decode(messy), bytes);
    });

    test('认不出来的字符要明确报错，并指出位置（不能悄悄跳过）', () {
      expect(
        () => base32Decode('ABCD#FGH'),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('第 5 个字符'),
        )),
      );
      // U 不在字母表里
      expect(() => base32Decode('ABU'), throwsA(isA<FormatException>()));
    });

    test('分组只为好看，解回来一样', () {
      final bytes = List<int>.generate(32, (i) => i & 0xff);
      final grouped = groupBase32(base32Encode(bytes));
      expect(grouped.contains('-'), isTrue);
      expect(base32Decode(grouped), bytes);
    });
  });

  group('KdfParams', () {
    test('编码/解析往返', () {
      const params = KdfParams(memoryKib: 64 * 1024, iterations: 3, parallelism: 2);
      expect(params.encode(), 'm=64MiB,t=3,p=2');
      expect(KdfParams.tryParse(params.encode()), params);
      expect(KdfParams.tryParse('m=8192KiB,t=1,p=1'),
          const KdfParams(memoryKib: 8 * 1024, iterations: 1, parallelism: 1));
    });

    test('越界或不认识一律拒绝，绝不猜', () {
      // 内存炸弹：一行 m=4096MiB 就能把内存撑爆
      expect(KdfParams.tryParse('m=4096MiB,t=3,p=1'), isNull);
      expect(KdfParams.tryParse('m=1MiB,t=3,p=1'), isNull);
      expect(KdfParams.tryParse('m=64MiB,t=0,p=1'), isNull);
      expect(KdfParams.tryParse('m=64MiB,t=99,p=1'), isNull);
      expect(KdfParams.tryParse('m=64MiB,t=3,p=0'), isNull);
      expect(KdfParams.tryParse('m=64MiB,t=3,p=99'), isNull);
      expect(KdfParams.tryParse('m=64MiB,t=3'), isNull);
      expect(KdfParams.tryParse('m=64MiB,t=3,p=1,x=9'), isNull);
      expect(KdfParams.tryParse('scrypt:64MiB'), isNull);
      expect(KdfParams.tryParse(''), isNull);
      expect(KdfParams.tryParse(null), isNull);
    });

    test('JSON 往返，以及认不出的算法要拒绝', () {
      const params = KdfParams(memoryKib: 32 * 1024, iterations: 2, parallelism: 1);
      expect(KdfParams.fromJson(params.toJson()), params);
      expect(
        KdfParams.fromJson(<String, Object?>{'algo': 'scrypt', 'm': 1024, 't': 1, 'p': 1}),
        isNull,
      );
      expect(KdfParams.fromJson(<String, Object?>{'algo': 'argon2id'}), isNull);
    });

    test('默认参数在下限之上（别把强度调到没意义）', () {
      expect(KdfParams.fallback.memoryKib, greaterThanOrEqualTo(KdfParams.minMemoryKib));
      expect(KdfParams.fallback.iterations, greaterThanOrEqualTo(2));
      expect(KdfParams.fallback.encode(), 'm=64MiB,t=3,p=1');
    });
  });

  group('加解密', () {
    test('往返：中文、空串、长文本都对得上', () async {
      final key = await _rawKey();
      final aad = VaultCrypto.aad(date: '2026-10-08', kind: 'body');
      for (final text in <String>['', '今天下雨。', 'a' * 5000, '混合 English 和中文，还有 emoji 🌧️']) {
        final sealed = await VaultCrypto.seal(key: key, plaintext: text, aad: aad);
        expect(sealed.startsWith('v1:'), isTrue);
        expect(await VaultCrypto.open(key: key, sealed: sealed, aad: aad), text);
      }
    });

    test('密文长度 = 明文长度 + nonce(24) + mac(16)', () async {
      final key = await _rawKey();
      final aad = VaultCrypto.aad(date: '2026-10-08', kind: 'body');
      final sealed = await VaultCrypto.seal(key: key, plaintext: '12345', aad: aad);
      final bytes = base64.decode(sealed.substring(3));
      expect(bytes.length, 5 + 24 + 16);
    });

    test('每次加密结果都不同（随机 nonce）', () async {
      final key = await _rawKey();
      final aad = VaultCrypto.aad(date: '2026-10-08', kind: 'body');
      final a = await VaultCrypto.seal(key: key, plaintext: '一样的内容', aad: aad);
      final b = await VaultCrypto.seal(key: key, plaintext: '一样的内容', aad: aad);
      expect(a, isNot(b));
    });

    test('密钥不对 → 解不开（不是解出乱码）', () async {
      final aad = VaultCrypto.aad(date: '2026-10-08', kind: 'body');
      final sealed = await VaultCrypto.seal(key: await _rawKey(), plaintext: '秘密', aad: aad);
      await expectLater(
        VaultCrypto.open(key: await _rawKey(), sealed: sealed, aad: aad),
        throwsA(isA<VaultAuthException>()),
      );
    });

    test('**AAD 绑住了"哪天、干什么用"**：换一天、换用途都解不开', () async {
      final key = await _rawKey();
      final sealed = await VaultCrypto.seal(
        key: key,
        plaintext: '秘密',
        aad: VaultCrypto.aad(date: '2026-10-08', kind: 'body'),
      );
      // 这一条是本设计的核心保证：把某天的密文剪到另一天，必须失败而不是解密成功
      await expectLater(
        VaultCrypto.open(key: key, sealed: sealed, aad: VaultCrypto.aad(date: '2026-10-09', kind: 'body')),
        throwsA(isA<VaultAuthException>()),
      );
      // 黑条的密文也不能拿来冒充整天正文
      await expectLater(
        VaultCrypto.open(key: key, sealed: sealed, aad: VaultCrypto.aad(date: '2026-10-08', kind: 'redaction')),
        throwsA(isA<VaultAuthException>()),
      );
    });

    test('被改过、被截断、格式不对 → 一律抛异常，绝不返回半个结果', () async {
      final key = await _rawKey();
      final aad = VaultCrypto.aad(date: '2026-10-08', kind: 'body');
      final sealed = await VaultCrypto.seal(key: key, plaintext: '秘密内容', aad: aad);

      // 改一个字节
      final raw = base64.decode(sealed.substring(3));
      raw[raw.length - 1] ^= 0x01;
      final tampered = 'v1:${base64.encode(raw)}';
      await expectLater(
        VaultCrypto.open(key: key, sealed: tampered, aad: aad),
        throwsA(isA<VaultAuthException>()),
      );

      // 截断
      final truncated = 'v1:${base64.encode(raw.sublist(0, raw.length - 5))}';
      await expectLater(
        VaultCrypto.open(key: key, sealed: truncated, aad: aad),
        throwsA(isA<VaultAuthException>()),
      );

      // 没有版本前缀 / 版本不认识 / base64 坏掉
      for (final bad in <String>['abcdef', 'v2:AAAA', 'v1:!!!!', 'v1:']) {
        await expectLater(
          VaultCrypto.open(key: key, sealed: bad, aad: aad),
          throwsA(isA<VaultAuthException>()),
          reason: bad,
        );
      }
    });
  });

  group('钥匙校验值', () {
    test('对的密钥通过，错的密钥不通过（而不是抛异常给界面）', () async {
      final key = await _rawKey();
      final check = await VaultCrypto.keyCheck(key);
      expect(await VaultCrypto.verifyKeyCheck(key, check), isTrue);
      expect(await VaultCrypto.verifyKeyCheck(await _rawKey(), check), isFalse);
      expect(await VaultCrypto.verifyKeyCheck(key, 'v1:garbage'), isFalse);
    });
  });

  group('恢复码', () {
    test('主密钥 → 恢复码 → 主密钥，完全一致', () {
      for (var i = 0; i < 5; i++) {
        final key = VaultCrypto.newMasterKey();
        final code = VaultCrypto.recoveryCode(key);
        expect(code.contains('-'), isTrue);
        final back = VaultCrypto.masterKeyFromRecoveryCode(code);
        expect(back.bytes, key.bytes);
      }
    });

    test('抄错字符也能救回来（I/L→1，O→0，小写，空格）', () {
      final key = VaultCrypto.newMasterKey();
      final code = VaultCrypto.recoveryCode(key)
          .replaceAll('1', 'l')
          .replaceAll('0', 'O')
          .replaceAll('-', ' ')
          .toLowerCase();
      expect(VaultCrypto.masterKeyFromRecoveryCode(code).bytes, key.bytes);
    });

    test('长度不对要明确报错，而不是悄悄给出一个别的密钥', () {
      expect(
        () => VaultCrypto.masterKeyFromRecoveryCode('ABCD-EFGH'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('口令派生', () {
    test('同一口令 + 同一盐 → 同一密钥；换个盐就不同', () async {
      final salt = base32Decode(VaultCrypto.newSalt());
      final a = await VaultCrypto.deriveKey(passphrase: '口令', salt: salt, params: _fast);
      final b = await VaultCrypto.deriveKey(passphrase: '口令', salt: salt, params: _fast);
      final c = await VaultCrypto.deriveKey(
        passphrase: '口令',
        salt: base32Decode(VaultCrypto.newSalt()),
        params: _fast,
      );
      expect(a.bytes, b.bytes);
      expect(a.bytes, isNot(c.bytes));
      expect(a.bytes.length, masterKeyLength);
    });

    test('默认参数在这台机器上的耗时（顺便确认没有慢到不能忍）', () async {
      final salt = base32Decode(VaultCrypto.newSalt());
      final watch = Stopwatch()..start();
      await VaultCrypto.deriveKey(
        passphrase: 'correct horse battery staple',
        salt: salt,
        params: KdfParams.fallback,
      );
      watch.stop();
      // 打印出来是为了定参数：解锁是每次开程序都要做的事
      // ignore: avoid_print
      print('Argon2id ${KdfParams.fallback} 耗时 ${watch.elapsedMilliseconds} ms');
      expect(watch.elapsedMilliseconds, lessThan(10000));
    });
  });
}
