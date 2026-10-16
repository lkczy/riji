import 'dart:async';
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

  /// 「停下来就验一次」的防抖计时器。
  Timer? _autoUnlock;

  /// 上一次已经验过的文字：同一段文字不重复验，
  /// 否则每次停顿都会白烧一次 700ms 的 Argon2id。
  String? _lastTried;

  /// 静默验证是不是正在进行。验证期间界面要给一点反馈——
  /// 否则那 0.7 秒里屏幕上毫无动静，人会觉得"卡住了"。
  bool _verifying = false;

  /// 验证进行中又敲了新内容时，把最新文字先记在这里，等这一轮结束再验。
  /// **不能直接丢掉**：否则你最后一版输入可能永远轮不到验证。
  String? _pendingText;
  bool _useRecoveryCode = false;
  String? _message;
  bool _messageIsError = true;

  @override
  void dispose() {
    _autoUnlock?.cancel();
    _secret.dispose();
    super.dispose();
  }

  /// 输完停手约 0.8 秒，就静默验一次口令。
  ///
  /// 为什么不能边打边验：验证一次 = 一次 Argon2id（本机约 700ms），
  /// 每敲一个键就验等于把你打字的过程变成烤 CPU。
  void _onSecretChanged(String value) {
    _autoUnlock?.cancel();
    final text = value.trim();
    if (text.isEmpty || text == _lastTried) return;
    // 180ms：够把"手还在打"和"打完了"分开，又不会让人等。
    // 真正的耗时在 Argon2id 本身（约 700ms），那是**故意的**——
    // 它就是"文件被拿走也难破解"的那部分成本。
    _autoUnlock = Timer(const Duration(milliseconds: 180), () {
      unawaited(_tryUnlockSilently(text));
    });
  }

  /// 静默验证：**对了就直接进**；错了什么都不显示——
  /// 不要在你还没打完的时候就跳出一句"口令不对"。
  /// 想立刻知道对错，仍然按 Enter 或者点「解锁」。
  Future<void> _tryUnlockSilently(String text) async {
    if (_busy || !mounted) return;
    if (_verifying) {
      // 已经在验了：把最新文字记下来，等这轮结束立刻接着验。
      _pendingText = text;
      return;
    }
    _verifying = true;
    _lastTried = text;
    try {
      final result =
          await widget.vault.unlock(text, isRecoveryCode: _useRecoveryCode);
      if (!mounted) return;
      if (result.ok) {
        _autoUnlock?.cancel();
        await _finishUnlock();
        return;
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
    final pending = _pendingText;
    _pendingText = null;
    if (pending != null && pending != text && mounted) {
      await _tryUnlockSilently(pending);
    }
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
    await _finishUnlock();
  }

  /// 解锁成功之后共用的收尾（显式解锁和静默解锁都走这里）。
  Future<void> _finishUnlock() async {
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
                  onChanged: _onSecretChanged,
                  decoration: InputDecoration(
                    labelText: _useRecoveryCode ? '恢复码' : '口令',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  // 静默验证**完全不碰按钮**：只是打字停了一下而已，
                  // 按钮不该跟着转圈（用户反馈："停顿就转圈，这个不太需要"）。
                  // 转圈只留给"你主动按了「解锁」"这条明确的路。
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
