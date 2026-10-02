import 'package:yaml/yaml.dart';

import 'day.dart';
import 'models/diary_entry.dart';

/// Markdown 文件与 [DiaryEntry] 之间的转换。
///
/// 设计上的两条硬性要求：
///
/// 1. **解码必须宽容。** 用户可以拿任意编辑器手写一个 `2026-02-14.md`，
///    哪怕完全没有 front matter、或者 front matter 写坏了，正文也必须能读出来。
///    宁可少几个元数据字段，也绝不能因为解析失败就让用户看不见自己写的东西。
/// 2. **正文必须原样保留。** 不做 trim、不转义、不重排。
class DiaryCodec {
  DiaryCodec._();

  static const String _delimiter = '---';

  // ---------------------------------------------------------------------------
  // 编码
  // ---------------------------------------------------------------------------

  /// 序列化为一个完整的 Markdown 文件内容。
  ///
  /// 一律使用 `\n` 换行（即使当前是 Windows）：这样 git diff 干净，
  /// 跨设备同步时也不会因为 CRLF/LF 差异产生假冲突。
  static String encode(DiaryEntry entry) {
    final buffer = StringBuffer()
      ..writeln(_delimiter)
      ..writeln('id: ${_scalar(entry.id)}')
      ..writeln('date: ${_scalar(formatIsoDate(entry.date))}')
      ..writeln('created: ${_scalar(formatIso8601WithOffset(entry.created))}')
      ..writeln('updated: ${_scalar(formatIso8601WithOffset(entry.updated))}')
      ..writeln('device: ${_scalar(entry.device)}');

    final mood = entry.mood;
    if (mood != null && mood.trim().isNotEmpty) {
      buffer.writeln('mood: ${_scalar(mood.trim())}');
    }

    final weather = entry.weather;
    if (weather != null && weather.trim().isNotEmpty) {
      buffer.writeln('weather: ${_scalar(weather.trim())}');
    }

    if (entry.tags.isEmpty) {
      buffer.writeln('tags: []');
    } else {
      buffer.writeln('tags:');
      for (final tag in entry.tags) {
        buffer.writeln('  - ${_scalar(tag)}');
      }
    }

    // 不认识的字段原样写回。顺序放在已知字段之后，
    // 这样将来新版本加的字段不会打乱前面几行的位置。
    final extra = entry.extraFrontMatter.trim();
    if (extra.isNotEmpty) {
      buffer
        ..write(extra)
        ..writeln();
    }

    // 分隔符之后空一行，正文原样跟上
    buffer
      ..writeln(_delimiter)
      ..writeln()
      ..write(entry.body);

    return buffer.toString();
  }

  /// 全数字的字符串必须加引号，否则 YAML 会把它解析成整数。
  /// ULID 恰好是字母数字混合、可能**纯数字**的，所以这条不是理论风险。
  static final RegExp _allDigits = RegExp(r'^\d+$');
  static final RegExp _plainSafe =
      RegExp(r'^[A-Za-z0-9\u4e00-\u9fff][A-Za-z0-9\u4e00-\u9fff _.\-]*$');
  static const Set<String> _reservedWords = {
    'true', 'false', 'yes', 'no', 'on', 'off', 'null', 'none', '~',
  };

  static String _scalar(String value) {
    if (_allDigits.hasMatch(value)) return '"$value"';
    if (_plainSafe.hasMatch(value) && !_reservedWords.contains(value.toLowerCase())) {
      return value;
    }
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\r', r'\r')
        .replaceAll('\n', r'\n');
    return '"$escaped"';
  }

  // ---------------------------------------------------------------------------
  // 解码
  // ---------------------------------------------------------------------------

  /// 解析文件内容。
  ///
  /// [fallbackDate] 通常来自文件名，[fallbackTimestamp] 通常来自文件修改时间，
  /// [fallbackDevice] 通常来自当前设备名。三者保证任何文件都能解析出条目。
  static DiaryEntry decode(
    String content, {
    required DateTime fallbackDate,
    required DateTime fallbackTimestamp,
    required String fallbackDevice,
  }) {
    final split = _split(content);

    Map<dynamic, dynamic>? frontMatter;
    var extraFrontMatter = '';
    final raw = split.frontMatter;
    if (raw != null && raw.trim().isNotEmpty) {
      final normalized = raw.replaceAll('\r\n', '\n');
      try {
        final parsed = loadYaml(normalized);
        if (parsed is Map) {
          frontMatter = parsed;
          extraFrontMatter = _extractUnknown(normalized);
        } else {
          // 能解析但不是映射（比如整块就是一个字符串），同样不能丢
          extraFrontMatter = _commentOut(normalized);
        }
      } catch (_) {
        // YAML 写坏了不是灾难：正文照读，元数据退回兜底值。
        // 但用户写下的原文绝不能消失，所以注释化保留。
        extraFrontMatter = _commentOut(normalized);
      }
    }

    String? text(String key) {
      final value = frontMatter?[key];
      if (value == null) return null;
      final result = value.toString().trim();
      return result.isEmpty ? null : result;
    }

    final date =
        parseIsoDate(text('date') ?? '') ?? dateOnly(fallbackDate);
    final created = parseTimestamp(text('created') ?? '') ?? fallbackTimestamp;
    final updated = parseTimestamp(text('updated') ?? '') ?? fallbackTimestamp;
    final device = text('device') ?? fallbackDevice;
    final id = text('id') ?? DiaryEntry.legacyIdFor(date);
    final mood = text('mood');
    final weather = text('weather');
    final tags = _parseTags(frontMatter?['tags']);

    return DiaryEntry(
      id: id,
      date: dateOnly(date),
      created: created,
      updated: updated,
      device: device,
      body: split.body,
      mood: mood,
      weather: weather,
      tags: tags,
      extraFrontMatter: extraFrontMatter,
    );
  }

  /// 本程序认识的 front matter 键。其余的一律原样保留。
  ///
  /// **加新字段时必须同时加到这里。** 漏加的话，新字段会被"未知字段保留"
  /// 机制再写一遍，文件里就会出现两个同名键（`weather:` 出现两次）。
  /// 这是这套前向兼容设计唯一的陷阱，`diary_codec_test.dart` 里有测试守着。
  static const Set<String> knownFrontMatterKeys = <String>{
    'id',
    'date',
    'created',
    'updated',
    'device',
    'mood',
    'weather',
    'tags',
  };

  static final RegExp _topLevelKey = RegExp(r'^([A-Za-z0-9_\-]+):');

  /// 挑出「不认识的键」对应的原始行，逐字节保留。
  ///
  /// 为什么保留原文而不是解析后重新生成：
  /// 重新序列化会丢注释、丢格式，也可能丢嵌套结构。只做行归属判断、
  /// 不做重新生成，是这里唯一不会丢东西的做法。
  static String _extractUnknown(String frontMatter) {
    final kept = <String>[];
    var keeping = false;

    for (final line in frontMatter.split('\n')) {
      // 注释一律保留：它可能是用户手写的说明，也可能是我们上一轮
      // 注释化保存下来的原文。丢了注释，用户会以为程序在乱改他的文件。
      if (line.trimLeft().startsWith('#')) {
        kept.add(line);
        continue;
      }

      // 顶层键：行首没有缩进且形如 `key:`。
      // 缩进行（列表项、嵌套值）不匹配，自然归给上一个键。
      final match = _topLevelKey.firstMatch(line);
      if (match != null) {
        keeping = !knownFrontMatterKeys.contains(match.group(1));
      }
      if (keeping) kept.add(line);
    }

    while (kept.isNotEmpty && kept.last.trim().isEmpty) {
      kept.removeLast();
    }
    return kept.join('\n');
  }

  /// 把无法解析的前言原文变成注释行。
  ///
  /// 两个都不亏的选择：直接原样保留会让 loadYaml 永远失败，等于把这份文件的
  /// 元数据永久毒化（连 id 都读不出来）；直接丢弃则会让用户手写的东西凭空消失。
  /// 注释化既留了痕，文件也重新变得可解析。
  static String _commentOut(String frontMatter) {
    final buffer = StringBuffer('# 以下原文无法解析为 front matter，已原样保留：');

    for (final line in frontMatter.split('\n')) {
      if (line.trim().isEmpty) continue;
      buffer
        ..writeln()
        ..write('# $line');
    }
    return buffer.toString();
  }

  static List<String> _parseTags(dynamic value) {
    final tags = <String>[];
    if (value is List) {
      for (final item in value) {
        final tag = item?.toString().trim() ?? '';
        if (tag.isNotEmpty && !tags.contains(tag)) tags.add(tag);
      }
    } else if (value is String) {
      // 容忍 `tags: 工作, 阅读` 这种顺手写法
      for (final part in value.split(',')) {
        final tag = part.trim();
        if (tag.isNotEmpty && !tags.contains(tag)) tags.add(tag);
      }
    }
    return tags;
  }

  /// 把开头的前言块和正文分开。找不到合法前言块时，整个内容都是正文。
  static ({String? frontMatter, String body}) _split(String content) {
    final firstNewline = content.indexOf('\n');
    if (firstNewline < 0) return (frontMatter: null, body: content);
    if (content.substring(0, firstNewline).trimRight() != _delimiter) {
      return (frontMatter: null, body: content);
    }

    var position = firstNewline + 1;
    while (position <= content.length) {
      final newline = content.indexOf('\n', position);
      final lineEnd = newline < 0 ? content.length : newline;
      if (content.substring(position, lineEnd).trimRight() == _delimiter) {
        final frontMatter = content.substring(firstNewline + 1, position);

        // 编码时在结束分隔符后写了一个空行，这里精确吃掉一个，
        // 保证 decode(encode(x)).body == x.body 对任意正文都成立。
        var bodyStart = newline < 0 ? content.length : newline + 1;
        if (bodyStart < content.length && content[bodyStart] == '\r') {
          bodyStart++;
        }
        if (bodyStart < content.length && content[bodyStart] == '\n') {
          bodyStart++;
        }
        return (frontMatter: frontMatter, body: content.substring(bodyStart));
      }
      if (newline < 0) break;
      position = newline + 1;
    }
    return (frontMatter: null, body: content);
  }
}
