/// 「这个位置适合放日记吗」的判断逻辑。
///
/// 刻意写成**纯函数**：只吃事实、吐结论，不碰文件系统。
/// 因为这里的每一条判断都关系到用户的数据会不会看起来"消失了"，
/// 必须能被完整单测覆盖，而不是靠手点界面去试。
library;

enum DriveKind { fixed, removable, network, unknown }

enum NoticeSeverity { error, warning, info }

class LocationNotice {
  const LocationNotice(this.severity, this.message);

  final NoticeSeverity severity;
  final String message;
}

/// 一次位置检查所需的全部事实。由平台层负责采集。
class DiaryLocationFacts {
  const DiaryLocationFacts({
    required this.rawPath,
    required this.normalizedPath,
    required this.currentRoot,
    required this.currentEntryCount,
    this.exists = false,
    this.isDirectory = false,
    this.writable = false,
    this.entryCount = 0,
    this.conflictCount = 0,
    this.foreignMarkdownCount = 0,
    this.subdirectoryCount = 0,
    this.driveKind = DriveKind.unknown,
    this.inspectionFailed = false,
  });

  /// 用户输入的原样文本。
  final String rawPath;

  /// 规范化后的绝对路径（由平台层用 path 包处理，两边都是规范形式才能比较）。
  final String normalizedPath;

  final String currentRoot;
  final int currentEntryCount;

  final bool exists;
  final bool isDirectory;

  /// 真的能写进去吗。这项必须实测（尝试建一个临时文件），不能靠猜。
  final bool writable;

  /// 目标位置已有的日记篇数。
  final int entryCount;

  /// 目标位置已有的同步冲突文件数。
  final int conflictCount;

  /// 目标位置的 .md 文件里，既不是日记也不是冲突文件的那些。
  /// 这个数字大，说明用户可能选了个通用文件夹。
  final int foreignMarkdownCount;

  final int subdirectoryCount;
  final DriveKind driveKind;

  /// 采集过程本身失败了（权限不足、路径非法等）。
  final bool inspectionFailed;
}

class DiaryLocationAssessment {
  const DiaryLocationAssessment({
    required this.notices,
    required this.canSwitch,
    required this.suggestCopy,
  });

  final List<LocationNotice> notices;

  /// 是否可以切换。只要有 error 就是 false。
  final bool canSwitch;

  /// 是否建议「把现有日记复制过去」——目标为空而当前位置有内容时成立。
  final bool suggestCopy;

  List<LocationNotice> get errors => notices
      .where((n) => n.severity == NoticeSeverity.error)
      .toList(growable: false);

  List<LocationNotice> get warnings => notices
      .where((n) => n.severity == NoticeSeverity.warning)
      .toList(growable: false);
}

/// 复制日记目录的结果。
///
/// [message] 是给用户看的：成功了要说清"旧位置没动过"，
/// 失败了要说清"日记位置没有被改动"。这两句话是用户判断
/// "我的数据现在安不安全"的唯一依据。
class DiaryCopyOutcome {
  const DiaryCopyOutcome({
    required this.ok,
    required this.filesCopied,
    required this.message,
  });

  final bool ok;
  final int filesCopied;
  final String message;
}

/// 执行位置切换的回调，由引导层实现（它才有权重建 DiaryController）。
typedef SwitchDiaryRootCallback = Future<DiaryCopyOutcome> Function(
  String newRoot, {
  required bool copyExisting,
});

/// 看起来是不是绝对路径。同时接受 Windows（`D:\`、`\\server\share`）和
/// POSIX（`/home/...`）形式，这样将来手机端不用改这里。
bool looksAbsolute(String path) {
  if (path.startsWith('/')) return true;
  if (path.startsWith(r'\\')) return true;
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}

DiaryLocationAssessment assessDiaryLocation(DiaryLocationFacts facts) {
  final notices = <LocationNotice>[];
  var canSwitch = true;

  void error(String message) {
    notices.add(LocationNotice(NoticeSeverity.error, message));
    canSwitch = false;
  }

  void warn(String message) =>
      notices.add(LocationNotice(NoticeSeverity.warning, message));

  void info(String message) =>
      notices.add(LocationNotice(NoticeSeverity.info, message));

  final target = facts.normalizedPath.trim();

  // ---- 硬性错误：这些情况下绝不能切换 ----

  if (target.isEmpty && facts.rawPath.trim().isEmpty) {
    error('请填写日记文件夹的路径。');
  } else if (!looksAbsolute(target)) {
    error('请填写完整路径，例如 D:\\日记。相对路径的含义会随启动方式变化，不能用。');
  }

  if (canSwitch && facts.inspectionFailed) {
    error('无法检查这个位置（可能是权限不足或路径非法）。请换一个位置。');
  }

  if (canSwitch && facts.exists && !facts.isDirectory) {
    error('这个路径是一个文件，不是文件夹。');
  }

  if (canSwitch && facts.exists && facts.isDirectory && !facts.writable) {
    error('这个文件夹没有写入权限，程序无法在这里保存日记。'
        '常见原因是选到了系统目录（如 C:\\Program Files）。');
  }

  // 路径比较用不区分大小写：Windows 上 D:\日记 和 d:\日记 是同一个地方。
  final sameAsCurrent =
      target.toLowerCase() == facts.currentRoot.trim().toLowerCase();
  if (canSwitch && sameAsCurrent) {
    error('这已经是当前的日记位置了。');
  }

  // ---- 警告：可以切换，但用户必须知道后果 ----

  if (canSwitch && !facts.exists) {
    info('这个文件夹还不存在，切换时会被创建。');
  }

  // 最容易被误解成「日记全丢了」的情况，必须说清楚。
  if (canSwitch && facts.currentEntryCount > 0 && facts.entryCount == 0) {
    warn('新位置一篇日记都没有，切换后界面会是空的。\n'
        '你的日记没有被删除——它们仍然在当前位置。\n'
        '如果想让日记跟着搬过去，请勾选下面「把现有日记复制到新位置」。');
  } else if (canSwitch && facts.entryCount > 0) {
    info('新位置已经有 ${facts.entryCount} 篇日记，切换后显示的是这些内容。\n'
        '当前位置的内容不会再显示，但不会被删除。');
  }

  if (canSwitch && facts.foreignMarkdownCount > 0) {
    warn('这个文件夹里还有 ${facts.foreignMarkdownCount} 个其它 .md 文件。\n'
        '程序会递归扫描整个文件夹，任何命名为 YYYY-MM-DD.md 的文件都会被当成日记'
        '显示出来，并且可能被程序改写。建议用一个专用文件夹。');
  }

  if (canSwitch && facts.subdirectoryCount > 50) {
    warn('这个文件夹下有 ${facts.subdirectoryCount} 个子文件夹，看起来是个通用目录。\n'
        '程序会递归扫描其中全部内容。换成一个专用文件夹更稳妥。');
  }

  if (canSwitch && facts.conflictCount > 0) {
    info('新位置有 ${facts.conflictCount} 个同步冲突文件，切换后可以在左侧看到提示。');
  }

  if (canSwitch && facts.driveKind == DriveKind.removable) {
    warn('这个位置在外接/可移动磁盘上。\n'
        '设备没插着的时候，程序会读不到日记，写入也会失败。');
  }

  if (canSwitch && facts.driveKind == DriveKind.network) {
    warn('这个位置在网络磁盘上。\n网络不通时会读不到日记，写入也会失败。');
  }

  // 用户明确选择了「不做应用层加密、依赖全盘加密」，所以位置变更会
  // 静默影响这层保护。程序没有权限查询 BitLocker 状态，只能提醒。
  if (canSwitch) {
    info('程序无法检测磁盘加密状态。你选择的是「不做应用层加密、依赖全盘加密」，'
        '如果新位置所在磁盘没有启用 BitLocker，日记就是明文存放的。');
  }

  final targetIsEmpty = !facts.exists || facts.entryCount == 0;
  final suggestCopy =
      canSwitch && facts.currentEntryCount > 0 && targetIsEmpty;

  return DiaryLocationAssessment(
    notices: notices,
    canSwitch: canSwitch,
    suggestCopy: suggestCopy,
  );
}
