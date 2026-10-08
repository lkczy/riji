import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/day.dart';
import '../core/writing_stats.dart';
import '../state/diary_controller.dart';

/// 日历的两种尺度。
enum CalendarScale {
  /// 一个月一张大格子表：**能选日期**（格子够大，点得准）。
  month,

  /// 一年一张小格子图：**一眼看全年**（格子小，点得中但不舒服）。
  year,
}

/// 写作日历：选日期和看热力图合成一个对话框，右上角切换两种尺度。
///
/// **为什么合成一个**：两者读的是同一批数据、动作也一样（点一下就跳到那天），
/// 分成两个入口只会让人猜"该点哪个"。侧栏那个日历图标开在月视图（因为它的
/// 本意是选日期），状态栏和命令面板里的「写作热力图」开在年视图。
///
/// **为什么月视图不能省**：年视图的格子只有 11px，当点击目标太小；
/// 一年 53 周按能舒服点中的尺寸排下来要 1300px 以上，塞不进窗口。
/// 所以"看"用年、"选"用月。
///
/// 打开期间**不跟随 entries 变化**：它是模态的，开着的时候写不了字；
/// 后台同步进来的改动等下次打开再看。
Future<void> showCalendarDialog(
  BuildContext context,
  DiaryController controller, {
  CalendarScale initialScale = CalendarScale.month,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _CalendarDialog(
      controller: controller,
      initialScale: initialScale,
    ),
  );
}

// -----------------------------------------------------------------------------
// 尺寸。**要调对话框大小就改这一段**（下面 build 里还有个"最大不超过窗口"的夹取）
// -----------------------------------------------------------------------------

// 年视图的格子。11 → 14 是这一次放大的结果；再大就要靠加宽对话框，
// 因为一年固定 53 列，宽度是被列数锁死的。
const double _yearCell = 14;
const double _yearGap = 3;
const double _yearPitch = _yearCell + _yearGap;
const double _yearDayLabelWidth = 24;
const double _monthLabelHeight = 16;

/// 年视图那一块的宽度（53 周 × 17 + 星期列）。对话框的宽度就是它。
const double _yearGridWidth = 53 * _yearPitch + _yearDayLabelWidth;

/// 月视图格子。54px：日历这一侧本来就是"选日期"用的，
/// 格子大到鼠标不容易点错，里面的日号也能用 16px 的字。
const double _monthCell = 54;
const double _monthGap = 6;
const double _monthGridWidth = 7 * (_monthCell + _monthGap);

/// 星期表头（一二三四五六日）那一条的高度，**给死**。
///
/// 给死是为了让 [_monthGridHeight] 是个能算出来的常数：靠文字自身高度的话，
/// 字号一改这个常数就不准了——第一版就漏算了它，结果框体溢出 22px。
const double _weekdayHeaderHeight = 20;
const double _weekdayHeaderGap = 8;

/// 月视图格子那一块的总高：表头 + 间距 + 6 行。
const double _monthGridHeight =
    _weekdayHeaderHeight + _weekdayHeaderGap + 6 * (_monthCell + _monthGap);

/// **两个尺度共用的格子区高度**。
///
/// 这是"年视图和月视图窗口一样大"的实现方式：月视图的格子正好填满它，
/// 年视图那一片只有 7 × 17 = 119 高，剩下的高度给下面的"当日详细"。
/// 高度固定住，切换 `月 | 年` 时对话框就不会跳。
const double _gridAreaHeight = _monthGridHeight;

/// 月视图右侧那一栏的宽度范围。
///
/// 当日简要放右边，而不是像年视图那样放在底下：年视图的格子铺满整个宽度，
/// 没有右边可用；月视图的格子只占一部分，右边本来就空着——把简要搬过去，
/// 省下来的竖向空间给格子。上限给得宽，是因为**正文尽量多显示**比留白有用。
const double _sidePanelMinWidth = 200;
const double _sidePanelMaxWidth = 480;

class _CalendarDialog extends StatefulWidget {
  const _CalendarDialog({
    required this.controller,
    required this.initialScale,
  });

  final DiaryController controller;
  final CalendarScale initialScale;

  @override
  State<_CalendarDialog> createState() => _CalendarDialogState();
}

class _CalendarDialogState extends State<_CalendarDialog> {
  late CalendarScale _scale = widget.initialScale;

  /// 月视图用年+月；年视图只用年。
  late int _year = widget.controller.selectedDate.year;
  late int _month = widget.controller.selectedDate.month;

  DayWriting? _hovered;

  /// 年份下拉里能选哪些年。
  ///
  /// 沿用被替换掉的 `showDatePicker` 那个范围（1970 到今年 +1），
  /// 这样合并不改变"能选到哪一天"这件事。
  List<int> get _years {
    final current = DateTime.now().year;
    final years = <int>[for (var year = current + 1; year >= 1970; year--) year];
    // 万一有超出范围的旧数据，也要能翻到
    for (final entry in widget.controller.entries) {
      if (!years.contains(entry.date.year)) years.insert(0, entry.date.year);
    }
    return years;
  }

  Future<void> _jumpTo(DateTime date) async {
    Navigator.of(context).pop();
    await widget.controller.openDate(date);
  }

  /// 上一步/下一步：月视图按月走（跨年自动），年视图按年走。
  void _step(int delta) {
    setState(() {
      _hovered = null;
      if (_scale == CalendarScale.year) {
        _year += delta;
        return;
      }
      var month = _month + delta;
      var year = _year;
      if (month < 1) {
        month = 12;
        year -= 1;
      } else if (month > 12) {
        month = 1;
        year += 1;
      }
      _month = month;
      _year = year;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 对话框的宽度 = 年视图那一块的宽度；窗口不够时按窗口夹，
    // 再不够就让格子横向滚动（两个视图都滚），而不是把对话框撑出屏幕。
    final available = MediaQuery.sizeOf(context).width - 160;
    final contentWidth = math.min(_yearGridWidth, math.max(available, 320.0));

    // 月视图右边那一栏：尽量宽（正文要多显示），窗口不够时先压它。
    final sidePanelWidth = (contentWidth - _monthGridWidth - 16)
        .clamp(_sidePanelMinWidth, _sidePanelMaxWidth)
        .toDouble();

    return AlertDialog(
      title: Row(
        children: <Widget>[
          const Text('写作日历'),
          const Spacer(),
          SegmentedButton<CalendarScale>(
            segments: const <ButtonSegment<CalendarScale>>[
              ButtonSegment<CalendarScale>(
                value: CalendarScale.month,
                label: Text('月'),
              ),
              ButtonSegment<CalendarScale>(
                value: CalendarScale.year,
                label: Text('年'),
              ),
            ],
            selected: <CalendarScale>{_scale},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (selection) => setState(() {
              _scale = selection.first;
              _hovered = null;
            }),
          ),
        ],
      ),
      content: SizedBox(
        width: contentWidth,
        // 纵向也要能滚：月视图（6 行格子 + 图例 + 详情）在 620px 高的窗口里放不下，
        // 会直接溢出。**这是被测试当场抓到的**——原来那个"窄窗口不撑坏"的测试
        // 只走年视图（格子只有 91px 高），没暴露。
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildNav(theme),
              const SizedBox(height: 10),
              _buildSummary(theme),
              const SizedBox(height: 10),
              // **两个尺度共用同一块固定高度的区域**，所以切换时对话框不跳：
              // 月视图用"格子 + 右侧那一栏"填满它；年视图的格子只有 7×17 高，
              // 剩下的高度给下面的当日详细。
              SizedBox(
                height: _gridAreaHeight,
                child: _scale == CalendarScale.year
                    ? _buildYearSection(theme)
                    : _buildMonthSection(theme, sidePanelWidth),
              ),
              const SizedBox(height: 10),
              _buildLegend(theme),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 顶部：翻页 + 年份
  // ---------------------------------------------------------------------------

  Widget _buildNav(ThemeData theme) {
    final years = _years;

    return Row(
      children: <Widget>[
        IconButton(
          tooltip: _scale == CalendarScale.year ? '上一年' : '上个月',
          visualDensity: VisualDensity.compact,
          onPressed: () => _step(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        DropdownButton<int>(
          value: years.contains(_year) ? _year : years.first,
          underline: const SizedBox.shrink(),
          style: theme.textTheme.bodyMedium,
          items: <DropdownMenuItem<int>>[
            for (final year in years)
              DropdownMenuItem<int>(
                value: year,
                child: Text('$year 年'),
              ),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _year = value;
              _hovered = null;
            });
          },
        ),
        IconButton(
          tooltip: _scale == CalendarScale.year ? '下一年' : '下个月',
          visualDensity: VisualDensity.compact,
          onPressed: () => _step(1),
          icon: const Icon(Icons.chevron_right),
        ),
        const Spacer(),
        TextButton(
          onPressed: () => _jumpTo(DateTime.now()),
          child: const Text('今天'),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 汇总
  // ---------------------------------------------------------------------------

  Widget _buildSummary(ThemeData theme) {
    final style = theme.textTheme.bodyMedium;

    if (_scale == CalendarScale.year) {
      final heatmap = YearHeatmap.build(
        year: _year,
        entries: widget.controller.entries,
      );
      if (heatmap.isEmpty) {
        return Text('$_year 年还没有写过日记。',
            style: style?.copyWith(color: theme.colorScheme.outline));
      }
      return Text(
        '$_year 年 · 写了 ${heatmap.writtenDays} 天 · 共 ${heatmap.totalCharacters} 字'
        ' · 最长连续 ${heatmap.longestStreak} 天',
        style: style,
      );
    }

    final grid = MonthGrid.build(
      year: _year,
      month: _month,
      entries: widget.controller.entries,
    );
    if (grid.isEmpty) {
      return Text('$_year 年 $_month 月还没有写过日记。',
          style: style?.copyWith(color: theme.colorScheme.outline));
    }
    return Text(
      '$_year 年 $_month 月 · 写了 ${grid.writtenDays} 天 · 共 ${grid.totalCharacters} 字',
      style: style,
    );
  }

  // ---------------------------------------------------------------------------
  // 月视图
  // ---------------------------------------------------------------------------

  /// 月视图那一行：**左边格子、右边当日详细**。
  ///
  /// 为什么月视图和年视图的详细位置不一样：年视图的格子铺满整个宽度（53 周 ×
  /// 17px = 901），右边没有地方放；月视图的格子只有 420 宽，右边本来空着一大片。
  /// 搬过去之后省下的竖向空间就给了格子（34 → 54px）和字（14 → 16px）。
  Widget _buildMonthSection(ThemeData theme, double sidePanelWidth) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 极窄窗口下让格子横向滚动，而不是把对话框撑破
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _buildMonthGrid(theme),
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: sidePanelWidth,
          child: _buildDayDetail(theme),
        ),
      ],
    );
  }

  Widget _buildMonthGrid(ThemeData theme) {
    final grid = MonthGrid.build(
      year: _year,
      month: _month,
      entries: widget.controller.entries,
    );
    final today = dateOnly(DateTime.now());
    final selected = dateOnly(widget.controller.selectedDate);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: _weekdayHeaderHeight,
          child: Row(
            children: <Widget>[
              for (final label in const <String>['一', '二', '三', '四', '五', '六', '日'])
                SizedBox(
                  width: _monthCell + _monthGap,
                  child: Center(
                    child: Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: _weekdayHeaderGap),
        for (final week in grid.weeks)
          Row(
            children: <Widget>[
              for (final day in week)
                Padding(
                  padding: const EdgeInsets.all(_monthGap / 2),
                  child: _buildMonthCell(
                    theme,
                    day,
                    isToday: day != null && isSameDay(day.date, today),
                    isSelected:
                        day != null && isSameDay(day.date, selected),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  /// 当日详细。**两个尺度共用同一块**：月视图放在格子右边，年视图放在格子下面。
  ///
  /// 三条刻意的做法：
  /// - **没悬停时显示"当前打开的那一天"**，不是一句"请把鼠标移上去"。
  ///   后者会让这一大块在默认状态下纯属浪费，而默认状态恰恰是最常见的状态。
  /// - **正文尽量多显示**（`DayWriting.text` 是整篇，不是首行），放不下的部分
  ///   按"这块地方实际能放下几行"截断并加省略号——不是滚动，也不是截成一行。
  ///   能放几行是算出来的，不是写死的：写死会在另一种尺寸下要么留一大片空、
  ///   要么溢出。
  /// - 字比原来的单行简要大一档（12 → 14），这一块现在有 200~360px 高，
  ///   小字在这么大的面上看着发虚。
  Widget _buildDayDetail(ThemeData theme) {
    final hovered = _hovered;
    final day = hovered ?? _writingFor(widget.controller.selectedDate);

    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.6,
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        // ⚠️ 不能用 surfaceContainerHigh：那正好就是 AlertDialog 自己的底色，
        // 画上去等于没画（第一版就是这样，右边看起来是一片空的）。
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(_factsFor(day), style: theme.textTheme.titleSmall),
          if (day.text.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => Text(
                  day.text,
                  style: bodyStyle,
                  maxLines: _linesThatFit(context, constraints, bodyStyle),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ] else
            const Spacer(),
          const SizedBox(height: 10),
          Text(
            hovered == null
                ? '鼠标停在格子上看那一天 · 点一下跳过去'
                : '点一下就跳到这一天',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  /// 把某一天的日记包成格子（没有就是 0 字的那一格）。
  DayWriting _writingFor(DateTime date) {
    final normalized = dateOnly(date);
    for (final entry in widget.controller.entries) {
      if (isSameDay(entry.date, normalized)) {
        return DayWriting.fromEntry(normalized, entry);
      }
    }
    return DayWriting.empty(normalized);
  }

  /// 那一天的事实，一行，用「·」连起来。年视图和月视图共用同一句，
  /// 所以两个尺度说法一致（测试也是按这一句断言的）。
  String _factsFor(DayWriting day) => <String>[
        formatIsoDate(day.date),
        weekdayShort(day.date),
        '${day.characters} 字',
        if (day.mood != null) day.mood!,
        if (day.weather != null) day.weather!,
        if (day.tags.isNotEmpty) day.tags.map((tag) => '#$tag').join(' '),
      ].join(' · ');

  /// 这块地方**实际能放下几行**正文。
  ///
  /// 算出来而不是写死：写死一个行数，换一种窗口尺寸就会要么留一大片空、
  /// 要么直接溢出。用 LayoutBuilder 给的高度除以这一档字体的真实行高，
  /// 字号还要过 `textScaler`（系统放大字体时行高跟着变）。
  int _linesThatFit(
    BuildContext context,
    BoxConstraints constraints,
    TextStyle? style,
  ) {
    if (!constraints.maxHeight.isFinite || constraints.maxHeight <= 0) return 1;
    final fontSize = style?.fontSize ?? 14;
    final lineHeight = MediaQuery.textScalerOf(context).scale(fontSize) *
        (style?.height ?? 1.2);
    if (lineHeight <= 0) return 1;
    // 取整之后 maxLines × 行高 ≤ 可用高度，所以不会溢出；差一点点的时候
    // 宁可早一行加省略号。
    return math.max(1, (constraints.maxHeight / lineHeight).floor());
  }

  Widget _buildMonthCell(
    ThemeData theme,
    DayWriting? day, {
    required bool isToday,
    required bool isSelected,
  }) {
    // 不属于这个月的位置：留白，和"这个月这天没写"必须长得不一样
    if (day == null) {
      return const SizedBox(width: _monthCell, height: _monthCell);
    }

    final level = day.level;
    // 深色格子上数字要能看清：level 3 以上底色已经接近纯主题色
    final numberColor =
        level >= 3 ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    final hovered = _hovered != null && isSameDay(_hovered!.date, day.date);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = day),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _jumpTo(day.date),
        child: Container(
          key: ValueKey<String>('calendar-day-${formatIsoDate(day.date)}'),
          width: _monthCell,
          height: _monthCell,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: levelColor(theme.colorScheme, level),
            borderRadius: BorderRadius.circular(6),
            // 三个标记要能分辨：今天、当前所在那一天、鼠标悬停
            border: Border.all(
              color: isSelected
                  ? theme.colorScheme.primary
                  : isToday
                      ? theme.colorScheme.onSurface
                      : hovered
                          ? theme.colorScheme.outline
                          : Colors.transparent,
              width: isSelected || isToday ? 2 : 1,
            ),
          ),
          child: Text(
            '${day.date.day}',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: numberColor,
              fontWeight: isToday ? FontWeight.w700 : null,
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 年视图
  // ---------------------------------------------------------------------------

  /// 年视图那一块：**格子在上面、当日详细在下面**。
  ///
  /// 一年是 53 列 × 7 行，铺满整个宽度之后只有 7 × 17 = 119 高，
  /// 剩下的高度（[_gridAreaHeight] 减掉这一点）给下面的详细——
  /// 这样年视图和月视图的对话框就是同一个尺寸，切换时不跳。
  Widget _buildYearSection(ThemeData theme) {
    return Column(
      // stretch：下面那张卡要和格子一样铺满整个宽度，不然它只有内容那么宽，
      // 和月视图右边那一栏一比就显得是两块不同的东西
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: _buildYearGrid(theme),
        ),
        const SizedBox(height: 14),
        Expanded(child: _buildDayDetail(theme)),
      ],
    );
  }

  Widget _buildYearGrid(ThemeData theme) {
    final heatmap = YearHeatmap.build(
      year: _year,
      entries: widget.controller.entries,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: _yearDayLabelWidth,
          child: Column(
            children: <Widget>[
              const SizedBox(height: _monthLabelHeight),
              for (final label in const <String>['一', '二', '三', '四', '五', '六', '日'])
                SizedBox(
                  height: _yearPitch,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              height: _monthLabelHeight,
              width: heatmap.columns.length * _yearPitch,
              child: Stack(
                children: <Widget>[
                  for (final entry in heatmap.monthStarts.entries)
                    Positioned(
                      left: entry.value * _yearPitch,
                      top: 0,
                      child: Text(
                        '${entry.key}月',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Row(
              children: <Widget>[
                for (final week in heatmap.columns)
                  Column(
                    children: <Widget>[
                      for (final day in week)
                        Padding(
                          padding: const EdgeInsets.only(
                            right: _yearGap,
                            bottom: _yearGap,
                          ),
                          child: _buildYearCell(theme, day),
                        ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildYearCell(ThemeData theme, DayWriting? day) {
    // 不属于这一年的位置什么都不画。**和"没写过"必须长得不一样**，
    // 否则分不清"那天没写"和"那格不算数"。
    if (day == null) {
      return const SizedBox(width: _yearCell, height: _yearCell);
    }

    final hovering = _hovered != null && isSameDay(_hovered!.date, day.date);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = day),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _jumpTo(day.date),
        child: Container(
          key: ValueKey<String>('calendar-cell-${formatIsoDate(day.date)}'),
          width: _yearCell,
          height: _yearCell,
          decoration: BoxDecoration(
            color: levelColor(theme.colorScheme, day.level),
            borderRadius: BorderRadius.circular(2),
            border: hovering
                ? Border.all(color: theme.colorScheme.onSurface, width: 1)
                : null,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 图例与详情（两个尺度共用）
  // ---------------------------------------------------------------------------

  Widget _buildLegend(ThemeData theme) {
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.outline,
    );

    return Row(
      children: <Widget>[
        Text('少', style: style),
        const SizedBox(width: 6),
        for (var level = 0; level <= 4; level++) ...<Widget>[
          Container(
            width: _yearCell,
            height: _yearCell,
            decoration: BoxDecoration(
              color: levelColor(theme.colorScheme, level),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 3),
        ],
        const SizedBox(width: 3),
        Text('多', style: style),
        const SizedBox(width: 14),
        // 档位写在图例上，别让用户猜"多少字算深色"
        Flexible(
          child: Text(
            '按当天字数分档（100 / 300 / 700）',
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// 档位 → 颜色。
///
/// **只用主题令牌 + 透明度**，一个色值都不硬编码：这样深浅色模式都自动成立
/// （写死一套绿色系的话，深色模式下会糊成一片）。两个尺度共用同一个映射，
/// 所以"多深算多少字"在月和年两个视图里是同一件事。
Color levelColor(ColorScheme scheme, int level) {
  if (level <= 0) return scheme.surfaceContainerHighest;
  const alphas = <double>[0, 0.28, 0.5, 0.72, 1];
  return scheme.primary.withValues(alpha: alphas[level.clamp(0, 4)]);
}
