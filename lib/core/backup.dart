import 'package:path/path.dart' as p;

import 'day.dart';

/// 备份的**纯逻辑**：命名、保留策略、安全判断、清单格式。
///
/// 这里刻意不碰文件系统，所以能秒级验证。真正读写文件的部分在平台层，
/// 它只负责把观察到的数据喂给这里的判断。
///
/// ## 为什么自动和手动分成两个目录
///
/// 保留策略**只能删自动快照**。把两类放进不同目录之后，"删到手动快照"在
/// 结构上就不可能发生——比在代码里写 if 判断可靠得多。

/// 自动快照最多留几份。
///
/// 自动快照每天至多一份，所以 30 份大约覆盖最近一个月的写字日。
const int kAutoSnapshotLimit = 30;

/// 每份快照里的清单文件名。
const String kManifestFileName = '备份清单.txt';

const String _autoDirName = '自动';
const String _manualDirName = '手动';

/// 一次备份操作的结果。
///
/// 定义在纯逻辑层而不是平台层：Windows 和 Web 两个实现共用同一个类型，
/// 避免两边各写一份、慢慢长歪。
class BackupOutcome {
  const BackupOutcome({
    required this.ok,
    required this.message,
    this.snapshotPath,
    this.skipped = false,
    this.pruned = 0,
  });

  final bool ok;
  final String message;

  /// 快照目录（备份成功时）或恢复到的目录。
  final String? snapshotPath;

  /// 因为「今天已经有自动备份」或「内容没变」而跳过。**这不算失败。**
  final bool skipped;

  /// 这次清掉了几份超期的自动快照。
  final int pruned;
}

/// 快照种类。
enum SnapshotKind {
  auto(_autoDirName, '自动'),
  manual(_manualDirName, '手动');

  const SnapshotKind(this.dirName, this.label);

  /// 备份根目录下的子目录名。
  final String dirName;

  /// 给人看的名字。
  final String label;

  static SnapshotKind? fromDirName(String name) {
    for (final kind in SnapshotKind.values) {
      if (kind.dirName == name) return kind;
    }
    return null;
  }
}

// -----------------------------------------------------------------------------
// 哪些东西不进备份
// -----------------------------------------------------------------------------

/// 正式日记目录里，哪些东西**不**进备份。
///
/// 注意这里和同步的忽略规则**方向相反**：
///
/// - 同步要**排除** `.history` / `.trash`：那是每台设备各自的痕迹，
///   同步只会让两端互相制造冲突
/// - 备份**必须包含**它们：出错之后最想要的就是这些历史
///
/// 所以两边各有一份名单，不是共用一份。这里排除的都是"过程痕迹"：
/// 还没落盘的草稿、原子写入的临时文件、同步工具的标记目录。
bool isExcludedFromBackup(String relativePath) {
  final segments = relativePath
      .split(RegExp(r'[\\/]+'))
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.isEmpty) return false;

  for (final segment in segments) {
    if (segment == '.drafts') return true;
    if (segment == '.stfolder') return true;
    if (segment == '.stversions') return true;
  }

  final name = segments.last;
  if (name == '.index.sqlite') return true;
  // 原子写入留下的：`<名字>.tmp-<随机>`
  if (name.contains('.tmp-')) return true;
  return false;
}

/// 距上次备份过了几天；从没备份过返回 null。
int? daysSinceBackup(DateTime? lastBackupAt, DateTime now) =>
    lastBackupAt == null ? null : now.difference(lastBackupAt).inDays;

/// 备份是不是该提醒用户了。
///
/// 三个条件缺一不可，其中第一条最容易被忽略：**没设置备份位置时不提醒**。
/// 那时候用户需要的是"先去设个位置"，而不是一个天天顶着、点了却无从下手的
/// 警告。同理，设置过位置却从没备份过也要提醒——"我配好了"和"它真的在跑"
/// 是两件事。
///
/// 放在纯逻辑层，是为了让状态栏和备份对话框共用同一套判断。两处各写一份，
/// 迟早会出现"图标说该备份、点开说还早"这种自相矛盾。
bool isBackupStale({
  required String? backupRoot,
  required DateTime? lastBackupAt,
  required DateTime now,
  int staleDays = 7,
}) {
  if (backupRoot == null || backupRoot.trim().isEmpty) return false;
  final last = lastBackupAt;
  if (last == null) return true;
  return now.difference(last).inDays >= staleDays;
}

// -----------------------------------------------------------------------------
// 命名
// -----------------------------------------------------------------------------

String _dateStamp(DateTime at) => formatIsoDate(at);

String _timeStamp(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}${at.minute.toString().padLeft(2, '0')}';

/// 把用户填的说明变成安全的目录名片段。
///
/// Windows 不允许 `\ / : * ? " < > |`，而这些字符在中文输入法下很容易顺手
/// 打出来。与其让整个备份因为一个字符失败，不如换掉。
/// 结尾的点和空格在 Windows 上同样非法，一并去掉。
String sanitizeLabel(String label, {int maxLength = 40}) {
  var cleaned = label
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  while (cleaned.endsWith('.') || cleaned.endsWith(' ')) {
    cleaned = cleaned.substring(0, cleaned.length - 1);
  }
  if (cleaned.length > maxLength) {
    cleaned = cleaned.substring(0, maxLength).trim();
  }
  return cleaned;
}

/// 快照的目录名。
///
/// - **自动**只到日期：一天至多一份。否则开关十次程序就有十份，
///   而"保留 30 份"就只覆盖三天了。
/// - **手动**到分钟，还可以带一句说明，比如「2026-10-02 2210 改主题之前」。
///
/// [collision] 为 true 时补一个 `-2` 这样的后缀（同一分钟连做两次备份）。
String snapshotDirName(
  SnapshotKind kind,
  DateTime at, {
  String? label,
  bool collision = false,
}) {
  final base = kind == SnapshotKind.auto
      ? _dateStamp(at)
      : '${_dateStamp(at)} ${_timeStamp(at)}';
  final suffix = collision ? '-2' : '';
  final trimmed = sanitizeLabel(label ?? '');
  if (trimmed.isEmpty) return '$base$suffix';
  return '$base$suffix $trimmed';
}

/// 恢复目录名。恢复**只能**落到这样的新目录里，见 [restoreDirName] 的说明。
String restoreDirName(DateTime at) =>
    'riji-恢复-${_dateStamp(at).replaceAll('-', '')}-${_timeStamp(at)}';

/// 从目录名解析出的快照信息。
class SnapshotName {
  const SnapshotName({required this.at, this.label, this.sequence = 1});

  final DateTime at;
  final String? label;

  /// 同一分钟内第几次（目录名里的 `-2`）。
  final int sequence;

  /// 说明**必须**跟在时间后面——所以 `2026-10-02 我的备份` 这种目录名解析
  /// 不出来，也就永远不会被保留策略删掉。这条是安全属性，不是格式洁癖。
  static final RegExp _pattern = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})(?: (\d{2})(\d{2})(?:-(\d+))?(?: (.*))?)?$',
  );

  /// 解析目录名。**认不出来返回 null。**
  ///
  /// 保留策略只删认得出来的目录——**宁可多占空间，也绝不删一个来路不明的
  /// 目录**。用户的备份根目录里可能有别的东西。
  static SnapshotName? parse(String dirName) {
    final match = _pattern.firstMatch(dirName.trim());
    if (match == null) return null;

    final year = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final day = int.tryParse(match.group(3)!);
    if (year == null || month == null || day == null) return null;

    final hour = match.group(4) == null ? 0 : int.tryParse(match.group(4)!) ?? 0;
    final minute = match.group(5) == null ? 0 : int.tryParse(match.group(5)!) ?? 0;
    final sequence = match.group(6) == null ? 1 : int.tryParse(match.group(6)!) ?? 1;
    final label = match.group(7)?.trim();

    // 拒绝 2026-13-45 这种能被正则匹配、但不是合法日期的名字
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    if (hour > 23 || minute > 59) return null;

    return SnapshotName(
      at: DateTime(year, month, day, hour, minute),
      label: (label == null || label.isEmpty) ? null : label,
      sequence: sequence,
    );
  }
}

// -----------------------------------------------------------------------------
// 保留策略
// -----------------------------------------------------------------------------

/// 自动快照里应该删掉哪些目录名（保留最新的 [limit] 份）。
///
/// 规则：
/// - 只考虑**认得出来**的目录名，认不出来的原样保留
/// - 按名字排序即可（时间戳格式的字典序就是时间序）
/// - 数量不超过 [limit] 时一份都不删
///
/// 调用方必须保证传进来的只是 `自动` 目录下的名字——手动快照**没有任何
/// 代码路径会删它**。除此之外，平台层在真正删除前还要确认目录里有
/// [kManifestFileName]：**一个不认识的目录，宁可多占空间也不删。**
List<String> autoSnapshotsToDelete(
  Iterable<String> dirNames, {
  int limit = kAutoSnapshotLimit,
}) {
  final known = dirNames
      .where((name) => SnapshotName.parse(name) != null)
      .toList()
    ..sort();
  if (known.length <= limit) return const <String>[];
  return known.sublist(0, known.length - limit);
}

/// 今天是不是已经有自动快照了（自动快照一天至多一份）。
bool hasAutoSnapshotToday(Iterable<String> autoDirNames, DateTime today) {
  for (final name in autoDirNames) {
    final parsed = SnapshotName.parse(name);
    if (parsed == null) continue;
    if (isSameDay(parsed.at, today)) return true;
  }
  return false;
}

// -----------------------------------------------------------------------------
// 位置安全检查
// -----------------------------------------------------------------------------

/// 备份位置合不合格。
class BackupTargetCheck {
  const BackupTargetCheck({required this.nested, required this.sameVolume});

  /// 两个目录互相包含（任一方向）。**必须拒绝。**
  final bool nested;

  /// 和日记在同一个卷上。允许，但要如实告诉用户：同盘挡不住盘坏。
  final bool sameVolume;

  bool get allowed => !nested;
}

String _normalize(String path) {
  // Windows 大小写不敏感，统一小写比较；去掉结尾的分隔符
  var result = p.normalize(p.absolute(path)).replaceAll('\\', '/');
  while (result.length > 1 && result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result.toLowerCase();
}

bool _contains(String parent, String child) =>
    child == parent || child.startsWith('$parent/');

/// 取路径的"卷"：`d:/someone/mydata` → `d:`；`//server/share/x` → `//server/share`。
///
/// 刻意不用 `package:path` 的对应函数：这里只需要判断"是不是同一个卷"，
/// 而**两个盘符也可能是同一块物理盘**——更精确的判断在纯逻辑层做不到，
/// 所以上层只能提示、不能保证，这一点必须如实告诉用户。
String _volumeOf(String normalized) {
  final unc = RegExp(r'^//([^/]+)/([^/]+)').firstMatch(normalized);
  if (unc != null) return '//${unc.group(1)}/${unc.group(2)}';
  final drive = RegExp(r'^([a-z]:)').firstMatch(normalized);
  return drive?.group(1) ?? '';
}

/// 检查备份位置。
///
/// **两个方向都要拒绝**：
/// - 备份目录在日记目录里面 → 下次备份会把上次的快照也拷进去（递归），
///   而且会被 Syncthing 同步到手机
/// - 日记目录在备份目录里面 → 同理，下一份快照会把上一份快照再拷一遍
///
/// [sameVolume] 只做提示。诚实说明：**两个盘符也可能是同一块物理盘**，
/// 这里判断不了，所以只能提示，不能保证。
BackupTargetCheck checkBackupTarget({
  required String diaryRoot,
  required String backupRoot,
}) {
  final diary = _normalize(diaryRoot);
  final backup = _normalize(backupRoot);
  final nested = _contains(diary, backup) || _contains(backup, diary);

  final diaryRootPart = _volumeOf(diary);
  final backupRootPart = _volumeOf(backup);
  final sameVolume = diaryRootPart.isNotEmpty && diaryRootPart == backupRootPart;

  return BackupTargetCheck(nested: nested, sameVolume: sameVolume);
}

// -----------------------------------------------------------------------------
// 内容有没有变
// -----------------------------------------------------------------------------

/// 一个文件的指纹。只看路径、大小、修改时间——**不读内容**。
class FileStamp {
  const FileStamp({
    required this.path,
    required this.size,
    required this.modified,
  });

  /// 相对日记根目录的路径，用 `/` 分隔。
  final String path;
  final int size;
  final DateTime modified;
}

/// 和上一份快照相比，内容有没有变化。
///
/// 自动备份在关闭程序时跑，为了判断"要不要备份"去把几 MB 全读一遍不值得。
/// 真正的内容完整性由每份快照里的清单负责，不在这一步。
bool hasChanges(List<FileStamp> previous, List<FileStamp> current) {
  if (previous.length != current.length) return true;

  final a = List<FileStamp>.of(previous)
    ..sort((x, y) => x.path.compareTo(y.path));
  final b = List<FileStamp>.of(current)
    ..sort((x, y) => x.path.compareTo(y.path));

  for (var i = 0; i < a.length; i++) {
    if (a[i].path != b[i].path) return true;
    if (a[i].size != b[i].size) return true;
    if (a[i].modified != b[i].modified) return true;
  }
  return false;
}

// -----------------------------------------------------------------------------
// 清单
// -----------------------------------------------------------------------------

/// 生成快照清单。
///
/// 它让每份快照**自己说明自己**：三年后打开一个目录，不依赖任何程序就能
/// 知道这是什么时候、从哪里、由谁来的一份备份，有多少文件、多大。
/// 校验和另外存在 [checksums]（路径 → SHA256 十六进制）里。
String renderManifest({
  required SnapshotKind kind,
  required DateTime at,
  required String source,
  required List<FileStamp> files,
  String? label,
  Map<String, String> checksums = const <String, String>{},
}) {
  final buffer = StringBuffer()
    ..writeln('riji 备份清单')
    ..writeln('时间: ${formatIsoDate(at)} ${_timeStamp(at)}')
    ..writeln('类型: ${kind.label}')
    ..writeln('来源: $source');
  final trimmed = sanitizeLabel(label ?? '');
  if (trimmed.isNotEmpty) buffer.writeln('说明: $trimmed');

  final totalBytes = files.fold<int>(0, (sum, file) => sum + file.size);
  buffer
    ..writeln('文件数: ${files.length}')
    ..writeln('总字节: $totalBytes')
    ..writeln('---');

  final sorted = List<FileStamp>.of(files)
    ..sort((x, y) => x.path.compareTo(y.path));
  for (final file in sorted) {
    final sum = checksums[file.path];
    buffer.write('${file.path}\t${file.size}\t'
        '${file.modified.toIso8601String()}');
    if (sum != null) buffer.write('\t$sum');
    buffer.writeln();
  }
  return buffer.toString();
}

/// 从清单里读回文件指纹（用来和当前状态比较，判断要不要备份）。
///
/// 解析不了的行直接跳过——清单是辅助信息，读不动不该让备份流程失败。
List<FileStamp> parseManifestStamps(String content) {
  final stamps = <FileStamp>[];
  var inBody = false;
  for (final line in content.split('\n')) {
    final trimmed = line.trimRight();
    if (!inBody) {
      if (trimmed == '---') inBody = true;
      continue;
    }
    if (trimmed.isEmpty) continue;
    final parts = trimmed.split('\t');
    if (parts.length < 3) continue;
    final size = int.tryParse(parts[1]);
    final modified = DateTime.tryParse(parts[2]);
    if (size == null || modified == null) continue;
    stamps.add(FileStamp(path: parts[0], size: size, modified: modified));
  }
  return stamps;
}
