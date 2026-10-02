import 'package:flutter/material.dart';

import '../core/day.dart';
import '../core/huangli.dart';

/// 悬浮显示的黄历卡片。
///
/// 是**只读**的：用来"瞄一眼"，不承载任何操作。所以调用方会把它包在
/// `IgnorePointer` 里，它不会挡住底下的点击。
///
/// 内容刻意分成两段，因为这两段的可信度完全不同：
///   * 干支、冲煞 —— 可验证（两个独立实现 100% 一致）
///   * 宜、忌 —— **不可验证**（同两个实现完全一致的日子是 0%），是传统历注
/// 所以宜忌那一段必须带出处说明，不能和干支混在一起显示得像同一类事实。
class HuangliCard extends StatelessWidget {
  const HuangliCard({
    super.key,
    required this.day,
    required this.maxHeight,
  });

  final HuangliDay day;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      color: theme.colorScheme.surfaceContainerHighest,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 344, maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '${formatIsoDate(day.date)} ${weekdayShort(day.date)}',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 6),
              Text(
                day.ganZhiSummary,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                day.chongShaSummary,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.tertiary),
              ),
              const Divider(height: 20),
              _termRow(theme, '宜', day.yi, theme.colorScheme.primary),
              const SizedBox(height: 10),
              _termRow(theme, '忌', day.ji, theme.colorScheme.error),
              const Divider(height: 20),
              Text(
                '宜忌是传统历注，依据通书规则，各家版本并不一致——'
                '仅供参考，不是事实。干支、冲煞为历法推算。',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _termRow(
    ThemeData theme,
    String label,
    List<String> terms,
    Color color,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 24,
          child: Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: terms.isEmpty
              ? Text(
                  '—',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                )
              : Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final term in terms)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Text(
                            term,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: color),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
