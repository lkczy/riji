import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/diary_codec.dart';
import 'package:riji/core/diary_paths.dart';
import 'package:riji/core/history.dart';
import 'package:riji/core/models/diary_entry.dart';
import 'package:riji/core/vault_file.dart';
import 'package:riji/core/vault_format.dart';
import 'package:riji/data/fs_diary_store.dart';
import 'package:riji/state/vault_service.dart';

/// 加密功能的**真文件系统**端到端测试。
///
/// 和别的测试不同，这一份用真的 `FsDiaryStore`、真的加解密、真的目录结构，
/// 并且**逐字节扫盘**：锁着的内容在磁盘上任何地方都不能以明文出现——
/// 包括 `.history/`、`.drafts/`、`.trash/` 和备份副本，那些是最容易漏的地方。
///
/// 目录建在系统临时目录下，**绝不碰用户的真实日记**。
/// Argon2id 是真的，所以这一份比其他测试慢几秒；这是值得的。
const String _passphrase = '样例口令-verify';
const String _wholeDaySecret = '这一整天都不该被别人看到（整天锁）';
const String _redactedSecret = '这一段只有我自己知道（按段锁）';
const String _plainText = '这一天是明文的，本来就该能被记事本打开。';
const String _trashSecret = '这一天的日记被删掉了（回收站里也不许有明文）';

late Directory _root;
late String _rootPath;
late FsDiaryStore _store;
late VaultService _vault;
late String _recoveryCode;
late DiaryEntry _lockedWhole;
late DiaryEntry _lockedParagraph;
late DateTime _wholeDay;
late DateTime _paragraphDay;
late DateTime _trashDay;

const String _device = 'verify-pc';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _filePath(DateTime date) => '$_rootPath${Platform.pathSeparator}'
    '${date.year}${Platform.pathSeparator}${DiaryPaths.fileNameFor(date)}';

/// 递归读出整个目录下所有文件的文本（解码失败也算，扫的是字节）。
String _allTextUnder(String path) {
  final buffer = StringBuffer();
  for (final entity in Directory(path).listSync(recursive: true)) {
    if (entity is File) {
      buffer.write(utf8.decode(entity.readAsBytesSync(), allowMalformed: true));
    }
  }
  return buffer.toString();
}

void main() {
  setUpAll(() async {
    _root = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}riji-vault-e2e-'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    _root.createSync(recursive: true);
    _rootPath = _root.path;

    _store = FsDiaryStore(rootPath: _rootPath, deviceName: _device);
    _vault = VaultService(diaryRoot: _rootPath);
    await _vault.load();

    final setup = await _vault.setUp(_passphrase);
    expect(setup.ok, isTrue, reason: setup.message);
    _recoveryCode = setup.recoveryCode!;

    final plainDay = DateTime(2026, 10, 1);
    _wholeDay = DateTime(2026, 10, 2);
    _paragraphDay = DateTime(2026, 10, 3);

    await _store.save(
      DiaryEntry.create(date: plainDay, device: _device, body: _plainText),
    );
    _lockedWhole = await _vault.lockWholeDay(
      DiaryEntry.create(date: _wholeDay, device: _device, body: _wholeDaySecret),
    );
    await _store.save(_lockedWhole);
    _lockedParagraph = await _vault.lockLine(
      DiaryEntry.create(
        date: _paragraphDay,
        device: _device,
        body: '今天去了医院。\n$_redactedSecret\n回来买了菜。',
      ),
      1,
    );
    await _store.save(_lockedParagraph);

    // 历史快照：写的就是"文件内容"，所以锁着的天自动是密文
    await _store.writeSnapshot(
      _paragraphDay,
      DiaryCodec.encode(_lockedParagraph),
      reason: SnapshotReason.manual,
      at: DateTime(2026, 10, 3, 22),
    );
    // 草稿：写的是**编辑区里的文本**，而编辑区永远是"磁盘上的形式"
    await _store.writeDraft(_paragraphDay, _lockedParagraph.body);
    await _store.writeDraft(_wholeDay, _lockedWhole.body);
    // 回收站：软删除 = 移动文件。**用单独的一天**，否则"按段锁的文件还在
    // 原地"和"所有条目都锁着"这两条断言就会自相矛盾。
    _trashDay = DateTime(2026, 10, 4);
    await _store.save(
      await _vault.lockWholeDay(
        DiaryEntry.create(date: _trashDay, device: _device, body: _trashSecret),
      ),
    );
    await _store.deleteEntry(_trashDay);
  });

  tearDownAll(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  test('保险库文件就在日记目录里（备份和同步必须带上它）', () {
    final file = File('$_rootPath${Platform.pathSeparator}${VaultFile.fileName}');
    expect(file.existsSync(), isTrue);
    expect(VaultFile.tryParse(file.readAsStringSync()), isNotNull);
    // 它不该含任何秘密：只有盐、参数、被包裹的主密钥、校验值
    final text = file.readAsStringSync();
    expect(text.contains(_wholeDaySecret), isFalse);
    expect(text.contains(_passphrase), isFalse);
    expect(text.contains(_recoveryCode.replaceAll('-', '')), isFalse,
        reason: '恢复码绝不落盘');
  });

  test('锁着的内容在磁盘上**任何地方**都不以明文出现', () {
    for (final secret in <String>[_wholeDaySecret, _redactedSecret, _trashSecret]) {
      expect(_allTextUnder(_rootPath).contains(secret), isFalse,
          reason: '「$secret」出现在了磁盘上');
    }
  });

  test('整天锁：正文清空、密文进 front matter、字数留着', () {
    final text = File(_filePath(_wholeDay)).readAsStringSync();
    expect(text, contains('enc-body:'));
    expect(text, contains('enc-params:'));
    expect(text, contains('chars:'));
    expect(text.contains(_wholeDaySecret), isFalse);
    // 正文是占位符：旧版本会把它当正文显示，于是界面上写着"这一天已加密"——
    // 比一片空白更好，而且**不会弄坏密文**（密文在 front matter 里）。
    final body = text.split('---')[2].trim();
    expect(body, wholeDayPlaceholder);
  });

  test('按段锁：文件里就是黑条，没锁的部分照旧是明文', () {
    final text = File(_filePath(_paragraphDay)).readAsStringSync();
    expect(text, contains('enc-redactions:'));
    expect(text, contains(redactionBar));
    expect(text, contains('今天去了医院。'));
    expect(text.contains(_redactedSecret), isFalse);
  });

  test('明文的那天一个字都没变，也不带任何 enc 字段', () {
    final text = File(_filePath(DateTime(2026, 10, 1))).readAsStringSync();
    expect(text, contains(_plainText));
    expect(text.contains('enc'), isFalse);
    expect(text.contains('chars:'), isFalse);
  });

  test('历史快照、草稿、回收站里都是密文（最容易漏的三处）', () {
    for (final dir in <String>['.history', '.drafts', '.trash']) {
      final path = '$_rootPath${Platform.pathSeparator}$dir';
      expect(Directory(path).existsSync(), isTrue, reason: '$dir 应该存在');
      final text = _allTextUnder(path);
      expect(text.contains(_wholeDaySecret), isFalse, reason: '$dir 里出现了整天锁的明文');
      expect(text.contains(_redactedSecret), isFalse, reason: '$dir 里出现了按段锁的明文');
    }
    // 草稿里应该是黑条本身——它记的是"编辑区里的样子"
    final drafts = _allTextUnder('$_rootPath${Platform.pathSeparator}.drafts');
    expect(drafts, contains(redactionBar));
  });

  test('旧版本不认识这些字段 → 会被原样保留（前向兼容）', () {
    final text = File(_filePath(_wholeDay)).readAsStringSync();
    final frontMatter = text.split('---')[1];
    // 旧版本（v1.0.0–v1.3.0）认识的键就这些，其余一律逐字节保留
    const oldKnownKeys = <String>{
      'id', 'date', 'created', 'updated', 'device', 'mood', 'weather', 'tags',
    };
    final keys = RegExp(r'^([A-Za-z0-9_\-]+):', multiLine: true)
        .allMatches(frontMatter)
        .map((m) => m.group(1)!)
        .toList();
    final newKeys =
        keys.where((k) => k.startsWith('enc') || k == 'chars').toList();
    expect(newKeys, isNotEmpty, reason: '锁着的内容用的是新增的顶层键');
    for (final key in newKeys) {
      expect(oldKnownKeys.contains(key), isFalse, reason: '$key 旧版本不该认识');
    }
  });

  test('模拟重启：新实例 + 口令解锁 → 原文解得回来；错口令解不开', () async {
    final restarted = VaultService(diaryRoot: _rootPath);
    await restarted.load();
    expect(restarted.isConfigured, isTrue);
    expect(restarted.isUnlocked, isFalse);

    final wrong = await restarted.unlock('错口令', isRecoveryCode: false);
    expect(wrong.ok, isFalse);
    expect(wrong.message, contains('口令不对'));

    final good = await restarted.unlock(_passphrase, isRecoveryCode: false);
    expect(good.ok, isTrue, reason: good.message);

    final entries = await _store.loadAll();
    expect(entries.length, 3, reason: '被删的那天在回收站里，不在正文目录里');
    expect(entries.where((e) => e.isLocked).length, 2, reason: '三天里两天是锁的');
    expect(entries.where((e) => !e.isLocked).single.date, DateTime(2026, 10, 1));
    expect(entries.every((e) => !e.isEmpty), isTrue,
        reason: '锁着的天算有内容，日历和每日提醒不会当成没写');

    expect(await restarted.prepare(entries), isEmpty);
    final whole = entries.firstWhere((e) => _sameDay(e.date, _wholeDay));
    expect(restarted.searchText(whole), _wholeDaySecret);
    final paragraph = entries.firstWhere((e) => _sameDay(e.date, _paragraphDay));
    expect(restarted.searchText(paragraph),
        '今天去了医院。\n$_redactedSecret\n回来买了菜。');
    expect(whole.characterCount, _wholeDaySecret.length);
  });

  test('恢复码也能解锁并读回原文（换了机器只剩恢复码的那条路）', () async {
    final viaCode = VaultService(diaryRoot: _rootPath);
    await viaCode.load();
    final result = await viaCode.unlock(_recoveryCode, isRecoveryCode: true);
    expect(result.ok, isTrue, reason: result.message);
    expect(result.recovery, isTrue);

    final entries = await _store.loadAll();
    await viaCode.prepare(entries);
    final whole = entries.firstWhere((e) => _sameDay(e.date, _wholeDay));
    expect(viaCode.searchText(whole), _wholeDaySecret);
  });

  test('备份副本里也是密文，而且带着保险库文件', () {
    final backupRoot = '$_rootPath-backup';
    final backup = Directory(backupRoot);
    if (backup.existsSync()) backup.deleteSync(recursive: true);
    backup.createSync(recursive: true);

    // 备份做的事就是文件级复制
    for (final entity in Directory(_rootPath).listSync(recursive: true)) {
      final relative = entity.path.substring(_rootPath.length + 1);
      if (entity is Directory) {
        Directory('$backupRoot${Platform.pathSeparator}$relative')
            .createSync(recursive: true);
      } else if (entity is File) {
        final target = File('$backupRoot${Platform.pathSeparator}$relative');
        target.parent.createSync(recursive: true);
        entity.copySync(target.path);
      }
    }

    final text = _allTextUnder(backupRoot);
    expect(text.contains(_wholeDaySecret), isFalse);
    expect(text.contains(_redactedSecret), isFalse);
    expect(
      File('$backupRoot${Platform.pathSeparator}${VaultFile.fileName}').existsSync(),
      isTrue,
      reason: '没有保险库文件的备份，就是一包谁都解不开的密文',
    );
    backup.deleteSync(recursive: true);
  });

  // ⚠️ 这一条会改动磁盘上的内容，所以放在最后
  test('解开整天之后，磁盘上回到明文', () async {
    final opened = await _vault.unlockWholeDay(_lockedWhole);
    await _store.save(opened);
    final text = File(_filePath(_wholeDay)).readAsStringSync();
    expect(text, contains(_wholeDaySecret));
    expect(text.contains('enc-body'), isFalse);
  });
}
