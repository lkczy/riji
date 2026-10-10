import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../core/base32.dart';
import '../core/models/diary_entry.dart';
import '../core/vault_content.dart';
import '../core/vault_crypto.dart';
import '../core/vault_file.dart';
import '../platform/platform.dart' as platform;

/// 读 / 写 / 删保险库文件。默认走平台层，测试注入假实现。
typedef VaultFileReader = Future<String?> Function(String diaryRoot);
typedef VaultFileWriter = Future<void> Function(String diaryRoot, String content);
typedef VaultFileDeleter = Future<void> Function(String diaryRoot);

/// 口令 → 密钥那一步。**默认是真的 Argon2id**；测试可以换掉它。
///
/// 为什么留这个口子：Argon2id 的实现会 `await Future.delayed(1µs)` 让出事件
/// 循环（还可能开 isolate），而 `testWidgets` 跑在**假时钟**里——那个 delay
/// 永远不会到，于是界面测试会直接挂到超时（实测 10 分钟）。
/// 换掉这一小步之后，界面测试里跑的还是真的加解密、真的文件格式。
typedef VaultKeyDeriver = Future<SecretKey> Function({
  required String passphrase,
  required List<int> salt,
  required KdfParams params,
});

/// 解锁的结果。给界面一句话，而不是一个 bool——用户需要知道**为什么**不行。
class VaultUnlockResult {
  const VaultUnlockResult({required this.ok, required this.message, this.recovery = false});

  final bool ok;
  final String message;

  /// 是不是靠恢复码进来的（界面要据此提示"建议改成好记的口令"）。
  final bool recovery;
}

/// 建库的结果：成功时把恢复码交给界面去显示。
class VaultSetupResult {
  const VaultSetupResult({required this.ok, required this.message, this.recoveryCode, this.warning});

  final bool ok;
  final String message;

  /// 恢复码。**只在这里出现一次**，之后程序里再也拿不到它。
  final String? recoveryCode;

  /// 建库成功了、但有件事必须让用户知道（比如"旧文件删不掉"）。
  final String? warning;
}

/// 「日记加密」的运行时状态。
///
/// 三种状态，界面上要分得清：
///   · **未配置**：还没有 `.vault`，加密功能没开过
///   · **已锁定**：有保险库，但这会儿没有密钥——锁着的内容看不见、搜不到
///   · **已解锁**：密钥在内存里。其中又分**会话解锁**（能看能改）和
///     **按次解锁**（只为搜索解密，不能改，用完即丢）
///
/// 为什么把"按次"和"会话"分得这么细：按次解锁是给"我只是想搜一下"准备的，
/// 它绝不该顺带把"改写文件"的能力也交出去——权限只给到需要的那一档。
class VaultService extends ChangeNotifier {
  VaultService({
    required this.diaryRoot,
    VaultFileReader? readFile,
    VaultFileWriter? writeFile,
    VaultFileDeleter? deleteFile,
    VaultKeyDeriver? deriveKey,
    // 命名参数没法用 initializing formal（Dart 不允许私有的具名参数），
    // 写成 `?? 默认值` 既表达了意图，也让这条 lint 不再误报。
    KdfParams? params,
  })  : _params = params ?? KdfParams.fallback,
        _readFile = readFile ?? _defaultRead,
        _writeFile = writeFile ?? _defaultWrite,
        _deleteFile = deleteFile ?? _defaultDelete,
        _deriveKey = deriveKey ?? VaultCrypto.deriveKey;

  /// 日记根目录。保险库文件就在它下面。
  final String diaryRoot;

  final VaultFileReader _readFile;
  final VaultFileWriter _writeFile;
  final VaultFileDeleter _deleteFile;
  final VaultKeyDeriver _deriveKey;

  /// 新建锁时用的参数。从已存在的保险库读到的参数优先。
  final KdfParams _params;

  VaultFile? _file;
  SecretKey? _masterKey;
  bool _searchOnly = false;

  /// 解出来的完整明文正文，按日期缓存（`2026-10-08` → 明文）。
  ///
  /// 解锁时一次性填好：搜索是**每次按键**都要跑的，不能指望每次按键都
  /// 去解密一遍文件。未解锁时这里为空，搜索就明确说"这几篇没参与"。
  final Map<String, String> _plainBodies = <String, String>{};

  /// 上次失败的原因，供界面显示（null = 没有失败）。
  String? _lastError;

  String? get lastError => _lastError;

  /// 有没有配置过加密。
  bool get isConfigured => _file != null;

  /// 现在有没有密钥（会话或按次都算）。
  bool get isUnlocked => _masterKey != null;

  /// 是不是"只为搜索"的按次解锁。
  bool get isSearchRevealed => _masterKey != null && _searchOnly;

  /// 能不能改文件（锁上/解开某天、某段）。按次解锁**不能**。
  bool get canWrite => _masterKey != null && !_searchOnly;

  /// 已解出来、还在缓存里的天数（界面显示"已解锁 N 天"）。
  int get revealedCount => _plainBodies.length;

  KdfParams get params => _file?.params ?? _params;

  VaultFile? get file => _file;

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 读保险库文件。启动时调一次。
  ///
  /// 文件存在但**解析不了**时：`isConfigured` 仍然是 true（文件在！），
  /// 但记下错误——界面要说"保险库文件坏了"，绝不能显示成"没加密"，
  /// 那会让用户以为自己的日记是明文、于是放心地做别的事。
  Future<void> load() async {
    _masterKey = null;
    _searchOnly = false;
    _plainBodies.clear();
    _lastError = null;

    final text = await _readFile(diaryRoot);
    if (text == null || text.trim().isEmpty) {
      _file = null;
      return;
    }
    final parsed = VaultFile.tryParse(text);
    _file = parsed;
    if (parsed == null) {
      _lastError = '保险库文件读不出来（内容损坏或被改过）。锁着的日记需要它才能打开。';
    }
    notifyListeners();
  }

  /// 建库：口令包裹一个全新的随机主密钥，写 `.vault`，返回恢复码。
  Future<VaultSetupResult> setUp(String passphrase) async {
    if (passphrase.trim().isEmpty) {
      return const VaultSetupResult(ok: false, message: '口令不能是空的。');
    }
    if (isConfigured) {
      return const VaultSetupResult(ok: false, message: '已经有保险库了。');
    }

    final masterKey = VaultCrypto.newMasterKey();
    final salt = VaultCrypto.newSalt();
    final kek = await _deriveKey(
      passphrase: passphrase,
      salt: base32Decode(salt),
      params: _params,
    );
    final wrapped = await VaultCrypto.seal(
      key: kek,
      plaintext: _keyToText(masterKey),
      aad: VaultCrypto.aad(date: '', kind: 'vault'),
    );
    final check = await VaultCrypto.keyCheck(masterKey);

    final file = VaultFile(
      salt: salt,
      params: _params,
      wrapped: wrapped,
      check: check,
      created: DateTime.now(),
    );

    try {
      await _writeFile(diaryRoot, file.encode());
    } catch (error) {
      return VaultSetupResult(ok: false, message: '写保险库文件失败：$error');
    }

    _file = file;
    _masterKey = masterKey;
    _searchOnly = false;
    notifyListeners();

    return VaultSetupResult(
      ok: true,
      message: '加密已开启：以后锁上的内容需要口令才能看。',
      recoveryCode: VaultCrypto.recoveryCode(masterKey),
      warning: '保险库文件在日记目录里（${VaultFile.fileName}）。备份和同步一定要带上它，'
          '否则那些密文谁也解不开。',
    );
  }

  /// 解锁。用口令或恢复码都行。
  ///
  /// [forSearchOnly] 为 true 时只给"解密来搜索"的权限，不能改写文件。
  Future<VaultUnlockResult> unlock(
    String secret, {
    required bool isRecoveryCode,
    bool forSearchOnly = false,
  }) async {
    final file = _file;
    if (file == null) {
      return const VaultUnlockResult(ok: false, message: '还没有保险库，先在「日记加密」里设置口令。');
    }

    SecretKey masterKey;
    if (isRecoveryCode) {
      try {
        masterKey = VaultCrypto.masterKeyFromRecoveryCode(secret);
      } on FormatException catch (error) {
        return VaultUnlockResult(ok: false, message: error.message);
      }
    } else {
      final kek = await _deriveKey(
        passphrase: secret,
        salt: base32Decode(file.salt),
        params: file.params,
      );
      try {
        final text = await VaultCrypto.open(
          key: kek,
          sealed: file.wrapped,
          aad: VaultCrypto.aad(date: '', kind: 'vault'),
        );
        masterKey = _keyFromText(text);
      } on VaultAuthException {
        // 口令错和"保险库文件被改过"在密码学上分不开，但对用户来说
        // 完全是两件事，所以把两种可能都说出来，而不是只甩一句"失败"。
        return const VaultUnlockResult(
          ok: false,
          message: '口令不对。（如果你确定口令没错，那就是保险库文件被改过或损坏了——'
              '这种时候恢复码还能用。）',
        );
      }
    }

    if (!await VaultCrypto.verifyKeyCheck(masterKey, file.check)) {
      return const VaultUnlockResult(
        ok: false,
        message: '密钥对不上：保险库文件里的校验值不匹配，文件可能被改过。',
      );
    }

    _masterKey = masterKey;
    _searchOnly = forSearchOnly;
    _lastError = null;
    notifyListeners();
    return VaultUnlockResult(
      ok: true,
      recovery: isRecoveryCode,
      message: forSearchOnly ? '已解锁（只为这次搜索）。' : '已解锁。',
    );
  }

  /// 关闭加密：删掉保险库文件。
  ///
  /// **必须先把所有锁着的天解开并保存**（调用方负责），否则那些密文就永远
  /// 解不开了——所以这个函数只在 [canWrite] 且调用方已经逐个解开之后才该被调用，
  /// 界面上也必须先把这句话说清楚。
  Future<VaultSetupResult> disableVault() async {
    if (!isConfigured) {
      return const VaultSetupResult(ok: false, message: '现在没有开加密。');
    }
    try {
      await _deleteFile(diaryRoot);
    } catch (error) {
      return VaultSetupResult(ok: false, message: '删保险库文件失败：$error');
    }
    _file = null;
    _masterKey = null;
    _searchOnly = false;
    _plainBodies.clear();
    notifyListeners();
    return const VaultSetupResult(
      ok: true,
      message: '加密已关闭。',
      warning: '如果还有哪一天是整天锁着的，它现在就是一串解不开的密文了——'
          '关之前必须先把那些天解开。',
    );
  }

  /// 锁上：丢掉内存里的密钥和所有明文。
  void lock() {
    if (_masterKey == null && _plainBodies.isEmpty) return;
    _masterKey = null;
    _searchOnly = false;
    _plainBodies.clear();
    notifyListeners();
  }

  /// 按次解锁用完之后调它：只丢掉"跟搜索有关"的东西，会话解锁不受影响。
  void releaseSearchReveal() {
    if (!_searchOnly) return;
    lock();
  }

  // ---------------------------------------------------------------------------
  // 读：搜索与预览
  // ---------------------------------------------------------------------------

  /// 这一天参与搜索的正文。
  ///
  /// 返回 **null 表示"这篇没参与"**（还锁着、或者解不开）。界面必须把
  /// 这个数字说出来——"搜不到"和"没搜"是两件完全不同的事。
  String? searchText(DiaryEntry entry) {
    if (!entry.isLocked) return entry.body;
    return _plainBodies[_dateKey(entry)];
  }

  /// 有没有哪一天是"锁着但没解出来"的（用来算"另有 N 篇未参与"）。
  bool participatesInSearch(DiaryEntry entry) =>
      !entry.isLocked || _plainBodies.containsKey(_dateKey(entry));

  /// 把锁着的正文解进缓存。解锁之后由调用方把当前所有条目交进来。
  ///
  /// 返回解不开的那些天（文件坏了、或者不是用这个密钥锁的）。
  Future<List<DiaryEntry>> prepare(Iterable<DiaryEntry> entries) async {
    final failed = <DiaryEntry>[];
    final content = _content;
    if (content == null) return failed;

    for (final entry in entries) {
      if (!entry.isLocked) continue;
      if (_plainBodies.containsKey(_dateKey(entry))) continue;
      try {
        _plainBodies[_dateKey(entry)] = await content.revealBody(entry);
      } on VaultAuthException {
        failed.add(entry);
      }
    }
    if (failed.isNotEmpty) {
      _lastError = '有 ${failed.length} 天的内容解不开（文件损坏，或者不是用这个密钥锁的）。';
    }
    notifyListeners();
    return failed;
  }

  /// 重新算一遍这一天的完整字数，写回锁里。
  ///
  /// 只在**已解锁**（能解开被锁的段）时才可能算准；算不出来就抛异常，
  /// 由调用方决定保留旧值。
  Future<DiaryEntry> refreshCharacters(DiaryEntry entry) async {
    final content = _requireContent();
    final lock = entry.lock;
    if (lock == null || !lock.isLocked) return entry;
    final plain = await content.revealBody(entry);
    final updated = lock.copyWith(characters: plain.runes.length);
    if (updated.characters == lock.characters) return entry;
    return entry.copyWith(lock: updated);
  }

  /// 读这一天的完整明文（**只读**，绝不写回编辑框）。
  ///
  /// 按次解锁（只为搜索）也允许用——它本来就有密钥，只是不许改写文件。
  /// 整天锁的那天没有黑条可点，所以必须走这条路才看得到内容。
  Future<String> revealDayText(DiaryEntry entry) {
    final key = _masterKey;
    if (key == null) {
      throw const VaultAuthException('还没有解锁。');
    }
    return VaultContent(key: key, params: params).revealBody(entry);
  }

  /// 看某一段黑条的原文（只读浮窗用）。
  ///
  /// 下面这几个都写成 `async`：这样"没解锁"是一个**失败的 Future**，
  /// 而不是一个在 Future 之前就冒出来的同步异常。两种都叫"抛异常"，
  /// 但调用方（尤其是 `expectLater` 这类）只能接住其中一种。
  Future<String> revealRedaction(DiaryEntry entry, int lineIndex) async =>
      _requireContent().revealRedaction(entry, lineIndex);

  // ---------------------------------------------------------------------------
  // 写：上锁 / 解锁
  // ---------------------------------------------------------------------------

  Future<DiaryEntry> lockWholeDay(DiaryEntry entry) async =>
      _requireContent().lockWholeDay(entry);

  Future<DiaryEntry> unlockWholeDay(DiaryEntry entry) async =>
      _requireContent().unlockWholeDay(entry);

  Future<DiaryEntry> lockLine(DiaryEntry entry, int lineIndex) async =>
      _requireContent().lockLine(entry, lineIndex);

  Future<DiaryEntry> unlockLine(DiaryEntry entry, int lineIndex) async =>
      _requireContent().unlockLine(entry, lineIndex);

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  VaultContent _requireContent() {
    final key = _masterKey;
    if (key == null) {
      throw const VaultAuthException('还没有解锁。锁上和解除都需要先解锁。');
    }
    if (_searchOnly) {
      throw const VaultAuthException('这是"只为搜索"的解锁状态，不能改写文件。');
    }
    return VaultContent(key: key, params: params);
  }

  VaultContent? get _content {
    final key = _masterKey;
    if (key == null) return null;
    return VaultContent(key: key, params: params);
  }

  static String _dateKey(DiaryEntry entry) =>
      '${entry.date.year.toString().padLeft(4, '0')}-'
      '${entry.date.month.toString().padLeft(2, '0')}-'
      '${entry.date.day.toString().padLeft(2, '0')}';

  /// 主密钥在文件里以什么形式存。用 base32 而不是裸字节：
  /// 万一以后要手工检查，也还能看懂。
  static String _keyToText(SecretKey key) => base32Encode(key.bytes);

  static SecretKey _keyFromText(String text) =>
      SecretKeyData(base32Decode(text));

  static Future<String?> _defaultRead(String root) =>
      platform.readVaultFile(root);

  static Future<void> _defaultWrite(String root, String content) =>
      platform.writeVaultFile(root, content);

  static Future<void> _defaultDelete(String root) =>
      platform.deleteVaultFile(root);
}

