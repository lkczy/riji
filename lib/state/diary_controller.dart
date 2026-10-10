import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/day.dart';
import '../core/diary_filter.dart';
import '../core/history.dart';
import '../core/models/diary_entry.dart';
import '../core/vault_crypto.dart';
import '../core/vault_format.dart';
import '../core/writing_prompts.dart';
import 'vault_service.dart';
import '../data/diary_store.dart';
import '../platform/platform.dart' as platform;

/// 编辑器的保存状态。状态栏必须让用户随时看到「我的字到底存进去没有」——
/// 日记程序里，"不确定存没存" 本身就是一种折磨。
enum SaveState { idle, dirty, saving, saved, failed }

class DiaryController extends ChangeNotifier {
  DiaryController({
    required this.store,
    required this.deviceName,
    this.vault,
  }) {
    vault?.addListener(_onVaultChanged);
  }

  /// 加密保险库。null = 这个构建/这个测试没有加密功能。
  ///
  /// 搜索和字数都要问它：锁着的正文是要先解密的，而"没参与搜索"和
  /// "搜不到"必须分得清。
  final VaultService? vault;

  /// 正在预热（防止 [prepareVaultForSearch] 自己触发自己，转成死循环）。
  bool _preparing = false;

  /// 已经销毁。异步收尾时（自动预热、保存）必须看它一眼：
  /// 解锁/锁定是随时可能发生的，而那些异步任务可能在控制器已经
  /// dispose 之后才回来——那时再 notifyListeners() 会直接报错。
  bool _disposed = false;

  /// 保险库状态变了：**一解锁就自动把锁着的正文解进缓存**。
  ///
  /// 为什么在这里监听，而不是让每个调用方记得调：解锁有两条路
  /// （「日记加密」对话框、侧栏的「解锁来搜索」）。漏掉任何一条，
  /// 搜索都会**悄悄少几篇**——而界面上那句"另有 N 篇已锁"还会继续挂着，
  /// 用户根本看不出搜的是个残缺的结果集。
  void _onVaultChanged() {
    final service = vault;
    if (service == null || _disposed) return;
    // 锁上了就别再显示原文了
    if (!service.isUnlocked) _resetRevealMode();
    if (!service.isUnlocked || _preparing) {
      notifyListeners();
      return;
    }
    _preparing = true;
    unawaited(
      prepareVaultForSearch().whenComplete(() => _preparing = false),
    );
  }

  final DiaryStore store;
  final String deviceName;

  /// 草稿最多落后这么久。
  ///
  /// 这里必须是**节流**而不是防抖：防抖会在用户连续打字时无限推迟保存，
  /// 一个连写十分钟的人等于十分钟没有任何保护。节流保证无论怎么打字，
  /// 每 2 秒至少有一份内容落盘。
  static const Duration draftInterval = Duration(seconds: 2);

  /// 正式保存的防抖时间。
  static const Duration saveDelay = Duration(milliseconds: 900);

  List<DiaryEntry> _entries = <DiaryEntry>[];
  List<ConflictFile> _conflicts = <ConflictFile>[];
  List<DateTime> _recoverableDrafts = <DateTime>[];

  bool _loading = true;
  String? _loadError;

  DateTime _selectedDate = dateOnly(DateTime.now());
  DiaryEntry? _current;
  String _body = '';
  String? _mood;
  String? _weather;
  List<String> _tags = <String>[];

  String _query = '';
  DiaryFilter _filter = DiaryFilter.none;
  SaveState _saveState = SaveState.idle;
  String? _saveError;
  DateTime? _savedAt;
  String? _lastExportPath;
  String? _lastConflictPath;

  int _promptOffset = 0;
  DateTime? _lastRandomDate;
  final Random _random = Random();

  Timer? _draftTimer;
  Timer? _saveTimer;
  DateTime? _lastDraftAt;
  int _bodyRevision = 0;

  /// 每当正文被**程序**整体替换（切换日期、恢复草稿）就自增。
  ///
  /// 编辑框靠它区分「正文是用户敲进来的」还是「程序换掉的」：
  /// 后者才需要把文本灌回输入框，否则每次自动保存都会重置光标位置，
  /// 正在写的一句话会被打断。
  int get bodyRevision => _bodyRevision;

  // ---------------------------------------------------------------------------
  // 只读状态
  // ---------------------------------------------------------------------------

  bool get isLoading => _loading;
  String? get loadError => _loadError;
  List<DiaryEntry> get entries => List<DiaryEntry>.unmodifiable(_entries);
  List<ConflictFile> get conflicts => List<ConflictFile>.unmodifiable(_conflicts);
  List<DateTime> get recoverableDrafts =>
      List<DateTime>.unmodifiable(_recoverableDrafts);

  DateTime get selectedDate => _selectedDate;
  String get body => _body;
  String? get mood => _mood;
  String? get weather => _weather;
  List<String> get tags => List<String>.unmodifiable(_tags);
  bool get hasEntry => _current != null;

  String get query => _query;
  DiaryFilter get filter => _filter;
  SaveState get saveState => _saveState;
  String? get saveError => _saveError;
  DateTime? get savedAt => _savedAt;
  String? get lastExportPath => _lastExportPath;

  /// 最近一次保存时检测到的外部改动。对方的版本被另存在这个文件里。
  ///
  /// 界面必须把这件事显示出来：用户需要知道"这一天被别处改过，
  /// 你写的内容在正式文件里，对方的内容在冲突文件里"，
  /// 而不是某天发现少了一段话。
  String? get lastConflictPath => _lastConflictPath;

  bool get isToday => isSameDay(_selectedDate, DateTime.now());
  String get locationDescription => store.locationDescription;

  /// 当前这一天是不是还什么都没写（正文、心情、天气、标签全空）。
  /// 判断条件和「不生成空日记文件」用的是同一套，两处必须一致。
  bool get isCurrentEntryEmpty =>
      _body.trim().isEmpty &&
      _mood == null &&
      _weather == null &&
      _tags.isEmpty;

  // ---------------------------------------------------------------------------
  // 每日一问
  // ---------------------------------------------------------------------------

  /// 当前这一天的写作引子。
  ///
  /// 刻意**不做成随机**：同一天每次打开都应该是同一个问题，
  /// 否则用户会怀疑"我刚才看到的那个问题呢"。想换用 [nextPrompt]。
  WritingPrompt get dailyPrompt =>
      promptForDate(_selectedDate, offset: _promptOffset);

  /// 用户点过「换一个」没有。界面用它决定要不要提示"这不是默认那条"。
  bool get promptWasRerolled => _promptOffset > 0;

  /// 换一个写作引子。
  void nextPrompt() {
    // 用引子总数取模：换够一圈就会回到起点，不会无限增长
    _promptOffset = (_promptOffset + 1) % kWritingPrompts.length;
    notifyListeners();
  }

  /// 内容是否真的落盘。false 时界面必须明确告知用户。
  bool get isPersistent => store.isPersistent;

  int get totalEntries => _entries.length;
  int get totalCharacters =>
      _entries.fold<int>(0, (sum, entry) => sum + entry.characterCount);

  /// 今天算不算「写过」。
  bool get hasWrittenToday =>
      _entries.any((entry) => isSameDay(entry.date, DateTime.now()));

  /// 跟当前日期同月同日、但年份不同的历史条目。
  /// 这是让人愿意长期写下去的功能里性价比最高的一个。
  List<DiaryEntry> get onThisDay => _entries
      .where((entry) =>
          entry.date.month == _selectedDate.month &&
          entry.date.day == _selectedDate.day &&
          entry.date.year != _selectedDate.year)
      .toList()
    ..sort((a, b) => b.date.compareTo(a.date));

  /// 搜索 + 筛选后的条目。搜索是纯内存过滤：数据量极小（十年也才 3650 条），
  /// 全量扫描就是毫秒级，所以不需要数据库索引。
  List<DiaryEntry> get visibleEntries {
    final needle = _query.trim().toLowerCase();

    return _entries.where((entry) {
      if (!_filter.matches(entry)) return false;
      if (needle.isEmpty) return true;

      // 每个结构化字段都要能被搜到，否则用户搜"晴"却得到"没有匹配的日记"，
      // 会以为那天的天气没存下来。
      //
      // 正文这一项要问保险库：锁着的天要么已经解密在内存里（搜得到），
      // 要么**根本没参与这次搜索**——那种情况界面上必须说出来，
      // 否则"搜不到"和"没搜"就长得一模一样了。
      final body = vault?.searchText(entry) ?? entry.body;
      return body.toLowerCase().contains(needle) ||
          (entry.mood?.toLowerCase().contains(needle) ?? false) ||
          (entry.weather?.toLowerCase().contains(needle) ?? false) ||
          entry.tags.any((tag) => tag.toLowerCase().contains(needle)) ||
          formatIsoDate(entry.date).contains(needle);
    }).toList();
  }

  /// 有几天的正文**没有参与这次搜索**（还锁着，或者解不开）。
  ///
  /// 界面必须把这个数字说出来："搜不到"和"没搜"是两件完全不同的事，
  /// 让人以为"没写过"，是最不该发生的一种误导。
  int get lockedNotSearchedCount {
    final service = vault;
    if (service == null) return 0;
    return _entries.where((entry) => !service.participatesInSearch(entry)).length;
  }

  /// 现在还有几天是锁着的（不管解没解开）。
  int get lockedEntriesCount =>
      _entries.where((entry) => entry.isLocked).length;

  /// 所有用过的标签，按使用次数从多到少排。
  /// 常用的排前面：标签自动补全时，最可能想输入的就该在最上面。
  List<String> get allTags => _rankedValues((entry) => entry.tags);

  List<String> get allMoods => _rankedValues(
        (entry) => entry.mood == null ? const <String>[] : <String>[entry.mood!],
      );

  List<String> get allWeathers => _rankedValues(
        (entry) =>
            entry.weather == null ? const <String>[] : <String>[entry.weather!],
      );

  List<String> _rankedValues(List<String> Function(DiaryEntry) pick) {
    final counts = <String, int>{};
    for (final entry in _entries) {
      for (final value in pick(entry)) {
        counts[value] = (counts[value] ?? 0) + 1;
      }
    }
    return counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
  }

  // ---------------------------------------------------------------------------
  // 加载
  // ---------------------------------------------------------------------------

  Future<void> load({DateTime? preferredDate}) async {
    _loading = true;
    notifyListeners();

    try {
      _entries = await store.loadAll();
      _conflicts = await store.findConflicts();
      _recoverableDrafts = await _findRecoverableDrafts();
      _loadError = null;
    } catch (error) {
      _loadError = '$error';
      _entries = <DiaryEntry>[];
    }

    _selectedDate = dateOnly(preferredDate ?? DateTime.now());
    _loading = false;
    await _openDate(_selectedDate);
    notifyListeners();
  }

  /// 只有草稿和已保存内容**确实不一致**时才提示恢复。
  /// 否则每次启动都弹窗，用户会学会无脑点掉，真正的丢失反而被忽略。
  Future<List<DateTime>> _findRecoverableDrafts() async {
    final result = <DateTime>[];
    for (final date in await store.datesWithDrafts()) {
      final draft = await store.readDraft(date);
      if (draft == null) continue;
      final saved = await store.loadByDate(date);
      if (saved == null || saved.body != draft) result.add(date);
    }
    return result;
  }

  Future<void> reload() => load(preferredDate: _selectedDate);

  // ---------------------------------------------------------------------------
  // 日期导航
  // ---------------------------------------------------------------------------

  Future<void> openDate(DateTime date) async {
    // 换天要退出「显示原文」：否则屏幕上会留着**别的日子**的解密内容
    if (!isSameDay(date, _selectedDate)) _resetRevealMode();
    if (isSameDay(date, _selectedDate) && _current != null) {
      notifyListeners();
      return;
    }
    await _flush();
    await _openDate(date);
    notifyListeners();
  }

  Future<void> goToToday() => openDate(DateTime.now());

  Future<void> shiftDay(int days) =>
      openDate(_selectedDate.add(Duration(days: days)));

  Future<void> _openDate(DateTime date) async {
    final target = dateOnly(date);
    _selectedDate = target;

    // 优先用磁盘上的那一份：另一台设备可能刚把今天的文件同步过来，
    // 而内存里的列表是程序启动时读的，已经过时了。
    var entry = await store.loadByDate(target) ?? _entryFor(target);
    if (entry != null) _mergeIn(entry);

    // 记下「磁盘上现在是这一份」，外部改动的判断以它为基准
    _lastRawContent = await store.readRawEntry(target);

    _current = entry;
    _body = entry?.body ?? '';
    _mood = entry?.mood;
    _weather = entry?.weather;
    _tags = entry?.tags.toList() ?? <String>[];
    _saveState = SaveState.idle;
    _saveError = null;
    // 换了天，上一天"被同步改过"的提示不该跟过来
    _externalReloadNotice = null;
    // 换了日期就回到这一天的默认问题：上一天按了几次「换一个」
    // 不该跟着跑到新的一天去。
    _promptOffset = 0;
    _bodyRevision++;

    // 历史快照是"这一天"的属性，换天就要跟着换。
    // 打开时留一份「打开时的样子」——它回答的是"我今天坐下来写之前，
    // 这篇是什么样"，是整条历史里最有用的一份。
    await _loadSnapshotCache();
    await _maybeSnapshot(SnapshotReason.opened);
  }

  DiaryEntry? _entryFor(DateTime date) {
    for (final entry in _entries) {
      if (isSameDay(entry.date, date)) return entry;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 编辑
  // ---------------------------------------------------------------------------

  void updateBody(String text) {
    if (text == _body) return;
    _body = text;
    _saveState = SaveState.dirty;
    _scheduleDraft();
    _scheduleSave();
    notifyListeners();
  }

  void setMood(String? mood) {
    final normalized = (mood == null || mood.trim().isEmpty) ? null : mood.trim();
    if (normalized == _mood) return;
    _mood = normalized;
    _saveState = SaveState.dirty;
    _scheduleSave();
    notifyListeners();
  }

  /// 天气。和心情一样是自由文本：预设之外用户想怎么写就怎么写。
  void setWeather(String? weather) {
    final normalized =
        (weather == null || weather.trim().isEmpty) ? null : weather.trim();
    if (normalized == _weather) return;
    _weather = normalized;
    _saveState = SaveState.dirty;
    _scheduleSave();
    notifyListeners();
  }

  void setTags(List<String> tags) {
    final cleaned = <String>[];
    for (final tag in tags) {
      final trimmed = tag.trim();
      if (trimmed.isNotEmpty && !cleaned.contains(trimmed)) cleaned.add(trimmed);
    }
    if (listEquals(cleaned, _tags)) return;
    _tags = cleaned;
    _saveState = SaveState.dirty;
    _scheduleSave();
    notifyListeners();
  }

  void setQuery(String value) {
    if (value == _query) return;
    _query = value;

    // 「按次解锁」是**只为这一次搜索**解密，用完就得丢。
    //
    // 搜索框一清空就是"这次搜索结束了"——此时把密钥和明文缓存一起扔掉。
    // 少了这一步，那句"用完即丢"就只是一句注释：密钥会一直留在内存里
    // 直到关掉程序，而那并不是用户选那一档时同意的事。
    if (value.trim().isEmpty) vault?.releaseSearchReveal();

    notifyListeners();
  }

  void setFilter(DiaryFilter filter) {
    _filter = filter;
    notifyListeners();
  }

  void clearFilter() {
    if (!_filter.isActive) return;
    _filter = DiaryFilter.none;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 草稿：节流写盘
  // ---------------------------------------------------------------------------

  void _scheduleDraft() {
    final now = DateTime.now();
    final last = _lastDraftAt;

    if (last == null || now.difference(last) >= draftInterval) {
      _writeDraftNow();
      return;
    }
    _draftTimer?.cancel();
    _draftTimer = Timer(draftInterval - now.difference(last), _writeDraftNow);
  }

  void _writeDraftNow() {
    _lastDraftAt = DateTime.now();
    final date = _selectedDate;
    final text = _body;
    unawaited(
      store.writeDraft(date, text).catchError((Object error) {
        debugPrint('[riji] 草稿写入失败：$error');
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // 正式保存
  // ---------------------------------------------------------------------------

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(saveNow()));
  }

  /// 正文里的黑条数和密文数对不上时，给出一句人话；对得上就是 null。
  ///
  /// 只看"黑条多出来"这一边：密文多出来（用户删掉了一行黑条）是允许的，
  /// 多余的密文会原样保留。
  String? _lockMismatchError() {
    final lock = _current?.lock;
    if (lock == null || !lock.isLocked) return null;
    if (lock.isWholeDay) return null;
    return barsMismatchError(_body, lock.redactions.length);
  }
  // ---------------------------------------------------------------------------
  // 加密：上锁 / 解锁
  //
  // 所有落盘都走同一个出口（[_applyLock] → saveNow），所以"锁着的天写成
  // 明文"这条路在结构上就不存在——这是 `docs/加密设计.md` 第 4 节那条纪律。
  // ---------------------------------------------------------------------------

  /// 当前这一天在底栏显示的**字数**。
  ///
  /// 锁着的天正文是空的（整天锁）或带黑条（按段锁），用 `_body` 算会显示成
  /// 0 字或算进黑条——两种都在骗人。所以问条目，条目里存着锁上那一刻的
  /// 完整字数（见 `docs/DATA-FORMAT.md` 的 `chars`）。
  int get currentCharacterCount => _current?.characterCount ?? _body.runes.length;
  /// 当前这一天的**正文**是不是只读。
  ///
  /// 锁着、又没解锁（或者只是"为搜索解锁"）时，正文一律不许改——
  /// 这样"把黑条改坏、内容和密文对不上"这件事从源头就不存在了，
  /// 保存护栏退化成第二道防线。
  ///
  /// **只锁正文**：心情、天气、标签是明文的，锁定状态下补一个心情照样可以。
  bool get isCurrentBodyReadOnly => currentDayIsLocked && !canLock;

  /// 能不能对当前这一天做加密操作（需要已解锁、且不是"只为搜索"那种解锁）。
  bool get canLock => vault?.canWrite ?? false;

  bool get currentDayIsLocked => _current?.isLocked ?? false;

  bool get currentDayIsWholeDayLocked => _current?.lock?.isWholeDay ?? false;

  /// 光标所在那一行能不能锁：要有内容、不是空行、不是黑条、也不是整天锁。
  bool canLockLine(int lineIndex) {
    if (!canLock || currentDayIsWholeDayLocked) return false;
    final lines = _body.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) return false;
    final line = lines[lineIndex];
    if (line.trim().isEmpty) return false;
    return !isRedactionLine(line);
  }

  /// 光标所在那一行是不是黑条（决定菜单里显示"解开这一段"还是"锁上这一段"）。
  bool lineIsRedacted(int lineIndex) {
    final lines = _body.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) return false;
    return isRedactionLine(lines[lineIndex]);
  }

  /// 锁上整天。
  Future<void> lockCurrentDay() async {
    final service = _requireVault();
    final entry = _ensureEntry();
    await _applyLock(await service.lockWholeDay(entry));
  }

  /// 解开整天（变回明文存盘）。调用方负责先确认。
  Future<void> unlockCurrentDay() async {
    final service = _requireVault();
    final entry = _current;
    if (entry == null) return;
    await _applyLock(await service.unlockWholeDay(entry));
  }

  /// 锁上某一行。
  Future<void> lockCurrentLine(int lineIndex) async {
    final service = _requireVault();
    final entry = _ensureEntry();
    await _applyLock(await service.lockLine(entry, lineIndex));
  }

  /// 解开某一行。
  Future<void> unlockCurrentLine(int lineIndex) async {
    final service = _requireVault();
    final entry = _current;
    if (entry == null) return;
    await _applyLock(await service.unlockLine(entry, lineIndex));
  }

  /// 手动/自动锁定**整个程序**。
  ///
  /// 两件事一起做，缺一不可：
  ///   1. 丢掉密钥（`vault.lock()`）
  ///   2. **清空内存里的日记内容**——明文的日子本来就以明文读进了内存，
  ///      只丢密钥的话，"锁上"就只是屏幕上看不见，内存里还在。
  ///
  /// 先 `_flush()` 再清：万一还有没落盘的编辑，锁定不能把它吃掉。
  Future<void> lockApp() async {
    await _flush();
    vault?.lock();
    _entries = <DiaryEntry>[];
    _conflicts = <ConflictFile>[];
    _recoverableDrafts = <DateTime>[];
    _current = null;
    _body = '';
    _mood = null;
    _weather = null;
    _tags = <String>[];
    _query = '';
    _resetRevealMode();
    _saveState = SaveState.idle;
    notifyListeners();
  }

  /// 解锁之后把内容读回来（锁定是把内存清空了的）。
  Future<void> reloadAfterUnlock() async {
    await load(preferredDate: _selectedDate);
  }

  /// 「显示原文」模式：整篇把黑条换成原文，**只读**。
  ///
  /// 这是"能看见、改不着"的落点：编辑框里的内容换成解出来的原文，
  /// 但**真正的正文控制器一个字都不动**（那才是要落盘的东西），
  /// 而且这个模式下输入框是只读的——不会有人把明文敲进去。
  bool _revealMode = false;
  String? _revealText;

  bool get revealMode => _revealMode;

  /// 要显示的原文（只在 [revealMode] 为 true 时有值）。
  String? get revealedText => _revealMode ? _revealText : null;

  /// 现在能不能进「显示原文」：这一天锁着、而且已经解锁（按次解锁也算）。
  bool get canRevealOriginal => currentDayIsLocked && canReadLocked;

  Future<void> enterRevealMode() async {
    if (!canRevealOriginal) return;
    final text = await revealCurrentDayText();
    if (_disposed) return;
    _revealText = text;
    _revealMode = true;
    notifyListeners();
  }

  void exitRevealMode() {
    if (!_revealMode) return;
    _revealMode = false;
    _revealText = null;
    notifyListeners();
  }

  /// 内部用：换天、锁定、上锁/解锁之后都要退出这个模式（否则会显示别的日子的原文）。
  void _resetRevealMode() {
    _revealMode = false;
    _revealText = null;
  }

  /// 能不能**只读地**看锁着的内容。按次解锁（只为搜索）也算——它本来就有密钥。
  bool get canReadLocked => vault?.isUnlocked ?? false;

  /// 读当前这一天的完整明文（只读浮窗用，**绝不写回编辑框**）。
  ///
  /// 整天锁的那天没有黑条可点，只能走这条路才看得到内容——否则用户为了
  /// "看一眼"就不得不把它解成明文存在磁盘上。
  Future<String> revealCurrentDayText() async {
    final service = _requireVault();
    final entry = _current;
    if (entry == null) {
      throw const VaultAuthException('这一天还没有内容。');
    }
    return service.revealDayText(entry);
  }

  /// 看某一段黑条的原文（只读）。
  Future<String> revealLine(int lineIndex) {
    final service = _requireVault();
    final entry = _current;
    if (entry == null) throw const VaultAuthException('这一天还没有内容。');
    return service.revealRedaction(entry, lineIndex);
  }

  /// 关闭加密：**先把所有锁着的天解开并落盘**，确认磁盘上一天都没锁着，
  /// 才去删保险库文件。
  ///
  /// 顺序绝不能反。`.vault` 里装的是主密钥，先删它等于把那几天的内容
  /// 永久扔掉——没有备份、没有后门。所以这里宁可**拒绝关闭**并说清原因，
  /// 也不冒这个险。
  ///
  /// （之前这里直接调 `disableVault()`，没有这道闸：点一下就可能丢数据。）
  Future<String> disableVaultSafely() async {
    final service = _requireVault();
    if (!service.isUnlocked) {
      throw const VaultAuthException('先解锁，才能关闭加密。');
    }
    if (service.isSearchRevealed) {
      throw const VaultAuthException('现在只是"为搜索解锁"，不能关加密。');
    }

    final locked = _entries.where((entry) => entry.isLocked).toList();
    final failed = <String>[];
    for (final entry in locked) {
      try {
        final opened = await service.unlockWholeDay(entry);
        await store.save(opened);
        _mergeIn(opened);
        if (isSameDay(entry.date, _selectedDate)) {
          // 当前这一天正好解开了：编辑框要立刻反映出来
          _current = opened;
          _body = opened.body;
          _bodyRevision++;
        }
      } catch (_) {
        failed.add(formatIsoDate(entry.date));
      }
    }

    if (failed.isNotEmpty) {
      throw VaultAuthException(
        '有 ${failed.length} 天解不开（${failed.join('、')}），所以**没有**关闭加密：'
        '先删保险库文件的话，那些内容就永久打不开了。',
      );
    }

    // 不信内存，只信落盘的结果：重新从磁盘读一遍，确认真的没有锁着的天了
    final onDisk = await store.loadAll();
    final stillLocked = onDisk.where((entry) => entry.isLocked).toList();
    if (stillLocked.isNotEmpty) {
      throw VaultAuthException(
        '磁盘上还有 ${stillLocked.length} 天是锁着的，没有关闭加密。',
      );
    }

    final result = await service.disableVault();
    if (!result.ok) throw VaultAuthException(result.message);
    _entries = onDisk;
    notifyListeners();
    return '加密已关闭：${onDisk.length} 天的内容都回到明文了。';
  }

  /// 解锁之后把锁着的正文解进内存缓存，让搜索能用上。
  ///
  /// 解不开的那些天会被报出来（文件坏了、或者不是用这个密钥锁的），
  /// 界面必须把它们算进"另有 N 篇未参与搜索"。
  Future<int> prepareVaultForSearch() async {
    final service = vault;
    if (service == null) return 0;
    final failed = await service.prepare(_entries);
    if (!_disposed) notifyListeners();
    return failed.length;
  }
  VaultService _requireVault() {
    final service = vault;
    if (service == null) {
      throw const VaultAuthException('这个构建没有加密功能。');
    }
    return service;
  }

  /// 把改好的条目接过来、落盘。
  ///
  /// 注意 `_body` 也跟着换：锁上整天之后正文是空的，编辑框必须立刻反映出来
  /// ——否则界面上还显示着明文，用户以为"没锁上"。
  Future<void> _applyLock(DiaryEntry entry) async {
    _resetRevealMode();
    _current = entry;
    _body = entry.body;
    _bodyRevision++;
    _mergeIn(entry);
    _saveState = SaveState.dirty;
    notifyListeners();
    await saveNow();
  }

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    _saveTimer = null;

    if (_saveState != SaveState.dirty && _saveState != SaveState.failed) return;

    // 从没写过内容的空白日期不要生成文件。
    // 否则光是翻看日历就会在硬盘上留下一堆空日记。
    if (_current == null &&
        _body.trim().isEmpty &&
        _mood == null &&
        _weather == null &&
        _tags.isEmpty) {
      _saveState = SaveState.idle;
      await store.clearDraft(_selectedDate);
      _lastDraftAt = null;
      notifyListeners();
      return;
    }

    _saveState = SaveState.saving;
    notifyListeners();

    final date = _selectedDate;

    // ⚠️ 加密护栏：正文里的黑条比密文多，**绝不许落盘**。
    //
    // 那种文件在界面上看着"锁着"，其实那些黑条底下什么都没有——
    // 一搜就搜得到，而用户以为它是锁着的。这是这个功能能造成的
    // 最坏的一种谎，所以宁可拒绝保存并说清楚，也不写下去。
    // （会走到这里的真实路径：用户手打了一行方块，或者恢复了黑条数
    //   和密文对不上的草稿。）
    final mismatch = _lockMismatchError();
    if (mismatch != null) {
      _saveState = SaveState.failed;
      _saveError = mismatch;
      notifyListeners();
      return;
    }

    try {
      var entry = _ensureEntry();

      // 锁着的天：字数用锁里存的那份。但如果**现在是解锁状态**，就能把
      // 被锁的段也解开、算出准确字数——那就顺手更新掉，否则热力图和底栏
      // 会一直停在锁上那一刻的旧值（而且用户完全看不出来）。
      final service = vault;
      if (entry.lock != null && (service?.canWrite ?? false)) {
        try {
          entry = await service!.refreshCharacters(entry);
        } catch (_) {
          // 解不开就算了，保留旧值。**绝不因为算字数失败而挡住保存**
        }
      }

      final outcome = await store.save(entry);
      _mergeIn(entry);
      // 刚写完盘，把基准更新成「磁盘上现在就是这一份」，否则下一轮外部
      // 检查会把程序自己刚写的内容当成别人的改动，白白重新载入一次。
      _lastRawContent = await store.readRawEntry(date);
      await store.clearDraft(date);
      _lastDraftAt = null;
      _savedAt = DateTime.now();
      _saveState = SaveState.saved;
      _saveError = null;

      if (outcome.hadConflict) {
        // 保存时发现磁盘上的内容已经被人改过。对方的版本已被另存，
        // 我们这边的改动也保住了，但用户必须知道，才能去手动合并。
        _lastConflictPath = outcome.conflictPath;
        _conflicts = await store.findConflicts();
      }

      // 定时留一份历史。绝大多数调用会被时间间隔挡住，一个字节都不读。
      if (outcome.wrote) {
        await _maybeSnapshot(SnapshotReason.auto);
      }
    } catch (error) {
      // 保存失败要让用户看见，而且草稿必须留着——
      // 这时候草稿是唯一还没丢的副本。
      _saveState = SaveState.failed;
      _saveError = '$error';
    }
    notifyListeners();
  }

  DiaryEntry _ensureEntry() {
    final now = DateTime.now();
    final existing = _current;
    if (existing != null) {
      return existing.copyWith(
        body: _body,
        mood: _mood,
        clearMood: _mood == null,
        weather: _weather,
        clearWeather: _weather == null,
        tags: _tags,
        updated: now,
        device: deviceName,
      );
    }
    final created = DiaryEntry.create(
      date: _selectedDate,
      device: deviceName,
      body: _body,
      mood: _mood,
      weather: _weather,
      tags: _tags,
    );
    _current = created;
    return created;
  }

  void _mergeIn(DiaryEntry entry) {
    final index = _entries.indexWhere((e) => isSameDay(e.date, entry.date));
    if (index >= 0) {
      _entries[index] = entry;
    } else {
      _entries.add(entry);
    }
    _entries.sort((a, b) => b.date.compareTo(a.date));
    if (isSameDay(entry.date, _selectedDate)) _current = entry;
  }

  /// 把待写入的内容立刻落盘。切换日期、关闭窗口、导出前都必须调用。
  Future<void> _flush() async {
    _draftTimer?.cancel();
    if (_saveState == SaveState.dirty || _saveState == SaveState.failed) {
      await saveNow();
    }
  }

  /// 程序退出前调用。
  Future<void> close() async {
    _draftTimer?.cancel();
    await _flush();
    _saveTimer?.cancel();
  }

  // ---------------------------------------------------------------------------
  // 草稿恢复
  // ---------------------------------------------------------------------------

  Future<void> recoverDraft(DateTime date) async {
    final draft = await store.readDraft(date);
    _recoverableDrafts =
        _recoverableDrafts.where((d) => !isSameDay(d, date)).toList();
    if (draft == null) {
      notifyListeners();
      return;
    }

    await openDate(date);
    _body = draft;
    _bodyRevision++;
    _saveState = SaveState.dirty;
    notifyListeners();
    await saveNow();
  }

  Future<void> discardDraft(DateTime date) async {
    await store.clearDraft(date);
    _recoverableDrafts =
        _recoverableDrafts.where((d) => !isSameDay(d, date)).toList();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 历史版本
  // ---------------------------------------------------------------------------
  //
  // 存在的理由：自动保存保护的是"崩溃"，**不保护"手滑"**。
  // 本程序没有"关闭而不保存"这道闸门，文件在 900ms 内就提交了；
  // 而 Ctrl+Z 只在当前编辑会话里管用，重启之后对已经落盘的内容无能为力。
  // 所以对"已经存进去的内容被改掉"这一类事故，历史快照是唯一的恢复途径。

  List<DiarySnapshot> _snapshots = <DiarySnapshot>[];
  DateTime? _snapshotCacheDate;

  /// 最新一份快照的时刻和内容，缓存在内存里。
  ///
  /// 为什么要缓存：自动保存是亚秒级的，而"距上次快照够久了吗"这个问题
  /// 每次保存都要问一次。如果每次都去列目录、读文件，就等于给每一次
  /// 自动保存都挂上一串磁盘操作。缓存之后这条路径是纯内存判断。
  DateTime? _newestSnapshotAt;
  String? _newestSnapshotContent;

  /// 当前这一天的历史快照（只有元信息），按时间从新到旧。
  List<DiarySnapshot> get snapshots =>
      List<DiarySnapshot>.unmodifiable(_snapshots);

  /// 读取某份快照的原始内容。列表要显示摘要时才调用。
  Future<String> snapshotContent(DiarySnapshot snapshot) =>
      store.readSnapshot(snapshot);

  /// 重新读一遍本日的历史快照。打开历史面板前调用。
  Future<void> refreshSnapshots() async {
    await _loadSnapshotCache();
    notifyListeners();
  }

  Future<void> _loadSnapshotCache() async {
    final date = _selectedDate;
    _snapshotCacheDate = date;

    try {
      _snapshots = await store.listSnapshots(date);
    } catch (error) {
      debugPrint('[riji] 读取历史快照失败：$error');
      _snapshots = <DiarySnapshot>[];
    }

    if (_snapshots.isEmpty) {
      _newestSnapshotAt = null;
      _newestSnapshotContent = null;
      return;
    }

    _newestSnapshotAt = _snapshots.first.savedAt;
    try {
      _newestSnapshotContent = await store.readSnapshot(_snapshots.first);
    } catch (_) {
      _newestSnapshotContent = null;
    }
  }

  /// 按 [SnapshotPolicy] 决定要不要留一份快照。返回是否真的留了。
  ///
  /// **绝不抛出**：留不下历史不能影响正常写作。
  Future<bool> _maybeSnapshot(SnapshotReason reason) async {
    try {
      if (_snapshotCacheDate == null ||
          !isSameDay(_snapshotCacheDate!, _selectedDate)) {
        await _loadSnapshotCache();
      }

      final now = DateTime.now();

      // 最便宜的一道闸：自动快照有 10 分钟间隔下限，而自动保存是亚秒级的，
      // 所以这一句会让几乎每一次保存直接返回，不读任何文件。
      if (reason == SnapshotReason.auto &&
          _newestSnapshotAt != null &&
          now.difference(_newestSnapshotAt!) < SnapshotPolicy.minInterval) {
        return false;
      }

      final content = await store.readRawEntry(_selectedDate);
      if (content == null) return false; // 这一天还没有内容

      // 内容和最新一份完全一样就不留：快照的价值在于记录**另一个样子**。
      //
      // 这个判断在恢复前那一份上也是安全的：如果当前内容与最新快照相同，
      // 那它本来就已经被保存过了，不存在"恢复会把它弄丢"的问题。
      final differs =
          _newestSnapshotContent == null || _newestSnapshotContent != content;
      if (!SnapshotPolicy.shouldSnapshot(
        reason: reason,
        now: now,
        contentDiffers: differs,
        newestAt: _newestSnapshotAt,
      )) {
        return false;
      }

      await store.writeSnapshot(
        _selectedDate,
        content,
        reason: reason,
        at: now,
      );
      await _loadSnapshotCache();
      return true;
    } catch (error) {
      // 历史留不下不是致命问题，绝不能因此打断写作
      debugPrint('[riji] 留历史快照失败：$error');
      return false;
    }
  }

  /// 用户主动留一个版本。返回是否真的新增了一份
  /// （和最新一份完全相同时不会重复留）。
  Future<bool> saveVersionNow() async {
    final saved = await _maybeSnapshot(SnapshotReason.manual);
    if (saved) notifyListeners();
    return saved;
  }

  /// 把这一天的正文恢复到某个历史版本。
  ///
  /// **覆盖之前先把当前内容留一份**——否则"恢复"本身就成了丢内容。
  Future<void> restoreSnapshot(DiarySnapshot snapshot) async {
    // 先落盘，这样"恢复之前"那一份拿到的是最新状态而不是几秒前的
    await saveNow();
    await _maybeSnapshot(SnapshotReason.beforeRestore);

    final content = await store.readSnapshot(snapshot);
    await store.restoreRaw(_selectedDate, content);

    // 重新读这一天，把界面同步过去
    final entry = await store.loadByDate(_selectedDate);
    if (entry != null) {
      _mergeIn(entry);
      _current = entry;
      _body = entry.body;
      _mood = entry.mood;
      _weather = entry.weather;
      _tags = entry.tags.toList();
    }

    _bodyRevision++;
    _saveState = SaveState.saved;
    _savedAt = DateTime.now();
    await store.clearDraft(_selectedDate);
    _lastDraftAt = null;
    await _loadSnapshotCache();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 删除与回收站
  // ---------------------------------------------------------------------------

  /// 删除当前这一天的日记。
  ///
  /// 是**软删除**：文件移进 `.trash`，字节一个都不少，回收站里能找回来。
  /// 历史快照也刻意保留——它们是这一天另一层独立的保护。
  Future<void> deleteCurrentEntry() async {
    _saveTimer?.cancel();
    _draftTimer?.cancel();

    await store.deleteEntry(_selectedDate);
    await store.clearDraft(_selectedDate);

    _entries.removeWhere((entry) => isSameDay(entry.date, _selectedDate));
    _current = null;
    _body = '';
    _mood = null;
    _weather = null;
    _tags = <String>[];
    _bodyRevision++;
    _saveState = SaveState.idle;
    _saveError = null;
    _savedAt = null;
    _lastDraftAt = null;
    _promptOffset = 0;

    await _loadSnapshotCache();
    notifyListeners();
  }

  Future<List<TrashedEntry>> listTrash() => store.listTrash();

  Future<String> readTrashedContent(TrashedEntry item) =>
      store.readTrashedContent(item);

  /// 从回收站恢复一条。
  ///
  /// 那一天已经有内容时**不会覆盖**：回收站里的那份会另存为冲突文件，
  /// 两边都保住，并由返回值里的 [DiarySaveOutcome.conflictPath] 说明去处。
  Future<DiarySaveOutcome> restoreFromTrash(TrashedEntry item) async {
    final outcome = await store.restoreFromTrash(item);
    if (outcome.hadConflict) _lastConflictPath = outcome.conflictPath;

    // 恢复的可能不是当前显示的那一天，所以要整表重读
    await load(preferredDate: _selectedDate);
    return outcome;
  }

  Future<void> purgeTrashEntry(TrashedEntry item) async {
    await store.purgeTrashEntry(item);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 导出
  // ---------------------------------------------------------------------------

  /// 导出成一个单独的 Markdown 文件。
  ///
  /// 导出功能必须第一天就有：数据被锁死在程序里是这类项目最大的风险。
  /// 这个实现刻意不依赖任何打包库——生成的是纯文本，用记事本就能看。
  Future<String> exportAsMarkdown() async {
    await _flush();

    final now = DateTime.now();
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';

    final buffer = StringBuffer()
      ..writeln('# riji 导出')
      ..writeln()
      ..writeln('- 导出时间：${formatIso8601WithOffset(now)}')
      ..writeln('- 条目数：${_entries.length}')
      ..writeln('- 总字数：$totalCharacters');

    // 锁着的天：导出的**是明文**。
    //
    // 导出这件事本身就是"我要拿出去用"，所以这里按设计解密（见
    // `docs/加密设计.md`）；但必须在导出文件里留下明确的痕迹——
    // 复制的这一份不再受加密保护，人得知道。
    final lockedCount = lockedEntriesCount;
    if (lockedCount > 0) {
      buffer
        ..writeln('- ⚠️ 其中 **$lockedCount 天原来是加密的**，这份导出里是**明文**，'
            '请当作未加密的副本保管')
        ..writeln('- （还没解锁的那些天在下面是黑条或空白，先解锁再导出才能带上原文）');
    }
    buffer.writeln();

    // 按时间正序，读起来像一本书
    final ordered = _entries.toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    for (final entry in ordered) {
      buffer
        ..writeln('---')
        ..writeln()
        ..writeln('## ${formatIsoDate(entry.date)}');

      final meta = <String>[];
      if (entry.mood != null) meta.add('心情：${entry.mood}');
      if (entry.weather != null) meta.add('天气：${entry.weather}');
      if (entry.tags.isNotEmpty) meta.add('标签：${entry.tags.join('、')}');
      if (meta.isNotEmpty) {
        buffer
          ..writeln()
          ..writeln(meta.join('　·　'));
      }

      buffer
        ..writeln()
        ..writeln(vault?.searchText(entry) ?? entry.body)
        ..writeln();
    }

    final path = await platform.writeExportFile(
      directory: platform.exportDirectoryFor(store.locationDescription),
      fileName: 'riji-$stamp.md',
      content: buffer.toString(),
    );
    _lastExportPath = path;
    notifyListeners();
    return path;
  }

  Future<void> revealDiaryFolder() =>
      platform.revealInFileManager(store.locationDescription);

  /// 用户看过冲突提示之后关掉它。文件还在，只是不再一直顶在界面上。
  void dismissConflictNotice() {
    if (_lastConflictPath == null) return;
    _lastConflictPath = null;
    notifyListeners();
  }

  Future<void> revealLastExport() async {
    final path = _lastExportPath;
    if (path != null) await platform.revealInFileManager(path);
  }

  /// 时光机：随机翻一篇以前写过的日记。
  ///
  /// 只挑**正文非空**的条目——翻到空白的一天毫无意义，那反而让人以为
  /// 自己的日记丢了。也会避开当前这一天。
  DiaryEntry? pickRandomEntry() {
    final candidates = _entries
        .where((entry) =>
            entry.body.trim().isNotEmpty &&
            !isSameDay(entry.date, _selectedDate))
        .toList();
    if (candidates.isEmpty) return null;

    // 不连续翻到同一条：否则点一下看到日期没变，观感像"坏了"
    if (candidates.length > 1 && _lastRandomDate != null) {
      candidates.removeWhere((e) => isSameDay(e.date, _lastRandomDate!));
    }

    final picked = candidates[_random.nextInt(candidates.length)];
    _lastRandomDate = picked.date;
    return picked;
  }

  /// 给状态栏用的存储位置显示名（完整路径太长）。
  String get shortLocation {
    final full = store.locationDescription;
    final base = p.basename(full);
    return base.isEmpty ? full : base;
  }

  // ---------------------------------------------------------------------------
  // 外部改动：同步工具把另一台设备的版本放进来了
  // ---------------------------------------------------------------------------

  /// 每隔这么久看一次磁盘。
  ///
  /// 3 秒是折中：日记文件只有一两 KB，读一次的开销可以忽略；而间隔再长，
  /// 「手机上写的已经同步过来了」和「你接着在电脑上打字」之间就会留出
  /// 一段足够撞车的时间。
  /// 定时器本身由界面持有（见 `HomePage`）：控制器在测试里往往不会被
  /// `dispose`，而 widget 测试结束后只要还有挂着的定时器就会直接判失败。
  static const Duration externalWatchInterval = Duration(seconds: 3);

  /// 上次看到的「磁盘上这一天的原始内容」。判断有没有被外部改过就靠它。
  ///
  /// 用原始内容而不是修改时间：同步工具会**保留文件原本的修改时间**，
  /// 所以时间戳不足以说明"这份内容是新的"。
  String? _lastRawContent;

  String? _externalReloadNotice;

  /// 当前这一天被自动重新载入过时的提示。
  ///
  /// 它**不代表有内容丢失**：能自动重新载入的前提就是没有未保存的内容。
  /// 所以这是一条信息性提示，用户看完关掉即可。
  String? get externalReloadNotice => _externalReloadNotice;

  void dismissExternalReloadNotice() {
    if (_externalReloadNotice == null) return;
    _externalReloadNotice = null;
    notifyListeners();
  }

  /// 检查当前这一天的文件有没有被别的程序（多半是同步工具）改过。
  ///
  /// 分两种情况：
  ///
  /// - **没有未保存的内容** → 直接重新载入。这样「手机写了今天的日记、
  ///   同步过来、你再在电脑上接着写」就不会演变成两个版本。
  /// - **有未保存的内容** → 什么都不做。让保存那条路去生成冲突文件，
  ///   两个版本都不会丢。**绝不能**在这里把用户正在写的东西冲掉。
  Future<void> checkExternalChange() async {
    if (_saveState != SaveState.idle && _saveState != SaveState.saved) return;

    final date = _selectedDate;
    String? raw;
    try {
      raw = await store.readRawEntry(date);
    } catch (error) {
      // 读不动就当没发生。绝不能因为一次读失败去动编辑器里的内容。
      debugPrint('[riji] 检查外部改动失败：$error');
      return;
    }

    if (raw == _lastRawContent) return;
    // 读的过程中用户换天了，这次结果作废
    if (!isSameDay(date, _selectedDate)) return;

    _lastRawContent = raw;
    final entry = await store.loadByDate(date);

    _current = entry;
    _body = entry?.body ?? '';
    _mood = entry?.mood;
    _weather = entry?.weather;
    _tags = entry?.tags.toList() ?? <String>[];
    _saveState = SaveState.idle;
    _saveError = null;
    // 正文是**程序**换掉的，编辑框要靠它把文本重新灌进去
    _bodyRevision++;
    if (entry != null) _mergeIn(entry);

    // 对方的版本可能被另存成了冲突文件，一并刷新出来
    _conflicts = await store.findConflicts();
    _externalReloadNotice = raw == null
        ? '这一天的文件在磁盘上不见了（可能被另一台设备删掉了），已重新载入。'
        : '这一天在磁盘上被改过（多半是另一台设备同步过来的），已重新载入。';
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    vault?.removeListener(_onVaultChanged);
    _draftTimer?.cancel();
    _saveTimer?.cancel();
    super.dispose();
  }
}
