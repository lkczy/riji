import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/diary_location.dart';
import '../platform/platform.dart' as platform;
import '../state/diary_controller.dart';

/// 「更改日记位置」对话框。
///
/// 这个界面的首要任务不是方便，而是**别让用户以为自己的日记丢了**。
/// 所以：改动前必须实测新位置能不能写、里面已经有什么；
/// 切换后界面变空时必须当场说明"文件没有被删除、它们在哪里"。
///
/// 下面几个探测函数做成可注入的，是为了能在 widget 测试里替换掉：
/// 真实实现会去探测磁盘写入、还可能起 PowerShell 查询磁盘类型，
/// 而在测试的假异步环境里起外部进程会直接挂住。
class DiaryLocationDialog extends StatefulWidget {
  const DiaryLocationDialog({
    super.key,
    required this.controller,
    required this.onSwitch,
    this.inspect = platform.gatherDiaryLocationFacts,
    this.listDrives = platform.listDiaryDriveRoots,
    this.listSubdirectories = platform.listDiarySubdirectories,
  });

  final DiaryController controller;
  final SwitchDiaryRootCallback onSwitch;

  final Future<DiaryLocationFacts> Function({
    required String rawPath,
    required String currentRoot,
    required int currentEntryCount,
  }) inspect;

  final List<String> Function() listDrives;

  final Future<List<String>> Function(String path) listSubdirectories;

  @override
  State<DiaryLocationDialog> createState() => _DiaryLocationDialogState();
}

class _DiaryLocationDialogState extends State<DiaryLocationDialog> {
  final TextEditingController _path = TextEditingController();

  Timer? _debounce;
  DiaryLocationFacts? _facts;
  DiaryLocationAssessment? _assessment;
  bool _inspecting = false;
  bool _copyExisting = false;
  bool _copyTouchedByUser = false;
  bool _busy = false;
  String? _failure;
  List<String> _drives = <String>[];

  String get _currentRoot => widget.controller.locationDescription;

  @override
  void initState() {
    super.initState();
    _drives = widget.listDrives();
    // 预填当前位置，用户多半只是想改最后一段
    _path.text = _currentRoot;
    _path.addListener(_onPathChanged);
    unawaited(_inspect());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _path.removeListener(_onPathChanged);
    _path.dispose();
    super.dispose();
  }

  void _onPathChanged() {
    _debounce?.cancel();
    // 防抖：每敲一个字都去实测磁盘写入太浪费，磁盘类型查询还可能要起进程
    _debounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(_inspect());
    });
  }

  Future<void> _inspect() async {
    final raw = _path.text;
    setState(() {
      _inspecting = true;
      _failure = null;
    });

    final facts = await widget.inspect(
      rawPath: raw,
      currentRoot: _currentRoot,
      currentEntryCount: widget.controller.totalEntries,
    );
    final assessment = assessDiaryLocation(facts);

    if (!mounted) return;
    setState(() {
      _facts = facts;
      _assessment = assessment;
      _inspecting = false;
      // 默认勾选「复制过去」：绝大多数人是想搬走而不是想换个空目录。
      // 但用户一旦自己动过这个勾，就不再替他改。
      if (!_copyTouchedByUser) {
        _copyExisting = assessment.suggestCopy;
      }
    });
  }

  Future<void> _pickFolder() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _FolderPickerDialog(
        initialPath: _facts?.normalizedPath ?? _currentRoot,
        drives: _drives,
        listSubdirectories: widget.listSubdirectories,
      ),
    );
    if (picked != null && mounted) {
      _path.text = picked;
      await _inspect();
    }
  }

  Future<void> _confirm() async {
    final facts = _facts;
    final assessment = _assessment;
    if (facts == null || assessment == null || !assessment.canSwitch) return;

    setState(() {
      _busy = true;
      _failure = null;
    });

    final outcome = await widget.onSwitch(
      facts.normalizedPath,
      copyExisting: _copyExisting && assessment.suggestCopy,
    );

    if (!mounted) return;

    if (!outcome.ok) {
      setState(() {
        _busy = false;
        _failure = outcome.message;
      });
      return;
    }

    Navigator.of(context).pop(outcome.message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final assessment = _assessment;

    return AlertDialog(
      title: const Text('日记保存位置'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _buildCurrentLocation(theme),
              const SizedBox(height: 18),
              Text('新位置', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _path,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        hintText: r'例如 D:\日记',
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickFolder,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('浏览'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildDriveShortcuts(theme),
              const SizedBox(height: 12),
              if (_inspecting)
                Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text('正在检查…', style: theme.textTheme.bodySmall),
                  ],
                )
              else if (assessment != null)
                _buildAssessment(theme, assessment),
              if (assessment != null && assessment.suggestCopy) ...<Widget>[
                const SizedBox(height: 8),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _copyExisting,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                            _copyExisting = value ?? false;
                            _copyTouchedByUser = true;
                          }),
                  title: const Text('把现有日记复制到新位置'),
                  subtitle: Text(
                    '只复制，不移动。原来的文件夹不会做任何改动，'
                    '确认新位置没问题后你可以自己决定要不要删掉它。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
              if (_failure != null) ...<Widget>[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _failure!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
              if (_busy) ...<Widget>[
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '正在切换（复制的话会逐个文件校验）…',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (_busy || !(assessment?.canSwitch ?? false))
              ? null
              : _confirm,
          child: const Text('切换位置'),
        ),
      ],
    );
  }

  Widget _buildCurrentLocation(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('当前位置', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        SelectableText(
          _currentRoot,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '共 ${widget.controller.totalEntries} 篇日记',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }

  Widget _buildDriveShortcuts(ThemeData theme) {
    if (_drives.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      children: <Widget>[
        for (final drive in _drives)
          ActionChip(
            visualDensity: VisualDensity.compact,
            label: Text(drive, style: theme.textTheme.bodySmall),
            onPressed: _busy ? null : () => _path.text = drive,
          ),
      ],
    );
  }

  Widget _buildAssessment(ThemeData theme, DiaryLocationAssessment assessment) {
    // Material 3 的 ColorScheme 没有 "warning" 角色：
    // error 给错误，tertiary 给警告，outline 给中性信息。
    // 仍然是走主题令牌，不硬编码颜色。
    Color colorFor(NoticeSeverity severity) => switch (severity) {
          NoticeSeverity.error => theme.colorScheme.error,
          NoticeSeverity.warning => theme.colorScheme.tertiary,
          NoticeSeverity.info => theme.colorScheme.outline,
        };

    IconData iconFor(NoticeSeverity severity) => switch (severity) {
          NoticeSeverity.error => Icons.error_outline,
          NoticeSeverity.warning => Icons.warning_amber_outlined,
          NoticeSeverity.info => Icons.info_outlined,
        };

    if (assessment.notices.isEmpty) {
      return Text('这个位置看起来没问题。', style: theme.textTheme.bodySmall);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final notice in assessment.notices)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(iconFor(notice.severity), size: 16, color: colorFor(notice.severity)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    notice.message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorFor(notice.severity),
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

/// 极简文件夹选择器。
///
/// 没有用系统原生选择器，因为那需要插件，而插件在 Windows 上要求
/// 开启开发者模式。自己用 dart:io 列目录足够完成这件事，
/// 代价是不如资源管理器好用——所以对话框里也保留了手输路径。
class _FolderPickerDialog extends StatefulWidget {
  const _FolderPickerDialog({
    required this.initialPath,
    required this.drives,
    required this.listSubdirectories,
  });

  final String initialPath;
  final List<String> drives;
  final Future<List<String>> Function(String path) listSubdirectories;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  late String _current;
  List<String> _children = <String>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final normalized = platform.normalizeDiaryPath(widget.initialPath);
    _current = normalized.isEmpty ? (widget.drives.isNotEmpty ? widget.drives.first : '/') : normalized;
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final children = await widget.listSubdirectories(_current);
    if (!mounted) return;
    setState(() {
      _children = children;
      _loading = false;
      if (children.isEmpty) {
        _error = '这个文件夹里没有子文件夹（可能没有权限读取）。可以直接选择它。';
      }
    });
  }

  void _goTo(String path) {
    _current = path;
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parent = platform.diaryParentDirectory(_current);

    return AlertDialog(
      title: const Text('选择文件夹'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SelectableText(
              _current,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: <Widget>[
                if (parent != null)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.arrow_upward, size: 14),
                    label: Text('上一层', style: theme.textTheme.bodySmall),
                    onPressed: () => _goTo(parent),
                  ),
                for (final drive in widget.drives)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(drive, style: theme.textTheme.bodySmall),
                    onPressed: () => _goTo(drive),
                  ),
              ],
            ),
            const Divider(height: 20),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: <Widget>[
                        for (final child in _children)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.folder_outlined, size: 18),
                            title: Text(
                              p.basename(child),
                              style: theme.textTheme.bodyMedium,
                            ),
                            onTap: () => _goTo(child),
                          ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              _error!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
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
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_current),
          child: const Text('选择这个文件夹'),
        ),
      ],
    );
  }
}
