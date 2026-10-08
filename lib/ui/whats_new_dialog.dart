import 'package:flutter/material.dart';

import '../core/release_notes.dart';

/// 「本版更新」。
///
/// 只在**升级之后第一次启动**弹一次：该不该弹的判断在
/// `core/app_version.dart` 的 `shouldAnnounceVersion`，记录在设置里。
///
/// 内容刻意很省——**版本、发布时间、新功能、bug 修复**，就这四项。
/// 内部改动和已知限制留在 `CHANGELOG.md` 里，想看的人自己去看；
/// 把整个 CHANGELOG 摊在启动时，用户只会学会无脑点掉。
///
/// 弹窗里不会出现 Markdown 标记：`**` 和反引号在解析时就去掉了
/// （见 `core/release_notes.dart` 的 `plainTextOf`）。
Future<void> showWhatsNewDialog(BuildContext context, ReleaseNotes notes) {
  return showDialog<void>(
    context: context,
    builder: (_) => _WhatsNewDialog(notes: notes),
  );
}

class _WhatsNewDialog extends StatelessWidget {
  const _WhatsNewDialog({required this.notes});

  final ReleaseNotes notes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = notes.date;

    return AlertDialog(
      title: const Text('本版更新'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 版本和日期挤成一行：这是用户最想先确认的一件事，
              // 而分成两行只会多占一行高度。
              //
              // 刻意用两个独立的 Text 而不是 `Text.rich`：RichText 里的文字
              // 默认的测试查找器找不到（要额外开 findRichText），
              // 为了一行高度换掉可测性不划算。
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: <Widget>[
                  Text(
                    '日迹 ${notes.version}',
                    style: theme.textTheme.titleSmall,
                  ),
                  if (date != null) ...<Widget>[
                    const SizedBox(width: 10),
                    Text(
                      '$date 发布',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 16),
              if (notes.features.isNotEmpty)
                ..._buildSection(theme, '新功能', notes.features),
              // 没有 bug 修复时整节不出现——弹窗里不摆空标题
              if (notes.features.isNotEmpty && notes.fixes.isNotEmpty)
                const SizedBox(height: 16),
              if (notes.fixes.isNotEmpty)
                ..._buildSection(theme, '修复', notes.fixes),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        // 不带「…」：它不打开下一层（详细说明里那条约定）
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }

  List<Widget> _buildSection(
    ThemeData theme,
    String title,
    List<String> items,
  ) {
    return <Widget>[
      Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
      const SizedBox(height: 6),
      for (final item in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '·',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(width: 8),
              // 条目允许折行（最多三行）：CHANGELOG 里的句子偶尔会偏长，
              // 截断成一句话的半截比多占一行难看得多。
              Expanded(
                child: Text(
                  item,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
    ];
  }
}
