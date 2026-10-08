import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/backup.dart';
import '../core/reminder.dart';

import '../core/diary_location.dart';
import '../core/diary_paths.dart';
import '../data/diary_store.dart';
import '../data/fs_diary_store.dart';

/// 桌面 / 移动端的平台实现。
///
/// 刻意只用 `dart:io` 和环境变量，不引入任何插件（path_provider 等）。
/// 原因：Flutter 为插件建符号链接要求 Windows 开启开发者模式，
/// 而开开发者模式需要管理员权限。为了定位一个目录而付这个代价不值得。

const bool isWebPlatform = false;

String get deviceName {
  try {
    final host = Platform.localHostname.trim();
    if (host.isNotEmpty) return host;
  } catch (_) {
    // 某些受限环境下拿不到主机名
  }
  return Platform.operatingSystem;
}

/// 默认日记目录：`<用户目录>/Documents/riji`。
String get defaultDiaryRoot {
  final environment = Platform.environment;
  final home = environment['USERPROFILE'] ?? environment['HOME'];
  if (home == null || home.trim().isEmpty) {
    return p.join(Directory.current.path, 'riji');
  }
  return p.join(home, 'Documents', 'riji');
}

DiaryStore createStore({required String rootPath, required String device}) =>
    FsDiaryStore(rootPath: rootPath, deviceName: device);

// -----------------------------------------------------------------------------
// 设置持久化：放在 %APPDATA%\riji\settings.json，与日记数据分开。
// 日记根目录本身是可配置的，所以设置文件不能放在日记目录里面。
// -----------------------------------------------------------------------------

File _settingsFile() => File(p.join(_appDataDir().path, 'settings.json'));

/// 程序自己的数据目录：`%APPDATA%\riji`。
///
/// 设置、单实例锁、提醒脚本、排队的外部动作都放这里。
/// **不放在日记目录里**：日记目录是可配置的、会被同步到手机上的，
/// 而这些是每台机器自己的东西。
Directory _appDataDir() {
  final base = Platform.environment['APPDATA'] ??
      Platform.environment['XDG_CONFIG_HOME'] ??
      Directory.current.path;
  return Directory(p.join(base, 'riji'));
}

/// 旧版本（程序还叫 riji 时）的设置目录名。
///
/// 改名之后不能当作什么都没发生：设置里存着**用户的日记目录**。新目录里
/// 找不到它，程序就会回退到默认位置、打开一个空白日记——用户会以为日记
/// 没了（数据其实一个字节都没少，只是程序不知道该去哪找）。
///
/// ⚠️ **这个字面量必须是旧名字 `myDiary`**：它指向的是"程序改名之前"的目录。
/// 改名的批量替换曾经把它一起改成了 `riji`，迁移于是**静默失效**——不报错，
/// 只会在某次重启后让用户以为日记丢了。`settings_migration_test.dart`
/// 有一条测试专门钉住它。
const String legacyAppDirName = 'myDiary';

/// 首次运行时把旧设置搬过来。只在**新位置还没有设置**时才动手，所以只生效一次。
///
/// 搬不动也绝不报错：最坏情况是回到默认日记位置，那也比打不开程序好。
/// 把旧目录里的设置搬到 [target]。
///
/// 只在 [target] **还不存在**时动手，所以它只会生效一次，也绝不会覆盖新设置。
/// 返回是否真的搬了——返回值是给测试用的，调用方不看。
///
/// 参数显式传进来（而不是在这里读 `Platform.environment`），目的就是让测试
/// 能塞两个临时目录进来，不必去碰真实的 `%APPDATA%`。
///
/// 搬不动也绝不抛异常：最坏情况是回到默认日记位置，那也比打不开程序好。
Future<bool> migrateLegacySettings({
  required String legacyDir,
  required File target,
}) async {
  try {
    if (await target.exists()) return false;
    final legacy = File(p.join(legacyDir, 'settings.json'));
    if (!await legacy.exists()) return false;
    await target.parent.create(recursive: true);
    await legacy.copy(target.path);
    stderr.writeln('[riji] 已把旧设置迁移到 ${target.path}');
    return true;
  } catch (_) {
    return false;
  }
}

/// 启动时调用：把 `%APPDATA%\myDiary\settings.json` 搬到当前的位置。
///
/// 迁移失败**不能影响启动**：最坏是回到默认日记位置，用户会在界面里看到
/// 日记是空的，但程序本身能开。
Future<void> _migrateLegacySettingsIfNeeded(File target) async {
  final base = Platform.environment['APPDATA'];
  if (base == null || base.isEmpty) return;
  await migrateLegacySettings(
    legacyDir: p.join(base, legacyAppDirName),
    target: target,
  );
}

Future<String?> readSettingsJson() async {
  final file = _settingsFile();
  await _migrateLegacySettingsIfNeeded(file);
  try {
    if (!await file.exists()) return null;
    return await file.readAsString();
  } catch (_) {
    // 设置读不出来就用默认值，绝不能因为设置损坏而打不开程序
    return null;
  }
}

Future<void> writeSettingsJson(String json) async {
  final file = _settingsFile();
  await file.parent.create(recursive: true);

  // 同样用先写临时文件再 rename 的方式，避免设置写到一半断电后损坏
  final temp = File('${file.path}.tmp');
  await temp.writeAsString(json, flush: true);
  await temp.rename(file.path);
}

// -----------------------------------------------------------------------------
// 导出与定位
// -----------------------------------------------------------------------------

/// 导出文件放哪：日记根目录的旁边，避免导出的东西被同步工具当成日记。
String exportDirectoryFor(String diaryRoot) =>
    p.join(p.dirname(diaryRoot), 'riji-导出');

Future<String> writeExportFile({
  required String directory,
  required String fileName,
  required String content,
}) async {
  final file = File(p.join(directory, fileName));
  await file.parent.create(recursive: true);
  await file.writeAsString(content, flush: true);
  return file.path;
}

/// 在资源管理器里定位到某个文件或目录。
Future<void> revealInFileManager(String path) async {
  if (Platform.isWindows) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      await Process.run('explorer', <String>[path]);
    } else {
      await Process.run('explorer', <String>['/select,', path]);
    }
  } else if (Platform.isMacOS) {
    await Process.run('open', <String>['-R', path]);
  } else {
    await Process.run('xdg-open', <String>[p.dirname(path)]);
  }
}

// -----------------------------------------------------------------------------
// 单实例锁
// -----------------------------------------------------------------------------
//
// 为什么要这个：两个实例指向同一个日记目录时，各自的内存状态会互相过时，
// 于是每次保存都会把对方的版本判成"外部改动"，产出一堆需要手工合并的
// 冲突文件。数据不会丢（冲突文件两边都保住了），但那个噪音完全没必要。

RandomAccessFile? _instanceLockHandle;

File _instanceLockFile() {
  final base = Platform.environment['APPDATA'] ??
      Platform.environment['XDG_CONFIG_HOME'] ??
      Directory.current.path;
  return File(p.join(base, 'riji', 'instance.lock'));
}

/// 尝试取得「只允许一个实例」的锁。拿到返回 true，说明已经有别的实例在跑。
///
/// 用**操作系统级的文件锁**，而不是自己维护一个带 PID 的锁文件。原因：
/// 进程崩溃、被任务管理器杀掉、断电时，操作系统会自动释放文件锁；而 PID
/// 文件会留下陈旧记录，于是程序不得不判断"那个进程还活着吗"——这个判断
/// 本身又会出错（PID 会被复用），最后表现成"程序说你已经开了一个，其实没有"，
/// 而用户只能手工去删那个文件。
///
/// 锁文件放设置目录（`%APPDATA%\riji\`）而不是日记目录：单实例是
/// **每台机器**的概念，不该跟着可配置、会被同步的日记目录跑。
Future<bool> acquireSingleInstanceLock() async {
  if (_instanceLockHandle != null) return true;

  try {
    final file = _instanceLockFile();
    await file.parent.create(recursive: true);

    // 用 append 而不是 write：write 会在打开时截断文件，
    // 那等于在别人持锁期间去改别人锁着的文件。
    final handle = await file.open(mode: FileMode.append);

    // exclusive 是**非阻塞**的：拿不到会抛异常，而不是傻等。
    await handle.lock(FileLock.exclusive);

    // 锁本身才是信号。写这一行是为了**程序退出之后**（锁随之释放）
    // 手工打开这个文件时能看出上一次是什么时候、在哪台机器上启动过。
    // 注意：运行期间整段被锁，别的程序读不到它——实测过。
    await handle.writeString(
      '${Platform.localHostname} 于 ${DateTime.now().toIso8601String()} 启动\n',
    );
    await handle.flush();

    _instanceLockHandle = handle;
    return true;
  } catch (_) {
    // 拿不到锁就是"已经有实例在跑"，也可能是文件系统不允许加锁。
    // 两种情况都按"拒绝启动第二个实例"处理，这是更安全的默认值。
    return false;
  }
}

/// 释放锁并关掉句柄。进程退出时操作系统本来也会释放，这里是显式收尾。
Future<void> releaseSingleInstanceLock() async {
  final handle = _instanceLockHandle;
  _instanceLockHandle = null;
  if (handle == null) return;
  try {
    await handle.unlock();
  } catch (_) {
    // 已经没锁了也无所谓
  }
  try {
    await handle.close();
  } catch (_) {
    // 关不掉就交给操作系统在进程退出时回收
  }
}

/// 退出程序。第二个实例点「关闭」时用。
void quitApp() => exit(0);

// -----------------------------------------------------------------------------
// 更改日记位置
// -----------------------------------------------------------------------------
//
// 这一整块的风险点在于：用户换了位置以后，界面上如果看不到日记，
// 第一反应是「我的日记没了」。所以这里的每项检查都必须**实测**，
// 不能靠猜——猜错了代价是用户不再信任这个程序。

const bool supportsDiaryLocationChange = true;

String normalizeDiaryPath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '';
  return p.normalize(p.absolute(trimmed));
}

Future<DiaryLocationFacts> gatherDiaryLocationFacts({
  required String rawPath,
  required String currentRoot,
  required int currentEntryCount,
}) async {
  final normalized = normalizeDiaryPath(rawPath);

  DiaryLocationFacts failed() => DiaryLocationFacts(
        rawPath: rawPath,
        normalizedPath: normalized,
        currentRoot: currentRoot,
        currentEntryCount: currentEntryCount,
        inspectionFailed: true,
      );

  if (normalized.isEmpty) {
    return DiaryLocationFacts(
      rawPath: rawPath,
      normalizedPath: '',
      currentRoot: currentRoot,
      currentEntryCount: currentEntryCount,
    );
  }

  try {
    final type = FileSystemEntity.typeSync(normalized, followLinks: false);
    final exists = type != FileSystemEntityType.notFound;
    final isDirectory = type == FileSystemEntityType.directory;

    var entryCount = 0;
    var conflictCount = 0;
    var foreignMarkdown = 0;
    var subdirectoryCount = 0;
    var writable = false;

    if (isDirectory) {
      final stats = await _scanDirectory(normalized);
      entryCount = stats.diaryFiles;
      conflictCount = stats.conflictFiles;
      foreignMarkdown = stats.foreignMarkdown;
      subdirectoryCount = stats.subdirectories;
      writable = await _probeWritable(normalized);
    } else if (!exists) {
      // 目录还不存在，那就要确认它能被创建出来——看最近的已存在祖先能不能写。
      writable = await _probeWritableAncestor(normalized);
    }

    return DiaryLocationFacts(
      rawPath: rawPath,
      normalizedPath: normalized,
      currentRoot: currentRoot,
      currentEntryCount: currentEntryCount,
      exists: exists,
      isDirectory: isDirectory,
      writable: writable,
      entryCount: entryCount,
      conflictCount: conflictCount,
      foreignMarkdownCount: foreignMarkdown,
      subdirectoryCount: subdirectoryCount,
      driveKind: await _driveKindFor(normalized),
    );
  } catch (_) {
    return failed();
  }
}

/// 真的往目录里写一个临时文件再删掉。这是判断「能不能写」唯一可靠的办法——
/// 看权限位、看只读属性都会漏掉网络驱动器、配额、受控文件夹访问等情况。
Future<bool> _probeWritable(String directoryPath) async {
  final probe = File(p.join(
    directoryPath,
    '.mydiary-write-probe-${DateTime.now().microsecondsSinceEpoch}',
  ));
  try {
    await probe.writeAsString('probe', flush: true);
    await probe.delete();
    return true;
  } catch (_) {
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {
      // 探测文件删不掉不影响结论
    }
    return false;
  }
}

Future<bool> _probeWritableAncestor(String path) async {
  var directory = Directory(path);
  for (var guard = 0; guard < 64; guard++) {
    if (await directory.exists()) return _probeWritable(directory.path);
    final parent = directory.parent;
    if (parent.path == directory.path) return false;
    directory = parent;
  }
  return false;
}

class _DirectoryStats {
  int diaryFiles = 0;
  int conflictFiles = 0;
  int foreignMarkdown = 0;
  int subdirectories = 0;
}

/// 统计一个目录里各类文件的数量。`.` 开头的目录一律跳过
/// （`.trash` 已删除、`.drafts` 草稿、`.xxx.tmp-` 写入中途的临时文件）。
Future<_DirectoryStats> _scanDirectory(String rootPath) async {
  final stats = _DirectoryStats();

  await for (final entity in Directory(rootPath)
      .list(recursive: true, followLinks: false)) {
    if (_isHidden(entity.path, rootPath)) continue;

    if (entity is Directory) {
      stats.subdirectories++;
      continue;
    }
    if (entity is! File) continue;

    final name = p.basename(entity.path);
    if (DiaryPaths.isDiaryFileName(name)) {
      stats.diaryFiles++;
    } else if (DiaryPaths.isConflictFileName(name)) {
      stats.conflictFiles++;
    } else if (name.toLowerCase().endsWith(DiaryPaths.extension)) {
      stats.foreignMarkdown++;
    }
  }
  return stats;
}

bool _isHidden(String absolutePath, String rootPath) {
  final relative = p.relative(absolutePath, from: rootPath);
  return p.split(relative).any((segment) => segment.startsWith('.'));
}

/// 磁盘类型决定要不要警告「设备没插着 / 网络不通时读不到日记」。
/// PowerShell 调用只做一次并缓存，因为界面会在每次输入变化时重新检查。
final Map<String, DriveKind> _driveKindCache = <String, DriveKind>{};

Future<DriveKind> _driveKindFor(String path) async {
  if (path.startsWith(r'\\')) return DriveKind.network;

  final letter = RegExp(r'^([A-Za-z]):').firstMatch(path)?.group(1);
  if (letter == null) return DriveKind.unknown;

  final key = letter.toUpperCase();
  if (key == 'A' || key == 'B') return DriveKind.removable;
  if (!Platform.isWindows) return DriveKind.fixed;

  final cached = _driveKindCache[key];
  if (cached != null) return cached;

  var kind = DriveKind.unknown;
  try {
    final result = await Process.run('powershell', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '(Get-Volume -DriveLetter $key -ErrorAction SilentlyContinue).DriveType',
    ]);
    final text = (result.stdout as String).trim();
    if (text.contains('Removable')) {
      kind = DriveKind.removable;
    } else if (text.contains('Network')) {
      kind = DriveKind.network;
    } else if (text.contains('Fixed')) {
      kind = DriveKind.fixed;
    }
  } catch (_) {
    // 查不出来就当未知，不因此阻断用户
  }

  _driveKindCache[key] = kind;
  return kind;
}

// -----------------------------------------------------------------------------
// 备份
// -----------------------------------------------------------------------------

/// 桌面端有真实文件系统，备份可用。
const bool supportsBackup = true;

/// 读出一份快照里记录的清单指纹。没有清单、或读不动，都返回 null。
Future<List<FileStamp>?> _readSnapshotStamps(String snapshotDir) async {
  final manifest = File(p.join(snapshotDir, kManifestFileName));
  if (!await manifest.exists()) return null;
  try {
    return parseManifestStamps(await manifest.readAsString());
  } catch (_) {
    return null;
  }
}

/// 列出某个种类目录下的快照目录名（目录不存在就返回空表）。
Future<List<String>> listBackupSnapshots(String kindDir) async {
  final dir = Directory(kindDir);
  if (!await dir.exists()) return const <String>[];
  final names = <String>[];
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is Directory) names.add(p.basename(entity.path));
  }
  names.sort();
  return names;
}

/// 走一遍日记目录，收集「应该进备份」的东西。
///
/// 排除的是过程痕迹（草稿、临时文件、同步标记），**包含** `.history` 和
/// `.trash`——它们和同步的规则相反，因为出错之后最想要的就是这些历史。
Future<List<FileStamp>> _collectBackupStamps(String diaryRoot) async {
  final stamps = <FileStamp>[];
  for (final relative in await _listFilesIncludingHidden(diaryRoot)) {
    if (isExcludedFromBackup(relative)) continue;
    final stat = await File(p.join(diaryRoot, relative)).stat();
    stamps.add(FileStamp(
      path: relative.replaceAll('\\', '/'),
      size: stat.size,
      modified: stat.modified,
    ));
  }
  return stamps;
}

/// 做一份备份快照。
///
/// 复制规则和「更改日记位置」完全一样：**只复制、拒绝覆盖、复制后逐个校验
/// 大小**。所以备份目标里原有的东西绝不会被这次操作毁掉。
///
/// 自动快照有两道闸，都是为了让「保留 30 份」真正等于"约一个月的写字日"：
///   1. 今天已经有自动快照 → 跳过（否则开关程序十次就产生十份）
///   2. 内容相对上一份自动快照没变 → 跳过（只是打开看看也产生一份毫无意义）
Future<BackupOutcome> createBackupSnapshot({
  required String diaryRoot,
  required String backupRoot,
  required SnapshotKind kind,
  String? label,
  DateTime? at,
}) async {
  final moment = at ?? DateTime.now();
  try {
    final kindDir = p.join(backupRoot, kind.dirName);
    final existing = await listBackupSnapshots(kindDir);

    if (kind == SnapshotKind.auto && hasAutoSnapshotToday(existing, moment)) {
      return const BackupOutcome(
        ok: true,
        skipped: true,
        message: '今天已经有一份自动备份了。',
      );
    }

    final stamps = await _collectBackupStamps(diaryRoot);

    if (kind == SnapshotKind.auto && existing.isNotEmpty) {
      final previous =
          await _readSnapshotStamps(p.join(kindDir, existing.last));
      if (previous != null && !hasChanges(previous, stamps)) {
        return const BackupOutcome(
          ok: true,
          skipped: true,
          message: '内容自上次备份以来没有变化。',
        );
      }
    }

    // 同一分钟内连做两次就补 -2、-3……**绝不覆盖已有的快照**
    var name = snapshotDirName(kind, moment, label: label);
    var target = p.join(kindDir, name);
    var attempt = 1;
    while (await Directory(target).exists()) {
      attempt++;
      target = p.join(kindDir, '$name-$attempt');
    }
    await Directory(target).create(recursive: true);

    for (final stamp in stamps) {
      final destination = File(p.join(target, stamp.path));
      await destination.parent.create(recursive: true);
      await File(p.join(diaryRoot, stamp.path)).copy(destination.path);
    }

    // 逐个校验大小，确认不是「看起来复制完了」
    final mismatched = <String>[];
    for (final stamp in stamps) {
      final destination = File(p.join(target, stamp.path));
      if (!await destination.exists() ||
          await destination.length() != stamp.size) {
        mismatched.add(stamp.path);
      }
    }
    if (mismatched.isNotEmpty) {
      return BackupOutcome(
        ok: false,
        snapshotPath: target,
        message: '复制后校验未通过：${mismatched.length} 个文件大小不一致，'
            '例如 ${mismatched.first}。\n这份备份不要用，'
            '请检查目标磁盘的空间和权限。',
      );
    }

    await File(p.join(target, kManifestFileName)).writeAsString(
      renderManifest(
        kind: kind,
        at: moment,
        source: diaryRoot,
        label: label,
        files: stamps,
      ),
    );

    // 先建新的、再修剪：备份失败的时候绝不修剪
    var pruned = 0;
    if (kind == SnapshotKind.auto) {
      for (final victim in autoSnapshotsToDelete(
        await listBackupSnapshots(kindDir),
      )) {
        final victimDir = p.join(kindDir, victim);
        // 删之前确认它确实是我们的一份快照。
        // **一个不认识的目录，宁可多占空间也绝不删。**
        if (await _readSnapshotStamps(victimDir) == null) continue;
        try {
          await Directory(victimDir).delete(recursive: true);
          pruned++;
        } catch (_) {
          // 删不掉就算了，绝不因为清理失败去动别的东西
        }
      }
    }

    return BackupOutcome(
      ok: true,
      snapshotPath: target,
      pruned: pruned,
      message: '已备份 ${stamps.length} 个文件。',
    );
  } catch (error) {
    return BackupOutcome(ok: false, message: '备份失败：$error');
  }
}

/// 从一份快照恢复到**一个新目录**。
///
/// 恢复**永不**写回正在使用的日记目录：恢复过程中覆盖原数据，是"备份把
/// 数据弄丢"最经典的事故。想让程序改用恢复出来的那份，走「更改日记位置」。
Future<BackupOutcome> restoreBackupSnapshot({
  required String snapshotDir,
  required String targetParent,
  DateTime? at,
}) async {
  final moment = at ?? DateTime.now();
  try {
    if (!await Directory(snapshotDir).exists()) {
      return const BackupOutcome(ok: false, message: '这份备份已经不存在了。');
    }

    var target = p.join(targetParent, restoreDirName(moment));
    var attempt = 1;
    while (await Directory(target).exists()) {
      attempt++;
      target = p.join(targetParent, '${restoreDirName(moment)}-$attempt');
    }

    var copied = 0;
    for (final relative in await _listFilesIncludingHidden(snapshotDir)) {
      // 清单本身不参与恢复，它不是日记内容
      if (p.basename(relative) == kManifestFileName) continue;
      final destination = File(p.join(target, relative));
      await destination.parent.create(recursive: true);
      await File(p.join(snapshotDir, relative)).copy(destination.path);
      copied++;
    }

    return BackupOutcome(
      ok: true,
      snapshotPath: target,
      message: '已恢复 $copied 个文件到：\n$target',
    );
  } catch (error) {
    return BackupOutcome(ok: false, message: '恢复失败：$error');
  }
}

/// 把整个日记目录复制到新位置。
///
/// 三条硬性约束：
///   1. **只复制，从不移动、从不删除**。旧位置的数据永远原封不动，
///      这样即使中途出错，用户最多是多了一份副本，不可能少东西。
///   2. **拒绝覆盖**。目标位置只要存在同名文件就立刻中止，绝不覆盖。
///      这条保证了「复制」在任何情况下都不会毁掉目标位置原有的内容。
///   3. **复制后逐个文件校验**。校验不过就报错，由调用方决定不要切换设置。
Future<DiaryCopyOutcome> copyDiaryTree({
  required String from,
  required String to,
  void Function(int copied, int total)? onProgress,
}) async {
  try {
    final relativePaths = await _listFilesIncludingHidden(from);
    if (relativePaths.isEmpty) {
      return const DiaryCopyOutcome(
        ok: true,
        filesCopied: 0,
        message: '当前位置没有文件需要复制。',
      );
    }

    var copied = 0;
    for (final relative in relativePaths) {
      final source = File(p.join(from, relative));
      final destination = File(p.join(to, relative));

      if (await destination.exists()) {
        return DiaryCopyOutcome(
          ok: false,
          filesCopied: copied,
          message: '目标位置已经存在同名文件：\n$relative\n'
              '为避免覆盖任何内容，复制已中止。请改用空文件夹。',
        );
      }

      await destination.parent.create(recursive: true);
      await source.copy(destination.path);
      copied++;
      onProgress?.call(copied, relativePaths.length);
    }

    // 逐个文件校验大小，确认不是"看起来复制完了"
    final mismatched = <String>[];
    for (final relative in relativePaths) {
      final source = File(p.join(from, relative));
      final destination = File(p.join(to, relative));
      if (!await destination.exists()) {
        mismatched.add(relative);
        continue;
      }
      if (await source.length() != await destination.length()) {
        mismatched.add(relative);
      }
    }

    if (mismatched.isNotEmpty) {
      return DiaryCopyOutcome(
        ok: false,
        filesCopied: copied,
        message: '复制后校验未通过，有 ${mismatched.length} 个文件大小不一致，'
            '例如：${mismatched.first}\n'
            '日记位置没有被改动，请检查目标磁盘空间和权限。',
      );
    }

    return DiaryCopyOutcome(
      ok: true,
      filesCopied: copied,
      message: '已复制 $copied 个文件。原来的位置没有做任何改动，'
          '确认新位置没问题之后，你可以自己决定要不要删掉旧文件夹。',
    );
  } catch (error) {
    return DiaryCopyOutcome(
      ok: false,
      filesCopied: 0,
      message: '复制失败：$error\n日记位置没有被改动。',
    );
  }
}

Future<List<String>> _listFilesIncludingHidden(String rootPath) async {
  final result = <String>[];
  await for (final entity in Directory(rootPath)
      .list(recursive: true, followLinks: false)) {
    if (entity is File) {
      result.add(p.relative(entity.path, from: rootPath));
    }
  }
  return result;
}

/// 可用的磁盘根目录，供界面上的快捷选择使用。
List<String> listDiaryDriveRoots() {
  if (!Platform.isWindows) return <String>['/'];
  final roots = <String>[];
  for (var code = 'A'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++) {
    final root = '${String.fromCharCode(code)}:\\';
    try {
      if (Directory(root).existsSync()) roots.add(root);
    } catch (_) {
      // 没有介质的读卡器/光驱会抛异常，跳过即可
    }
  }
  return roots;
}

/// 返回**完整路径**而不是名字：这样界面不用自己拼路径，
/// 也就不需要知道当前平台用哪种分隔符。
Future<List<String>> listDiarySubdirectories(String path) async {
  final result = <String>[];
  try {
    await for (final entity
        in Directory(path).list(followLinks: false)) {
      if (entity is Directory) result.add(entity.path);
    }
  } catch (_) {
    // 权限不足或路径不可读时返回空列表，由界面给出提示
  }
  result.sort((a, b) => p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
  return result;
}

/// 目录的上级；已经在根上则返回 null。
String? diaryParentDirectory(String path) {
  final parent = Directory(path).parent.path;
  return parent == path ? null : parent;
}

// -----------------------------------------------------------------------------
// 每日提醒
// -----------------------------------------------------------------------------
//
// 装进系统的四样东西，缺一不可：
//   1. `%APPDATA%\riji\remind.ps1`   到点要跑的脚本（判断今天写没写 + 发通知）
//   2. `HKCU\...\AppUserModelId\...` 通知显示成「日迹」而不是某个进程名
//   3. `HKCU\Software\Classes\riji`  点通知能回到日记
//   4. 一个每天到点的计划任务
//
// 为什么不用插件：本项目零插件（见 README），所以这些都靠**命令行调
// PowerShell**——这条路在本项目已经是既有做法（磁盘类型查询就是这么做的）。
// 实测过：`Register-ScheduledTask` 非管理员可用，通知能弹、归属能显示成「日迹」。

/// 只有 Windows 能用：计划任务 + WinRT 通知都是 Windows 的东西。
bool get supportsReminder => Platform.isWindows;

/// 当前程序本体的完整路径。
///
/// 用途：注册 `riji://` 协议时要写进注册表（点通知才能回到这个程序），
/// 以及提醒的"指纹"里要带上它（程序被挪了位置就得重新注册）。
String get appExecutablePath => Platform.resolvedExecutable;

/// 程序的进程名（不带 `.exe`）。
///
/// 提醒脚本靠它判断"程序是不是正在跑"：在跑就交给程序自己提醒，
/// 不重复发系统通知。默认就是 exe 的文件名。
String _appProcessName() {
  try {
    final name = p.basenameWithoutExtension(Platform.resolvedExecutable);
    if (name.trim().isNotEmpty) return name;
  } catch (_) {
    // 拿不到就用一个保守的默认值
  }
  return 'riji';
}

/// 提醒脚本、图标、排队的外部动作，都放设置目录。
///
/// 和单实例锁同一个理由：这些是**每台机器**的东西，不该跟着可配置、
/// 会被同步的日记目录跑。放到日记目录里还会被同步到手机上去。
File _reminderScriptFile() =>
    File(p.join(_appDataDir().path, 'remind.ps1'));

File _reminderIconFile() => File(p.join(_appDataDir().path, 'reminder.ico'));

File _activationFile() =>
    File(p.join(_appDataDir().path, 'activation.txt'));

/// 跑一段 PowerShell，只看退出码。
///
/// **不解析它的输出**：子进程的 stdout 按系统 ANSI 代码页解码，中文会变成
/// 乱码，而且乱得没有规律。要判断成败就用退出码（`$ErrorActionPreference='Stop'`
/// 会让出错的那一步把退出码变成 1）。
Future<bool> _runPowerShell(String command) async {
  try {
    final result = await Process.run('powershell', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      command,
    ]);
    // 只看退出码，**不解析输出**：子进程的 stdout/stderr 按系统 ANSI 代码页
    // 解码，中文会变成没有规律的乱码。出错的那一步因为
    // `$ErrorActionPreference='Stop'` 会把退出码变成非 0，这就够判断了。
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 把提醒装进系统。**幂等**：重复调用就是覆盖一遍，所以每次改设置都能直接调它。
///
/// 失败的顺序是：先能写的（文件、注册表）再建任务。中途失败会留下半套东西，
/// 但两边都能收拾——再启用一次就是覆盖，停用则一次全删。
/// 调用方**只在全部成功之后**才把指纹记进设置，所以失败会在下次启动时自动重试。
Future<ReminderOutcome> applyReminder({
  required ReminderTime time,
  required List<int> weekdays,
  required String diaryRoot,
  required List<int> iconBytes,
}) async {
  if (!Platform.isWindows) {
    return const ReminderOutcome(ok: false, message: '每日提醒目前只在 Windows 上提供。');
  }

  try {
    await _appDataDir().create(recursive: true);

    // 1. 图标。注册表里的 IconUri 要指向一个 **.ico/.png 文件**（exe 不行），
    //    而程序自己的图标是编进 exe 资源里的、磁盘上没有这个文件，
    //    所以从打包资源里写一份出来。
    final icon = _reminderIconFile();
    await icon.writeAsBytes(iconBytes, flush: true);

    // 2. 脚本。⚠️ **必须带 UTF-8 BOM**：PS 5.1 读没有 BOM 的文件会按 ANSI 解，
    //    里面的中文会变成语法错误（不是乱码，是直接跑不起来）。
    final script = _reminderScriptFile();
    await script.writeAsBytes(
      <int>[
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(buildReminderScript(
          diaryRoot: diaryRoot,
          exeName: _appProcessName(),
        )),
      ],
      flush: true,
    );

    // 3. 通知归属
    final appIdOk = await _runPowerShell(buildAppModelIdCommand(
      appId: reminderAppId,
      displayName: '日迹',
      iconPath: icon.path,
    ));
    if (!appIdOk) {
      return const ReminderOutcome(
        ok: false,
        message: '写通知归属（注册表）失败。可以再试一次；不行就先别开这个功能。',
      );
    }

    // 4. 协议：点通知要能回到日记
    final protocolOk = await _runPowerShell(buildProtocolHandlerCommand(
      protocol: reminderProtocol,
      exePath: Platform.resolvedExecutable,
      description: '日迹：打开今天的日记',
    ));
    if (!protocolOk) {
      return const ReminderOutcome(
        ok: false,
        message: '注册 riji:// 协议失败，点通知回不到日记。可以再试一次。',
      );
    }

    // 5. 计划任务：真正决定"几点提醒"的那一样
    final taskOk = await _runPowerShell(buildRegisterTaskCommand(
      time: time,
      weekdays: weekdays,
      scriptPath: script.path,
    ));
    if (!taskOk) {
      return const ReminderOutcome(
        ok: false,
        message: '建计划任务失败，所以到点不会提醒。可以再试一次。',
      );
    }

    return ReminderOutcome(
      ok: true,
      message: '已启用：${reminderScheduleLabel(time, weekdays)}，'
          '只在那天还没写的时候提醒。',
    );
  } catch (error) {
    return ReminderOutcome(ok: false, message: '启用失败：$error');
  }
}

/// 把提醒从系统里撤掉：任务、脚本、图标、两个注册表项，一个不留。
///
/// **每一步都独立容错**：删不掉其中一样不该让剩下的留在系统里。
Future<ReminderOutcome> removeReminder() async {
  if (!Platform.isWindows) {
    return const ReminderOutcome(ok: true, message: '已关闭。');
  }

  final failures = <String>[];

  if (!await _runPowerShell(buildUnregisterTaskCommand())) {
    // 任务本来就不存在时 Unregister 也会返回非 0，不能当成"失败"报给用户
    failures.add('计划任务（可能本来就不存在）');
  }
  if (!await _runPowerShell(
      buildRemoveAppModelIdCommand(appId: reminderAppId))) {
    failures.add('通知归属注册表项（可能本来就不存在）');
  }
  if (!await _runPowerShell(
      buildRemoveProtocolHandlerCommand(protocol: reminderProtocol))) {
    failures.add('协议注册表项（可能本来就不存在）');
  }

  for (final file in <File>[_reminderScriptFile(), _reminderIconFile()]) {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      failures.add(p.basename(file.path));
    }
  }

  if (failures.isEmpty) {
    return const ReminderOutcome(ok: true, message: '已关闭，系统里没留东西。');
  }
  // 「本来就不存在」也会走到这里，所以措辞不能是"删除失败"
  return ReminderOutcome(
    ok: true,
    message: '已关闭。这几样没确认到（多半是本来就没有）：${failures.join('、')}',
  );
}

/// 排队一个"外部要我做的事"。
///
/// 点通知时 Windows 会起第二个实例（带 `riji://today`），而第二个实例拿不到
/// 单实例锁、也**没法把已开的窗口调到前台**（不用插件做不到）。所以它只能
/// 留个纸条走人，由正在跑的那个实例自己发现。文件系统是这个项目里唯一
/// 可靠的进程间通道——而且它本来就在盯着磁盘（外部改动轮询）。
Future<void> queueActivation(String url) async {
  try {
    await _activationFile().writeAsString('$url\n', flush: true);
  } catch (_) {
    // 写不进去就算了：最坏情况是这一次点击没反应，不该因此报错
  }
}

/// 取走排队的外部动作（读到就删）。没有、或者读不动，都返回 null。
Future<String?> takeQueuedActivation() async {
  try {
    final file = _activationFile();
    if (!await file.exists()) return null;
    final text = await file.readAsString();
    await file.delete();
    final first = text.split('\n').first.trim();
    return first.isEmpty ? null : first;
  } catch (_) {
    return null;
  }
}
