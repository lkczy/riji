import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/diary_codec.dart';
import 'package:riji/core/models/diary_entry.dart';
import 'package:riji/core/vault_content.dart';
import 'package:riji/core/vault_crypto.dart';
import 'package:riji/core/vault_file.dart';
import 'package:riji/core/vault_format.dart';

const KdfParams _params = KdfParams(memoryKib: 64 * 1024, iterations: 3, parallelism: 1);

const String _secret = '今天和某某见了面，聊到很晚。';
const String _otherSecret = '这一段本来不想让人看见。';

DiaryEntry _entry(String body) => DiaryEntry(
      id: '01M4A3EMFRK1XZN0GD5GFEMSDR',
      date: DateTime(2026, 10, 8),
      created: DateTime(2026, 10, 8, 9),
      updated: DateTime(2026, 10, 8, 21),
      device: 'test-pc',
      body: body,
      mood: '平静',
      tags: const <String>['日常'],
    );

/// 走一遍真实的"存盘 → 读回"，确保密文能穿过编解码。
DiaryEntry _persist(DiaryEntry entry) => DiaryCodec.decode(
      DiaryCodec.encode(entry),
      fallbackDate: entry.date,
      fallbackTimestamp: entry.updated,
      fallbackDevice: 'fallback',
    );

void main() {
  late VaultContent content;

  setUp(() {
    content = VaultContent(key: VaultCrypto.newMasterKey(), params: _params);
  });

  group('整天锁', () {
    test('锁上之后：正文清空、密文进 front matter、盘上没有明文', () async {
      final entry = _entry(_secret);
      final locked = await content.lockWholeDay(entry);

      expect(locked.body, wholeDayPlaceholder);
      expect(locked.lock!.isWholeDay, isTrue);
      expect(locked.lock!.characters, _secret.length);
      // 元数据是明文，解开之前也能按心情/标签找
      expect(locked.mood, '平静');
      expect(locked.tags, <String>['日常']);

      // **最关键的一条**：落到磁盘上的字节里不能有明文
      final text = DiaryCodec.encode(locked);
      expect(text.contains(_secret), isFalse);
      expect(text.contains('某某'), isFalse);
      expect(text, contains('enc-body:'));
    });

    test('读回来仍然是密文，解开得到原文', () async {
      final locked = _persist(await content.lockWholeDay(_entry(_secret)));
      expect(locked.isLocked, isTrue);
      expect(await content.revealBody(locked), _secret);
    });

    test('解开整天：正文变回明文，锁整个去掉', () async {
      final locked = await content.lockWholeDay(_entry(_secret));
      final opened = await content.unlockWholeDay(locked);
      expect(opened.body, _secret);
      expect(opened.lock, isNull);
      expect(opened.isLocked, isFalse);
      expect(DiaryCodec.encode(opened).contains('enc'), isFalse);
    });

    test('密钥不对 → 明确报错，不是解出乱码', () async {
      final locked = await content.lockWholeDay(_entry(_secret));
      final other = VaultContent(key: VaultCrypto.newMasterKey(), params: _params);
      await expectLater(other.revealBody(locked), throwsA(isA<VaultAuthException>()));
    });

    test('把某天的密文剪到另一天 → 解不开（AAD 绑住了日期）', () async {
      final locked = await content.lockWholeDay(_entry(_secret));
      final transplanted = locked.copyWith(date: DateTime(2026, 10, 9));
      await expectLater(
        content.revealBody(transplanted),
        throwsA(isA<VaultAuthException>()),
      );
    });
  });

  group('按段锁（黑条）', () {
    test('锁一段：那一行变黑条，密文进 enc-redactions，盘上没有明文', () async {
      final entry = _entry('今天去了医院。\n$_otherSecret\n回来买了菜。');
      final locked = await content.lockLine(entry, 1);

      final lines = locked.body.split('\n');
      // 黑条和原文等长
      expect(isRedactionLine(lines[1]), isTrue);
      expect(lines[1].runes.length, _otherSecret.runes.length);
      expect(lines[0], '今天去了医院。');
      expect(lines[2], '回来买了菜。');
      expect(locked.lock!.isParagraphs, isTrue);
      expect(locked.lock!.redactions.length, 1);

      final text = DiaryCodec.encode(locked);
      expect(text.contains('不想让人看见'), isFalse);
      expect(text, contains('enc-redactions:'));
      expect(text, contains(redactionBar));
      // 没锁的部分照旧是明文（这正是方案 C 的取舍）
      expect(text, contains('今天去了医院。'));
    });

    test('点黑条看原文 / 搜索用的完整正文', () async {
      final locked = _persist(await content.lockLine(
        _entry('今天去了医院。\n$_otherSecret\n回来买了菜。'),
        1,
      ));
      expect(await content.revealRedaction(locked, 1), _otherSecret);
      expect(
        await content.revealBody(locked),
        '今天去了医院。\n$_otherSecret\n回来买了菜。',
      );
    });

    test('锁两段、解开中间那段：剩下那段自动重编号，内容不错位', () async {
      final entry = _entry('第一行\n$_secret\n$_otherSecret\n第四行');
      var locked = await content.lockLine(entry, 1);
      locked = await content.lockLine(locked, 2);
      expect(locked.lock!.redactions.keys.toList(), <String>['r1', 'r2']);
      expect(await content.revealRedaction(locked, 1), _secret);
      expect(await content.revealRedaction(locked, 2), _otherSecret);

      // 解开第一段（位置 0）→ 第二段应该变成 r1，而且内容还是它自己
      final after = await content.unlockLine(locked, 1);
      expect(after.lock!.redactions.keys.toList(), <String>['r1']);
      expect(after.body.split('\n')[1], _secret, reason: '被解开的那行变回明文');
      expect(redactionLineCount(after.body), 1);
      expect(await content.revealRedaction(after, 2), _otherSecret);
      expect(
        await content.revealBody(after),
        '第一行\n$_secret\n$_otherSecret\n第四行',
      );
    });

    test('黑条比密文**少**时也不许解：宁可报错，不能张冠李戴', () async {
      final entry = _entry('第一行\n$_secret\n$_otherSecret\n第四行');
      var locked = await content.lockLine(entry, 1);
      locked = await content.lockLine(locked, 2);
      expect(locked.lock!.redactions.length, 2);

      // 模拟"用户在解锁状态下把第一行黑条改成了普通文字"：
      // 黑条只剩 1 行，密文还是 2 段。
      final lines = locked.body.split('\n');
      lines[1] = '手打的一行字';
      final damaged = locked.copyWith(body: lines.join('\n'));

      // 如果不校验数量，剩下的那行黑条会去配**第一段**密文，
      // 界面上就会显示成 $_secret —— 而它其实是 $_otherSecret。
      await expectLater(
        content.revealBody(damaged),
        throwsA(isA<VaultAuthException>()),
      );
      await expectLater(
        content.revealRedaction(damaged, 2),
        throwsA(isA<VaultAuthException>()),
      );
    });

    test('字数是"完整字数"，含被锁起来的部分', () async {
      final entry = _entry('第一行\n$_otherSecret\n第三行');
      final locked = await content.lockLine(entry, 1);
      expect(locked.lock!.characters, entry.body.length);
    });

    test('空行、已经锁着的行、越界 → 原样返回，不折腾', () async {
      final entry = _entry('第一行\n\n第三行');
      expect((await content.lockLine(entry, 1)).body, entry.body);

      final locked = await content.lockLine(_entry('第一行\n$_otherSecret'), 1);
      final again = await content.lockLine(locked, 1);
      expect(again.lock!.redactions.length, 1);
      expect(again.body, locked.body);
    });
  });

  group('两种形态之间转换', () {
    test('按段锁 → 整天锁：已有的黑条会被解开并合并，不丢内容', () async {
      final entry = _entry('第一行\n$_secret\n第三行');
      final paragraph = await content.lockLine(entry, 1);
      final wholeDay = await content.lockWholeDay(paragraph);

      expect(wholeDay.body, wholeDayPlaceholder);
      expect(wholeDay.lock!.isWholeDay, isTrue);
      expect(wholeDay.lock!.redactions, isEmpty, reason: '合并之后不该再有按段的密文');
      expect(await content.revealBody(wholeDay), '第一行\n$_secret\n第三行');
    });

    test('整天锁着的时候按段加锁 → 明确拒绝，而不是干出奇怪的事', () async {
      final locked = await content.lockWholeDay(_entry(_secret));
      await expectLater(
        content.lockLine(locked, 0),
        throwsA(isA<VaultAuthException>()),
      );
    });

    test('解锁全部黑条 = 变回明文的一天', () async {
      final entry = _entry('第一行\n$_secret\n第三行');
      final locked = await content.lockLine(entry, 1);
      final opened = await content.unlockAllLines(locked);
      expect(opened.body, entry.body);
      expect(opened.lock, isNull);
    });
  });

  group('.vault 文件', () {
    test('往返：编码后解析回来一模一样', () {
      final file = VaultFile(
        salt: VaultCrypto.newSalt(),
        params: _params,
        wrapped: 'v1:QUJD',
        check: 'v1:REVG',
        created: DateTime(2026, 10, 8, 21),
      );
      final back = VaultFile.tryParse(file.encode());
      expect(back, isNotNull);
      expect(back!.salt, file.salt);
      expect(back.params, _params);
      expect(back.wrapped, 'v1:QUJD');
      expect(back.check, 'v1:REVG');
      expect(back.created, file.created);
    });

    test('坏文件一律返回 null，绝不猜', () {
      expect(VaultFile.tryParse('不是 JSON'), isNull);
      expect(VaultFile.tryParse('[]'), isNull);
      expect(VaultFile.tryParse('{}'), isNull);
      // 缺 wrapped / check
      expect(
        VaultFile.tryParse('{"v":"v1","kdf":{"algo":"argon2id","m":65536,"t":3,"p":1,"salt":"AA"}}'),
        isNull,
      );
      // 内存炸弹参数
      expect(
        VaultFile.tryParse(
          '{"v":"v1","kdf":{"algo":"argon2id","m":4194304,"t":3,"p":1,"salt":"AA"},'
          '"wrapped":"v1:A","check":"v1:B"}',
        ),
        isNull,
      );
      // 认不出的 KDF
      expect(
        VaultFile.tryParse(
          '{"v":"v1","kdf":{"algo":"scrypt","m":65536,"t":3,"p":1,"salt":"AA"},'
          '"wrapped":"v1:A","check":"v1:B"}',
        ),
        isNull,
      );
    });

    test('文件里不出现主密钥本身（只有被口令包裹的那份）', () {
      final key = VaultCrypto.newMasterKey();
      final code = VaultCrypto.recoveryCode(key).replaceAll('-', '');
      final file = VaultFile(
        salt: VaultCrypto.newSalt(),
        params: _params,
        wrapped: 'v1:被口令包裹过的东西',
        check: 'v1:校验值',
      );
      expect(file.encode().contains(code), isFalse);
    });
  });
}
