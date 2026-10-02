import 'package:flutter/material.dart';

import '../core/day.dart';
import '../state/diary_controller.dart';

/// 启动提示。
///
/// 原则：只在该弹的时候弹。每次都弹的提示等于没有提示——
/// 用户会学会无脑点掉，真正的那次内容丢失反而被忽略。
/// 所以草稿提示仅在「草稿与已保存内容确实不同」时出现（判定在控制器里）。
Future<void> showStartupPrompts(
  BuildContext context,
  DiaryController controller,
) async {
  if (controller.recoverableDrafts.isNotEmpty) {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DraftRecoveryDialog(controller: controller),
    );
  }
  if (controller.conflicts.isNotEmpty && context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (_) => _ConflictsDialog(controller: controller),
    );
  }
}

/// 单独打开冲突清单。左侧栏的冲突徽标点进来用。
Future<void> showConflictsDialog(
  BuildContext context,
  DiaryController controller,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ConflictsDialog(controller: controller),
  );
}

class _DraftRecoveryDialog extends StatefulWidget {
  const _DraftRecoveryDialog({required this.controller});

  final DiaryController controller;

  @override
  State<_DraftRecoveryDialog> createState() => _DraftRecoveryDialogState();
}

class _DraftRecoveryDialogState extends State<_DraftRecoveryDialog> {
  final Map<DateTime, String> _previews = <DateTime, String>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPreviews();
  }

  Future<void> _loadPreviews() async {
    for (final date in widget.controller.recoverableDrafts) {
      final draft = await widget.controller.store.readDraft(date);
      if (draft != null) _previews[date] = draft;
    }
    if (mounted) setState(() => _loading = false);
  }

  static String _preview(String? text) {
    if (text == null || text.trim().isEmpty) return '（草稿是空的）';
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 60 ? flat : '${flat.substring(0, 60)}…';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final dates = widget.controller.recoverableDrafts;

        return AlertDialog(
          title: const Text('发现未保存的草稿'),
          content: SizedBox(
            width: 560,
            child: dates.isEmpty
                ? const Text('草稿已全部处理完。')
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        '上次退出时还有内容没写进日记文件。草稿比正式文件新，'
                        '但要不要恢复得你来决定——程序不会替你覆盖任何东西。',
                      ),
                      const SizedBox(height: 12),
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else
                        Flexible(
                          child: ListView(
                            shrinkWrap: true,
                            children: <Widget>[
                              for (final date in dates)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(formatIsoDate(date)),
                                  subtitle: Text(
                                    _preview(_previews[date]),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      TextButton(
                                        onPressed: () =>
                                            widget.controller.discardDraft(date),
                                        child: const Text('丢弃'),
                                      ),
                                      const SizedBox(width: 8),
                                      FilledButton(
                                        onPressed: () =>
                                            widget.controller.recoverDraft(date),
                                        child: const Text('恢复'),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(dates.isEmpty ? '完成' : '稍后处理'),
            ),
          ],
        );
      },
    );
  }
}

class _ConflictsDialog extends StatelessWidget {
  const _ConflictsDialog({required this.controller});

  final DiaryController controller;

  @override
  Widget build(BuildContext context) {
    final conflicts = controller.conflicts;

    return AlertDialog(
      title: Text('发现 ${conflicts.length} 个同步冲突文件'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '同一天在两台设备上都被改过，同步工具保留了双方的版本。'
              '程序不会自动合并——它无法判断你想留哪句话。请打开文件夹手动处理，'
              '确认内容合并好之后，把冲突文件删掉即可。',
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final conflict in conflicts)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.call_split_outlined),
                      title: Text(formatIsoDate(conflict.date)),
                      subtitle: Text(conflict.fileName),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => controller.revealDiaryFolder(),
          child: const Text('打开日记文件夹'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }
}
