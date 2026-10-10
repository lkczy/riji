/// 日记加密的密码学内核。**纯逻辑：不碰文件系统、不认识日记格式。**
///
/// 这一层只做四件事：口令派生、加密、解密、钥匙校验。所有"什么时候加密、
/// 加密哪一段、写到哪个字段"的问题都在别处（`lib/data` 和 `lib/state`），
/// 因为那些是最该被断言的部分，而真跑密码学又太慢。
///
/// 算法（见 `docs/加密设计.md`）：
///   · XChaCha20-Poly1305 —— AEAD，192 位随机 nonce，纯 Dart 下比软件 AES 快
///   · Argon2id —— 口令派生，参数随密文走（文件自描述）
///
/// ⚠️ **明确只用 `package:cryptography/dart.dart` 里的纯 Dart 实现**
/// （`DartArgon2id` / `DartXchacha20`），不用 `Cryptography.instance`。
/// 本项目的硬规矩是零插件：那个工厂会去挑平台实现，挑到原生实现就可能在
/// Windows 上要求开发者模式（详见 `docs/开发须知.md` §6）。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'base32.dart';

/// 密文格式版本。换算法就是 v2，旧文件继续能读。
const String vaultVersion = 'v1';

/// XChaCha20 的 nonce 长度（192 位）。
const int _nonceLength = 24;

/// Poly1305 的认证标签长度。
const int _macLength = 16;

/// 主密钥长度。
const int masterKeyLength = 32;

/// 盐长度。
const int saltLength = 16;

/// Argon2id 参数。存进 `.vault` 和每个 `.md` 的 `enc-params` 里。
///
/// 存进**每个文件**是为了"文件自描述"：把 `.md` 单独拷到另一台机器，
/// 有口令就能打开，不需要另外还记得当时的参数。
class KdfParams {
  const KdfParams({
    required this.memoryKib,
    required this.iterations,
    required this.parallelism,
  });

  /// 内存开销，单位是 **1 kB 块**（Argon2 的惯例）。
  final int memoryKib;
  final int iterations;
  final int parallelism;

  /// 默认参数。Argon2id 要"慢到值得"，但解锁是每次开程序都要做的事——
  /// 目标是在这台机器上约 0.3–1 秒（实现时实测过）。
  static const KdfParams fallback =
      KdfParams(memoryKib: 64 * 1024, iterations: 3, parallelism: 1);

  /// 读别人给的文件时要设上下限：`enc-params` 是可以被改的，
  /// 不设限的话一行 `m=4096MiB` 就能把内存撑爆。
  static const int minMemoryKib = 8 * 1024;
  static const int maxMemoryKib = 512 * 1024;
  static const int maxIterations = 16;
  static const int maxParallelism = 8;

  /// 写进 front matter 的人可读形式：`m=64MiB,t=3,p=1`。
  String encode() => 'm=${memoryKib ~/ 1024}MiB,t=$iterations,p=$parallelism';

  /// 解析 `m=64MiB,t=3,p=1`。**任何一项越界或不认识都返回 null**，
  /// 由调用方决定怎么办（一般是明确报"这个文件的参数不合法"，不猜）。
  static KdfParams? tryParse(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    int? memory;
    int? iterations;
    int? parallelism;
    for (final part in text.split(',')) {
      final kv = part.trim().split('=');
      if (kv.length != 2) return null;
      final key = kv[0].trim().toLowerCase();
      final raw = kv[1].trim().toLowerCase();
      if (key == 'm') {
        final match = RegExp(r'^(\d+)(kib|mib)?$').firstMatch(raw);
        if (match == null) return null;
        final value = int.tryParse(match.group(1)!);
        if (value == null) return null;
        memory = (match.group(2) == 'mib') ? value * 1024 : value;
      } else if (key == 't') {
        iterations = int.tryParse(raw);
      } else if (key == 'p') {
        parallelism = int.tryParse(raw);
      } else {
        return null;
      }
    }
    if (memory == null || iterations == null || parallelism == null) return null;
    if (memory < minMemoryKib || memory > maxMemoryKib) return null;
    if (iterations < 1 || iterations > maxIterations) return null;
    if (parallelism < 1 || parallelism > maxParallelism) return null;
    return KdfParams(
      memoryKib: memory,
      iterations: iterations,
      parallelism: parallelism,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'algo': 'argon2id',
        'm': memoryKib,
        't': iterations,
        'p': parallelism,
      };

  /// 从 `.vault` 的 JSON 里读。同样**宁可不认，也不猜**。
  static KdfParams? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['algo'] != 'argon2id') return null;
    final memory = json['m'];
    final iterations = json['t'];
    final parallelism = json['p'];
    if (memory is! int || iterations is! int || parallelism is! int) return null;
    if (memory < minMemoryKib || memory > maxMemoryKib) return null;
    if (iterations < 1 || iterations > maxIterations) return null;
    if (parallelism < 1 || parallelism > maxParallelism) return null;
    return KdfParams(
      memoryKib: memory,
      iterations: iterations,
      parallelism: parallelism,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is KdfParams &&
      other.memoryKib == memoryKib &&
      other.iterations == iterations &&
      other.parallelism == parallelism;

  @override
  int get hashCode => Object.hash(memoryKib, iterations, parallelism);

  @override
  String toString() => encode();
}

/// 加密失败的**唯一**一种解释：要么口令（密钥）不对，要么内容被改过。
///
/// 故意不细分：AEAD 校验失败时，密码学上本来就分不出这两者。
/// "口令错"和"文件坏"的区别靠**先验钥匙校验值**来分（见 [keyCheck]）。
class VaultAuthException implements Exception {
  const VaultAuthException([this.detail]);

  final String? detail;

  @override
  String toString() =>
      '解密失败（口令不对，或者内容被改过）${detail == null ? '' : '：$detail'}';
}

/// 密码学内核。所有方法都是静态的、无状态的——密钥由调用方拿着。
abstract final class VaultCrypto {
  static final DartXchacha20 _cipher = DartXchacha20.poly1305Aead();

  /// 口令 + 盐 + 参数 → 32 字节密钥（用来**包裹**主密钥，不直接加密日记）。
  static Future<SecretKey> deriveKey({
    required String passphrase,
    required List<int> salt,
    required KdfParams params,
  }) async {
    final argon2 = DartArgon2id(
      memory: params.memoryKib,
      iterations: params.iterations,
      parallelism: params.parallelism,
      hashLength: masterKeyLength,
    );
    return argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  /// 加密一段文本，返回可以直接写进 front matter 的字符串。
  ///
  /// 形态：`v1:<base64(nonce || mac || ciphertext)>`——**带版本前缀**，
  /// 这样人肉看一眼就知道这是密文、哪一版，而不是一串随机 base64。
  static Future<String> seal({
    required SecretKey key,
    required String plaintext,
    required List<int> aad,
  }) async {
    final box = await _cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      aad: aad,
    );
    final bytes = Uint8List(_nonceLength + _macLength + box.cipherText.length)
      ..setRange(0, _nonceLength, box.nonce)
      ..setRange(_nonceLength, _nonceLength + _macLength, box.mac.bytes)
      ..setRange(_nonceLength + _macLength, _nonceLength + _macLength + box.cipherText.length, box.cipherText);
    return '$vaultVersion:${base64.encode(bytes)}';
  }

  /// 解密。任何不正常（格式不对、长度不对、校验失败）都抛
  /// [VaultAuthException]，**绝不返回半个结果**。
  static Future<String> open({
    required SecretKey key,
    required String sealed,
    required List<int> aad,
  }) async {
    final separator = sealed.indexOf(':');
    if (separator <= 0) {
      throw const VaultAuthException('密文格式不对');
    }
    if (sealed.substring(0, separator) != vaultVersion) {
      throw VaultAuthException(
        '密文版本是 ${sealed.substring(0, separator)}，这个版本的程序不认识',
      );
    }
    final Uint8List bytes;
    try {
      bytes = base64.decode(sealed.substring(separator + 1));
    } on FormatException {
      throw const VaultAuthException('密文不是合法的 base64');
    }
    if (bytes.length < _nonceLength + _macLength) {
      throw const VaultAuthException('密文太短，文件可能被截断了');
    }
    final box = SecretBox(
      bytes.sublist(_nonceLength + _macLength),
      nonce: bytes.sublist(0, _nonceLength),
      mac: Mac(bytes.sublist(_nonceLength, _nonceLength + _macLength)),
    );
    try {
      final clear = await _cipher.decrypt(box, secretKey: key, aad: aad);
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      throw const VaultAuthException();
    }
  }

  /// 钥匙校验值：用主密钥加密一个固定串。
  ///
  /// 存在的意义是**把"口令错"和"这天文件坏了"分开**：
  /// 口令错 → `.vault` 里的主密钥解不开（或这里验不过）；验过了还解不开
  /// 某一天 → 是那天的文件出了问题。
  static Future<String> keyCheck(SecretKey key) => seal(
        key: key,
        plaintext: _keyCheckPlaintext,
        aad: aad(date: '', kind: 'check'),
      );

  static Future<bool> verifyKeyCheck(SecretKey key, String check) async {
    try {
      final text = await open(key: key, sealed: check, aad: aad(date: '', kind: 'check'));
      return text == _keyCheckPlaintext;
    } on VaultAuthException {
      return false;
    }
  }

  static const String _keyCheckPlaintext = 'riji-vault-check';

  /// 把"这段密文属于哪天、干什么用的"绑进 AAD。
  ///
  /// 于是把某一天的 `enc-body` 剪到另一天、或者把某段黑条的密文换到
  /// 另一段，都会**解不开**，而不是悄悄解出别人的内容。
  static List<int> aad({required String date, required String kind}) =>
      utf8.encode('riji/$vaultVersion/$kind/$date');

  /// 密码学安全的随机字节。
  static Uint8List randomBytes(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  /// 新盐（base32，方便写进 JSON 也方便人看）。
  static String newSalt() => base32Encode(randomBytes(saltLength));

  /// 新主密钥 → 恢复码就是它的 base32 分组形式，见 [recoveryCode]。
  static SecretKey newMasterKey() => SecretKeyData(randomBytes(masterKeyLength));

  /// 主密钥 → 给人抄的恢复码。
  static String recoveryCode(SecretKey key) =>
      groupBase32(base32Encode(key.bytes));

  /// 恢复码 → 主密钥。抄错了要**明确报错**，不能悄悄解出别的密钥
  /// （那会表现成"恢复码无效"，让人以为是自己记错了）。
  static SecretKey masterKeyFromRecoveryCode(String code) {
    final bytes = base32Decode(code);
    if (bytes.length != masterKeyLength) {
      throw FormatException(
        '恢复码长度不对：应该是 ${masterKeyLength * 8 ~/ 5} 个字符，'
        '现在是 ${bytes.length} 个字节（${base32Encode(bytes).length} 个字符）',
      );
    }
    return SecretKeyData(bytes);
  }
}

/// 让 `SecretKey.bytes` 好用一点（`cryptography` 只给了异步的 extractBytes）。
extension SecretKeyBytes on SecretKey {
  Uint8List get bytes {
    final key = this;
    if (key is SecretKeyData) return Uint8List.fromList(key.bytes);
    throw ArgumentError('只支持 SecretKeyData（本项目只从自己的代码构造密钥）');
  }
}
