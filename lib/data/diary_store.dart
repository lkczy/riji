import '../core/day.dart';
import '../core/diary_codec.dart';
import '../core/history.dart';
import '../core/models/diary_entry.dart';

/// 一个同步冲突遗留的文件。
///
/// 我们**不自动合并**：程序无法判断用户想保留哪句话。
/// 正确做法是把它列出来，让用户自己处理。
class ConflictFile {
  const ConflictFile({
    required this.path,
    required this.fileName,
    required this.date,
  });

  final String path;
  final String fileName;
  final DateTime date;
}

/// 一次保存的结果。
///
/// [conflictPath] 非空表示：写入前发现**磁盘上的内容已经不是我们读到的那一份**
/// （Syncthing 从手机同步过来、另一个程序实例、用户用别的编辑器改过），
/// 对方的版本被原样保存在这个文件里，两边都没有丢。
class DiarySaveOutcome {
  const DiarySaveOutcome({required this.wrote, this.conflictPath});

  /// 是否真的写了盘（内容没变时会跳过写入）。
  final bool wrote;

  /// 检测到外部改动时，对方版本的保存位置。
  final String? conflictPath;

  bool get hadConflict => conflictPath != null;
}

/// 一份历史快照（**只有元信息，不含正文**）。
///
/// 刻意不在这里带正文摘要：自动保存是亚秒级的，而"要不要留一份快照"这个
/// 判断每次保存都要做一次，所以列出快照必须便宜到只是一次目录枚举。
/// 需要正文时用 `readSnapshot` 单独去读——那是打开历史面板时才发生的事。
class DiarySnapshot {
  const DiarySnapshot({
    required this.id,
    required this.savedAt,
    required this.reason,
  });

  /// 存储层自己认的标识（文件系统实现里就是绝对路径）。
  final String id;

  final DateTime savedAt;
  final SnapshotReason reason;
}

/// 回收站里的一条（同样只有元信息）。
class TrashedEntry {
  const TrashedEntry({
    required this.id,
    required this.date,
    required this.deletedAt,
  });

  final String id;
  final DateTime date;
  final DateTime? deletedAt;
}

/// 存储层接口。
///
/// 这是「桌面端优先、将来扩展手机端」这个目标的技术落点：
/// 桌面端用文件系统实现（[FsDiaryStore]），手机端换成 App 沙盒目录，
/// 测试和 web 预览用内存实现（[MemoryDiaryStore]）。
/// **UI 层只依赖这个接口**，所以换平台不需要改任何界面代码。
///
/// 数据量的一个重要事实：一年 365 个文件，写十年也才 3650 个。
/// 所以 [loadAll] 直接全量扫描就是毫秒级，不需要数据库索引。
abstract class DiaryStore {
  /// 全部条目，按日期倒序（最新在前）。
  Future<List<DiaryEntry>> loadAll();

  /// 读取某一天。不存在返回 null。
  Future<DiaryEntry?> loadByDate(DateTime date);

  /// 写入某一天。
  ///
  /// 实现必须保证三件事：
  ///   1. **内容没变就不写**，否则自动保存会不断刷新文件修改时间；
  ///   2. **写入是原子的**，先写临时文件再 rename，断电不产生半截文件；
  ///   3. **绝不静默覆盖别人的改动**——写入前要确认磁盘上的内容还是自己
  ///      上次读到的那一份，不是的话把对方另存为冲突文件并如实报告。
  Future<DiarySaveOutcome> save(DiaryEntry entry);

  /// 删除某一天。
  ///
  /// 实现应当是**软删除**（移入回收目录），而不是真的抹掉字节。
  /// 日记程序没有「后悔药」是不可接受的。
  Future<void> deleteEntry(DateTime date);

  // ---------------------------------------------------------------------------
  // 回收站
  // ---------------------------------------------------------------------------

  /// 回收站里的内容，按日期倒序。
  Future<List<TrashedEntry>> listTrash();

  /// 读取回收站里某一条的原始内容（给列表显示摘要用）。
  Future<String> readTrashedContent(TrashedEntry item);

  /// 把回收站里的一条放回去。
  ///
  /// 如果那一天**已经有内容了**（删完又写了新的），绝不能覆盖：对方的版本
  /// 被另存为冲突文件，两边都保住，并由返回值如实报告。
  Future<DiarySaveOutcome> restoreFromTrash(TrashedEntry item);

  /// 彻底删掉回收站里的一条。这是唯一真正抹字节的地方。
  Future<void> purgeTrashEntry(TrashedEntry item);

  // ---------------------------------------------------------------------------
  // 历史快照
  // ---------------------------------------------------------------------------

  /// 读取某一天的**原始文件内容**，不做解析。
  ///
  /// 历史快照必须存原始字节：解析再重新编码会丢掉手工编辑的痕迹，
  /// 而快照的全部意义就是"当时到底是什么样子"。不存在返回 null。
  Future<String?> readRawEntry(DateTime date);

  /// 留一份快照。调用方负责按 [SnapshotPolicy] 判断该不该留。
  Future<void> writeSnapshot(
    DateTime date,
    String content, {
    required SnapshotReason reason,
    required DateTime at,
  });

  /// 某一天的历史快照，按时间**从新到旧**。
  Future<List<DiarySnapshot>> listSnapshots(DateTime date);

  /// 读取一份快照的原始内容。
  Future<String> readSnapshot(DiarySnapshot snapshot);

  Future<void> deleteSnapshot(DiarySnapshot snapshot);

  /// 把原始内容写回某一天。用于恢复历史版本。
  ///
  /// 和 [save] 不同，它**不做"外部改动"检查**——调用方已经明确知道自己在
  /// 覆盖什么（用户选了"恢复这一版"），而且在真正覆盖之前必须先留一份
  /// [SnapshotReason.beforeRestore] 快照。
  Future<void> restoreRaw(DateTime date, String content);

  /// 读取草稿正文。草稿是本机的，不参与同步。
  Future<String?> readDraft(DateTime date);

  Future<void> writeDraft(DateTime date, String body);

  Future<void> clearDraft(DateTime date);

  /// 存在草稿的日期。用于启动时提示恢复。
  Future<List<DateTime>> datesWithDrafts();

  /// 同步冲突遗留的文件。
  Future<List<ConflictFile>> findConflicts();

  /// 给用户看的存储位置描述。
  String get locationDescription;

  /// 内容是否真的落到了磁盘上。
  ///
  /// 这个标志存在的唯一目的，是**不给出虚假的安心感**：
  /// 内存实现下状态栏不能显示"已保存"，否则用户会以为日记安全了，
  /// 关掉页面才发现什么都没留下。日记程序撒这种谎是不可接受的。
  bool get isPersistent;
}

/// 内存实现。用于单元测试和 web 预览。
class MemoryDiaryStore implements DiaryStore {
  MemoryDiaryStore({this.deviceName = 'memory'});

  final String deviceName;

  final Map<String, DiaryEntry> _entries = <String, DiaryEntry>{};
  final Map<String, String> _drafts = <String, String>{};
  final List<ConflictFile> _conflicts = <ConflictFile>[];

  /// 每一条日记的**原始文件内容**。
  ///
  /// 内存实现也存一份，是因为 `readRawEntry` 是接口的一部分，而历史快照
  /// 要存原始字节。让测试替身漏掉这个能力，会让依赖快照的测试失真。
  final Map<String, String> _raw = <String, String>{};
  final Map<String, List<_MemSnapshot>> _snapshots =
      <String, List<_MemSnapshot>>{};
  final List<_MemTrash> _trashItems = <_MemTrash>[];

  static String _key(DateTime date) => formatIsoDate(date);

  /// 测试辅助：预置一条条目。
  void seed(DiaryEntry entry) {
    _entries[_key(entry.date)] = entry;
    _raw[_key(entry.date)] = DiaryCodec.encode(entry);
  }

  /// 测试辅助：预置一个冲突文件。
  void seedConflict(ConflictFile conflict) => _conflicts.add(conflict);

  /// 测试辅助：让下一次 [save] 返回这个结果，用来验证界面如何处理
  /// 「写入前发现磁盘被别处改过」。
  ///
  /// 为什么需要它：那条路径的真实实现要读写文件，而 `testWidgets` 跑在
  /// 假异步环境里，`await` 真实 `dart:io` 的 Future 会**永远不返回**
  /// （假异步不驱动真事件循环）。真实文件 I/O 的正确性由
  /// `fs_diary_store_test.dart` 里的普通 `test()` 覆盖。
  DiarySaveOutcome? nextSaveOutcome;

  @override
  String get locationDescription => '内存（未持久化）';

  @override
  bool get isPersistent => false;

  @override
  Future<List<DiaryEntry>> loadAll() async {
    final all = _entries.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return all;
  }

  @override
  Future<DiaryEntry?> loadByDate(DateTime date) async => _entries[_key(date)];

  @override
  Future<DiarySaveOutcome> save(DiaryEntry entry) async {
    _entries[_key(entry.date)] = entry;
    _raw[_key(entry.date)] = DiaryCodec.encode(entry);
    final outcome = nextSaveOutcome ?? const DiarySaveOutcome(wrote: true);
    nextSaveOutcome = null;
    return outcome;
  }

  @override
  Future<void> deleteEntry(DateTime date) async {
    final entry = _entries.remove(_key(date));
    final content = _raw.remove(_key(date));
    if (entry == null && content == null) return;
    _trashItems.add(_MemTrash(
      date: dateOnly(date),
      deletedAt: DateTime.now(),
      content: content ?? DiaryCodec.encode(entry!),
    ));
  }

  @override
  Future<List<TrashedEntry>> listTrash() async {
    final items = _trashItems.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return items
        .map((item) => TrashedEntry(
              id: item.id,
              date: item.date,
              deletedAt: item.deletedAt,
            ))
        .toList();
  }

  @override
  Future<String> readTrashedContent(TrashedEntry item) async {
    for (final stored in _trashItems) {
      if (stored.id == item.id) return stored.content;
    }
    throw StateError('回收站里找不到这一条：${item.id}');
  }

  @override
  Future<DiarySaveOutcome> restoreFromTrash(TrashedEntry item) async {
    final index = _trashItems.indexWhere((t) => t.id == item.id);
    if (index < 0) {
      throw StateError('回收站里找不到这一条：${item.id}');
    }
    final stored = _trashItems.removeAt(index);
    final entry = DiaryCodec.decode(
      stored.content,
      fallbackDate: stored.date,
      fallbackTimestamp: stored.deletedAt,
      fallbackDevice: deviceName,
    );

    // 那一天已经有内容了 —— 绝不覆盖，把回收站里的这份另存为冲突文件
    if (_entries.containsKey(_key(stored.date))) {
      final conflictPath =
          '${_key(stored.date)}.conflict-restored-${stored.deletedAt.microsecondsSinceEpoch}.md';
      _conflicts.add(ConflictFile(
        path: conflictPath,
        fileName: conflictPath,
        date: stored.date,
      ));
      return DiarySaveOutcome(wrote: true, conflictPath: conflictPath);
    }

    _entries[_key(stored.date)] = entry;
    _raw[_key(stored.date)] = stored.content;
    return const DiarySaveOutcome(wrote: true);
  }

  @override
  Future<void> purgeTrashEntry(TrashedEntry item) async {
    _trashItems.removeWhere((t) => t.id == item.id);
  }

  @override
  Future<String?> readRawEntry(DateTime date) async => _raw[_key(date)];

  /// 测试辅助：模拟「同步工具把这一天的文件换掉了」。
  ///
  /// 磁盘（[_raw]）和内存里的条目（`_entries`）都跟着变成新内容——同步落到
  /// 磁盘上的就是这个样子。真正"落后"的是上层：它记着的那份原始内容还是旧的，
  /// 于是自动重载才有得可测。
  ///
  /// [content] 传 null 表示这一天在磁盘上**不存在**了（被另一台设备删掉）。
  void simulateExternalWrite(DateTime date, String? content) {
    final key = _key(date);
    if (content == null) {
      _raw.remove(key);
      _entries.remove(key);
      return;
    }
    _raw[key] = content;
    _entries[key] = DiaryCodec.decode(
      content,
      fallbackDate: dateOnly(date),
      fallbackTimestamp: DateTime.now(),
      fallbackDevice: deviceName,
    );
  }

  @override
  Future<void> writeSnapshot(
    DateTime date,
    String content, {
    required SnapshotReason reason,
    required DateTime at,
  }) async {
    final list = _snapshots.putIfAbsent(_key(date), () => <_MemSnapshot>[]);
    final stored = _MemSnapshot(
      savedAt: at,
      reason: reason,
      content: content,
      sequence: list.length,
    );
    list.add(stored);
    list.sort((a, b) => b.savedAt.compareTo(a.savedAt));

    final prune = SnapshotPolicy.pruneIndex(list.length);
    if (prune != null) list.removeAt(prune);
  }

  @override
  Future<List<DiarySnapshot>> listSnapshots(DateTime date) async {
    final list = _snapshots[_key(date)] ?? const <_MemSnapshot>[];
    return list
        .map((item) => DiarySnapshot(
              id: item.id,
              savedAt: item.savedAt,
              reason: item.reason,
            ))
        .toList();
  }

  @override
  Future<String> readSnapshot(DiarySnapshot snapshot) async {
    for (final list in _snapshots.values) {
      for (final item in list) {
        if (item.id == snapshot.id) return item.content;
      }
    }
    throw StateError('快照不存在：${snapshot.id}');
  }

  @override
  Future<void> deleteSnapshot(DiarySnapshot snapshot) async {
    for (final list in _snapshots.values) {
      list.removeWhere((item) => item.id == snapshot.id);
    }
  }

  @override
  Future<void> restoreRaw(DateTime date, String content) async {
    _raw[_key(date)] = content;
    _entries[_key(date)] = DiaryCodec.decode(
      content,
      fallbackDate: dateOnly(date),
      fallbackTimestamp: DateTime.now(),
      fallbackDevice: deviceName,
    );
  }

  @override
  Future<String?> readDraft(DateTime date) async => _drafts[_key(date)];

  @override
  Future<void> writeDraft(DateTime date, String body) async {
    _drafts[_key(date)] = body;
  }

  @override
  Future<void> clearDraft(DateTime date) async {
    _drafts.remove(_key(date));
  }

  @override
  Future<List<DateTime>> datesWithDrafts() async {
    // 测试替身也要如实反映草稿状态，否则依赖它的测试会得出错误结论
    final dates = <DateTime>[];
    for (final key in _drafts.keys) {
      final date = parseIsoDate(key);
      if (date != null) dates.add(date);
    }
    dates.sort((a, b) => b.compareTo(a));
    return dates;
  }

  @override
  Future<List<ConflictFile>> findConflicts() async =>
      List<ConflictFile>.unmodifiable(_conflicts);
}

class _MemSnapshot {
  _MemSnapshot({
    required this.savedAt,
    required this.reason,
    required this.content,
    required int sequence,
  }) : id = 'mem-${savedAt.microsecondsSinceEpoch}-$sequence';

  final DateTime savedAt;
  final SnapshotReason reason;
  final String content;
  final String id;
}

class _MemTrash {
  _MemTrash({required this.date, required this.deletedAt, required this.content});

  final DateTime date;
  final DateTime deletedAt;
  final String content;

  String get id => '${formatIsoDate(date)}-${deletedAt.microsecondsSinceEpoch}';
}
