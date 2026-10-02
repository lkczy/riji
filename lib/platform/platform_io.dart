import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/backup.dart';

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

File _settingsFile() {
  final base = Platform.environment['APPDATA'] ??
      Platform.environment['XDG_CONFIG_HOME'] ??
      Directory.current.path;
  return File(p.join(base, 'riji', 'settings.json'));
}

/// 旧版本（程序还叫 riji 时）的设置目录名。
///
/// 改名之后不能当作什么都没发生：设置里存着**用户的日记目录**。新目录里
/// 找不到它，程序就会回退到默认位置、打开一个空白日记——用户会以为日记
/// 没了（数据其实一个字节都没少，只是程序不知道该去哪找）。
const String _legacyAppDirName = 'riji';

/// 首次运行时把旧设置搬过来。只在**新位置还没有设置**时才动手，所以只生效一次。
///
/// 搬不动也绝不报错：最坏情况是回到默认日记位置，那也比打不开程序好。
Future<void> _migrateLegacySettings(File target) async {
  try {
    if (await target.exists()) return;
    final base = Platform.environment['APPDATA'];
    if (base == null || base.isEmpty) return;
    final legacy = File(p.join(base, _legacyAppDirName, 'settings.json'));
    if (!await legacy.exists()) return;
    await target.parent.create(recursive: true);
    await legacy.copy(target.path);
    stderr.writeln('[riji] 已把旧设置迁移到 ${target.path}');
  } catch (_) {
    // 迁移失败不能影响启动
  }
}

Future<String?> readSettingsJson() async {
  final file = _settingsFile();
  await _migrateLegacySettings(file);
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
