import 'dart:math';

/// ULID：前 10 个字符是 48 位毫秒时间戳，后 16 个字符是 80 位随机数，
/// 用 Crockford Base32 编码（去掉了容易看错的 I、L、O、U），共 26 字符。
///
/// 为什么不用自增 ID：日记要在电脑和手机两台设备上各自新建条目，
/// 自增 ID 必然撞号。ULID 全局唯一，而且字典序恰好等于时间序——
/// 按 id 排序就是按创建时间排序。
class Ulid {
  Ulid._();

  static const String alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static const int length = 26;

  static const int _timeChars = 10;
  static const int _randomChars = 16;
  static const int _timeMask = 0xFFFFFFFFFFFF; // 48 位

  static final Random _random = Random.secure();

  /// 生成一个新的 ULID。[at] 只影响时间戳部分，主要用于测试。
  static String generate({DateTime? at}) {
    final int ms =
        (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch & _timeMask;

    final buffer = StringBuffer();
    for (var i = _timeChars - 1; i >= 0; i--) {
      buffer.write(alphabet[(ms >> (5 * i)) & 0x1F]);
    }
    for (var i = 0; i < _randomChars; i++) {
      buffer.write(alphabet[_random.nextInt(32)]);
    }
    return buffer.toString();
  }

  static bool isValid(String value) {
    if (value.length != length) return false;
    for (var i = 0; i < value.length; i++) {
      if (!alphabet.contains(value[i])) return false;
    }
    return true;
  }

  /// 从 ULID 还原出生成时刻（UTC）。用于排查问题，不参与业务逻辑。
  static DateTime? timestamp(String value) {
    if (!isValid(value)) return null;
    var ms = 0;
    for (var i = 0; i < _timeChars; i++) {
      ms = (ms << 5) | alphabet.indexOf(value[i]);
    }
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
}
