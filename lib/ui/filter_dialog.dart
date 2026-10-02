import 'package:flutter/material.dart';

import '../core/diary_filter.dart';
import '../state/diary_controller.dart';

/// 筛选对话框：标签 / 心情 / 天气 三个维度各选一个值。
///
/// 用对话框而不是下拉菜单：三个维度都塞进菜单就会变成菜单套子菜单，
/// 改一个条件要点三四次。对话框一次看全，点一下就改。
///
/// 交互是「草稿 + 应用」而不是即时生效：即时生效的话，取消就得回滚，
/// 而回滚一个已经作用到列表上的条件很容易出错。
class DiaryFilterDialog extends StatefulWidget {
  const DiaryFilterDialog({super.key, required this.controller});

  final DiaryController controller;

  @override
  State<DiaryFilterDialog> createState() => _DiaryFilterDialogState();
}

class _DiaryFilterDialogState extends State<DiaryFilterDialog> {
  late DiaryFilter _draft = widget.controller.filter;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return AlertDialog(
      title: const Text('筛选日记'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _buildGroup(
                context,
                label: '标签',
                icon: Icons.local_offer_outlined,
                values: controller.allTags,
                selected: _draft.tag,
                onPick: (value) => setState(() => _draft = _draft.withTag(value)),
              ),
              _buildGroup(
                context,
                label: '心情',
                icon: Icons.mood,
                values: controller.allMoods,
                selected: _draft.mood,
                onPick: (value) => setState(() => _draft = _draft.withMood(value)),
              ),
              _buildGroup(
                context,
                label: '天气',
                icon: Icons.wb_sunny_outlined,
                values: controller.allWeathers,
                selected: _draft.weather,
                onPick: (value) =>
                    setState(() => _draft = _draft.withWeather(value)),
              ),
              const Divider(height: 8),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _draft.isActive
                      ? '筛选条件：${_draft.describe()}'
                      : '没有设置筛选条件，显示全部日记。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => setState(() => _draft = DiaryFilter.none),
          child: const Text('清除'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            controller.setFilter(_draft);
            Navigator.of(context).pop();
          },
          child: const Text('应用'),
        ),
      ],
    );
  }

  Widget _buildGroup(
    BuildContext context, {
    required String label,
    required IconData icon,
    required List<String> values,
    required String? selected,
    required ValueChanged<String?> onPick,
  }) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 16, color: theme.colorScheme.outline),
              const SizedBox(width: 6),
              Text(label, style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 6),
          if (values.isEmpty)
            Text(
              '还没有用过',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                ChoiceChip(
                  label: const Text('全部'),
                  selected: selected == null,
                  onSelected: (_) => onPick(null),
                  visualDensity: VisualDensity.compact,
                  labelStyle: theme.textTheme.bodySmall,
                ),
                for (final value in values)
                  ChoiceChip(
                    label: Text(value),
                    selected: selected == value,
                    // 再点一次已选中的值 = 取消这一维度
                    onSelected: (_) => onPick(selected == value ? null : value),
                    visualDensity: VisualDensity.compact,
                    labelStyle: theme.textTheme.bodySmall,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
