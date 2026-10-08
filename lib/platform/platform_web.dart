import '../core/backup.dart';
import '../core/diary_location.dart';
import '../core/reminder.dart';
import '../data/diary_store.dart';

/// web 上的平台实现。
///
/// web 只用于**开发时预览界面**，不是交付目标——浏览器里没有可写的
/// 文件系统，所以这里用内存存储。真正的手机端会走 platform_io.dart，
/// 只是换一个根目录（App 沙盒），界面代码一行都不用改。

const bool isWebPlatform = true;

/// web 上没有真实文件系统，所以「更改日记位置」这个功能整个不出现。
const bool supportsDiaryLocationChange = false;

String get deviceName => 'web';

String get defaultDiaryRoot => 'memory://riji';

DiaryStore createStore({required String rootPath, required String device}) =>
    MemoryDiaryStore(deviceName: device);

Future<String?> readSettingsJson() async => null;

Future<void> writeSettingsJson(String json) async {}

String exportDirectoryFor(String diaryRoot) => diaryRoot;

Future<String> writeExportFile({
  required String directory,
  required String fileName,
  required String content,
}) async {
  throw UnsupportedError('web 预览模式没有文件系统，无法导出');
}

Future<void> revealInFileManager(String path) async {}

// -----------------------------------------------------------------------------
// 单实例锁：web 上不需要（预览模式没有共享的日记目录）
// -----------------------------------------------------------------------------

Future<bool> acquireSingleInstanceLock() async => true;

Future<void> releaseSingleInstanceLock() async {}

void quitApp() {}

// -----------------------------------------------------------------------------
// 更改日记位置：web 上全部不可用
// -----------------------------------------------------------------------------

String normalizeDiaryPath(String path) => path;

Future<DiaryLocationFacts> gatherDiaryLocationFacts({
  required String rawPath,
  required String currentRoot,
  required int currentEntryCount,
}) async {
  return DiaryLocationFacts(
    rawPath: rawPath,
    normalizedPath: rawPath,
    currentRoot: currentRoot,
    currentEntryCount: currentEntryCount,
    inspectionFailed: true,
  );
}

/// web 上没有可写的文件系统，所以备份整个功能不可用。
/// **界面必须据此隐藏入口，而不是给一个点了会失败的按钮。**
const bool supportsBackup = false;

Future<BackupOutcome> createBackupSnapshot({
  required String diaryRoot,
  required String backupRoot,
  required SnapshotKind kind,
  String? label,
  DateTime? at,
}) async =>
    const BackupOutcome(ok: false, message: '预览模式没有文件系统，无法备份。');

Future<List<String>> listBackupSnapshots(String kindDir) async => <String>[];

Future<BackupOutcome> restoreBackupSnapshot({
  required String snapshotDir,
  required String targetParent,
  DateTime? at,
}) async =>
    const BackupOutcome(ok: false, message: '预览模式没有文件系统，无法恢复。');

Future<DiaryCopyOutcome> copyDiaryTree({
  required String from,
  required String to,
  void Function(int copied, int total)? onProgress,
}) async {
  return const DiaryCopyOutcome(
    ok: false,
    filesCopied: 0,
    message: '预览模式没有文件系统，无法复制。',
  );
}

List<String> listDiaryDriveRoots() => <String>[];

Future<List<String>> listDiarySubdirectories(String path) async => <String>[];

String? diaryParentDirectory(String path) => null;

// -----------------------------------------------------------------------------
// 每日提醒：预览模式没有系统集成，整个功能不出现
// -----------------------------------------------------------------------------

/// web 上既没有计划任务也没有 Windows 通知，**界面必须据此隐藏入口**，
/// 而不是给一个点了会失败的开关。
bool get supportsReminder => false;

/// 预览模式没有"程序本体路径"这回事。
String get appExecutablePath => '';

Future<ReminderOutcome> applyReminder({
  required ReminderTime time,
  required List<int> weekdays,
  required String diaryRoot,
  required List<int> iconBytes,
}) async =>
    const ReminderOutcome(ok: false, message: '预览模式没有系统集成，无法启用提醒。');

Future<ReminderOutcome> removeReminder() async =>
    const ReminderOutcome(ok: true, message: '已关闭。');

Future<void> queueActivation(String url) async {}

Future<String?> takeQueuedActivation() async => null;
