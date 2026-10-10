import 'package:cryptography/cryptography.dart';

import 'day.dart';
import 'models/diary_entry.dart';
import 'vault_crypto.dart';
import 'vault_format.dart';

/// 对一个条目做"上锁 / 解锁"的操作。**纯逻辑：不碰文件系统**。
///
/// 它拿着主密钥，所以只应该在**已解锁**的时候构造。所有函数都返回**新的
/// 条目**，绝不原地改——上层拿到新条目后照常走既有的保存路径，于是一个
/// 出口就保证了"落盘的一定是密文"（见 `docs/加密设计.md` 第 4 节）。
class VaultContent {
  const VaultContent({required this.key, required this.params});

  final SecretKey key;
  final KdfParams params;

  // ---------------------------------------------------------------------------
  // 读（只用于搜索、预览、浮窗，绝不写回编辑框）
  // ---------------------------------------------------------------------------

  /// 黑条数和密文数必须**严格相等**才允许解开。
  ///
  /// 为什么少一个也不行：对应关系是"按出现顺序"。用户如果（在解锁状态下）
  /// 把某一行黑条改成了普通文字，剩下的黑条就会去配**前面的**密文——
  /// 于是界面上显示的是**另一段**的内容，而且悄无声息。宁可整篇报错，
  /// 也不能张冠李戴。
  void _requireMatchingCounts(DiaryEntry entry, DayLock lock) {
    final bars = redactionLineCount(entry.body);
    final ciphers = lock.redactions.length;
    if (bars != ciphers) {
      throw VaultAuthException(
        '正文里有 $bars 行黑条，但存着 $ciphers 段密文，对不上——'
        '${bars > ciphers ? '多出来的黑条底下没有内容' : '有一段密文找不到对应的黑条'}，'
        '解开只会张冠李戴，所以这里不解。',
      );
    }
  }

  /// 这一天的**完整明文正文**：锁着的会解开、黑条会换回原文。
  ///
  /// 明文的天直接返回 [DiaryEntry.body]（不经过任何密码学）。
  /// 解不开时抛 [VaultAuthException]，由调用方决定怎么告知用户。
  Future<String> revealBody(DiaryEntry entry) async {
    final lock = entry.lock;
    if (lock == null || !lock.isLocked) return entry.body;

    if (lock.isWholeDay) {
      return VaultCrypto.open(
        key: key,
        sealed: lock.bodyCipher!,
        aad: VaultCrypto.aad(date: _dateKey(entry), kind: 'body'),
      );
    }

    // 按段锁：把黑条按顺序换回原文
    _requireMatchingCounts(entry, lock);
    final ciphers = _ciphers(lock);
    var index = 0;
    final lines = entry.body.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (!isRedactionLine(lines[i])) continue;
      if (index >= ciphers.length) {
        throw const VaultAuthException('正文里的黑条比密文多，没救了');
      }
      lines[i] = await VaultCrypto.open(
        key: key,
        sealed: ciphers[index],
        aad: VaultCrypto.aad(date: _dateKey(entry), kind: 'redaction'),
      );
      index++;
    }
    return lines.join('\n');
  }

  /// 解开某一段黑条（给浮窗看原文用）。
  Future<String> revealRedaction(DiaryEntry entry, int lineIndex) async {
    final lock = entry.lock;
    if (lock == null || lock.isWholeDay) {
      throw const VaultAuthException('这一天不是按段锁的');
    }
    final lines = entry.body.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length || !isRedactionLine(lines[lineIndex])) {
      throw const VaultAuthException('这一行不是黑条');
    }
    _requireMatchingCounts(entry, lock);
    final position = _barPosition(lines, lineIndex);
    final ciphers = _ciphers(lock);
    if (position >= ciphers.length) {
      throw const VaultAuthException('这一行黑条没有对应的密文');
    }
    return VaultCrypto.open(
      key: key,
      sealed: ciphers[position],
      aad: VaultCrypto.aad(date: _dateKey(entry), kind: 'redaction'),
    );
  }

  // ---------------------------------------------------------------------------
  // 写
  // ---------------------------------------------------------------------------

  /// 锁上**整天**：正文变空，整篇密文进 front matter。
  ///
  /// 如果这天本来是按段锁的，会先把已有的黑条解开、合并成完整正文再整体加密
  /// ——所以"先锁几段、后来决定整天锁"不会丢东西。
  Future<DiaryEntry> lockWholeDay(DiaryEntry entry) async {
    final plain = await revealBody(entry);
    final sealed = await VaultCrypto.seal(
      key: key,
      plaintext: plain,
      aad: VaultCrypto.aad(date: _dateKey(entry), kind: 'body'),
    );
    return entry.copyWith(
      // 正文留一个占位符（而不是空的）：手机上、记事本里打开都能看懂
      // "这一天锁着"。解不开的人看到的是它，不是一片空白。
      body: wholeDayPlaceholder,
      lock: DayLock(
        params: params,
        bodyCipher: sealed,
        characters: plain.runes.length,
      ),
    );
  }

  /// 解开整天：正文变回明文，锁整个去掉。
  ///
  /// ⚠️ 这是**用户在知情下选择的降级**：磁盘上从此是明文。界面必须先说清。
  Future<DiaryEntry> unlockWholeDay(DiaryEntry entry) async {
    final plain = await revealBody(entry);
    return entry.copyWith(body: plain, clearLock: true);
  }

  /// 锁上某一行（"这一段我不想让人看见"）。
  Future<DiaryEntry> lockLine(DiaryEntry entry, int lineIndex) async {
    // 先判"整天锁"：整天锁的正文是空的，不先拦下来的话会被下面的空行护栏
    // 静默吃掉，界面上就变成"点了没反应"，而不是一句能看懂的话。
    if (entry.lock?.isWholeDay ?? false) {
      throw const VaultAuthException('这一天是整天锁的，要先解开整天才能按段锁');
    }
    final lines = entry.body.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) return entry;
    final text = lines[lineIndex];
    if (isRedactionLine(text)) return entry; // 已经是黑条
    if (text.trim().isEmpty) return entry; // 空行没什么可锁

    final position = _barPosition(lines, lineIndex);
    final ciphers = _ciphers(entry.lock)..insert(position, await VaultCrypto.seal(
        key: key,
        plaintext: text,
        aad: VaultCrypto.aad(date: _dateKey(entry), kind: 'redaction'),
      ));

    final updated = entry.copyWith(
      body: barForLineAt(entry.body, lineIndex, text.runes.length),
      lock: _lockWith(ciphers),
    );
    return _withCharacters(updated);
  }

  /// 解开某一段：黑条换回明文，密文从 front matter 删掉。
  ///
  /// ⚠️ 同样是把这段变回**明文存盘**，界面必须先说清。
  Future<DiaryEntry> unlockLine(DiaryEntry entry, int lineIndex) async {
    final lock = entry.lock;
    if (lock == null || lock.isWholeDay) {
      throw const VaultAuthException('这一天不是按段锁的');
    }
    final lines = entry.body.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length || !isRedactionLine(lines[lineIndex])) {
      return entry;
    }
    final position = _barPosition(lines, lineIndex);
    final ciphers = _ciphers(lock);
    if (position >= ciphers.length) {
      throw const VaultAuthException('这一行黑条没有对应的密文');
    }
    final text = await VaultCrypto.open(
      key: key,
      sealed: ciphers[position],
      aad: VaultCrypto.aad(date: _dateKey(entry), kind: 'redaction'),
    );
    ciphers.removeAt(position);

    final updated = entry.copyWith(
      body: revealLine(entry.body, lineIndex, text),
      lock: ciphers.isEmpty ? null : _lockWith(ciphers),
      clearLock: ciphers.isEmpty,
    );
    return _withCharacters(updated);
  }

  /// 把一天里所有黑条解开（"今天我全部解锁"）。
  Future<DiaryEntry> unlockAllLines(DiaryEntry entry) async => unlockWholeDay(entry);

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  static String _dateKey(DiaryEntry entry) => formatIsoDate(dateOnly(entry.date));

  /// 按出现顺序取出密文。用 map 的插入顺序保证"第 1 行黑条 = r1"。
  static List<String> _ciphers(DayLock? lock) {
    if (lock == null) return <String>[];
    return lock.redactions.keys.map((k) => lock.redactions[k]!).toList();
  }

  /// 第 [lineIndex] 行之前有几行黑条——也就是它在密文列表里的位置。
  static int _barPosition(List<String> lines, int lineIndex) {
    var count = 0;
    for (var i = 0; i < lineIndex && i < lines.length; i++) {
      if (isRedactionLine(lines[i])) count++;
    }
    return count;
  }

  /// 按位置重新编号（`r1`、`r2`……）。
  ///
  /// 每次都重编号：键只是**位置标签**，不代表"哪一段的身份"。所以
  /// 解锁中间某一段之后，后面的段号会整体前移，而密文不会错位——
  /// 因为顺序才是唯一的事实来源。
  DayLock _lockWith(List<String> ciphers) => DayLock(
        params: params,
        redactions: <String, String>{
          for (var i = 0; i < ciphers.length; i++) redactionKey(i): ciphers[i],
        },
      );

  /// 字数跟着更新：锁上/解开之后，完整正文明文我们手上有，能算准。
  Future<DiaryEntry> _withCharacters(DiaryEntry entry) async {
    final lock = entry.lock;
    if (lock == null || !lock.isLocked) return entry;
    final plain = await revealBody(entry);
    return entry.copyWith(lock: lock.copyWith(characters: plain.runes.length));
  }
}
