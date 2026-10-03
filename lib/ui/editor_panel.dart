import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/backup.dart';
import '../core/day.dart';
import '../data/settings.dart';
import '../platform/platform.dart' as platform;
import '../state/diary_controller.dart';
import '../state/settings_controller.dart';
import 'diary_actions.dart';
import 'markdown_formatting.dart';
import 'theme.dart';

/// 「外观」菜单里的动作。主题三档和字体设置放在同一个菜单里——
/// 它们都是"看着舒服"这一类的事，没必要再占一个标题栏图标。
enum _AppearanceAction { system, light, dark, typography }

/// 右下角「更多」菜单里的动作。
///
/// 为什么把这些收进菜单：状态栏在窄窗口下本来就挤，而它们要么很少用
/// （改日记位置、看历史），要么不该一点就中（删除）。
///
/// 顺序是刻意的：**日常用的在上，碰数据管理的在中，破坏性的单独隔在下**。
enum _MoreAction { openFolder, location, export, backup, history, trash, delete }

/// 右侧写作区。
///
/// 设计取向：写作体验优先于功能数量。
/// 打开就写、正文占绝对主体、状态栏明确告诉用户「存没存进去」。
class EditorPanel extends StatefulWidget {
  const EditorPanel({
    super.key,
    required this.controller,
    required this.settings,
    required this.bodyController,
    required this.bodyFocus,
    required this.zenMode,
    required this.onPickDate,
    required this.onToggleZen,
    required this.onOpenCommandPalette,
    this.onOpenLocationSettings,
  });

  final DiaryController controller;
  final SettingsController settings;
  final TextEditingController bodyController;
  final FocusNode bodyFocus;
  final bool zenMode;
  final VoidCallback onPickDate;
  final VoidCallback onToggleZen;

  /// 唤出命令面板。面板本身挂在 `HomePage` 上——它必须在侧栏搜索框有焦点时
  /// 也能唤出，而侧栏和写作区是兄弟，这一层管不到它。这里只是它的一个入口。
  final VoidCallback onOpenCommandPalette;

  /// 打开「日记位置」对话框。为 null 时不显示这一项
  /// （web 预览没有文件系统，不支持改位置）。
  final VoidCallback? onOpenLocationSettings;

  @override
  State<EditorPanel> createState() => _EditorPanelState();
}

class _EditorPanelState extends State<EditorPanel> {
  // 标签输入框的控制器由 Autocomplete 自己管理，所以这里不需要一个。
  final TextEditingController _moodInput = TextEditingController();
  final TextEditingController _weatherInput = TextEditingController();

  static const List<String> _presetMoods = <String>[
    '平静', '开心', '低落', '焦虑', '疲惫', '兴奋', '感激', '烦躁',
  ];

  /// 天气预设刻意比心情少：天气的说法太多（"小雨转阴"、"闷热"……），
  /// 预设只负责覆盖最常见的几种，剩下的交给自由输入。
  static const List<String> _presetWeathers = <String>[
    '晴', '多云', '阴', '雨', '雪', '雾',
  ];

  DiaryController get _controller => widget.controller;

  @override
  void dispose() {
    _moodInput.dispose();
    _weatherInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    return Column(
      children: <Widget>[
        _buildHeader(context),
        if (controller.loadError != null)
          Container(
            width: double.infinity,
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              '日记目录读取有问题：${controller.loadError}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        if (!controller.isPersistent) _buildNonPersistentBanner(context),
        if (controller.lastConflictPath != null) _buildConflictStrip(context),
        if (controller.externalReloadNotice != null)
          _buildExternalReloadStrip(context),
        _buildMetaBar(context),
        if (controller.onThisDay.isNotEmpty) _buildOnThisDay(context),
        if (controller.isCurrentEntryEmpty) _buildPromptCard(context),
        _buildFormatStrip(context),
        const Divider(height: 1),
        Expanded(child: _buildWritingArea(context)),
        const Divider(height: 1),
        _buildStatusBar(context),
      ],
    );
  }

  // ---------------------------------------------------------------------------

  /// 检测到外部改动时的警告条。
  ///
  /// 这一条**不能**做成几秒后自动消失的提示：它代表"这一天存在另一个版本"，
  /// 用户需要在方便的时候去合并。悄悄消失等于把冲突埋起来，
  /// 那和静默覆盖只差一步。
  Widget _buildConflictStrip(BuildContext context) {
    final theme = Theme.of(context);
    final path = _controller.lastConflictPath;

    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(20, 6, 6, 6),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.call_split_outlined,
            size: 16,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '这一天在别处被改过。你写的内容保留在正式文件里，'
              '对方的版本已另存为冲突文件，两边都没有丢。\n$path',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: _controller.revealDiaryFolder,
            child: const Text('打开文件夹'),
          ),
          IconButton(
            tooltip: '知道了',
            visualDensity: VisualDensity.compact,
            onPressed: _controller.dismissConflictNotice,
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }

  /// 「这一天被同步改过、已自动重新载入」的提示条。
  ///
  /// 用信息色而不是错误色，因为自动重新载入的前提就是**没有未保存的内容**——
  /// 这次什么都没有丢。做成红色会让用户以为出了问题。
  /// 真正的冲突由上面那条 [_buildConflictStrip] 负责，两件事必须能分辨。
  Widget _buildExternalReloadStrip(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(20, 6, 6, 6),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.sync,
            size: 16,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _controller.externalReloadNotice!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          IconButton(
            tooltip: '知道了',
            visualDensity: VisualDensity.compact,
            onPressed: _controller.dismissExternalReloadNotice,
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }

  /// 存储不落盘时的警告条。
  ///
  /// 状态栏那边绝不会显示"已保存"来安抚用户——内存模式就是内存模式。
  Widget _buildNonPersistentBanner(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      color: theme.colorScheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '预览模式：内容只存在内存里，关掉页面就没了。要真正写日记请构建 Windows 桌面版。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 还没动笔时给一个写作引子。
  ///
  /// 只在空白时出现：已经开始写了就不需要它，而它会占掉本来就不宽裕的
  /// 编辑区高度。**空页面才是真正的障碍**，有内容之后就不是了。
  Widget _buildPromptCard(BuildContext context) {
    final theme = Theme.of(context);
    final prompt = _controller.dailyPrompt;

    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.lightbulb_outline,
              size: 18,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  prompt.category,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 2),
                Text(prompt.text, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
          TextButton(
            onPressed: _controller.nextPrompt,
            child: const Text('换一个'),
          ),
        ],
      ),
    );
  }

  /// 时光机：随机翻到一篇以前写过的日记。
  ///
  /// 实现只在 [travelToRandomEntryAction] 里有一份——命令面板也调它。
  Future<void> _travelToRandomEntry() =>
      travelToRandomEntryAction(context, _controller);

  /// 外观切换（主题 + 字体）。
  ///
  /// 带文字标签，不是纯图标：纯图标按钮混在一排图标里根本看不出来是干什么的，
  /// 第一版就是这样，用户只能靠悬停提示才发现它。
  /// 窄窗口下才退回纯图标，把空间让给日期。
  Widget _buildAppearanceMenu(BuildContext context, {required bool compact}) {
    final theme = Theme.of(context);
    final settings = widget.settings;

    _AppearanceAction currentAction() => switch (settings.themeMode) {
          AppThemeMode.system => _AppearanceAction.system,
          AppThemeMode.light => _AppearanceAction.light,
          AppThemeMode.dark => _AppearanceAction.dark,
        };

    AppThemeMode? modeFor(_AppearanceAction action) => switch (action) {
          _AppearanceAction.system => AppThemeMode.system,
          _AppearanceAction.light => AppThemeMode.light,
          _AppearanceAction.dark => AppThemeMode.dark,
          _AppearanceAction.typography => null,
        };

    return PopupMenuButton<_AppearanceAction>(
      tooltip: '外观：${themeModeLabel(settings.themeMode)}',
      initialValue: currentAction(),
      onSelected: (action) {
        final mode = modeFor(action);
        if (mode != null) {
          settings.setThemeMode(mode);
          return;
        }
        // 先让菜单的关闭动画走完再开对话框，否则对话框会叠在菜单遮罩上。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(showTypographyAction(context, settings));
        });
      },
      itemBuilder: (context) => <PopupMenuEntry<_AppearanceAction>>[
        for (final mode in AppThemeMode.values)
          PopupMenuItem<_AppearanceAction>(
            value: switch (mode) {
              AppThemeMode.system => _AppearanceAction.system,
              AppThemeMode.light => _AppearanceAction.light,
              AppThemeMode.dark => _AppearanceAction.dark,
            },
            child: Row(
              children: <Widget>[
                Icon(themeModeIcon(mode), size: 18),
                const SizedBox(width: 10),
                Text(themeModeLabel(mode)),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<_AppearanceAction>(
          value: _AppearanceAction.typography,
          child: Row(
            children: <Widget>[
              const Icon(Icons.format_size, size: 18),
              const SizedBox(width: 10),
              Text('字体与行距（${settings.typography.fontSize.round()} px）'),
            ],
          ),
        ),
      ],
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: 8,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(themeModeIcon(settings.themeMode), size: 18),
            if (!compact) ...<Widget>[
              const SizedBox(width: 6),
              Text('外观', style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 桌面窗口是可以被拖窄的，标题栏必须跟着让出空间，
        // 否则日期会把整行挤爆（第一版就是这么坏掉的）。
        final compact = constraints.maxWidth < 620;

        return Padding(
          padding:
              EdgeInsets.fromLTRB(compact ? 6 : 16, 12, compact ? 6 : 16, 8),
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: '前一天',
                visualDensity: VisualDensity.compact,
                onPressed: () => controller.shiftDay(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: InkWell(
                  onTap: widget.onPickDate,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 4 : 10,
                      vertical: 6,
                    ),
                    child: Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            // 窄窗口下退成 ISO 短日期，宁可少点装饰也别截断
                            compact
                                ? formatIsoDate(controller.selectedDate)
                                : formatChineseDate(controller.selectedDate),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        if (controller.isToday) ...<Widget>[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '今天',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_drop_down,
                          size: 20,
                          color: theme.colorScheme.outline,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '后一天',
                visualDensity: VisualDensity.compact,
                onPressed: () => controller.shiftDay(1),
                icon: const Icon(Icons.chevron_right),
              ),
              // 只在列表被隐藏时需要，否则和左侧面板的按钮重复
              if (widget.zenMode)
                TextButton(
                  onPressed: controller.goToToday,
                  child: const Text('今天'),
                ),
              IconButton(
                tooltip: '时光机：随机翻一篇以前写的日记',
                visualDensity: VisualDensity.compact,
                onPressed: _travelToRandomEntry,
                icon: const Icon(Icons.casino_outlined, size: 20),
              ),
              _buildAppearanceMenu(context, compact: compact),
              IconButton(
                tooltip: widget.zenMode ? '显示日记列表' : '专注模式（隐藏日记列表）',
                visualDensity: VisualDensity.compact,
                onPressed: widget.onToggleZen,
                icon: Icon(
                  widget.zenMode
                      ? Icons.vertical_split
                      : Icons.vertical_split_outlined,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMetaBar(BuildContext context) {
    final controller = _controller;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildSingleValueRow(
            context,
            icon: Icons.mood,
            presets: _presetMoods,
            value: controller.mood,
            onChanged: controller.setMood,
            input: _moodInput,
            hint: '自定义',
            fieldKeyPrefix: 'mood',
          ),
          const SizedBox(height: 8),
          _buildSingleValueRow(
            context,
            icon: Icons.wb_sunny_outlined,
            presets: _presetWeathers,
            value: controller.weather,
            onChanged: controller.setWeather,
            input: _weatherInput,
            hint: '自定义',
            fieldKeyPrefix: 'weather',
          ),
          const SizedBox(height: 8),
          _buildTagRow(context),
        ],
      ),
    );
  }

  /// 一行「预设选项 + 自由输入」，心情和天气共用这个结构。
  ///
  /// 预设是为了三秒钟点完，自由输入是为了不被预设框死。
  /// 少了任何一半，用户都会遇到"想写的东西写不下"。
  Widget _buildSingleValueRow(
    BuildContext context, {
    required IconData icon,
    required List<String> presets,
    required String? value,
    required ValueChanged<String?> onChanged,
    required TextEditingController input,
    required String hint,
    required String fieldKeyPrefix,
  }) {
    final theme = Theme.of(context);

    // 预设之外的取值也要列出来，否则手工输入过的值会在界面上"消失"，
    // 用户会以为程序把它丢了。
    final options = <String>[
      ...presets,
      if (value != null && !presets.contains(value)) value,
    ];

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Icon(icon, size: 18, color: theme.colorScheme.outline),
        for (final option in options)
          ChoiceChip(
            label: Text(option),
            selected: value == option,
            onSelected: (selected) => onChanged(selected ? option : null),
            visualDensity: VisualDensity.compact,
            labelStyle: theme.textTheme.bodySmall,
          ),
        SizedBox(
          width: 104,
          child: TextField(
            key: Key('$fieldKeyPrefix-input'),
            controller: input,
            style: theme.textTheme.bodySmall,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            onSubmitted: (text) {
              final trimmed = text.trim();
              if (trimmed.isEmpty) return;
              onChanged(trimmed);
              input.clear();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTagRow(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Icon(
          Icons.local_offer_outlined,
          size: 18,
          color: theme.colorScheme.outline,
        ),
        for (final tag in controller.tags)
          InputChip(
            label: Text(tag),
            visualDensity: VisualDensity.compact,
            labelStyle: theme.textTheme.bodySmall,
            onDeleted: () {
              final next = controller.tags.toList()..remove(tag);
              controller.setTags(next);
            },
          ),
        _buildTagInput(context),
      ],
    );
  }

  /// 标签输入框，带已用标签的自动补全。
  ///
  /// 标签的价值恰恰在于**反复使用同一批词**；一旦标签多起来，
  /// 每次重新手打就成了每天都要付的成本。所以补全在这里不是锦上添花。
  Widget _buildTagInput(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    return SizedBox(
      width: 128,
      child: Autocomplete<String>(
        // 选中后把输入框清空：那个标签已经变成一个 chip 了，
        // 输入框里再留一份只会让人以为没加上。
        displayStringForOption: (_) => '',
        optionsBuilder: (value) {
          final query = value.text.trim().toLowerCase();
          final candidates = controller.allTags
              .where((tag) => !controller.tags.contains(tag));
          if (query.isEmpty) return candidates;
          return candidates.where((tag) => tag.toLowerCase().contains(query));
        },
        onSelected: (tag) {
          controller.setTags(<String>[...controller.tags, tag]);
        },
        fieldViewBuilder:
            (context, textController, focusNode, onFieldSubmitted) {
          return TextField(
            key: const Key('tag-input'),
            controller: textController,
            focusNode: focusNode,
            style: theme.textTheme.bodySmall,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '加标签',
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            onSubmitted: (value) {
              final trimmed = value.trim();
              if (trimmed.isEmpty) return;
              controller.setTags(<String>[...controller.tags, trimmed]);
              textController.clear();
            },
          );
        },
        optionsViewBuilder: (context, onSelected, options) {
          final items = options.toList();
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(6),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxHeight: 240, maxWidth: 200),
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final option = items[index];
                    return ListTile(
                      dense: true,
                      title: Text(option, style: theme.textTheme.bodySmall),
                      onTap: () => onSelected(option),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 「去年的今天」。这是让人愿意长期写下去的功能里性价比最高的一个。
  Widget _buildOnThisDay(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.history, size: 16, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Text('往年的今天', style: theme.textTheme.bodySmall),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                for (final entry in controller.onThisDay.take(3))
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      '${entry.date.year} 年'
                      '${entry.preview.isEmpty ? '' : ' · ${entry.preview}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    labelStyle: theme.textTheme.bodySmall,
                    onPressed: () => controller.openDate(entry.date),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 内联格式按钮。
  ///
  /// 有了按钮，快捷键才被发现；有了快捷键，写起来才不用离开键盘。两个都要。
  ///
  /// 注意这些做的是**插入 Markdown 标记**，不是改某个加粗属性——
  /// 正文永远是纯文本，这是这个程序不肯让步的地方。
  Widget _buildFormatStrip(BuildContext context) {
    final theme = Theme.of(context);

    Widget button({
      required IconData icon,
      required String tooltip,
      required String open,
      required String close,
    }) {
      return IconButton(
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        onPressed: () => _applyFormat(open, close),
        icon: Icon(icon),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
      child: Row(
        children: <Widget>[
          const Spacer(),
          button(
            icon: Icons.format_bold,
            tooltip: '加粗（Ctrl+B）',
            open: MarkdownFormatter.bold,
            close: MarkdownFormatter.bold,
          ),
          button(
            icon: Icons.format_italic,
            tooltip: '斜体（Ctrl+I）',
            open: MarkdownFormatter.italic,
            close: MarkdownFormatter.italic,
          ),
          button(
            icon: Icons.format_underlined,
            tooltip: '下划线（Ctrl+U，会插入 <u> 标签）',
            open: MarkdownFormatter.underlineOpen,
            close: MarkdownFormatter.underlineClose,
          ),
          const SizedBox(width: 4),
          Text(
            'Markdown',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  /// 对当前选区套用一对标记；再按一次取消。
  ///
  /// 实现只在 [applyMarkdownFormat] 里有一份——命令面板也调它。
  void _applyFormat(String open, String close) => applyMarkdownFormat(
        bodyController: widget.bodyController,
        controller: _controller,
        bodyFocus: widget.bodyFocus,
        open: open,
        close: close,
      );

  Widget _buildWritingArea(BuildContext context) {
    final typography = widget.settings.typography;

    return Center(
      child: ConstrainedBox(
        // 行宽限制在易读范围内。横跨 4K 屏幕的一行字没法读。
        constraints: BoxConstraints(maxWidth: typography.lineWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 28, 20),
          child: KeyedSubtree(
            // 每当正文被**程序**整体替换（切换日期、恢复草稿）就换一个 key，
            // 让 Flutter 重建整个输入框子树——连带把它的撤销栈一起丢掉。
            //
            // 为什么必须这么做：Flutter 的撤销栈记录 controller 的**每一次**
            // 值变化，不区分是用户敲的还是程序赋的（`undo_history.dart` 里
            // `shouldChangeUndoStack` 默认一律放行）。而本程序所有日期共用
            // 一个 controller，于是撤销栈里混着好几天的内容。实测后果：
            // 切到别的日期再切回来按 Ctrl+Z，会把**那一天**的内容灌进当前这天，
            // 900ms 后自动保存落盘，而原内容没有任何副本。
            //
            // 用 bodyRevision 而不是日期做 key：它精确表示"程序替换了正文"，
            // 所以恢复草稿这类也算进去；而用户打字不会动它，不会打断输入。
            key: ValueKey<int>(_controller.bodyRevision),
            child: CallbackShortcuts(
              // Ctrl+B / Ctrl+I / Ctrl+U 在 Windows 上没有被 Flutter 的
              // 输入框默认占用（那套 Emacs 式 Ctrl+B 只在 macOS 生效），
              // 所以可以安全地拿来当格式快捷键。
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.keyB, control: true):
                    () => _applyFormat(
                          MarkdownFormatter.bold,
                          MarkdownFormatter.bold,
                        ),
                const SingleActivator(LogicalKeyboardKey.keyI, control: true):
                    () => _applyFormat(
                          MarkdownFormatter.italic,
                          MarkdownFormatter.italic,
                        ),
                const SingleActivator(LogicalKeyboardKey.keyU, control: true):
                    () => _applyFormat(
                          MarkdownFormatter.underlineOpen,
                          MarkdownFormatter.underlineClose,
                        ),
              },
              child: TextField(
                key: const Key('diary-body-field'),
                controller: widget.bodyController,
                focusNode: widget.bodyFocus,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                style: TextStyle(
                  fontSize: typography.fontSize,
                  height: typography.lineHeight,
                  fontWeight: fontWeightFor(typography.fontWeightValue),
                ),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: '今天发生了什么？',
                  hintStyle: TextStyle(fontSize: typography.fontSize),
                ),
                onChanged: _controller.updateBody,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBar(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    return Padding(
      // 右边只留 4：更多按钮就是这个角落的最后一个元素。
      // 内边距给大了，它会看起来飘在中间而不是贴在角上。
      padding: const EdgeInsets.fromLTRB(20, 6, 4, 6),
      child: Row(
        children: <Widget>[
          _buildSaveIndicator(context),
          const SizedBox(width: 16),
          Text(
            '${controller.body.runes.length} 字',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          // 这里必须用 Expanded 而不是「Spacer + Flexible」。
          //
          // 那两者各占一半自由空间，而 Flexible 是松约束——路径文字用不到
          // 那一半时，多出来的空白并不会还回去，于是右边的「更多」按钮被
          // 留在了中间（实测：窗口宽 1200，按钮中心停在 928 而不是贴到右边缘）。
          // Expanded 会把剩余空间全部吃掉，文字右对齐，按钮才真正落在角上。
          Expanded(
            child: Text(
              controller.locationDescription,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 命令面板的入口。
          //
          // 面板本身靠 Ctrl+K 就能开，但**只留快捷键等于没有入口**：没人会去猜
          // 一个看不见的功能。按钮和快捷键两个都要（格式条那边已经写过同一条）。
          //
          // 图标刻意复用已经在用的 `search`：这个项目的图标字体是按用到的字形
          // 裁剪的，新图标出问题只在 release 构建里暴露成空白方块
          // （见 docs/开发须知.md 第 1.1 条）。语义靠 tooltip 补足。
          IconButton(
            tooltip: '命令面板（Ctrl+K）',
            visualDensity: VisualDensity.compact,
            onPressed: widget.onOpenCommandPalette,
            icon: const Icon(Icons.search, size: 18),
          ),
          if (_showBackupWarning()) _buildBackupWarning(context),
          const SizedBox(width: 8),
          _buildMoreMenu(context),
        ],
      ),
    );
  }

  /// 备份该提醒了吗。判断本身在纯逻辑层，和备份对话框共用一套，
  /// 免得出现「图标说该备份、点开说还早」这种自相矛盾。
  bool _showBackupWarning() =>
      platform.supportsBackup &&
      isBackupStale(
        backupRoot: widget.settings.backupRoot,
        lastBackupAt: widget.settings.lastBackupAt,
        now: DateTime.now(),
      );

  /// 备份过期时的一个小警告图标。
  ///
  /// **只在真的该备份时出现**，平时完全不占地方：功能做出来却想不起来用，
  /// 等于没有；但常驻一个图标又会变成噪音，看久了就没人看了。
  ///
  /// 图标复用代码里已经在用的 `warning_amber_outlined`。这个项目裁剪过图标
  /// 字体，**换一个没用过的图标会在 release 构建里变成空白**，而那种失败
  /// 只在真机构建里暴露——语义稍弱一点、靠 tooltip 补足是更划算的选择。
  Widget _buildBackupWarning(BuildContext context) {
    final theme = Theme.of(context);
    final days = daysSinceBackup(widget.settings.lastBackupAt, DateTime.now());
    final tooltip = days == null ? '还没有备份过，点这里去备份' : '已经 $days 天没备份了';

    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(
        Icons.warning_amber_outlined,
        size: 18,
        color: theme.colorScheme.error,
      ),
      onPressed: () => unawaited(openBackupAction(
        context,
        settings: widget.settings,
        controller: _controller,
      )),
    );
  }

  /// 右下角的「更多」菜单。
  ///
  /// 这里原本分散着三个常驻控件（打开文件夹的图标、导出按钮），加上左侧栏
  /// 底部的「日记位置」。现在全部收进来，状态栏只剩保存状态、字数和路径，
  /// 而这个按钮本身成为右下角最靠边的元素。
  ///
  /// 顺序：日常操作（打开文件夹、存储位置、导出、备份）
  /// → （分隔）数据管理（历史版本、回收站）→ （分隔）破坏性操作（删除）。
  ///
  /// 文案后面刻意不带「…」：这个菜单里每一项都会打开对话框或确认框，
  /// 有的带有的不带反而不一致，所以统一去掉。
  Widget _buildMoreMenu(BuildContext context) {
    final theme = Theme.of(context);
    final canDelete = !_controller.isCurrentEntryEmpty;
    final onOpenLocation = widget.onOpenLocationSettings;

    Widget row(IconData icon, String label, {Color? color}) => Row(
          children: <Widget>[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Text(
              label,
              style: color == null
                  ? theme.textTheme.bodyMedium
                  : theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ],
        );

    return PopupMenuButton<_MoreAction>(
      tooltip: '更多',
      onSelected: _handleMoreAction,
      icon: const Icon(Icons.more_vert, size: 20),
      itemBuilder: (context) => <PopupMenuEntry<_MoreAction>>[
        PopupMenuItem<_MoreAction>(
          value: _MoreAction.openFolder,
          child: row(Icons.folder_open, '打开日记文件夹'),
        ),
        if (onOpenLocation != null)
          PopupMenuItem<_MoreAction>(
            value: _MoreAction.location,
            // 用「储物箱」而不是另一个文件夹图标：原来的 folder_outlined
            // 和上面的 folder_open 几乎分不出来，等于没有图标。
            child: row(Icons.inventory_2_outlined, '日记存储位置'),
          ),
        PopupMenuItem<_MoreAction>(
          value: _MoreAction.export,
          child: row(Icons.ios_share, '导出'),
        ),
        // 预览模式没有可写的文件系统，这一项整个不出现——
        // 给一个点了会失败的按钮，比没有这个按钮更糟。
        if (platform.supportsBackup)
          PopupMenuItem<_MoreAction>(
            value: _MoreAction.backup,
            child: row(Icons.save_outlined, '备份'),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<_MoreAction>(
          value: _MoreAction.history,
          child: row(Icons.history, '历史版本'),
        ),
        PopupMenuItem<_MoreAction>(
          value: _MoreAction.trash,
          child: row(Icons.restore_from_trash, '回收站'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<_MoreAction>(
          value: _MoreAction.delete,
          enabled: canDelete,
          child: row(
            Icons.delete_forever,
            canDelete ? '删除这一天的日记' : '这一天还没写东西',
            color: canDelete
                ? theme.colorScheme.error
                : theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }

  /// 打开文件夹、备份、历史版本、回收站、导出、删除都转交给 [diary_actions]。
  ///
  /// 这一层只负责"菜单点了哪一项"，不负责动作本身怎么实现——因为命令面板
  /// 要执行同一批动作，实现必须只有一份。
  Future<void> _handleMoreAction(_MoreAction action) async {
    switch (action) {
      case _MoreAction.openFolder:
        await revealDiaryFolderAction(context, _controller);
      case _MoreAction.backup:
        await openBackupAction(
          context,
          settings: widget.settings,
          controller: _controller,
        );
      case _MoreAction.location:
        widget.onOpenLocationSettings?.call();
      case _MoreAction.export:
        await exportDiaryAction(context, _controller);
      case _MoreAction.history:
        await showHistoryAction(context, _controller);
      case _MoreAction.trash:
        await showTrashAction(context, _controller);
      case _MoreAction.delete:
        await deleteCurrentEntryAction(context, _controller);
    }
  }

  Widget _buildSaveIndicator(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    final (IconData icon, Color color, String label) =
        switch (controller.saveState) {
      SaveState.idle => (
          Icons.check_circle_outline,
          theme.colorScheme.outline,
          controller.hasEntry ? '已保存' : '还没写',
        ),
      SaveState.dirty => (
          Icons.edit_outlined,
          theme.colorScheme.primary,
          '未保存…',
        ),
      SaveState.saving => (
          Icons.sync,
          theme.colorScheme.primary,
          '正在保存…',
        ),
      SaveState.saved => (
          Icons.check_circle,
          theme.colorScheme.primary,
          controller.isPersistent ? '已保存' : '已存入内存',
        ),
      SaveState.failed => (
          Icons.error_outline,
          theme.colorScheme.error,
          '保存失败',
        ),
    };

    final savedAt = controller.savedAt;
    final suffix = controller.saveState == SaveState.saved && savedAt != null
        ? ' · ${_clock(savedAt)}'
        : '';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          '$label$suffix',
          style: theme.textTheme.bodySmall?.copyWith(color: color),
        ),
        if (controller.saveState == SaveState.failed &&
            controller.saveError != null) ...<Widget>[
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              controller.saveError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }

  static String _clock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}:'
      '${value.second.toString().padLeft(2, '0')}';
}
