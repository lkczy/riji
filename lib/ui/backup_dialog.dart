import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/backup.dart';
import '../core/day.dart';
import '../platform/platform.dart' as platform;
import '../state/diary_controller.dart';
import '../state/settings_controller.dart';

/// 打开备份对话框。
Future<void> showBackupDialog(
  BuildContext context, {
  required SettingsController settings,
  required DiaryController controller,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => BackupDialog(settings: settings, controller: controller),
  );
}

/// 备份对话框：状态、立即备份、设置位置、恢复。
///
/// 设计取向：**每一件做不到的事都要说清为什么**。没设位置时「立即备份」
/// 是禁用的，旁边写着原因；同盘备份是允许的，但明确告诉用户它挡不住盘坏。
/// 这个项目里最不能接受的就是让用户以为安全了。
class BackupDialog extends StatefulWidget {
  const BackupDialog({
    super.key,
    required this.settings,
    required this.controller,
  });

  final SettingsController settings;
  final DiaryController controller;

  @override
  State<BackupDialog> createState() => _BackupDialogState();
}

class _BackupDialogState extends State<BackupDialog> {
  final TextEditingController _label = TextEditingController();

  bool _busy = false;
  bool _loadingCounts = true;
  int _autoCount = 0;
  int _manualCount = 0;
  String? _message;
  String? _error;

  /// 日记根目录的真实路径。桌面端就是磁盘路径，预览模式下不是——
  /// 但预览模式的 `supportsBackup` 是 false，入口根本不会出现。
  String get _diaryRoot => widget.controller.locationDescription;

  @override
  void initState() {
    super.initState();
    unawaitedRefresh();
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> unawaitedRefresh() async {
    final root = widget.settings.backupRoot;
    if (root == null) {
      if (mounted) setState(() => _loadingCounts = false);
      return;
    }
    var auto = 0;
    var manual = 0;
    try {
      auto = (await platform.listBackupSnapshots(
        p.join(root, SnapshotKind.auto.dirName),
      ))
          .length;
      manual = (await platform.listBackupSnapshots(
        p.join(root, SnapshotKind.manual.dirName),
      ))
          .length;
    } catch (_) {
      // 数不出来不影响用，下面显示成「—」即可
      auto = -1;
    }
    if (!mounted) return;
    setState(() {
      _autoCount = auto;
      _manualCount = manual;
      _loadingCounts = false;
    });
  }

  // ---------------------------------------------------------------------------

  Future<void> _backupNow() async {
    final root = widget.settings.backupRoot;
    if (root == null) return;

    setState(() {
      _busy = true;
      _message = null;
      _error = null;
    });

    BackupOutcome outcome;
    try {
      outcome = await platform.createBackupSnapshot(
        diaryRoot: _diaryRoot,
        backupRoot: root,
        kind: SnapshotKind.manual,
        label: _label.text,
      );
    } catch (error) {
      outcome = BackupOutcome(ok: false, message: '备份失败：$error');
    }

    if (!mounted) return;
    if (outcome.ok) {
      await widget.settings.noteBackupSucceeded(DateTime.now());
    } else {
      await widget.settings.noteBackupFailed(outcome.message);
    }
    if (!mounted) return;

    setState(() {
      _busy = false;
      if (outcome.ok) {
        _message = '${outcome.message}\n${outcome.snapshotPath ?? ''}';
        _label.clear();
      } else {
        _error = outcome.message;
      }
    });
    await unawaitedRefresh();
  }

  Future<void> _editBackupRoot() async {
    final controller = TextEditingController(
      text: widget.settings.backupRoot ?? '',
    );
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _BackupRootDialog(
        controller: controller,
        diaryRoot: _diaryRoot,
        initial: widget.settings.backupRoot,
      ),
    );
    controller.dispose();
    if (result == null) return;

    await widget.settings.setBackupRoot(result);
    if (!mounted) return;
    setState(() {
      _message = result.isEmpty ? '已取消备份位置。' : '备份位置已设为：\n$result';
      _error = null;
    });
    await unawaitedRefresh();
  }

  Future<void> _restore() async {
    final root = widget.settings.backupRoot;
    if (root == null) return;

    setState(() {
      _busy = true;
      _message = null;
      _error = null;
    });

    List<_SnapshotChoice> choices = <_SnapshotChoice>[];
    try {
      for (final kind in SnapshotKind.values) {
        final dir = p.join(root, kind.dirName);
        for (final name in await platform.listBackupSnapshots(dir)) {
          final parsed = SnapshotName.parse(name);
          choices.add(_SnapshotChoice(
            kind: kind,
            name: name,
            path: p.join(dir, name),
            at: parsed?.at,
            label: parsed?.label,
          ));
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '列出备份失败：$error';
        });
      }
      return;
    }

    if (!mounted) return;
    if (choices.isEmpty) {
      setState(() {
        _busy = false;
        _error = '这个位置里还没找到任何备份。';
      });
      return;
    }

    // 时间倒序：最近的备份排在最前面，这是绝大多数时候要选的那一份
    choices.sort((a, b) {
      final left = a.at ?? DateTime(1900);
      final right = b.at ?? DateTime(1900);
      return right.compareTo(left);
    });

    setState(() => _busy = false);
    final picked = await showDialog<_SnapshotChoice>(
      context: context,
      builder: (_) => _RestorePickerDialog(choices: choices),
    );
    if (picked == null || !mounted) return;

    final parent = platform.diaryParentDirectory(_diaryRoot);
    if (parent == null) {
      setState(() => _error = '取不到日记目录的上级目录，无法确定恢复到哪儿。');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    BackupOutcome outcome;
    try {
      outcome = await platform.restoreBackupSnapshot(
        snapshotDir: picked.path,
        targetParent: parent,
      );
    } catch (error) {
      outcome = BackupOutcome(ok: false, message: '恢复失败：$error');
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      if (outcome.ok) {
        _message = '${outcome.message}\n\n'
            '原来的日记目录一个字都没动。想让程序改用恢复出来的那份，'
            '走「更多 → 日记存储位置」。';
        _restoredPath = outcome.snapshotPath;
      } else {
        _error = outcome.message;
      }
    });
  }

  String? _restoredPath;

  Future<void> _openBackupFolder() async {
    final root = widget.settings.backupRoot;
    if (root == null) return;
    try {
      await platform.revealInFileManager(root);
    } catch (error) {
      if (mounted) setState(() => _error = '打开文件夹失败：$error');
    }
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final root = widget.settings.backupRoot;
    final configured = root != null;
    final lastError = widget.settings.lastBackupError;

    return AlertDialog(
      title: const Text('备份'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 上次失败要**显眼**：它多半发生在关程序的时候，那时候弹不出提示。
              // 只在这次会话里显示是不够的，所以这个值存在设置文件里。
              if (lastError != null) _buildErrorBox(theme, '上次备份失败：$lastError'),
              if (_error != null) _buildErrorBox(theme, _error!),
              if (_message != null) _buildMessageBox(theme, _message!),

              _row(theme, Icons.history, '上次备份',
                  _describeLastBackup(widget.settings.lastBackupAt)),
              const SizedBox(height: 8),
              _row(
                theme,
                Icons.folder_open,
                '目标位置',
                configured
                    ? root
                    : '还没设置 —— 不设置就没法备份，因为日记是唯一一份',
              ),
              const SizedBox(height: 8),
              _row(
                theme,
                Icons.inventory_2_outlined,
                '已有备份',
                !configured
                    ? '—'
                    : _loadingCounts
                        ? '正在数…'
                        : _autoCount < 0
                            ? '读不出来'
                            : '自动 $_autoCount 份 · 手动 $_manualCount 份',
              ),

              const SizedBox(height: 16),
              TextField(
                controller: _label,
                enabled: configured && !_busy,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: '这一份的说明（可留空）',
                  helperText: '比如「改主题之前」。会写进备份的文件名和清单里。',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 4),
              if (!configured)
                Text(
                  '先设置备份位置，才能开始备份。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),

              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton.icon(
                    // 禁用而不是隐藏：用户需要看到"这个功能存在，但还差一步"
                    onPressed: configured && !_busy ? _backupNow : null,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('立即备份'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _editBackupRoot,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: Text(configured ? '更改备份位置…' : '设置备份位置…'),
                  ),
                  TextButton.icon(
                    onPressed: configured && !_busy ? _restore : null,
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('从备份恢复…'),
                  ),
                  if (configured)
                    TextButton.icon(
                      onPressed: _busy ? null : _openBackupFolder,
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('打开备份文件夹'),
                    ),
                  if (_restoredPath != null)
                    TextButton.icon(
                      onPressed: () =>
                          platform.revealInFileManager(_restoredPath!),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('打开恢复出来的文件夹'),
                    ),
                ],
              ),

              const SizedBox(height: 12),
              Text(
                '备份只复制、从不删改日记。自动备份在你关闭程序时做，'
                '一天至多一份，只保留最近 $kAutoSnapshotLimit 份；'
                '手动做的那些永远不会被程序删掉。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
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

  Widget _row(ThemeData theme, IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: theme.colorScheme.outline),
        const SizedBox(width: 10),
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }

  Widget _buildErrorBox(ThemeData theme, String text) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline,
              size: 18, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          if (text.startsWith('上次备份失败'))
            TextButton(
              onPressed: () async {
                await widget.settings.dismissBackupError();
                if (mounted) setState(() {});
              },
              child: const Text('知道了'),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageBox(ThemeData theme, String text) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.check_circle_outline,
              size: 18, color: theme.colorScheme.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatMoment(DateTime at) =>
    '${formatIsoDate(at)} ${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

String _describeLastBackup(DateTime? at) {
  if (at == null) return '从来没有备份过';
  final days = DateTime.now().difference(at).inDays;
  if (days <= 0) return '今天（${_formatMoment(at)}）';
  if (days == 1) return '昨天（${_formatMoment(at)}）';
  return '$days 天前（${_formatMoment(at)}）';
}

/// 设置备份位置。
///
/// 刻意只做**文本框输入/粘贴**，不集成「更改日记位置」那套驱动器浏览——
/// 那套界面是为了"在不知道盘符的情况下选路径"，而备份位置通常是你已经
/// 知道的一个目录（移动硬盘、网盘同步目录）。复杂界面换不来对应的价值。
class _BackupRootDialog extends StatefulWidget {
  const _BackupRootDialog({
    required this.controller,
    required this.diaryRoot,
    required this.initial,
  });

  final TextEditingController controller;
  final String diaryRoot;
  final String? initial;

  @override
  State<_BackupRootDialog> createState() => _BackupRootDialogState();
}

class _BackupRootDialogState extends State<_BackupRootDialog> {
  String? _blocking;
  String? _warning;

  void _validate(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _blocking = null;
        _warning = null;
      });
      return;
    }
    final check = checkBackupTarget(
      diaryRoot: widget.diaryRoot,
      backupRoot: trimmed,
    );
    setState(() {
      _blocking = check.nested
          ? '这个位置和日记目录互相包含，不能用来备份。\n'
              '技术原因：备份目录在日记目录里会递归复制（下次备份把这次的一起拷进去），'
              '而且会被 Syncthing 同步到手机；反过来则会让每一份备份把上一份再拷一遍。'
          : null;
      _warning = check.nested
          ? null
          : check.sameVolume
              ? '注意：这个位置和日记在**同一个盘**上。'
                  '它能防住误删误改，但**挡不住这块盘坏掉**。\n'
                  '（另外如实说明：两个盘符也可能是同一块物理盘，这里判断不了。）\n'
                  '真正防盘坏的是你定期把备份传到云盘那一步。'
              : null;
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) _validate(widget.initial!);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('备份位置'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('填一个目录的完整路径。备份会在这个目录下建「自动」和「手动」两个文件夹。'),
            const SizedBox(height: 12),
            TextField(
              controller: widget.controller,
              autofocus: true,
              onChanged: _validate,
              decoration: const InputDecoration(
                hintText: r'例如 E:\日记备份',
                border: OutlineInputBorder(),
              ),
            ),
            if (_blocking != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _blocking!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            if (_warning != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _warning!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onTertiaryContainer),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('不用备份'),
        ),
        FilledButton(
          onPressed: _blocking != null
              ? null
              : () => Navigator.of(context).pop(widget.controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _SnapshotChoice {
  const _SnapshotChoice({
    required this.kind,
    required this.name,
    required this.path,
    required this.at,
    required this.label,
  });

  final SnapshotKind kind;
  final String name;
  final String path;
  final DateTime? at;
  final String? label;
}

/// 选一份备份来恢复。
///
/// 刻意**不显示任何"确认覆盖"之类的话**——恢复是写到新目录的，
/// 不存在覆盖。说反了会让用户不敢用。
class _RestorePickerDialog extends StatelessWidget {
  const _RestorePickerDialog({required this.choices});

  final List<_SnapshotChoice> choices;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('从备份恢复'),
      content: SizedBox(
        width: 520,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '选一份备份。它会恢复到一个**新文件夹**里，正在用的日记目录不会被动。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: choices.length,
                itemBuilder: (context, index) {
                  final choice = choices[index];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      choice.kind == SnapshotKind.auto
                          ? Icons.sync
                          : Icons.bookmark_outline,
                      size: 18,
                    ),
                    title: Text(
                      choice.label ?? choice.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${choice.kind.label} · ${choice.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(context).pop(choice),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
