import 'package:flutter/material.dart';

import '../state/diary_controller.dart';
import '../state/vault_service.dart';

/// 程序锁的解锁界面。
///
/// **什么都不显示，除了这个界面本身**：日记列表、正文、搜索结果一个都不渲染。
/// 否则"锁"就只是盖了一层纸。
///
/// 用**和日记加密同一个口令**（不再多一个密码让人记）。
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({
    super.key,
    required this.controller,
    required this.vault,
  });

  final DiaryController controller;
  final VaultService vault;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final TextEditingController _secret = TextEditingController();
  bool _busy = false;
  bool _useRecoveryCode = false;
  String? _message;
  bool _messageIsError = true;

  @override
  void dispose() {
    _secret.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_secret.text.trim().isEmpty) {
      setState(() {
        _message = _useRecoveryCode ? '请把恢复码贴进来。' : '请输入口令。';
        _messageIsError = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await widget.vault.unlock(
      _secret.text,
      isRecoveryCode: _useRecoveryCode,
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _busy = false;
        _message = result.message;
        _messageIsError = true;
      });
      return;
    }
    // 锁定时把内存里的日记清空了，现在读回来
    await widget.controller.reloadAfterUnlock();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(Icons.lock_outline,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('日迹已锁定', style: theme.textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 22),
                TextField(
                  controller: _secret,
                  obscureText: !_useRecoveryCode,
                  autofocus: true,
                  enabled: !_busy,
                  onSubmitted: (_) => _busy ? null : _unlock(),
                  decoration: InputDecoration(
                    labelText: _useRecoveryCode ? '恢复码' : '口令',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: _busy ? null : _unlock,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('解锁'),
                ),
                const SizedBox(height: 6),
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
                const SizedBox(height: 4),
                Text(
                  _useRecoveryCode
                      ? '恢复码就是当初设口令时抄下来的那串字母数字。'
                      : '忘了口令？用当初抄下来的恢复码也能进。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                if (_message != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    _message!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _messageIsError
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                  ),
                ],
                if (!widget.vault.isConfigured) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    '保险库文件读不出来，你的日记没有被加密。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    // 保险库没了就没有可保护的东西了。**绝不能把人锁在自己的日记外面。**
                    onPressed: () => widget.controller.load(),
                    child: const Text('直接进入'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
