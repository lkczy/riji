import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/day.dart';
import '../core/diary_codec.dart';
import '../core/diary_paths.dart';
import '../core/history.dart';
import '../core/models/diary_entry.dart';
import 'diary_store.dart';

/// 文件系统实现。桌面端和手机端都用它——手机端只是换一个根目录
/// （App 沙盒），代码完全一样。这也是「一天一个 Markdown 文件」
/// 这个数据格式的最大回报。
class FsDiaryStore implements DiaryStore {
  FsDiaryStore({required String rootPath, required this.deviceName})
      : rootPath = p.normalize(p.absolute(rootPath));

  final String rootPath;
  final String deviceName;

  int _tempCounter = 0;

  /// 每个文件「我们上次看到的原始内容」。
  ///
  /// 用来回答一个必须回答的问题：**磁盘上的内容还是不是我们读到的那一份？**
  /// 如果答案是否，说明有人在我们背后改了它（Syncthing 从手机同步过来、
  /// 另一个程序实例、用户拿别的编辑器手改），这时候绝不能直接覆盖。
  ///
  /// 存原始文本而不是哈希：不必担心碰撞，而且日记的数据量小到可以忽略——
  /// 十年 3650 篇、每篇约 1KB，总共约 4MB。
  final Map<String, String> _observedContent = <String, String>{};

  Directory get _root => Directory(rootPath);
  Directory get _drafts =>
      Directory(p.join(rootPath, DiaryPaths.draftsDirName));
  Directory get _trash =>
      Directory(p.join(rootPath, DiaryPaths.trashDirName));

  @override
  String get locationDescription => rootPath;

  @override
  bool get isPersistent => true;

  Future<void> ensureRoot() async {
    if (!await _root.exists()) {
      await _root.create(recursive: true);
    }
  }

  // ---------------------------------------------------------------------------
  // 读取
  // ---------------------------------------------------------------------------

  @override
  Future<List<DiaryEntry>> loadAll() async {
    if (!await _root.exists()) return <DiaryEntry>[];

    final entries = <DiaryEntry>[];
    await for (final entity in _root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (_isHidden(entity.path)) continue;
      if (!DiaryPaths.isDiaryFileName(p.basename(entity.path))) continue;

      final entry = await _readEntry(entity);
      if (entry != null) entries.add(entry);
    }

    entries.sort((a, b) => b.date.compareTo(a.date));
    return entries;
  }

  @override
  Future<DiaryEntry?> loadByDate(DateTime date) async {
    final file = File(_pathFor(date));
    if (!await file.exists()) return null;
    return _readEntry(file);
  }

  /// 任何一层目录以 `.` 开头就跳过：`.trash`（已删除）、`.drafts`（草稿）、
  /// `.xxx.tmp-123`（写入中途的临时文件）都不该被当成日记读进来。
  /// 漏掉这条，用户删掉的日记会在下次启动时"复活"。
  bool _isHidden(String absolutePath) {
    final relative = p.relative(absolutePath, from: rootPath);
    return p.split(relative).any((segment) => segment.startsWith('.'));
  }

  /// 按字节读出来再解成文本。
  /// `allowMalformed`：用老编辑器存成 GBK 的文件不该整个消失。
  Future<String> _readRawContent(File file) async {
    final bytes = await file.readAsBytes();
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<DiaryEntry?> _readEntry(File file) async {
    try {
      final fallbackDate = DiaryPaths.dateFromFileName(p.basename(file.path));
      if (fallbackDate == null) return null;

      final content = await _readRawContent(file);
      // 记下"我们读到的就是这一份"，保存时要用它判断磁盘有没有被别人改过
      _observedContent[file.path] = content;

      final stat = await file.stat();
      return DiaryCodec.decode(
        content,
        fallbackDate: fallbackDate,
        fallbackTimestamp: stat.modified,
        fallbackDevice: deviceName,
      );
    } catch (error) {
      // 一个文件读不动不能让整个程序打不开
      debugPrint('[riji] 读取失败，已跳过 ${file.path}：$error');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 写入
  // ---------------------------------------------------------------------------

  @override
  Future<DiarySaveOutcome> save(DiaryEntry entry) async {
    await ensureRoot();
    final target = File(_pathFor(entry.date));
    final encoded = DiaryCodec.encode(entry);

    String? onDisk;
    if (await target.exists()) {
      onDisk = await _readRawContent(target);
    }

    // 磁盘上的内容已经不是我们上次读到的那一份 —— 有人在背后改了这一天。
    //
    // 这时候**两个版本都不能丢**。做法和 Syncthing 一致：
    // 对方的版本原样另存为冲突文件，我们正在编辑的版本留在正式文件里，
    // 然后把这件事如实报告给上层，由界面告诉用户去合并。
    // 直接覆盖对方，或者把编辑器里的内容丢掉，都是不可接受的。
    if (onDisk != null && onDisk != _observedContent[target.path]) {
      final conflictPath = _pathForConflict(entry.date);
      await _atomicWriteString(File(conflictPath), onDisk);
      await _writeEntry(target, encoded);
      return DiarySaveOutcome(wrote: true, conflictPath: conflictPath);
    }

    // 内容没变就不写盘。自动保存每秒都在跑，每次都写会把文件的
    // 修改时间刷爆，也会让 Syncthing 和 git 产生大量无意义的同步动作。
    if (onDisk == encoded) {
      return const DiarySaveOutcome(wrote: false);
    }

    await _writeEntry(target, encoded);
    return const DiarySaveOutcome(wrote: true);
  }

  /// 写正式文件，并记下"磁盘上现在是这一份"。
  Future<void> _writeEntry(File target, String content) async {
    await _atomicWriteString(target, content);
    _observedContent[target.path] = content;
  }

  String _pathForConflict(DateTime date) => p.join(
        rootPath,
        date.year.toString().padLeft(4, '0'),
        DiaryPaths.conflictFileNameFor(date, DateTime.now(), deviceName),
      );

  /// 原子写入：先写同目录下的临时文件，flush 到磁盘，再 rename 覆盖目标。
  ///
  /// 同分区 rename 是原子操作，所以任何时刻断电，目标文件要么是旧的完整内容、
  /// 要么是新的完整内容，**不存在半截文件**。直接覆写则可能在写到一半时断电，
  /// 那样丢的不是一次编辑，而是整天甚至整年的日记。
  Future<void> _atomicWriteString(File target, String content) async {
    await target.parent.create(recursive: true);

    final tempPath = p.join(
      target.parent.path,
      '.${p.basename(target.path)}.tmp-${DateTime.now().microsecondsSinceEpoch}-${_tempCounter++}',
    );
    final temp = File(tempPath);

    final handle = await temp.open(mode: FileMode.write);
    try {
      await handle.writeString(content);
      await handle.flush(); // 真正落盘，而不是停在系统缓存里
    } finally {
      await handle.close();
    }

    try {
      await temp.rename(target.path);
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // 清理临时文件失败无所谓，它已经被 _isHidden 挡住，不会被误读
      }
      rethrow;
    }
  }

  /// 软删除：移进回收站，不抹字节。
  ///
  /// 文件名里带上删除时刻（微秒），所以同一天删两次不会互相覆盖，
  /// 而且用户手工在资源管理器里翻回收站时能看出先后。
  @override
  Future<void> deleteEntry(DateTime date) async {
    final target = File(_pathFor(date));
    if (!await target.exists()) return;

    await _trash.create(recursive: true);
    final destination =
        p.join(_trash.path, DiaryPaths.trashFileNameFor(date, DateTime.now()));
    await target.rename(destination);
    _observedContent.remove(target.path);
  }

  // ---------------------------------------------------------------------------
  // 回收站
  // ---------------------------------------------------------------------------

  @override
  Future<List<TrashedEntry>> listTrash() async {
    if (!await _trash.exists()) return <TrashedEntry>[];

    final items = <TrashedEntry>[];
    await for (final entity in _trash.list(followLinks: false)) {
      if (entity is! File) continue;

      final name = p.basename(entity.path);
      final date = DiaryPaths.trashDateFromFileName(name);
      if (date == null) continue;

      items.add(TrashedEntry(
        id: entity.path,
        date: date,
        deletedAt: DiaryPaths.trashDeletedAtFromFileName(name),
      ));
    }

    items.sort((a, b) => b.date.compareTo(a.date));
    return items;
  }

  @override
  Future<String> readTrashedContent(TrashedEntry item) =>
      _readRawContent(File(item.id));

  @override
  Future<DiarySaveOutcome> restoreFromTrash(TrashedEntry item) async {
    final source = File(item.id);
    if (!await source.exists()) {
      throw StateError('回收站里的这个文件已经不在了：${item.id}');
    }
    final content = await _readRawContent(source);
    final target = File(_pathFor(item.date));

    // 那一天已经有内容了（删掉之后又写了新的）。
    // **绝不覆盖**：把回收站里的这份另存为冲突文件，两边都保住。
    if (await target.exists()) {
      final conflictPath = _pathForConflict(item.date);
      await _atomicWriteString(File(conflictPath), content);
      try {
        await source.delete();
      } catch (_) {
        // 删不掉原件不影响结果：内容已经另存好了
      }
      return DiarySaveOutcome(wrote: true, conflictPath: conflictPath);
    }

    await target.parent.create(recursive: true);
    await source.rename(target.path);
    _observedContent[target.path] = content;
    return const DiarySaveOutcome(wrote: true);
  }

  @override
  Future<void> purgeTrashEntry(TrashedEntry item) async {
    final file = File(item.id);
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉就留着，下次再说——这里绝不能抛异常打断界面
    }
  }

  // ---------------------------------------------------------------------------
  // 历史快照
  // ---------------------------------------------------------------------------

  Directory _snapshotDir(DateTime date) => Directory(
        p.join(rootPath, DiaryPaths.historyDirName, formatIsoDate(date)),
      );

  @override
  Future<String?> readRawEntry(DateTime date) async {
    final file = File(_pathFor(date));
    if (!await file.exists()) return null;
    return _readRawContent(file);
  }

  @override
  Future<void> writeSnapshot(
    DateTime date,
    String content, {
    required SnapshotReason reason,
    required DateTime at,
  }) async {
    final dir = _snapshotDir(date);
    await dir.create(recursive: true);
    final target =
        File(p.join(dir.path, DiaryPaths.snapshotFileNameFor(at, reason)));
    await _atomicWriteString(target, content);
    await _pruneSnapshots(date);
  }

  /// 超出上限时丢一份。策略见 [SnapshotPolicy.pruneIndex]。
  Future<void> _pruneSnapshots(DateTime date) async {
    final snapshots = await listSnapshots(date);
    final index = SnapshotPolicy.pruneIndex(snapshots.length);
    if (index == null) return;
    await deleteSnapshot(snapshots[index]);
  }

  @override
  Future<List<DiarySnapshot>> listSnapshots(DateTime date) async {
    final dir = _snapshotDir(date);
    if (!await dir.exists()) return <DiarySnapshot>[];

    final day = dateOnly(date);
    final snapshots = <DiarySnapshot>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;

      final name = p.basename(entity.path);
      final at = DiaryPaths.snapshotTimeFromFileName(name, day);
      final reason = DiaryPaths.snapshotReasonFromFileName(name);
      if (at == null || reason == null) continue;

      snapshots.add(DiarySnapshot(
        id: entity.path,
        savedAt: at,
        reason: reason,
      ));
    }

    // 时间戳在文件名最前面，所以排序也可靠
    snapshots.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return snapshots;
  }

  @override
  Future<String> readSnapshot(DiarySnapshot snapshot) =>
      _readRawContent(File(snapshot.id));

  @override
  Future<void> deleteSnapshot(DiarySnapshot snapshot) async {
    final file = File(snapshot.id);
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 快照删不掉不是要紧事，下次超限时会再试
    }
  }

  @override
  Future<void> restoreRaw(DateTime date, String content) async {
    await ensureRoot();
    await _writeEntry(File(_pathFor(date)), content);
  }

  // ---------------------------------------------------------------------------
  // 草稿
  // ---------------------------------------------------------------------------

  File _draftFile(DateTime date) => File(
        p.joinAll(<String>[rootPath, ...DiaryPaths.draftSegmentsFor(date)]),
      );

  @override
  Future<String?> readDraft(DateTime date) async {
    final file = _draftFile(date);
    if (!await file.exists()) return null;
    try {
      return utf8.decode(await file.readAsBytes(), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeDraft(DateTime date, String body) async {
    await _drafts.create(recursive: true);
    await _atomicWriteString(_draftFile(date), body);
  }

  @override
  Future<void> clearDraft(DateTime date) async {
    final file = _draftFile(date);
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 草稿删不掉不是要紧事，下次启动最多再提示一次恢复
    }
  }

  @override
  Future<List<DateTime>> datesWithDrafts() async {
    if (!await _drafts.exists()) return <DateTime>[];

    final pattern = RegExp(r'^(\d{4}-\d{2}-\d{2})\.draft$');
    final dates = <DateTime>[];
    await for (final entity in _drafts.list()) {
      if (entity is! File) continue;
      final match = pattern.firstMatch(p.basename(entity.path));
      if (match == null) continue;
      final date = parseIsoDate(match.group(1)!);
      if (date != null) dates.add(date);
    }
    dates.sort((a, b) => b.compareTo(a));
    return dates;
  }

  // ---------------------------------------------------------------------------
  // 冲突
  // ---------------------------------------------------------------------------

  @override
  Future<List<ConflictFile>> findConflicts() async {
    if (!await _root.exists()) return <ConflictFile>[];

    final conflicts = <ConflictFile>[];
    await for (final entity in _root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (_isHidden(entity.path)) continue;

      final fileName = p.basename(entity.path);
      final date = DiaryPaths.conflictDateFromFileName(fileName);
      if (date == null) continue;

      conflicts.add(ConflictFile(
        path: entity.path,
        fileName: fileName,
        date: date,
      ));
    }
    return conflicts;
  }

  // ---------------------------------------------------------------------------

  String _pathFor(DateTime date) =>
      p.joinAll(<String>[rootPath, ...DiaryPaths.segmentsFor(date)]);
}
