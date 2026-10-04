import 'dart:async';

import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/backup.dart';
import '../core/command_palette.dart';
import '../core/day.dart';
import '../core/diary_location.dart';
import '../core/release_notes.dart';
import '../data/release_info.dart';
import '../data/settings.dart';
import '../platform/platform.dart' as platform;
import '../state/diary_controller.dart';
import '../state/settings_controller.dart';
import 'command_palette.dart';
import 'diary_actions.dart';
import 'diary_location_dialog.dart';
import 'editor_panel.dart';
import 'entry_list_panel.dart';
import 'markdown_formatting.dart';
import 'prompts.dart';
import 'theme.dart';
import 'whats_new_dialog.dart';

class DiaryHomePage extends StatefulWidget {
  const DiaryHomePage({
    super.key,
    required this.controller,
    required this.settings,
    required this.onSwitchDiaryRoot,
    this.releaseInfo,
  });

  final DiaryController controller;
  final SettingsController settings;
  final SwitchDiaryRootCallback onSwitchDiaryRoot;

  /// 版本与更新记录。可空——读不到就没有「本版更新」这件事。
  final ReleaseInfo? releaseInfo;

  @override
  State<DiaryHomePage> createState() => _DiaryHomePageState();
}

class _DiaryHomePageState extends State<DiaryHomePage>
    with WidgetsBindingObserver {
  final TextEditingController _body = TextEditingController();
  final FocusNode _bodyFocus = FocusNode();

  /// 侧栏搜索框的焦点。命令面板的「搜索日记」要能把光标送进去，
  /// 所以节点由这里持有——面板和侧栏是兄弟，面板够不到侧栏的私有状态。
  final FocusNode _searchFocus = FocusNode();

  DateTime? _syncedDate;
  int _syncedRevision = -1;
  bool _promptsShown = false;
  bool _zenMode = false;

  /// 命令面板是不是开着。防止连按两次 Ctrl+K 叠出两层。
  bool _paletteOpen = false;

  /// 盯住磁盘的定时器——见 [initState]。它必须由界面持有，随树一起销毁。
  Timer? _externalWatchTimer;

  DiaryController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onControllerChanged);

    // 盯住磁盘：同步工具随时可能把另一台设备的版本放进来。
    //
    // 定时器放在界面而不是控制器里，是为了让它随 widget 树一起销毁——
    // widget 测试结束时会检查有没有还挂着的定时器。
    _externalWatchTimer = Timer.periodic(
      DiaryController.externalWatchInterval,
      (_) => unawaited(_controller.checkExternalChange()),
    );

    // 控制器完全可能在界面创建**之前**就已经加载完了（内存存储、
    // 或者日记很小所以文件读取极快）。如果只在通知回调里同步正文，
    // 就会漏掉这种情况——表现是「重新打开已有内容的一天，正文框却是空的，
    // 只显示提示语」。所以这里必须补一次初始同步。
    _syncBodyFromController();

    // 打开即写：第一帧之后把光标交给正文。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bodyFocus.requestFocus();
    });

    // 和正文同步同一个坑：控制器可能在界面创建之前就加载完了，
    // 那次通知没人听，草稿/冲突提示就不会自己冒出来。
    if (!_controller.isLoading) {
      _promptsShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(showStartupPrompts(
            context,
            _controller,
            settings: widget.settings,
            releaseInfo: widget.releaseInfo,
          ));
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant DiaryHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;

    // 换了日记位置就会换一个新的 DiaryController（存储不同了）。
    // 必须把监听和正文同步一起迁过去，否则界面还挂在旧控制器上，
    // 表现是"切完位置以后打字没反应、列表也空了"。
    oldWidget.controller.removeListener(_onControllerChanged);
    widget.controller.addListener(_onControllerChanged);

    _syncedDate = null;
    _syncedRevision = -1;
    _syncBodyFromController();

    // 新位置可能有草稿或同步冲突，得重新提示一次
    _promptsShown = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _bodyFocus.requestFocus();
      if (!widget.controller.isLoading) {
        _promptsShown = true;
        unawaited(showStartupPrompts(
          context,
          widget.controller,
          settings: widget.settings,
          releaseInfo: widget.releaseInfo,
        ));
      }
    });
  }

  @override
  void dispose() {
    _externalWatchTimer?.cancel();
    _controller.removeListener(_onControllerChanged);
    WidgetsBinding.instance.removeObserver(this);

    // 关窗前把待写内容落盘
    unawaited(_controller.close());

    _body.dispose();
    _bodyFocus.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_controller.close());
    }
  }

  /// 关闭窗口时 Flutter 会先问一声，可以借这个机会把异步工作做完再放行退出。
  ///
  /// 这个钩子是**必需的**，不是锦上添花：[didChangeAppLifecycleState] 那条路
  /// 是"发出去就不管"（`unawaited`），而 Windows runner 在 WM_DESTROY 里直接
  /// PostQuitMessage —— 进程立刻结束，没跑完的异步操作会被腰斩。
  /// 自动备份将来就接在这里。
  ///
  /// 已实测（Flutter 3.47 / Windows 10，2026-10-02）：点窗口的关闭按钮时这个
  /// 回调会被调用，而且在返回之前 `await` 的异步操作**确实能跑完**。
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    try {
      await _controller.close();
      await _runAutoBackupOnExit();
    } catch (error) {
      // 退出前的收尾失败绝不能把用户困在程序里——记下来，放行退出。
      debugPrint('[riji] 退出前收尾失败：$error');
    }
    return AppExitResponse.exit;
  }

  /// 关闭程序时自动备份一次。
  ///
  /// 三道闸门都在平台层：没设位置直接返回、一天至多一份、内容没变就跳过。
  /// **失败绝不阻止退出**——备份是为了保住数据，不是为了把用户关在程序里。
  Future<void> _runAutoBackupOnExit() async {
    if (!platform.supportsBackup) return;
    final backupRoot = widget.settings.backupRoot;
    if (backupRoot == null || backupRoot.trim().isEmpty) return;

    final outcome = await platform.createBackupSnapshot(
      diaryRoot: _controller.locationDescription,
      backupRoot: backupRoot,
      kind: SnapshotKind.auto,
    );

    if (outcome.ok && !outcome.skipped) {
      await widget.settings.noteBackupSucceeded(DateTime.now());
    } else if (!outcome.ok) {
      // 失败必须**跨启动可见**：这时候弹不出任何提示（窗口正在关闭），
      // 只写日志的话用户会一直以为备份是好的——那比没有备份更危险。
      await widget.settings.noteBackupFailed(outcome.message);
    }
    // skipped：今天已经备过、或内容没变。上一次成功的时间仍然是最新的，
    // 不能动它，否则「多久没备份了」这个判断会失真。
  }

  /// 把控制器里的正文灌进输入框。
  ///
  /// 只在「正文被程序整体替换」时调用：初始加载、切换日期、恢复草稿。
  /// 每次自动保存都灌一遍的话，正在写的那句话会被光标重置打断。
  void _syncBodyFromController() {
    final controller = _controller;
    _syncedDate = controller.selectedDate;
    _syncedRevision = controller.bodyRevision;
    _body.value = TextEditingValue(
      text: controller.body,
      selection: TextSelection.collapsed(offset: controller.body.length),
    );
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final controller = _controller;

    final dateChanged =
        _syncedDate == null || !isSameDay(_syncedDate!, controller.selectedDate);
    final revisionChanged = _syncedRevision != controller.bodyRevision;

    if (dateChanged || revisionChanged) {
      _syncBodyFromController();
      if (dateChanged) {
        // 打开即写：切到某一天，光标直接落在正文里。
        //
        // 必须等这一帧结束再要焦点：编辑框子树带了一个随正文版本变化的 key
        // （见 editor_panel 里那段说明，是为了清掉跨日期的撤销栈），
        // 所以切日期时它是被整个重建的。在这一帧里 FocusNode 还挂在即将
        // 卸载的旧控件上，此时 requestFocus 会丢掉。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _bodyFocus.requestFocus();
        });
      }
    }

    if (!controller.isLoading && !_promptsShown) {
      _promptsShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(showStartupPrompts(
            context,
            controller,
            settings: widget.settings,
            releaseInfo: widget.releaseInfo,
          ));
        }
      });
    }

    setState(() {});
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _controller.selectedDate,
      firstDate: DateTime(1970),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: '选择日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked != null) await _controller.openDate(picked);
  }

  Future<void> _openLocationDialog() async {
    final message = await showDialog<String>(
      context: context,
      builder: (_) => DiaryLocationDialog(
        controller: _controller,
        onSwitch: widget.onSwitchDiaryRoot,
      ),
    );
    if (!mounted || message == null || message.isEmpty) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // 命令面板
  // ---------------------------------------------------------------------------

  /// 唤出命令面板。
  ///
  /// 面板挂在**这里**而不是 `EditorPanel` 里，因为 Ctrl+K 必须在侧栏搜索框、
  /// 心情/天气/标签输入框都有焦点时也能用——那些控件是写作区的兄弟或别的子树，
  /// 藏在 `EditorPanel` 内部就够不到它们了。
  Future<void> _openCommandPalette() async {
    // 已经开着就不要再开一层：连按两次 Ctrl+K 应该是"没反应"，
    // 而不是叠出第二个面板（第二个关掉之后第一个还在，很难受）。
    if (_paletteOpen) return;
    _paletteOpen = true;
    try {
      final action = await showCommandPalette(context, actions: _buildCommands());
      if (!mounted || action == null) return;

      await action.run();
      if (!mounted) return;

      // 面板关掉之后把焦点还回去：默认还给正文，命令也可以指定别的地方
      // （「搜索日记」的结果就是把光标送进侧栏的搜索框）。否则用户接着打字
      // 就打进了空气里——「打开即写」这条在项目里踩过一次。
      //
      // 必须等这一帧结束再要焦点：此刻对话框还在树上、它的焦点作用域还占着，
      // 这时候 requestFocus 会被随后到来的卸载吞掉。切日期那条路径
      // （见 _onControllerChanged）用的是同一个模式。
      final target = action.focusTarget ?? _bodyFocus;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) target.requestFocus();
      });
    } finally {
      _paletteOpen = false;
    }
  }

  /// 对正文当前选区套一对 Markdown 标记；再按一次取消。
  ///
  /// 实现和格式条共用 [applyMarkdownFormat] 那一份。
  void _applyFormat(String open, String close) => applyMarkdownFormat(
        bodyController: _body,
        controller: _controller,
        bodyFocus: _bodyFocus,
        open: open,
        close: close,
      );

  /// 当前这一版要显示给用户的更新内容；没有就是 null。
  ReleaseNotes? get _releaseNotes {
    final release = widget.releaseInfo;
    if (release == null) return null;
    return release.changeLog.forVersion(release.version);
  }

  /// 命令面板里能搜到的所有东西。
  ///
  /// 这里**不实现任何新能力**：只是把已经存在的动作再列一遍，菜单和按钮一个都
  /// 不动（新手靠看得见，熟练的人靠搜，两个都要）。所以这张表里的每一行都应该
  /// 能在界面上找到对应的入口——改功能时两边要一起改，别让它们分叉。
  ///
  /// 顺序按用途分组：写作 → 导航 → 外观 → 数据 → 筛选 → 破坏性操作。
  /// 空查询时列表就是这个顺序，所以它是有意义的，别随手打乱。
  List<CommandAction> _buildCommands() {
    final controller = _controller;
    final settings = widget.settings;

    final hasPastEntries =
        controller.entries.any((entry) => entry.body.trim().isNotEmpty);
    final canDelete = !controller.isCurrentEntryEmpty;
    final filterActive = controller.filter.isActive;

    final release = widget.releaseInfo;
    final releaseNotes = _releaseNotes;

    return <CommandAction>[
      // ---------------------------------------------------------------- 写作
      CommandAction(
        icon: Icons.format_bold,
        run: () async =>
            _applyFormat(MarkdownFormatter.bold, MarkdownFormatter.bold),
        command: const PaletteCommand(
          id: 'format.bold',
          title: '加粗',
          keywords: <String>['加粗', '粗体', 'bold', '格式', 'markdown'],
          shortcut: 'Ctrl+B',
        ),
      ),
      CommandAction(
        icon: Icons.format_italic,
        run: () async =>
            _applyFormat(MarkdownFormatter.italic, MarkdownFormatter.italic),
        command: const PaletteCommand(
          id: 'format.italic',
          title: '斜体',
          keywords: <String>['斜体', 'italic', '格式', 'markdown'],
          shortcut: 'Ctrl+I',
        ),
      ),
      CommandAction(
        icon: Icons.format_underlined,
        run: () async => _applyFormat(
          MarkdownFormatter.underlineOpen,
          MarkdownFormatter.underlineClose,
        ),
        command: const PaletteCommand(
          id: 'format.underline',
          title: '下划线',
          subtitle: '会插入 <u> 标签',
          keywords: <String>['下划线', 'underline', '格式', 'markdown'],
          shortcut: 'Ctrl+U',
        ),
      ),
      CommandAction(
        icon: Icons.lightbulb_outline,
        run: () async => controller.nextPrompt(),
        command: PaletteCommand(
          id: 'prompt.next',
          title: '换一个写作引子',
          keywords: const <String>['引子', '问题', '每日一问', '换一个', 'prompt'],
          enabled: controller.isCurrentEntryEmpty,
          // 引子只在空白页上出现（有内容之后它就不是障碍了），
          // 所以"不能换"的真正原因和"今天已经动笔了"是同一件事。
          disabledReason: '今天已经动笔了，引子不再显示',
        ),
      ),
      CommandAction(
        icon: Icons.bookmark_add_outlined,
        run: () async => _snapshotNow(),
        command: PaletteCommand(
          id: 'snapshot.now',
          title: '留一份当前版本',
          subtitle: '和「历史版本」里的手动快照是同一件事',
          keywords: const <String>['快照', '版本', '历史', '留一份', 'snapshot'],
          enabled: controller.hasEntry,
          disabledReason: '今天还没写过，没有可留的版本',
        ),
      ),

      // ---------------------------------------------------------------- 导航
      CommandAction(
        icon: Icons.chevron_left,
        run: () async => controller.shiftDay(-1),
        command: const PaletteCommand(
          id: 'nav.prev',
          title: '前一天',
          keywords: <String>['前一天', '上一天', '昨天', '上一页', 'previous'],
        ),
      ),
      CommandAction(
        icon: Icons.chevron_right,
        run: () async => controller.shiftDay(1),
        command: const PaletteCommand(
          id: 'nav.next',
          title: '后一天',
          keywords: <String>['后一天', '下一天', '明天', '下一页', 'next'],
        ),
      ),
      CommandAction(
        icon: Icons.today,
        run: () async => controller.goToToday(),
        command: const PaletteCommand(
          id: 'nav.today',
          title: '今天',
          keywords: <String>['今天', '回到今天', '当前', 'today'],
        ),
      ),
      CommandAction(
        icon: Icons.calendar_month,
        run: () async => _pickDate(),
        command: const PaletteCommand(
          id: 'nav.pickDate',
          title: '选择日期',
          keywords: <String>['日期', '日历', '跳转', '选日期', 'calendar'],
        ),
      ),
      CommandAction(
        icon: Icons.casino_outlined,
        run: () async => travelToRandomEntryAction(context, controller),
        command: PaletteCommand(
          id: 'nav.timeMachine',
          title: '时光机',
          subtitle: '随机翻一篇以前写过的日记',
          keywords: const <String>['时光机', '随机', '翻一篇', '回顾', 'random'],
          enabled: hasPastEntries,
          disabledReason: '还没有以前写过的日记可以翻',
        ),
      ),
      CommandAction(
        icon: Icons.search,
        // 这条命令的**结果就是**把光标放到侧栏搜索框里，所以焦点目标不是正文。
        focusTarget: _searchFocus,
        run: () async => _searchFocus.requestFocus(),
        command: PaletteCommand(
          id: 'nav.search',
          title: '搜索日记',
          subtitle: '搜正文、标签、心情、天气、日期',
          keywords: const <String>['搜索', '查找', '全文', 'search', 'find'],
          enabled: !_zenMode,
          // 专注模式会把整个侧栏（连同搜索框）从树上摘掉，此时聚焦是空操作。
          disabledReason: '专注模式隐藏了日记列表',
        ),
      ),

      // ---------------------------------------------------------------- 外观
      for (final mode in AppThemeMode.values)
        CommandAction(
          icon: themeModeIcon(mode),
          run: () async => settings.setThemeMode(mode),
          command: PaletteCommand(
            id: 'appearance.${mode.name}',
            title: '外观：${themeModeLabel(mode)}',
            subtitle: settings.themeMode == mode ? '当前' : null,
            keywords: <String>[
              '外观',
              '主题',
              '配色',
              themeModeLabel(mode),
              ..._themeKeywords(mode),
            ],
          ),
        ),
      CommandAction(
        icon: Icons.format_size,
        run: () async => showTypographyAction(context, settings),
        command: PaletteCommand(
          id: 'appearance.typography',
          title: '字体与行距',
          subtitle: '当前字号 ${settings.typography.fontSize.round()} px',
          keywords: const <String>[
            '字体',
            '字号',
            '行距',
            '行宽',
            '字重',
            '排版',
            'typography',
          ],
        ),
      ),
      CommandAction(
        icon: _zenMode ? Icons.vertical_split : Icons.vertical_split_outlined,
        run: () async => _toggleZen(),
        command: PaletteCommand(
          id: 'view.zen',
          title: '专注模式',
          subtitle: _zenMode ? '已开启（隐藏日记列表）' : '隐藏左侧日记列表，全屏写作',
          keywords: const <String>['专注', '全屏', '隐藏列表', 'zen', 'focus'],
        ),
      ),

      // ------------------------------------------------------- 数据与位置
      CommandAction(
        icon: Icons.folder_open,
        run: () async => revealDiaryFolderAction(context, controller),
        command: const PaletteCommand(
          id: 'data.folder',
          title: '打开日记文件夹',
          keywords: <String>['文件夹', '目录', '资源管理器', 'explorer', 'folder'],
        ),
      ),
      // 预览模式（web）没有可写的文件系统，这一条整个不注册——
      // 给一个点了会失败的命令，比没有这个命令更糟。
      if (platform.supportsDiaryLocationChange)
        CommandAction(
          icon: Icons.inventory_2_outlined,
          run: () async => _openLocationDialog(),
          command: const PaletteCommand(
            id: 'data.location',
            title: '日记存储位置',
            subtitle: '换一个文件夹；只复制，从不移动',
            keywords: <String>['位置', '目录', '迁移', '存储', '根目录', 'path'],
          ),
        ),
      CommandAction(
        icon: Icons.ios_share,
        run: () async => exportDiaryAction(context, controller),
        command: const PaletteCommand(
          id: 'data.export',
          title: '导出为 Markdown',
          keywords: <String>['导出', 'markdown', 'export', '另存'],
        ),
      ),
      if (platform.supportsBackup)
        CommandAction(
          icon: Icons.save_outlined,
          run: () async => openBackupAction(
            context,
            settings: settings,
            controller: controller,
          ),
          command: PaletteCommand(
            id: 'data.backup',
            title: '备份',
            // 备份图标只在"该备份了"的时候才出现在状态栏上，所以那时候反而
            // 更需要一个随时找得到的入口——这一条就是。
            subtitle: settings.backupRoot == null
                ? '还没设备份位置'
                : '上次备份：${_lastBackupLabel(settings.lastBackupAt)}',
            keywords: const <String>['备份', '快照', '存档', 'backup'],
          ),
        ),
      CommandAction(
        icon: Icons.history,
        run: () async => showHistoryAction(context, controller),
        command: const PaletteCommand(
          id: 'data.history',
          title: '历史版本',
          subtitle: '查看 / 恢复这一天的历史快照',
          keywords: <String>['历史', '版本', '快照', '恢复', 'history'],
        ),
      ),
      CommandAction(
        icon: Icons.restore_from_trash,
        run: () async => showTrashAction(context, controller),
        command: const PaletteCommand(
          id: 'data.trash',
          title: '回收站',
          subtitle: '删除是软删除，字节一个不少',
          keywords: <String>['回收站', '恢复', '垃圾', 'trash'],
        ),
      ),

      // ---------------------------------------------------------------- 筛选
      CommandAction(
        icon: Icons.filter_list,
        run: () async => showFilterAction(context, controller),
        command: PaletteCommand(
          id: 'filter.open',
          title: '筛选',
          subtitle: filterActive ? controller.filter.describe() : null,
          keywords: const <String>[
            '筛选',
            '过滤',
            '标签',
            '心情',
            '天气',
            'filter',
          ],
        ),
      ),
      CommandAction(
        icon: Icons.clear,
        run: () async => controller.clearFilter(),
        command: PaletteCommand(
          id: 'filter.clear',
          title: '清除筛选',
          keywords: const <String>['清除筛选', '取消筛选', '重置', 'clear'],
          enabled: filterActive,
          disabledReason: '当前没有筛选条件',
        ),
      ),

      // ------------------------------------------------------------ 帮助
      // 弹窗只在升级后弹一次，所以必须留一个随时能再打开的入口——
      // 做得出来却找不到，等于没做（这条在项目里反复出现过）。
      if (release != null)
        CommandAction(
          icon: Icons.history,
          run: () async {
            final notes = releaseNotes;
            if (notes != null) await showWhatsNewDialog(context, notes);
          },
          command: PaletteCommand(
            id: 'help.whatsNew',
            title: '本版更新',
            subtitle: '日迹 ${release.version}',
            keywords: const <String>[
              '更新',
              '版本',
              '新功能',
              '修复',
              '更新记录',
              'changelog',
            ],
            // 这一版没有写给用户看的内容时置灰，而不是点了没反应
            enabled: releaseNotes != null,
            disabledReason: '这一版没有写给用户看的更新内容',
          ),
        ),

      // ------------------------------------------------------------ 破坏性
      CommandAction(
        icon: Icons.delete_forever,
        run: () async => deleteCurrentEntryAction(context, controller),
        command: PaletteCommand(
          id: 'data.delete',
          title: '删除这一天的日记',
          subtitle: '移进回收站，内容不会被抹掉',
          keywords: const <String>['删除', '移除', '回收站', 'delete'],
          enabled: canDelete,
          // 和「更多」菜单同一句话：置灰而不是隐藏，并且说明原因。
          disabledReason: '这一天还没写东西',
        ),
      ),
    ];
  }

  /// 主题三档各自的别名。中文没有词边界，光靠"浅色/深色"两个词，
  /// 想切夜间模式的人搜「暗」「夜间」就找不到。
  List<String> _themeKeywords(AppThemeMode mode) => switch (mode) {
        AppThemeMode.system => const <String>['跟随系统', '自动', 'system'],
        AppThemeMode.light => const <String>['浅色', '白天', '亮色', 'light'],
        AppThemeMode.dark => const <String>['深色', '暗色', '夜间', '黑色', 'dark'],
      };

  String _lastBackupLabel(DateTime? at) {
    if (at == null) return '从没成功过';
    final days = daysSinceBackup(at, DateTime.now());
    if (days == null) return '从没成功过';
    return days == 0 ? '今天' : '$days 天前';
  }

  void _toggleZen() => setState(() => _zenMode = !_zenMode);

  /// 手动留一份版本，并把结果如实说出来。
  ///
  /// 「和最新一份完全相同就不重复留」是快照那套策略的一部分，
  /// 这里必须把它显示出来——否则用户点了没反应，会以为按钮坏了。
  Future<void> _snapshotNow() async {
    final messenger = ScaffoldMessenger.of(context);
    final created = await _controller.saveVersionNow();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(created ? '已留一份当前版本。' : '和最新一份完全相同，没有重复留。'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    if (controller.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Ctrl+K 绑在这里，不是绑在某个输入框上：键事件从焦点节点向上冒泡，
    // 这一层在侧栏、正文、心情/天气/标签输入框的**共同祖先**上，
    // 所以哪个控件有焦点都能唤出面板。
    //
    // Ctrl+K 在 Windows 上没有被 Flutter 文本框的默认绑定占用：那套 Emacs 式
    // 绑定（Ctrl+K 是 kill line）只在 macOS 和 web 上生效——和 Ctrl+B/I/U
    // 是同一个前提（见 editor_panel 里的说明）。
    // ⚠️ 唯一的例外是浏览器预览：`flutter run -d chrome` 下 Ctrl+K 会被
    // 文本框吃掉，那是预览环境，不是目标形态。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            () => unawaited(_openCommandPalette()),
      },
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            // 侧栏固定 320px 在窄窗口下会把写作区挤没
            final narrow = constraints.maxWidth < 900;

            return Row(
              children: <Widget>[
                if (!_zenMode) ...<Widget>[
                  SizedBox(
                    width: narrow ? 250 : 320,
                    child: EntryListPanel(
                      controller: controller,
                      onPickDate: _pickDate,
                      searchFocus: _searchFocus,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: EditorPanel(
                    controller: controller,
                    settings: widget.settings,
                    bodyController: _body,
                    bodyFocus: _bodyFocus,
                    zenMode: _zenMode,
                    onPickDate: _pickDate,
                    onToggleZen: _toggleZen,
                    onOpenCommandPalette:
                        () => unawaited(_openCommandPalette()),
                    // 「日记位置」从左侧栏底部移到了这里。顺带一个好处：
                    // 专注模式会隐藏左侧栏，以前那种状态下就没法改位置了。
                    onOpenLocationSettings:
                        platform.supportsDiaryLocationChange
                            ? _openLocationDialog
                            : null,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
