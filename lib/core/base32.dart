/// Crockford base32：给**人要抄下来**的字符串用的编码。
///
/// 为什么不用标准 base32（RFC 4648）：它同时包含 `I`/`1`、`O`/`0`，手抄时
/// 几乎必错。Crockford 的字母表**去掉了 I、L、O、U**，并且规定
/// `I`/`L` 读作 `1`、`O` 读作 `0`——抄错一个字母也能救回来。
///
/// 为什么不用 24 个英文单词的助记词：那要多维护一份 2048 词的词表，
/// 而且中文用户抄英文单词未必比抄 32 进制稳。恢复码只需要**抄一次、
/// 万一用得上时能准确输进去**，这两条它都满足。
///
/// 这一层不是加密，只是编码：**认不出来的字符要明确报错**，不能悄悄跳过
/// （跳过就等于把"抄错了一位"变成"解不开但不知道哪儿错了"）。
library;

/// Crockford 字母表。顺序就是 0–31。
const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// 手抄容错：这些字符按 Crockford 的规定归一化。
const Map<String, String> _aliases = <String, String>{
  'I': '1',
  'L': '1',
  'O': '0',
};

/// 把字节编码成 base32 字符串（**不带填充**，分组交给调用方）。
String base32Encode(List<int> bytes) {
  if (bytes.isEmpty) return '';
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final byte in bytes) {
    buffer = (buffer << 8) | (byte & 0xff);
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(_alphabet[(buffer >> bits) & 0x1f]);
    }
  }
  // 末尾不足 5 位的，左边补 0 凑满
  if (bits > 0) {
    out.write(_alphabet[(buffer << (5 - bits)) & 0x1f]);
  }
  return out.toString();
}

/// 解码。忽略连字符、空格、换行**和大小写**；其余认不出来的字符抛
/// [FormatException]（带上位置，方便对着抄错的地方找）。
List<int> base32Decode(String text) {
  final bytes = <int>[];
  var buffer = 0;
  var bits = 0;
  for (var i = 0; i < text.length; i++) {
    final raw = text[i];
    if (raw == '-' || raw == ' ' || raw == '\n' || raw == '\r' || raw == '\t') {
      continue;
    }
    final upper = raw.toUpperCase();
    final char = _aliases[upper] ?? upper;
    final value = _alphabet.indexOf(char);
    if (value < 0) {
      throw FormatException('第 ${i + 1} 个字符抄错了：「$raw」', text, i);
    }
    buffer = (buffer << 5) | value;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      bytes.add((buffer >> bits) & 0xff);
    }
  }
  return bytes;
}

/// 每 4 个字符插一个连字符，方便照着抄、也方便读回来核对位数。
String groupBase32(String text, {int size = 4}) {
  final out = StringBuffer();
  for (var i = 0; i < text.length; i += size) {
    if (i > 0) out.write('-');
    out.write(text.substring(i, i + size > text.length ? text.length : i + size));
  }
  return out.toString();
}
