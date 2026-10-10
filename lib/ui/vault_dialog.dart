import 'dart:async';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../core/vault_crypto.dart';
import '../core/vault_file.dart';
import '../state/diary_controller.dart';
import '../state/settings_controller.dart';
import '../state/vault_service.dart';

/// 打开「日记加密」。
///
/// 这里只管**保险库级别**的事：设口令、解锁、锁定、关闭加密。
/// 「锁上这一天」「锁上这一段」在编辑器的「⋮」菜单里，因为它们要知道光标在哪。
Future<void> showVaultDialog(
  BuildContext context, {
  required VaultService vault,
  required DiaryController controller,
  SettingsController? settings,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => VaultDialog(
      vault: vault,
      controller: controller,
      // 少了这一行，"程序锁"那一段永远不出现——而且 analyze 抓不到：
      // 用不到的可选参数完全合法，只有界面测试能抓到。
      settings: settings,
    ),
  );
}

class VaultDialog extends StatefulWidget {
  const VaultDialog({
    super.key,
    required this.vault,
    required this.controller,
    this.settings,
  });

  final VaultService vault;

  /// 关闭加密要经过控制器：它才知道有哪几天是锁着的，也才能**先解开再删**。
  final DiaryController controller;

  /// 程序锁那几项的读写入口。为 null 时不显示那一段（测试里常常不需要）。
  final SettingsController? settings;

  @override
  State<VaultDialog> createState() => _VaultDialogState();
}

class _VaultDialogState extends State<VaultDialog> {
  final TextEditingController _passphrase = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final TextEditingController _secret = TextEditingController();

  bool _busy = false;
  bool _useRecoveryCode = false;

  /// 建库之后显示的恢复码（只在这里出现一次）。
  String? _recoveryCode;
  bool _recoveryCopied = false;

  String? _message;
  bool _messageIsError = false;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    _secret.dispose();
    super.dispose();
  }

  void _say(String text, {bool error = false}) {
    setState(() {
      _message = text;
      _messageIsError = error;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setUp() async {
    final passphrase = _passphrase.text;
    if (passphrase.length < 4) {
      _say('口令太短了。它要挡住的是"文件被谁拿走"，请至少 4 个字符。', error: true);
      return;
    }
    if (passphrase != _confirm.text) {
      _say('两次输入的口令不一样。', error: true);
      return;
    }
    await _run(() async {
      final result = await widget.vault.setUp(passphrase);
      if (!mounted) return;
      if (!result.ok) {
        _say(result.message, error: true);
        return;
      }
      setState(() {
        _recoveryCode = result.recoveryCode;
        _passphrase.clear();
        _confirm.clear();
        _message = result.message;
        _messageIsError = false;
      });
      if (result.warning != null) {
        // 建库成功了，但"备份要带上 .vault"这件事必须让人看见
        _say(result.warning!, error: false);
      }
    });
  }

  Future<void> _unlock() async {
    final secret = _secret.text;
    if (secret.trim().isEmpty) {
      _say(_useRecoveryCode ? '请把恢复码贴进来。' : '请输入口令。', error: true);
      return;
    }
    await _run(() async {
      final result = await widget.vault.unlock(
        secret,
        isRecoveryCode: _useRecoveryCode,
      );
      if (!mounted) return;
      if (!result.ok) {
        _say(result.message, error: true);
        return;
      }
      _secret.clear();
      _say(result.message);
    });
  }

  Future<void> _disable() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关闭加密？'),
        content: const Text(
          '这会把日记目录里的保险库文件删掉。\n\n'
          '**锁着的内容必须先全部解开**（回到明文存盘），否则它们就永远打不开了。\n\n'
          '做之前建议先备份。',
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
            child: const Text('我明白，关闭'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _run(() async {
      // 走控制器：它会把锁着的天**逐个解开并落盘**，确认磁盘上真的没有
      // 锁着的内容之后才删保险库文件。失败就什么都不删。
      try {
        final message = await widget.controller.disableVaultSafely();
        if (!mounted) return;
        _say(message);
      } on VaultAuthException catch (error) {
        if (mounted) _say('$error', error: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vault = widget.vault;

    return AnimatedBuilder(
      animation: vault,
      builder: (context, _) {
        return AlertDialog(
          title: Row(
            children: <Widget>[
              const Text('日记加密'),
              const SizedBox(width: 10),
              Icon(
                vault.isUnlocked ? Icons.lock_open : Icons.lock_outline,
                size: 18,
                color: vault.isUnlocked
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  ..._statusSection(theme, vault),
                  const Divider(height: 28),
                  ..._body(theme, vault),
                  if (_busy) ...<Widget>[
                    const SizedBox(height: 16),
                    Row(
                      children: <Widget>[
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 10),
                        Text('正在处理…', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ],
                  if (_message != null) ...<Widget>[
                    const SizedBox(height: 14),
                    Text(
                      _message!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _messageIsError
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary,
                      ),
                    ),
                  ],
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
      },
    );
  }

  List<Widget> _statusSection(ThemeData theme, VaultService vault) {
    final rows = <String, String>{
      '状态': !vault.isConfigured
          ? '没有开加密'
          : vault.isUnlocked
              ? (vault.isSearchRevealed ? '已解锁（只为搜索）' : '已解锁')
              : '已锁定',
    };
    if (vault.isConfigured) {
      rows['保险库文件'] = '日记目录里的 ${VaultFile.fileName}（'
          '${vault.params.encode()}）';
    }
    return <Widget>[
      for (final entry in rows.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 76,
                child: Text(entry.key, style: theme.textTheme.bodyMedium),
              ),
              Expanded(
                child: Text(
                  entry.value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            ],
          ),
        ),
      if (vault.lastError != null) ...<Widget>[
        const SizedBox(height: 8),
        Text(
          vault.lastError!,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.error),
        ),
      ],
    ];
  }

  List<Widget> _body(ThemeData theme, VaultService vault) {
    if (!vault.isConfigured) return _setupForm(theme);
    if (_recoveryCode != null) return _recoveryPanel(theme);
    if (!vault.isUnlocked) return _unlockForm(theme);
    return _unlockedPanel(theme, vault);
  }

  // ---------------------------------------------------------------------------
  // 未配置：设口令
  // ---------------------------------------------------------------------------

  List<Widget> _setupForm(ThemeData theme) => <Widget>[
        Text('设一个口令', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 6),
        Text(
          '开启之后：你可以把某些天、或者某几段**加密**。加密的内容会用'
          'XChaCha20-Poly1305 加密后**留在原文件里**，没有口令的人看到的'
          '要么是黑条、要么是打不开的密文。\n'
          '日记以外的一切都不变：明文的天照样能用记事本打开。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _passphrase,
          obscureText: true,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '口令',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _confirm,
          obscureText: true,
          enabled: !_busy,
          onSubmitted: (_) => _busy ? null : _setUp(),
          decoration: const InputDecoration(
            labelText: '再输一遍',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _busy ? null : _setUp,
            child: const Text('开启加密'),
          ),
        ),
      ];

  // ---------------------------------------------------------------------------
  // 刚建库：显示恢复码
  // ---------------------------------------------------------------------------

  List<Widget> _recoveryPanel(ThemeData theme) => <Widget>[
        Text('这是你的恢复码', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 6),
        Text(
          '**忘了口令时，这是唯一的办法。** 程序里没有后门，也没有'
          '"找回密码"这回事——口令和它都丢了，锁着的内容就永久打不开了。\n'
          '抄在纸上、或者放进密码管理器。它会存进日记目录以外的任何地方都可以，'
          '但**不要**和日记放在一起。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            _recoveryCode!,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            IconButton(
              tooltip: '复制',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _recoveryCode!));
                if (mounted) setState(() => _recoveryCopied = true);
              },
              icon: const Icon(Icons.copy_all_outlined, size: 18),
            ),
            Text(
              _recoveryCopied ? '已复制（复制不算抄下来，别只放在剪贴板里）' : '复制',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ];

  // ---------------------------------------------------------------------------
  // 已配置未解锁
  // ---------------------------------------------------------------------------

  List<Widget> _unlockForm(ThemeData theme) => <Widget>[
        Text('解锁', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 6),
        Text(
          _useRecoveryCode
              ? '把恢复码贴进来（大小写、连字符都无所谓）。'
              : '输入口令。解锁之后，锁着的内容就能看、能搜、能改；'
                  '关掉程序或者点「锁定」就会重新锁上。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _secret,
          obscureText: !_useRecoveryCode,
          enabled: !_busy,
          onSubmitted: (_) => _busy ? null : _unlock(),
          decoration: InputDecoration(
            labelText: _useRecoveryCode ? '恢复码' : '口令',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _useRecoveryCode = !_useRecoveryCode;
                        _secret.clear();
                        _message = null;
                      }),
              child: Text(_useRecoveryCode ? '改用口令' : '改用恢复码'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _busy ? null : _unlock,
              child: const Text('解锁'),
            ),
          ],
        ),
      ];

  // ---------------------------------------------------------------------------
  // 已解锁
  // ---------------------------------------------------------------------------

  /// 打开程序锁：**第一次**弹一次说明，之后不再弹。
  ///
  /// 只弹一次的分寸：每次都弹是噪音；一次都不弹，会让人以为它等于"全盘加密"——
  /// 而它挡不住绕过程序直接去翻文件的人。
  Future<void> _toggleAppLock(bool enabled) async {
    final settings = widget.settings;
    if (settings == null) return;
    if (!enabled) {
      await settings.setAppLock(enabled: false);
      return;
    }
    if (!settings.appLockNoticeShown) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('程序锁是一道栅栏，不是保险柜'),
          content: const Text(
            '它挡住的是：别人用你已登录的电脑点开这个程序。\n\n'
            '它挡不住的是：绕过程序直接去翻日记文件的人——'
            '没有加密的日子在磁盘上仍然是明文。\n\n'
            '要挡住后者，靠的是「日记加密」把内容加密。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
    if (!mounted) return;
    await settings.setAppLock(enabled: true, noticeShown: true);
  }

  List<Widget> _appLockSection(ThemeData theme, DiaryController controller) {
    final settings = widget.settings;
    if (settings == null) return const <Widget>[];
    return <Widget>[
      const Divider(height: 28),
      Text(
        '程序锁',
        style: theme.textTheme.titleSmall
            ?.copyWith(color: theme.colorScheme.primary),
      ),
      const SizedBox(height: 6),
      Row(
        children: <Widget>[
          Expanded(
            child: Text('进入程序时需要口令', style: theme.textTheme.bodyMedium),
          ),
          Switch(
            value: settings.appLockEnabled,
            onChanged: _toggleAppLock,
          ),
        ],
      ),
      Tooltip(
        message: '挡住"别人用你已登录的电脑点开这个程序"。\n'
            '明文的日子在磁盘上仍然是明文——绕过程序直接看文件的人是挡不住的。',
        child: Text(
          '挡住别人点开这个程序（明文的日子在磁盘上仍是明文）。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
      if (settings.appLockEnabled) ...<Widget>[
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Text('闲置后自动锁上', style: theme.textTheme.bodyMedium),
            const SizedBox(width: 12),
            DropdownButton<int>(
              value: settings.appLockIdleMinutes,
              isDense: true,
              onChanged: (value) {
                if (value != null) settings.setAppLock(idleMinutes: value);
              },
              items: const <DropdownMenuItem<int>>[
                DropdownMenuItem<int>(value: 0, child: Text('从不')),
                // 1 分钟是**为了让你能验证它到底锁不锁**：等 5 分钟太久了
                DropdownMenuItem<int>(value: 1, child: Text('1 分钟')),
                DropdownMenuItem<int>(value: 5, child: Text('5 分钟')),
                DropdownMenuItem<int>(value: 10, child: Text('10 分钟')),
                DropdownMenuItem<int>(value: 15, child: Text('15 分钟')),
                DropdownMenuItem<int>(value: 30, child: Text('30 分钟')),
              ],
            ),
          ],
        ),
      ],
    ];
  }

  /// 已解锁时的面板。
  ///
  /// 排版原则：**先给一个能立刻做的动作，再给设置，最后才是危险操作**。
  /// 原来那两段解释性文字挪进了下面那行小字和 tooltip——弹窗里堆长句子
  /// 只会让人不看完就乱点（用户反馈："内容过于复杂，不方便使用"）。
  List<Widget> _unlockedPanel(ThemeData theme, VaultService vault) => <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.lock_open, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('已解锁', style: theme.textTheme.titleSmall),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () {
                      // 和 Ctrl+L 一样的行为：开了程序锁就连内存一起清掉
                      // （否则同一个"立即锁定"在两个入口下效果不同）
                      if (widget.settings?.appLockEnabled ?? false) {
                        unawaited(widget.controller.lockApp());
                        Navigator.of(context).pop();
                        return;
                      }
                      vault.lock();
                      _say('已锁定。');
                    },
              icon: const Icon(Icons.lock_outline, size: 16),
              label: const Text('立即锁定'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '锁着的内容现在能看能搜。要锁某一天或某一段：回编辑区，把光标放到那一行，用「⋮」菜单里的加密项。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        ..._appLockSection(theme, widget.controller),
        const Divider(height: 28),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy ? null : _disable,
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            child: const Text('关闭加密…'),
          ),
        ),
      ];
}

/// 只为**一次搜索**解锁：不开会话，用完就丢。
///
/// 和「日记加密」里那个完整对话框分开，是因为这件事的心智完全不同：
/// 用户此刻只是想搜一个词，不该被迫先理解保险库、会话、锁定这一整套。
/// 所以这里只要一个输入框，而且明确写着"用完即丢"。
Future<VaultUnlockResult?> showVaultUnlockPrompt(
  BuildContext context, {
  required VaultService vault,
}) {
  return showDialog<VaultUnlockResult>(
    context: context,
    builder: (context) => _VaultSearchUnlockDialog(vault: vault),
  );
}

class _VaultSearchUnlockDialog extends StatefulWidget {
  const _VaultSearchUnlockDialog({required this.vault});

  final VaultService vault;

  @override
  State<_VaultSearchUnlockDialog> createState() =>
      _VaultSearchUnlockDialogState();
}

class _VaultSearchUnlockDialogState extends State<_VaultSearchUnlockDialog> {
  final TextEditingController _secret = TextEditingController();
  bool _busy = false;
  bool _useRecoveryCode = false;
  String? _message;

  @override
  void dispose() {
    _secret.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await widget.vault.unlock(
      _secret.text,
      isRecoveryCode: _useRecoveryCode,
      forSearchOnly: true,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      Navigator.of(context).pop(result);
      return;
    }
    setState(() => _message = result.message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('解锁来搜索'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '输入口令，锁着的那几天就会参与这次搜索。\n'
              '**这不是"打开加密"**：不解锁任何写入能力，锁完的内容在磁盘上'
              '仍然是密文，关掉程序也不会留下密钥。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _secret,
              obscureText: !_useRecoveryCode,
              autofocus: true,
              enabled: !_busy,
              onSubmitted: (_) => _busy ? null : _submit(),
              decoration: InputDecoration(
                labelText: _useRecoveryCode ? '恢复码' : '口令',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_message != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                _message!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _useRecoveryCode = !_useRecoveryCode;
                    _secret.clear();
                    _message = null;
                  }),
          child: Text(_useRecoveryCode ? '改用口令' : '改用恢复码'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('解锁'),
        ),
      ],
    );
  }
}