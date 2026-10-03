import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/command_palette.dart';

/// 一条命令在界面层的完整形态：可搜索的描述 + 图标 + 真正要执行的东西。
///
/// 分成两层（[PaletteCommand] 在 core、这里在 ui）不是为了优雅，是因为
/// `core/` 不依赖 Flutter：匹配和排序要能用普通 `test()` 量。
class CommandAction {
  const CommandAction({
    required this.command,
    required this.icon,
    required this.run,
    this.focusTarget,
  });

  final PaletteCommand command;

  /// 图标。**只用代码里已经在用的那些图标**：这个项目的图标字体是按用到的
  /// 字形裁剪的，新图标出问题只会在 release 构建里暴露成空白方块
  /// （见 `docs/开发须知.md` 第 1.1 条）。
  final IconData icon;

  final Future<void> Function() run;

  /// 这条命令执行完，焦点该还给谁。
  ///
  /// 默认（null）还给正文：面板一关，用户的下一句话应该落进日记里，而不是
  /// 打进空气里（「打开即写」这条在项目里踩过一次）。
  /// 少数命令的执行结果**就是**把光标放到别处（例如「搜索日记」），
  /// 那时在这里指定目标节点。
  final FocusNode? focusTarget;
}

/// 弹出命令面板。返回用户选中的那一条；按 Esc 或点面板外面返回 null。
Future<CommandAction?> showCommandPalette(
  BuildContext context, {
  required List<CommandAction> actions,
}) {
  return showDialog<CommandAction>(
    context: context,
    builder: (_) => _CommandPaletteDialog(actions: actions),
  );
}

/// 行高固定。
///
/// 固定行高不是为了好看，是为了「把选中项滚进视野」能用一个乘法算出来。
/// 一行和两行的高度不同的话，就只能靠 `Scrollable.ensureVisible`，而它在列表项
/// **还没被构建出来**时拿不到 context —— 用方向键一路按到底时正好会遇到这种项。
const double _rowHeight = 56;

/// 列表区的最大高度。约六行，再多就该靠搜索而不是靠翻。
const double _listMaxHeight = 360;

class _CommandPaletteDialog extends StatefulWidget {
  const _CommandPaletteDialog({required this.actions});

  final List<CommandAction> actions;

  @override
  State<_CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<_CommandPaletteDialog> {
  final TextEditingController _query = TextEditingController();
  final ScrollController _scroll = ScrollController();

  late List<int> _visible;
  int _selected = 0;

  /// 把动作表摊成纯描述的列表，交给 core 去排序。
  List<PaletteCommand> get _commands =>
      <PaletteCommand>[for (final action in widget.actions) action.command];

  @override
  void initState() {
    super.initState();
    // 空查询 = 全部命令，保持注册顺序。
    _visible = rankCommands('', _commands);
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() {
      _visible = rankCommands(value, _commands);
      // 每次改查询都从第一条重新开始。保持选中项不动的话，打一个字就「跳」到
      // 列表中间，而用户根本没看过那一条。
      _selected = 0;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _move(int delta) {
    if (_visible.isEmpty) return;
    setState(() {
      _selected = (_selected + delta).clamp(0, _visible.length - 1);
    });
    _revealSelected();
  }

  /// 把选中项滚进视野。
  ///
  /// 行高固定，所以这是一个乘法，不依赖「那一项有没有被构建出来」。
  void _revealSelected() {
    if (!_scroll.hasClients) return;
    final target = _selected * _rowHeight - _listMaxHeight / 2 + _rowHeight / 2;
    _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  void _run(int index) {
    final action = widget.actions[_visible[index]];
    // 禁用的命令**可以选中、但不能执行**。原因是显示在它自己那一行上的，
    // 不需要再弹一个提示 —— SnackBar 在对话框底下的遮罩后面，用户根本看不见。
    if (!action.command.enabled) return;
    Navigator.of(context).pop(action);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      // 贴着上方而不是正中：它是个「输入框」，不是个「确认框」。
      // 位置和 VS Code / Obsidian 一致，视线不用在屏幕中间来回找。
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: CallbackShortcuts(
          // 上下键在这里**必须**绑住：单选文本框自己不会用它们，
          // 而光标在列表和输入框之间来回跑是这类面板最常见的用法。
          // 键事件是从焦点节点向上冒泡的，这一层在输入框的焦点之上、
          // 而 Flutter 那套文本编辑快捷键在更外层（WidgetsApp），所以我们先拿到。
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _buildQueryField(),
              const Divider(height: 1),
              _buildResultList(theme),
              const Divider(height: 1),
              _buildHint(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQueryField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: TextField(
        key: const Key('command-palette-query'),
        controller: _query,
        autofocus: true,
        onChanged: _onQueryChanged,
        // 回车走输入框自己的 onSubmitted，不再绑一次键：输入框本来就会把回车
        // 交出来，多绑一处就多一处需要维护、需要测的东西。
        onSubmitted: (_) {
          if (_visible.isNotEmpty) _run(_selected);
        },
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          prefixIcon: Icon(Icons.search, size: 18),
          hintText: '搜功能：试试「深色」「行距」「备份」',
        ),
      ),
    );
  }

  Widget _buildResultList(ThemeData theme) {
    if (_visible.isEmpty) {
      return SizedBox(
        height: 120,
        child: Center(
          child: Text(
            '没有匹配的命令',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      );
    }

    return Flexible(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _listMaxHeight),
        child: ListView.builder(
          controller: _scroll,
          itemExtent: _rowHeight,
          itemCount: _visible.length,
          itemBuilder: (context, index) => _buildRow(theme, index),
        ),
      ),
    );
  }

  Widget _buildRow(ThemeData theme, int index) {
    final action = widget.actions[_visible[index]];
    final command = action.command;
    final selected = index == _selected;
    final enabled = command.enabled;

    final foreground = !enabled
        ? theme.colorScheme.outline
        : selected
            ? theme.colorScheme.onPrimaryContainer
            : theme.colorScheme.onSurface;

    // 禁用时用「为什么不能点」，否则用「当前值」。两者都是一句话，
    // 而且是用户此刻最需要的那一句。
    final secondary = enabled ? command.subtitle : command.disabledReason;

    return InkWell(
      key: ValueKey<String>('command-${command.id}'),
      onTap: enabled ? () => _run(index) : null,
      child: Container(
        color: selected ? theme.colorScheme.primaryContainer : null,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: <Widget>[
            Icon(
              action.icon,
              size: 18,
              color: enabled ? foreground : theme.colorScheme.outlineVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    command.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                    ),
                  ),
                  if (secondary != null)
                    Text(
                      secondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: selected && enabled
                            ? theme.colorScheme.onPrimaryContainer
                                .withValues(alpha: 0.75)
                            : theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
            ),
            if (command.shortcut != null) ...<Widget>[
              const SizedBox(width: 12),
              Text(
                command.shortcut!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHint(ThemeData theme) {
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.outline,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: <Widget>[
          Text('↑↓ 选择 · Enter 执行 · Esc 关闭', style: style),
          const Spacer(),
          Text('${_visible.length} 条', style: style),
        ],
      ),
    );
  }
}
