/// 日期工具。
///
/// 日记的「日期」只到天，时分秒没有意义；但创建/修改时刻需要精确到秒并带时区。
/// 这两类值在这里分工：前者用 [dateOnly]，后者用 [formatIso8601WithOffset]。
library;

String _two(int n) => n.toString().padLeft(2, '0');

/// 归一化到本地当天零点。所有「归属日期」都必须先过这一道。
DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// `2026-02-14`。这是文件名和 front matter 里 `date` 字段的统一格式。
String formatIsoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${_two(value.month)}-${_two(value.day)}';

/// 严格解析 `YYYY-MM-DD`，不接受 `2026-2-4` 这种松散写法。
DateTime? parseIsoDate(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value.trim());
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final parsed = DateTime(year, month, day);
  // 拦掉 2026-02-30 这类会被 DateTime 静默滚到下个月的日期
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    return null;
  }
  return parsed;
}

/// 自己维护中文星期名，而不是依赖 intl 的区域数据初始化。
/// DateTime.weekday 是 1=周一 … 7=周日。
const List<String> _weekdayNames = <String>['一', '二', '三', '四', '五', '六', '日'];

/// `周一`
String weekdayShort(DateTime value) => '周${_weekdayNames[value.weekday - 1]}';

/// `2026 年 2 月 14 日  星期六`
String formatChineseDate(DateTime value) {
  final weekday = _weekdayNames[value.weekday - 1];
  return '${value.year} 年 ${value.month} 月 ${value.day} 日  星期$weekday';
}

/// `2026-02-14T08:12:33+08:00`。
///
/// Dart 的 [DateTime.toIso8601String] 对本地时间**不带时区偏移**，
/// 跨设备同步时会产生歧义，所以这里自己补上。故意省略毫秒，
/// 让文件内容更干净、diff 更稳定。
String formatIso8601WithOffset(DateTime value) {
  final local = value.isUtc ? value.toLocal() : value;
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final abs = offset.abs();
  final hours = _two(abs.inHours);
  final minutes = _two(abs.inMinutes % 60);

  return '${local.year.toString().padLeft(4, '0')}-${_two(local.month)}-${_two(local.day)}'
      'T${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}'
      '$sign$hours:$minutes';
}

/// 解析带时区的时间戳，统一转换成本地时间。
/// 不带时区的历史时间戳按本地时间解释，保证老文件仍可读。
DateTime? parseTimestamp(String value) {
  final parsed = DateTime.tryParse(value.trim());
  if (parsed == null) return null;
  return parsed.isUtc ? parsed.toLocal() : parsed;
}
