import 'dart:async';

import 'package:flutter/material.dart';

import '../core/day.dart';
import '../core/diary_codec.dart';
import '../data/diary_store.dart';
import '../state/diary_controller.dart';

/// 一份快照加上它的正文，用于列表展示。
class _HistoryRow {
  const _HistoryRow({
    required this.snapshot,
    required this.preview,
    required this.characters,
  });

  final DiarySnapshot snapshot;
  final String preview;
  final int characters;
}

/// 历史版本面板。
///
/// 关闭时返回一句要给用户看的话（恢复成功了、或者和上一版一样没新增），
/// 由调用方用 SnackBar 显示——和「日记位置」对话框一样的约定。
class HistoryDialog extends StatefulWidget {
  const HistoryDialog({super.key, required this.controller});

  final DiaryController controller;

  @override
  State<HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<HistoryDialog> {
  bool _loading = true;
  String? _error;
  String? _notice;
  List<_HistoryRow> _rows = <_HistoryRow>[];

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
      await widget.controller.refreshSnapshots();
      final date = widget.controller.selectedDate;
      final rows = <_HistoryRow>[];

      for (final snapshot in widget.controller.snapshots) {
        String content;
        try {
          content = await widget.controller.snapshotContent(snapshot);
        } catch (_) {
          // 单份读不动就跳过，不能让整个面板打不开
          continue;
        }
        final entry = DiaryCodec.decode(
          content,
          fallbackDate: date,
          fallbackTimestamp: snapshot.savedAt,
          fallbackDevice: 'history',
        );
        rows.add(_HistoryRow(
          snapshot: snapshot,
          preview: entry.listPreview,
          characters: entry.body.runes.length,
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

  Future<void> _saveVersion() async {
    final saved = await widget.controller.saveVersionNow();
    if (!mounted) return;
    setState(() => _notice = saved
        ? '已经留了一份当前版本。'
        : '当前内容和最新一版完全一样，没有重复留。');
    await _load();
  }

  Future<void> _restore(_HistoryRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复这一版？'),
        content: Text(
          '这一天会变成 ${_clock(row.snapshot.savedAt)} 的样子。\n\n'
          '当前内容**不会丢**：程序会先把它自动留成一份新的历史版本，'
          '你随时可以再恢复回来。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await widget.controller.restoreSnapshot(row.snapshot);
      if (!mounted) return;
      Navigator.of(context).pop('已恢复到 ${_clock(row.snapshot.savedAt)} 的版本。');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '恢复失败：$error');
    }
  }

  static String _clock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}:'
      '${value.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = widget.controller.selectedDate;

    return AlertDialog(
      title: Text('历史版本 · ${formatIsoDate(date)}'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: _saveVersion,
                  icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                  label: const Text('留一份当前版本'),
                ),
                const Spacer(),
                if (_notice != null)
                  Flexible(
                    child: Text(
                      _notice!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
            const Divider(height: 12),
            Expanded(child: _buildBody(theme)),
          ],
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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.history_toggle_off,
                  size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text(
                '这一天还没有历史版本。\n'
                '开始写之后，程序会在你打开它时、以及每隔一段时间自动留一份。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
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
                _clock(row.snapshot.savedAt),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              // Flexible：这一行右边还有「恢复」按钮，原因名最长的
              // 「恢复之前的内容」在窄对话框里会顶出去。
              Flexible(
                child: Text(
                  row.snapshot.reason.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${row.characters} 字',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
          subtitle: Text(
            row.preview.isEmpty ? '（这一天当时还是空的）' : row.preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          trailing: TextButton(
            onPressed: () => _restore(row),
            child: const Text('恢复'),
          ),
          onTap: () => _restore(row),
        );
      },
    );
  }
}
