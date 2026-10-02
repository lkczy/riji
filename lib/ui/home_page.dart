import 'dart:async';

import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../core/backup.dart';
import '../core/day.dart';
import '../core/diary_location.dart';
import '../platform/platform.dart' as platform;
import '../state/diary_controller.dart';
import '../state/settings_controller.dart';
import 'diary_location_dialog.dart';
import 'editor_panel.dart';
import 'entry_list_panel.dart';
import 'prompts.dart';

class DiaryHomePage extends StatefulWidget {
  const DiaryHomePage({
    super.key,
    required this.controller,
    required this.settings,
    required this.onSwitchDiaryRoot,
  });

  final DiaryController controller;
  final SettingsController settings;
  final SwitchDiaryRootCallback onSwitchDiaryRoot;

  @override
  State<DiaryHomePage> createState() => _DiaryHomePageState();
}

class _DiaryHomePageState extends State<DiaryHomePage>
    with WidgetsBindingObserver {
  final TextEditingController _body = TextEditingController();
  final FocusNode _bodyFocus = FocusNode();

  DateTime? _syncedDate;
  int _syncedRevision = -1;
  bool _promptsShown = false;
  bool _zenMode = false;

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
        if (mounted) unawaited(showStartupPrompts(context, _controller));
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
        unawaited(showStartupPrompts(context, widget.controller));
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
        if (mounted) unawaited(showStartupPrompts(context, controller));
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

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    if (controller.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
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
                  onToggleZen: () => setState(() => _zenMode = !_zenMode),
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
    );
  }
}
