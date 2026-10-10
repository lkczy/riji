import 'dart:convert';

import 'vault_crypto.dart';

/// `<日记目录>/.vault` 的内容。
///
/// 为什么放在**日记目录里**、而不是 `%APPDATA%`：备份和同步要带上它。
/// 一份没有 `.vault` 的备份，就是一包谁都解不开的密文——那等于备份失效。
///
/// 它本身**不含任何秘密**：里面只有盐、KDF 参数、被口令包裹过的主密钥、
/// 和一段校验值。没有口令（也没有恢复码）的人拿到它什么也做不了。
class VaultFile {
  const VaultFile({
    required this.salt,
    required this.params,
    required this.wrapped,
    required this.check,
    this.version = vaultVersion,
    this.created,
  });

  /// 文件名。以点开头，所以日记扫描不会把它当成条目。
  static const String fileName = '.vault';

  final String version;

  /// Argon2id 的盐（base32）。
  final String salt;

  final KdfParams params;

  /// 用口令派生的密钥（KEK）包裹后的主密钥。
  final String wrapped;

  /// 钥匙校验值：用主密钥加密的固定串。用来把"口令错"和"文件坏"分开。
  final String check;

  final DateTime? created;

  Map<String, Object?> toJson() => <String, Object?>{
        'v': version,
        'kdf': <String, Object?>{
          ...params.toJson(),
          'salt': salt,
        },
        'wrapped': wrapped,
        'check': check,
        if (created != null) 'created': created!.toIso8601String(),
      };

  /// 写成文件内容。缩进 2 格：这份文件人是会去看的（排查问题、手工恢复）。
  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 解析。**任何一处不合法都返回 null**，绝不猜。
  ///
  /// 宁可直接说"这个保险库文件坏了"，也不要拿半个参数去派生密钥——
  /// 那样只会得到一个"口令明明是对的、却怎么也解不开"的鬼故事。
  static VaultFile? tryParse(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;

    final version = decoded['v']?.toString().trim();
    if (version == null || version.isEmpty) return null;

    final kdf = decoded['kdf'];
    if (kdf is! Map) return null;
    final params = KdfParams.fromJson(kdf);
    if (params == null) return null;

    final salt = kdf['salt']?.toString().trim() ?? '';
    final wrapped = decoded['wrapped']?.toString().trim() ?? '';
    final check = decoded['check']?.toString().trim() ?? '';
    if (salt.isEmpty || wrapped.isEmpty || check.isEmpty) return null;

    DateTime? created;
    final rawCreated = decoded['created']?.toString();
    if (rawCreated != null) created = DateTime.tryParse(rawCreated);

    return VaultFile(
      version: version,
      salt: salt,
      params: params,
      wrapped: wrapped,
      check: check,
      created: created,
    );
  }

  @override
  String toString() =>
      'VaultFile($version, ${params.encode()}, 建于 ${created ?? '未知'})';
}
