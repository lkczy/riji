/// 加密相关测试共用的假件。
///
/// 只做两件事：把保险库文件放在内存里（一个字节都不落盘），以及把
/// "口令 → 密钥"换成一个可预测的实现——真 Argon2id 每次要 0.7 秒，而且
/// 在 `testWidgets` 的假时钟下会直接挂住（见 `vault_service.dart` 里
/// [VaultKeyDeriver] 那段注释）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:riji/core/models/diary_entry.dart';
import 'package:riji/core/vault_crypto.dart';
import 'package:riji/state/vault_service.dart';

/// 测试用的小参数（真按 8 MiB / 1 轮，够快又不至于没有）。
const KdfParams fastKdf = KdfParams(
  memoryKib: 8 * 1024,
  iterations: 1,
  parallelism: 1,
);

/// 可预测的"口令 → 密钥"：同样的口令给同样的密钥，不同口令给不同密钥。
///
/// 它**不是密码学安全的**，只用于测试——真实现是 Argon2id（见生产代码）。
Future<SecretKey> predictableDeriveKey({
  required String passphrase,
  required List<int> salt,
  required KdfParams params,
}) async {
  final bytes = Uint8List(32);
  final raw = utf8.encode(passphrase);
  for (var i = 0; i < 32; i++) {
    bytes[i] = (i < raw.length ? raw[i] : 0x5a) ^ salt[i % salt.length];
  }
  return SecretKeyData(bytes);
}

/// 内存里的 `.vault`。
class FakeVaultFiles {
  String? content;
  int writes = 0;
  int deletes = 0;
  bool failWrite = false;

  Future<String?> read(String root) async => content;

  Future<void> write(String root, String text) async {
    if (failWrite) throw const VaultWriteFailure();
    writes++;
    content = text;
  }

  Future<void> delete(String root) async {
    deletes++;
    content = null;
  }
}

class VaultWriteFailure implements Exception {
  const VaultWriteFailure();
  @override
  String toString() => '磁盘满了（测试里故意造的）';
}

/// 造一个接到假文件上的保险库。
VaultService makeVault(FakeVaultFiles files, {String root = r'D:\someone\MyData'}) =>
    VaultService(
      diaryRoot: root,
      params: fastKdf,
      deriveKey: predictableDeriveKey,
      readFile: files.read,
      writeFile: files.write,
      deleteFile: files.delete,
    );

/// 一条指定日期的日记（测试里用固定日期，免得跟着"今天"漂）。
DiaryEntry entryFor(DateTime date, String body) => DiaryEntry(
      id: '01M4A3EMFRK1XZN0GD5GFEMSDR',
      date: date,
      created: date,
      updated: date,
      device: 'test',
      body: body,
    );

bool sameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
