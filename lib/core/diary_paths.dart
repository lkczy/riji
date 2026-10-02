import 'day.dart';
import 'history.dart';

/// 日期 ↔ 文件路径 的映射规则。
///
/// 布局：`<根目录>/YYYY/YYYY-MM-DD.md`
/// 按年分目录，避免单个目录堆积上万个文件。
///
/// 这里刻意只返回**路径片段**而不是拼好的字符串，
/// 让真正碰文件系统的那一层去决定分隔符——web 端和 Windows 的分隔符不同。
class DiaryPaths {
  DiaryPaths._();

  static const String extension = '.md';
  static const String draftsDirName = '.drafts';
  static const String indexFileName = '.index.sqlite';

  /// 已删除的日记。软删除，字节都还在。
  static const String trashDirName = '.trash';

  /// 历史快照。和 [trashDirName]、[draftsDirName] 一样以 `.` 开头，
  /// 所以自动被「不当成日记读进来」的规则挡住。
  static const String historyDirName = '.history';

  static final RegExp _diaryFileName = RegExp(r'^(\d{4}-\d{2}-\d{2})\.md$');

  /// `2026-10-04/213045123-opened.md` 里的文件名部分。
  static final RegExp _snapshotFileName =
      RegExp(r'^(\d{6})(\d{3})-([a-z\-]+)\.md$');

  /// `2026-10-04.md.1730000000000000.deleted`
  static final RegExp _trashFileName =
      RegExp(r'^(\d{4}-\d{2}-\d{2})\.md\.(\d+)\.deleted$');

  /// 同时识别我们自己的冲突命名和 Syncthing 自己产生的冲突命名
  /// （`2026-02-14.sync-conflict-20260214-214002-ABCDEFG.md`）。
  /// Syncthing 才是冲突文件的主要来源，漏掉它等于漏掉大部分冲突。
  static final RegExp _conflictFileName =
      RegExp(r'^(\d{4}-\d{2}-\d{2})\.(?:sync-)?conflict-.*\.md$');

  /// `2026-02-14.md`
  static String fileNameFor(DateTime date) => '${formatIsoDate(date)}$extension';

  /// `['2026', '2026-02-14.md']`
  static List<String> segmentsFor(DateTime date) => <String>[
        date.year.toString().padLeft(4, '0'),
        fileNameFor(date),
      ];

  /// 从文件名还原日期。不是日记文件则返回 null。
  static DateTime? dateFromFileName(String fileName) {
    final match = _diaryFileName.firstMatch(fileName);
    if (match == null) return null;
    return parseIsoDate(match.group(1)!);
  }

  /// 是不是一条正常日记的文件名（冲突文件不算）。
  static bool isDiaryFileName(String fileName) =>
      _diaryFileName.hasMatch(fileName);

  /// 是不是同步冲突产生的文件。
  static bool isConflictFileName(String fileName) =>
      _conflictFileName.hasMatch(fileName);

  /// 从冲突文件名还原它对应的日期。
  static DateTime? conflictDateFromFileName(String fileName) {
    final match = _conflictFileName.firstMatch(fileName);
    if (match == null) return null;
    return parseIsoDate(match.group(1)!);
  }

  /// 冲突文件的文件名。
  ///
  /// 冲突时**绝不静默覆盖**：把较旧的那份另存成这个名字，让用户自己合并。
  /// 宁可多一个需要手动处理的文件，也不能少一句用户写过的话。
  static String conflictFileNameFor(
    DateTime date,
    DateTime timestamp,
    String device,
  ) {
    final stamp = '${timestamp.year.toString().padLeft(4, '0')}'
        '${timestamp.month.toString().padLeft(2, '0')}'
        '${timestamp.day.toString().padLeft(2, '0')}'
        'T'
        '${timestamp.hour.toString().padLeft(2, '0')}'
        '${timestamp.minute.toString().padLeft(2, '0')}'
        '${timestamp.second.toString().padLeft(2, '0')}';
    return '${formatIsoDate(date)}.conflict-$stamp-${sanitizeDevice(device)}$extension';
  }

  /// 设备名进文件名前必须净化：Windows 文件名不允许 `\ / : * ? " < > |`。
  static String sanitizeDevice(String device) {
    final cleaned = device.replaceAll(RegExp(r'[^A-Za-z0-9\-_]'), '-');
    return cleaned.isEmpty ? 'unknown' : cleaned;
  }

  /// 草稿文件相对于根目录的片段：`['.drafts', '2026-02-14.draft']`
  static List<String> draftSegmentsFor(DateTime date) => <String>[
        draftsDirName,
        '${formatIsoDate(date)}.draft',
      ];

  // ---------------------------------------------------------------------------
  // 历史快照
  // ---------------------------------------------------------------------------
  //
  // 布局：`<根>/.history/2026-10-04/213045123-opened.md`
  //
  // 文件名里带时间和原因，好处是**把文件单独拷出来也自解释**：
  // 不用查数据库、不用问程序，看名字就知道这是哪一天哪个时刻的什么版本。
  // 时间戳排在最前面，所以按文件名排序天然就是时间顺序。

  /// `['.history', '2026-10-04', '213045123-opened.md']`
  static List<String> snapshotSegmentsFor(DateTime date, String fileName) =>
      <String>[historyDirName, formatIsoDate(date), fileName];

  /// `213045123-opened.md`（时 分 秒 毫秒 + 原因）
  static String snapshotFileNameFor(DateTime at, SnapshotReason reason) {
    final stamp = '${at.hour.toString().padLeft(2, '0')}'
        '${at.minute.toString().padLeft(2, '0')}'
        '${at.second.toString().padLeft(2, '0')}'
        '${at.millisecond.toString().padLeft(3, '0')}';
    return '$stamp-${reason.tag}$extension';
  }

  /// 从快照文件名还原它的时刻。**取文件名而不是文件时间**：
  /// 复制、同步、备份都会改掉文件的修改时间，但改不掉名字。
  static DateTime? snapshotTimeFromFileName(String fileName, DateTime date) {
    final match = _snapshotFileName.firstMatch(fileName);
    if (match == null) return null;
    final stamp = match.group(1)!;
    final millis = int.tryParse(match.group(2)!) ?? 0;
    return DateTime(
      date.year,
      date.month,
      date.day,
      int.parse(stamp.substring(0, 2)),
      int.parse(stamp.substring(2, 4)),
      int.parse(stamp.substring(4, 6)),
      millis,
    );
  }

  static SnapshotReason? snapshotReasonFromFileName(String fileName) {
    final match = _snapshotFileName.firstMatch(fileName);
    if (match == null) return null;
    return SnapshotReason.fromTag(match.group(3)!);
  }

  /// 是不是一份历史快照的文件名。
  static bool isSnapshotFileName(String fileName) =>
      _snapshotFileName.hasMatch(fileName);

  // ---------------------------------------------------------------------------
  // 回收站
  // ---------------------------------------------------------------------------

  /// `2026-10-04.md.1730000000000000.deleted`
  static String trashFileNameFor(DateTime date, DateTime deletedAt) =>
      '${fileNameFor(date)}.${deletedAt.microsecondsSinceEpoch}.deleted';

  static DateTime? trashDateFromFileName(String fileName) {
    final match = _trashFileName.firstMatch(fileName);
    if (match == null) return null;
    return parseIsoDate(match.group(1)!);
  }

  static DateTime? trashDeletedAtFromFileName(String fileName) {
    final match = _trashFileName.firstMatch(fileName);
    if (match == null) return null;
    final micros = int.tryParse(match.group(2)!);
    if (micros == null) return null;
    return DateTime.fromMicrosecondsSinceEpoch(micros);
  }

  /// 搜索索引等派生物，同步工具应当忽略。
  ///
  /// [historyDirName] 和 [trashDirName] 必须在这里：历史快照和已删除的内容
  /// 是本机的操作痕迹，同步它们只会让两台设备互相制造冲突文件，
  /// 白白把容量和噪音翻倍。
  static const List<String> syncIgnorePatterns = <String>[
    indexFileName,
    draftsDirName,
    historyDirName,
    trashDirName,
    '*.tmp-*',
  ];
}
