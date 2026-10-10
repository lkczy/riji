import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/models/diary_entry.dart';
import 'package:riji/core/vault_crypto.dart';
import 'package:riji/core/vault_file.dart';
import 'package:riji/state/vault_service.dart';

/// 测试用的小参数：默认 64 MiB 每次派生要 0.7 秒，几十个用例加起来没法忍。
const KdfParams _fast = KdfParams(memoryKib: 8 * 1024, iterations: 1, parallelism: 1);

/// 假的保险库文件存储：只放在内存里，一个字节都不落到磁盘。
class _FakeFiles {
  String? content;
  int writes = 0;
  int deletes = 0;
  bool failWrite = false;

  Future<String?> read(String root) async => content;

  Future<void> write(String root, String text) async {
    if (failWrite) throw const FileSystemExceptionForTest();
    writes++;
    content = text;
  }

  Future<void> delete(String root) async {
    deletes++;
    content = null;
  }
}

class FileSystemExceptionForTest implements Exception {
  const FileSystemExceptionForTest();
  @override
  String toString() => '磁盘满了（测试里故意造的）';
}

VaultService _service(_FakeFiles files) => VaultService(
      diaryRoot: r'D:\someone\MyData',
      params: _fast,
      readFile: files.read,
      writeFile: files.write,
      deleteFile: files.delete,
    );

DiaryEntry _entry(String body) => DiaryEntry(
      id: '01M4A3EMFRK1XZN0GD5GFEMSDR',
      date: DateTime(2026, 10, 8),
      created: DateTime(2026, 10, 8, 9),
      updated: DateTime(2026, 10, 8, 21),
      device: 'test-pc',
      body: body,
      mood: '平静',
    );

const String _secret = '今天和某某见了面，聊到很晚。';

void main() {
  group('建库', () {
    test('建库成功 → 拿到恢复码；文件里没有明文密钥', () async {
      final files = _FakeFiles();
      final vault = _service(files);
      await vault.load();
      expect(vault.isConfigured, isFalse);

      final result = await vault.setUp('我的口令');
      expect(result.ok, isTrue);
      expect(result.recoveryCode, isNotNull);
      expect(result.warning, contains(VaultFile.fileName));
      expect(vault.isConfigured, isTrue);
      expect(vault.isUnlocked, isTrue);
      expect(vault.canWrite, isTrue, reason: '建完库就等于解锁了');

      // 落盘的内容里只有被口令包裹过的主密钥
      final written = files.content!;
      expect(written.contains(result.recoveryCode!.replaceAll('-', '')), isFalse);
      expect(VaultFile.tryParse(written), isNotNull);
    });

    test('空口令、重复建库 → 明确拒绝', () async {
      final files = _FakeFiles();
      final vault = _service(files);
      await vault.load();
      expect((await vault.setUp('   ')).ok, isFalse);

      await vault.setUp('口令');
      final again = await vault.setUp('另一个口令');
      expect(again.ok, isFalse);
      expect(again.message, contains('已经有'));
    });

    test('写文件失败 → 不算成功（不能报成功却什么都没留下）', () async {
      final files = _FakeFiles()..failWrite = true;
      final vault = _service(files);
      await vault.load();
      final result = await vault.setUp('口令');
      expect(result.ok, isFalse);
      expect(result.message, contains('写保险库文件失败'));
      expect(vault.isConfigured, isFalse);
    });
  });

  group('解锁', () {
    test('口令对 → 解锁；口令错 → 说清是口令错', () async {
      final files = _FakeFiles();
      final setup = _service(files);
      await setup.load();
      final code = (await setup.setUp('正确的口令')).recoveryCode!;

      final vault = _service(files);
      await vault.load();

      final bad = await vault.unlock('错的口令', isRecoveryCode: false);
      expect(bad.ok, isFalse);
      expect(bad.message, contains('口令不对'));
      expect(vault.isUnlocked, isFalse);

      final good = await vault.unlock('正确的口令', isRecoveryCode: false);
      expect(good.ok, isTrue);
      expect(vault.isUnlocked, isTrue);
      expect(vault.canWrite, isTrue);

      // 恢复码那条路（新写一遍，模拟"换台机器只有恢复码"）
      final fresh = _service(files);
      await fresh.load();
      final viaCode = await fresh.unlock(code, isRecoveryCode: true);
      expect(viaCode.ok, isTrue);
      expect(viaCode.recovery, isTrue);
      expect(fresh.isUnlocked, isTrue);
    });

    test('恢复码抄错 → 明确报错，不给出别的密钥', () async {
      final files = _FakeFiles();
      final vault = _service(files);
      await vault.load();
      await vault.setUp('口令');
      final other = _service(files);
      await other.load();
      final bad = await other.unlock('ABCD-EFGH', isRecoveryCode: true);
      expect(bad.ok, isFalse);
      expect(other.isUnlocked, isFalse);
    });

    test('没有保险库就去解锁 → 提示先设置口令', () async {
      final vault = _service(_FakeFiles());
      await vault.load();
      final result = await vault.unlock('随便', isRecoveryCode: false);
      expect(result.ok, isFalse);
      expect(result.message, contains('还没有保险库'));
    });

    test('保险库文件坏了 → 说文件坏了，而不是显示成"没加密"', () async {
      final files = _FakeFiles()..content = '{"v":"v1"这不是合法内容';
      final vault = _service(files);
      await vault.load();
      expect(vault.isConfigured, isFalse, reason: '解析不出来就是没有可用的保险库');
      expect(vault.lastError, isNotNull);
      expect(vault.lastError, contains('读不出来'));
    });
  });

  group('按次解锁的权限边界', () {
    test('只为搜索解锁：能解密搜索，但**不能改写文件**', () async {
      final files = _FakeFiles();
      final setup = _service(files);
      await setup.load();
      await setup.setUp('口令');
      final locked = await setup.lockWholeDay(_entry(_secret));

      final vault = _service(files);
      await vault.load();
      final result = await vault.unlock('口令', isRecoveryCode: false, forSearchOnly: true);
      expect(result.ok, isTrue);
      expect(vault.isSearchRevealed, isTrue);
      expect(vault.canWrite, isFalse, reason: '按次解锁不该顺带交出改写能力');

      expect(await vault.prepare(<DiaryEntry>[locked]), isEmpty);
      expect(vault.searchText(locked), _secret, reason: '搜索能看见');

      await expectLater(
        vault.unlockWholeDay(locked),
        throwsA(isA<VaultAuthException>()),
      );
      await expectLater(
        vault.lockLine(_entry('普通正文'), 0),
        throwsA(isA<VaultAuthException>()),
      );

      // 用完即丢
      vault.releaseSearchReveal();
      expect(vault.isUnlocked, isFalse);
      expect(vault.searchText(locked), isNull);
      expect(vault.participatesInSearch(locked), isFalse);
    });

    test('会话解锁：能看能改；锁定之后缓存清空', () async {
      final files = _FakeFiles();
      final setup = _service(files);
      await setup.load();
      await setup.setUp('口令');
      final locked = await setup.lockWholeDay(_entry(_secret));

      final vault = _service(files);
      await vault.load();
      await vault.unlock('口令', isRecoveryCode: false);
      expect(vault.canWrite, isTrue);
      expect(await vault.prepare(<DiaryEntry>[locked]), isEmpty);
      expect(vault.searchText(locked), _secret);
      expect(await vault.unlockWholeDay(locked).then((e) => e.body), _secret);

      vault.lock();
      expect(vault.isUnlocked, isFalse);
      expect(vault.searchText(locked), isNull);
      expect(vault.revealedCount, 0);
    });

    test('会话解锁调 releaseSearchReveal **不会**把会话也锁掉', () async {
      final files = _FakeFiles();
      final setup = _service(files);
      await setup.load();
      await setup.setUp('口令');
      final locked = await setup.lockWholeDay(_entry(_secret));

      final vault = _service(files);
      await vault.load();
      await vault.unlock('口令', isRecoveryCode: false);
      await vault.prepare(<DiaryEntry>[locked]);
      vault.releaseSearchReveal();
      expect(vault.isUnlocked, isTrue, reason: '会话解锁不受搜索那档影响');
      expect(vault.searchText(locked), _secret);
    });
  });

  group('搜索参与的可见性', () {
    test('解密失败的天要被报出来，而不是悄悄当成"没内容"', () async {
      final files = _FakeFiles();
      final setup = _service(files);
      await setup.load();
      await setup.setUp('口令');
      final locked = await setup.lockWholeDay(_entry(_secret));

      // 换一把完全不相干的密钥去解（模拟文件被人动过/密钥不符）
      final other = _FakeFiles();
      final otherSetup = _service(other);
      await otherSetup.load();
      await otherSetup.setUp('另一个口令');

      final vault = _service(other);
      await vault.load();
      await vault.unlock('另一个口令', isRecoveryCode: false);
      final failed = await vault.prepare(<DiaryEntry>[locked]);
      expect(failed.length, 1);
      expect(vault.lastError, contains('解不开'));
      expect(vault.searchText(locked), isNull, reason: '解不开 = 没参与搜索，界面要说出来');
    });

    test('明文的天永远参与搜索，和解锁状态无关', () async {
      final vault = _service(_FakeFiles());
      await vault.load();
      final plain = _entry('普通的一天');
      expect(vault.searchText(plain), '普通的一天');
      expect(vault.participatesInSearch(plain), isTrue);
    });
  });

  group('关闭加密', () {
    test('删掉保险库文件，回到"未配置"', () async {
      final files = _FakeFiles();
      final vault = _service(files);
      await vault.load();
      await vault.setUp('口令');
      final result = await vault.disableVault();
      expect(result.ok, isTrue);
      expect(files.deletes, 1);
      expect(vault.isConfigured, isFalse);
      expect(vault.isUnlocked, isFalse);
      expect(result.warning, contains('解开'));

      // 再锁就没人认了
      expect((await vault.disableVault()).ok, isFalse);
    });
  });

}
