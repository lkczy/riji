import 'dart:async';

import 'package:flutter/material.dart';

import '../core/day.dart';
import '../core/diary_codec.dart';
import '../data/diary_store.dart';
import '../state/diary_controller.dart';

/// 回收站里的一条加上正文摘要。
class _TrashRow {
  const _TrashRow({
    required this.item,
    required this.preview,
    required this.characters,
  });

  final TrashedEntry item;
  final String preview;
  final int characters;
}

/// 回收站。
///
/// 删除是**软删除**（文件移进 `.trash`，字节都在），所以这里能看、能恢复。
/// 只有「永久删除」才真的抹字节，所以它要二次确认。
///
/// 关闭时返回一句要给用户看的话，由调用方用 SnackBar 显示。
class TrashDialog extends StatefulWidget {
  const TrashDialog({super.key, required this.controller});

  final DiaryController controller;

  @override
  State<TrashDialog> createState() => _TrashDialogState();
}

class _TrashDialogState extends State<TrashDialog> {
  bool _loading = true;
  String? _error;
  String? _pendingMessage;
  List<_TrashRow> _rows = <_TrashRow>[];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final items = await widget.controller.listTrash();
      final rows = <_TrashRow>[];
      for (final item in items) {
        var preview = '';
        var characters = 0;
        try {
          final content = await widget.controller.readTrashedContent(item);
          final entry = DiaryCodec.decode(
            content,
            fallbackDate: item.date,
            fallbackTimestamp: item.deletedAt ?? item.date,
            fallbackDevice: 'trash',
          );
          preview = entry.listPreview;
          characters = entry.body.runes.length;
        } catch (_) {
          // 单条读不动不能连累整个列表
        }
        rows.add(_TrashRow(
          item: item,
          preview: preview,
          characters: characters,
        ));
      }

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _restore(_TrashRow row) async {
    try {
      final outcome = await widget.controller.restoreFromTrash(row.item);
      if (!mounted) return;

      if (outcome.hadConflict) {
        // 那一天已经有内容了。绝不能覆盖，所以回收站里这份被另存了。
        _pendingMessage = '这一天已经有内容了，所以没有覆盖它：\n'
            '回收站里的版本被另存到了\n${outcome.conflictPath}';
        await _load();
        return;
      }

      _pendingMessage = '已恢复 ${formatIsoDate(row.item.date)} 的日记。';
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '恢复失败：$error');
    }
  }

  Future<void> _purge(_TrashRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('永久删除？'),
        content: Text(
          '${formatIsoDate(row.item.date)} 的这一份会被真正抹掉，'
          '**无法恢复**。\n\n'
          '如果要保留，请改用「恢复」。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await widget.controller.purgeTrashEntry(row.item);
      if (!mounted) return;
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '删除失败：$error');
    }
  }

  static String _stamp(DateTime? value) {
    if (value == null) return '';
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')} '
        '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('回收站'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '删除是软删除：文件被移到日记目录下的 .trash 里，内容一个字节都没少。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            if (_pendingMessage != null) ...<Widget>[
              const SizedBox(height: 10),
              // 恢复完必须当场给出反馈：那一行会从列表里消失，
              // 但不说明它去哪了，用户会以为是被删掉了。
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _pendingMessage!,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            const Divider(height: 16),
            Expanded(child: _buildBody(theme)),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(_pendingMessage),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.error),
        ),
      );
    }
    if (_rows.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.delete_outline,
                size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              '回收站是空的。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      itemCount: _rows.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final row = _rows[index];
        return ListTile(
          dense: true,
          title: Row(
            children: <Widget>[
              Text(
                formatIsoDate(row.item.date),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              // 必须 Flexible + 省略号：这一行右边还有两个操作按钮，
              // 日期加删除时间在窄对话框里放不下。
              Flexible(
                child: Text(
                  row.item.deletedAt == null
                      ? ''
                      : '删于 ${_stamp(row.item.deletedAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            ],
          ),
          subtitle: Text(
            row.preview.isEmpty
                ? '（空）'
                : '${row.preview}'
                    '${row.characters > 0 ? '　·　${row.characters} 字' : ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextButton(
                onPressed: () => _restore(row),
                child: const Text('恢复'),
              ),
              IconButton(
                tooltip: '永久删除',
                onPressed: () => _purge(row),
                icon: Icon(Icons.delete_forever,
                    size: 18, color: theme.colorScheme.error),
              ),
            ],
          ),
        );
      },
    );
  }
}
