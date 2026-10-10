import 'dart:async';

import 'package:flutter/material.dart';

import '../core/chinese_calendar.dart';
import '../core/day.dart';
import '../core/huangli.dart';
import '../core/models/diary_entry.dart';
import '../data/huangli_source.dart';
import '../state/diary_controller.dart';
import '../state/settings_controller.dart';
import 'filter_dialog.dart';
import 'huangli_card.dart';
import 'prompts.dart';
import 'vault_dialog.dart';
import 'vault_menu.dart';

/// 给某一栏加「悬停 / 长按看黄历」的能力。
///
/// 单独做成一个组件，是为了拿到**这一栏自己的** RenderObject——黄历卡片要
/// 贴着这一栏的上下位置弹出来，而 `itemBuilder` 拿到的 context 属于整个列表，
/// 算不出单栏的位置。
///
/// 两个触发源、同一张卡片：桌面用鼠标悬停，触屏用长按。手机上没有 hover，
/// 长按是唯一的入口，所以这个兜底不是可选项。
class _PeekTarget extends StatelessWidget {
  const _PeekTarget({
    required this.date,
    required this.onHover,
    required this.onLongPress,
    required this.onDismiss,
    required this.child,
  });

  final DateTime date;
  final void Function(DateTime date, Rect anchor) onHover;
  final void Function(DateTime date, Rect anchor) onLongPress;
  final VoidCallback onDismiss;
  final Widget child;

  Rect? _globalRect(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }


  @override
  Widget build(BuildContext context) {
    Rect? rect() {
      final value = _globalRect(context);
      return value;
    }

    return MouseRegion(
      onEnter: (_) {
        final anchor = rect();
        if (anchor != null) onHover(date, anchor);
      },
      onExit: (_) => onDismiss(),
      child: GestureDetector(
        // 长按是触屏上的入口：手机上鼠标悬停不存在。
        // 它不做延迟——长按本身已经是明确的操作了。
        onLongPressStart: (_) {
          final anchor = rect();
          if (anchor != null) onLongPress(date, anchor);
        },
        child: child,
      ),
    );
  }
}

/// 左侧日记列表 + 搜索。
///
/// 搜索是纯内存过滤：十年日记也才 3650 条，全量扫描就是毫秒级。
/// 这也是「一天一个 Markdown 文件」相对数据库方案的额外好处——
/// 派生数据可以完全不存在，也就不存在索引过期、需要重建的问题。
class EntryListPanel extends StatefulWidget {
  const EntryListPanel({
    super.key,
    required this.controller,
    required this.onPickDate,
    required this.settings,
    this.searchFocus,
  });

  final DiaryController controller;
  final SettingsController settings;
  final VoidCallback onPickDate;

  /// 搜索框的焦点节点，由上层持有。
  ///
  /// 为什么不由这里自己建：命令面板的「搜索日记」要能把光标送进这个输入框，
  /// 而面板挂在 `HomePage` 上——它是这一层的**兄弟**，够不到这里的私有状态。
  final FocusNode? searchFocus;

  @override
  State<EntryListPanel> createState() => _EntryListPanelState();
}

class _EntryListPanelState extends State<EntryListPanel> {
  final TextEditingController _search = TextEditingController();

  /// 鼠标停在某一栏多久之后才弹黄历。太短的话鼠标划过列表会弹一串卡片。
  static const Duration _peekDelay = Duration(milliseconds: 650);

  /// 离开之后隔一小会儿才关。纯粹为了不让鼠标抖动造成闪一下。
  static const Duration _dismissGrace = Duration(milliseconds: 180);

  HuangliTable? _huangli;
  OverlayEntry? _card;
  DateTime? _peekDate;
  Timer? _showTimer;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHuangli());
  }

  Future<void> _loadHuangli() async {
    try {
      final table = await loadHuangliTable();
      if (!mounted) return;
      setState(() => _huangli = table);
    } catch (error) {
      // 黄历加载失败只意味着没有悬浮卡片，绝不能影响日记本身
      debugPrint('[riji] 黄历数据加载失败：$error');
    }
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _dismissTimer?.cancel();
    _removeCard();
    _search.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 黄历悬浮卡片
  // ---------------------------------------------------------------------------
  //
  // 两个触发源、同一个卡片：
  //   * 桌面：鼠标悬停（延迟后弹出）
  //   * 触屏：长按（没有 hover，这是手机端唯一的入口）
  //
  // 卡片是**只读**的，包在 IgnorePointer 里，不会挡住底下的点击。
  // 指针移到卡片上会被判成"离开列表行"，卡片随即关闭——这是刻意的：
  // 它是"瞄一眼"，不是可以停留操作的面板。

  void _schedulePeek(DateTime date, Rect anchor) {
    _dismissTimer?.cancel();
    // 已经在显示这一天了就别重来一遍，否则会出现闪一下
    if (_peekDate != null && isSameDay(_peekDate!, date) && _card != null) {
      return;
    }
    _showTimer?.cancel();
    _showTimer = Timer(_peekDelay, () => _presentCard(date, anchor));
  }

  void _scheduleDismiss() {
    _showTimer?.cancel();
    _dismissTimer?.cancel();
    _dismissTimer = Timer(_dismissGrace, _removeCard);
  }

  void _removeCard() {
    _card?.remove();
    _card = null;
    _peekDate = null;
  }

  void _presentCard(DateTime date, Rect anchor) {
    final table = _huangli;
    if (table == null) return;

    final day = table.forDate(date);
    // 超出黄历覆盖范围（2000–2060）就不显示。宁可没有，也不显示错的。
    if (day == null) return;

    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    _removeCard();

    final screen = MediaQuery.sizeOf(context);
    const estimatedHeight = 320.0;
    final maxTop = screen.height - estimatedHeight;
    final top = anchor.top.clamp(8.0, maxTop < 8.0 ? 8.0 : maxTop);

    _peekDate = date;
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        // 浮在日记列表右边，盖在写作区上——侧栏只有 250~320px，卡片放不下
        left: anchor.right + 8,
        top: top,
        child: IgnorePointer(
          child: HuangliCard(
            day: day,
            maxHeight: screen.height - top - 12,
          ),
        ),
      ),
    );
    _card = entry;
    overlay.insert(entry);
  }

  /// 左侧日期的右键菜单：加密/解密这一天。
  ///
  /// **先把那一天打开再算菜单项**：菜单里"能不能锁/能不能看原文"是按
  /// "当前这一天"算的，不先切过去就会拿错日期的状态。
  Future<void> _showEntryVaultMenu(Offset globalPosition, DateTime date) async {
    final controller = widget.controller;
    await controller.openDate(date);
    if (!mounted) return;
    await showVaultMenuAt(
      context,
      globalPosition: globalPosition,
      controller: controller,
      settings: widget.settings,
      title: formatIsoDate(date),
      // 「日记加密…」是设置，用「⋮」就够了，这里不放；
      // 但"删掉这一天"要放——在列表里右键某一天，最自然的期待就是能处理它。
      includeVaultDialog: false,
      includeDeleteDay: true,
    );
  }

  /// 「解锁来搜索」：只为这次搜索解锁，用完即丢。
  ///
  /// 它**不会**打开"能改写文件"那一档权限（见 `VaultService.canWrite`），
  /// 所以即便点错了也不会把任何东西写成明文。
  Future<void> _unlockForSearch() async {
    final controller = widget.controller;
    final vault = controller.vault;
    if (vault == null) return;
    final messenger = ScaffoldMessenger.of(context);

    final result = await showVaultUnlockPrompt(context, vault: vault);
    if (result == null || !result.ok) return;

    final failed = await controller.prepareVaultForSearch();
    if (failed > 0) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('有 $failed 天的内容解不开：文件可能被改过，或者不是用这个口令锁的。'),
        ),
      );
      return;
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('已解锁：锁着的内容这次搜索也会参与。')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final entries = controller.visibleEntries;

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Column(
            children: <Widget>[
              TextField(
                controller: _search,
                focusNode: widget.searchFocus,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索日记…',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: controller.query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () {
                            _search.clear();
                            controller.setQuery('');
                          },
                        ),
                  border: const OutlineInputBorder(),
                ),
                onChanged: controller.setQuery,
              ),
              // ⚠️ 搜索结果不完整必须说出来。
              //
              // 锁着、又还没解锁的那些天**没有参与搜索**。对用户来说，
              // "搜不到"和"没搜"是两件完全不同的事：前者意味着"我没写过"，
              // 后者只是"这会儿看不见"。让人把后者当成前者，是最不该发生
              // 的一种误导——所以这行提示**命中为 0 时也照样显示**。
              if (controller.lockedNotSearchedCount > 0) ...<Widget>[
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.lock_outline,
                      size: 14,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '另有 ${controller.lockedNotSearchedCount} 篇已加密，'
                        '没有参与搜索',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _unlockForSearch(),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('解锁来搜索'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        _search.clear();
                        controller.setQuery('');
                        controller.goToToday();
                      },
                      icon: const Icon(Icons.today, size: 16),
                      label: Text(controller.hasWrittenToday ? '今天（已写）' : '今天'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: '月视图/年视图',
                    onPressed: widget.onPickDate,
                    icon: const Icon(Icons.calendar_month, size: 18),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: controller.filter.isActive
                        ? '筛选：${controller.filter.describe()}'
                        : '筛选',
                    isSelected: controller.filter.isActive,
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => DiaryFilterDialog(controller: controller),
                    ),
                    icon: const Icon(Icons.filter_list, size: 18),
                  ),
                ],
              ),
              // 筛选生效时把条件摆在明面上：用户忘了自己筛过东西，
              // 就会以为"我的日记怎么少了一大半"。
              if (controller.filter.isActive) ...<Widget>[
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Flexible(
                      child: InputChip(
                        label: Text(
                          controller.filter.describe(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        labelStyle: theme.textTheme.bodySmall,
                        visualDensity: VisualDensity.compact,
                        onDeleted: controller.clearFilter,
                        deleteButtonTooltipMessage: '清除筛选',
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: entries.isEmpty
              ? _buildEmptyState(theme, controller)
              // 滚动就关掉卡片：否则它会停在旧位置，指向的已经不是那一行了
              : NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification is ScrollUpdateNotification) {
                      _removeCard();
                    }
                    return false;
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return _PeekTarget(
                        date: entry.date,
                        // 悬停要延迟：鼠标划过列表不该弹一串卡片
                        onHover: (date, anchor) => _schedulePeek(date, anchor),
                        // 长按是明确的操作，立刻弹，不再等
                        onLongPress: _presentCard,
                        onDismiss: _scheduleDismiss,
                        child: GestureDetector(
                          // 右键：加密/解密这一天的菜单
                          onSecondaryTapDown: (details) =>
                              _showEntryVaultMenu(
                            details.globalPosition,
                            entry.date,
                          ),
                          child: _EntryTile(
                            entry: entry,
                            selected:
                                isSameDay(entry.date, controller.selectedDate),
                            onTap: () => controller.openDate(entry.date),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
        const Divider(height: 1),
        _buildFooter(theme, controller),
      ],
    );
  }

  Widget _buildEmptyState(ThemeData theme, DiaryController controller) {
    final searching = controller.query.trim().isNotEmpty;
    final filtering = controller.filter.isActive;

    final String message;
    if (searching) {
      message = '没有匹配的日记';
    } else if (filtering) {
      message = '没有符合筛选的日记';
    } else {
      message = '还没有日记';
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              searching || filtering
                  ? Icons.search_off
                  : Icons.auto_stories_outlined,
              size: 40,
              color: theme.colorScheme.outlineVariant,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            if (filtering) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                controller.filter.describe(),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outlineVariant,
                ),
              ),
              TextButton(
                onPressed: controller.clearFilter,
                child: const Text('清除筛选'),
              ),
            ] else if (!searching) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                '在右边写下第一句吧',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outlineVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme, DiaryController controller) {
    final conflicts = controller.conflicts.length;

    // 「日记位置」原本在这一行，现在移到了编辑区右下角的「更多」菜单里，
    // 所以这一行只在有冲突时才有内容——没冲突就整行不占位。
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            controller.filter.isActive || controller.query.trim().isNotEmpty
                ? '筛选出 ${controller.visibleEntries.length} / ${controller.totalEntries} 篇'
                : '共 ${controller.totalEntries} 篇 · ${controller.totalCharacters} 字',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          if (conflicts > 0) ...<Widget>[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: ActionChip(
                avatar: Icon(
                  Icons.call_split_outlined,
                  size: 14,
                  color: theme.colorScheme.error,
                ),
                label: Text('$conflicts 个冲突'),
                labelStyle: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: () => showConflictsDialog(context, controller),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final DiaryEntry entry;
  final bool selected;
  final VoidCallback onTap;


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mood = entry.mood;
    final annotation = ChineseCalendar.annotate(entry.date);

    return ListTile(
      dense: true,
      isThreeLine: annotation.hasLunarLine,
      selected: selected,
      selectedTileColor:
          theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      title: Row(
        children: <Widget>[
          Text(
            formatIsoDate(entry.date),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            weekdayShort(entry.date),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          // 阳历节日紧跟在阳历日期后面，因为它属于这一行的日期
          if (annotation.solarFestival != null) ...<Widget>[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                annotation.solarFestival!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (mood != null && mood.isNotEmpty)
            Text(
              mood,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (annotation.hasLunarLine) _buildLunarLine(theme, annotation),
          Text(
            entry.listPreview.isEmpty ? '（空）' : entry.listPreview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  /// 农历那一行：**阴历节日 · 农历日期 · 节气**。
  ///
  /// 顺序是有讲究的：阴历节日和农历日期是一体的（春节就是正月初一），
  /// 所以节日排在日期前面当引子；节气是另一套体系，排在日期后面。
  ///
  /// 用 Text.rich 而不是几个 Text 拼，这样窄侧栏下能整体省略号收尾，不会溢出。
  Widget _buildLunarLine(ThemeData theme, DayAnnotation annotation) {
    final base = theme.textTheme.labelSmall;
    final dim = base?.copyWith(color: theme.colorScheme.outline);
    final spans = <InlineSpan>[];

    void add(String text, TextStyle? style) {
      if (spans.isNotEmpty) spans.add(TextSpan(text: ' · ', style: dim));
      spans.add(TextSpan(text: text, style: style));
    }

    if (annotation.lunarFestival != null) {
      add(
        annotation.lunarFestival!,
        base?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    if (annotation.lunar != null) add(annotation.lunar!.text, dim);
    if (annotation.solarTerm != null) {
      add(
        annotation.solarTerm!,
        base?.copyWith(color: theme.colorScheme.tertiary),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 1, bottom: 2),
      child: Text.rich(
        TextSpan(style: dim, children: spans),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
