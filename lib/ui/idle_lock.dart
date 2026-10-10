import 'dart:async';

import 'package:flutter/material.dart';

/// 盯着"用户多久没动过"，超时就回调一次。
///
/// 为什么放在 `MaterialApp.builder` 上包一层：它要吃掉**所有**指针和键盘事件，
/// 而包在那一层不用去改任何现有界面的嵌套（改嵌套是这类改动最容易出错的地方）。
///
/// 为什么不做"窗口失焦就锁"：切出去查个东西、复制一句话都会被锁在外面，
/// 那样的功能最后只会被关掉。闲置时间到了才锁，是能被长期用下去的档位。
class IdleLock extends StatefulWidget {
  const IdleLock({
    super.key,
    required this.idleLimit,
    required this.onIdle,
    required this.child,
    this.now = DateTime.now,
  });

  /// 闲置多久算超时。null 表示不锁。
  final Duration? idleLimit;

  final Future<void> Function() onIdle;
  final Widget child;

  /// 取当前时间。**可注入**：不注入的话这个类只能靠真实等待来测，
  /// 而"等 5 分钟看它锁不锁"是没法写进测试的。
  final DateTime Function() now;

  @override
  State<IdleLock> createState() => _IdleLockState();
}

class _IdleLockState extends State<IdleLock> {
  /// 每隔这么久检查一次。5 秒的粒度对"分钟级"的闲置足够，
  /// 又不至于一直在后台醒来。
  static const Duration _tick = Duration(seconds: 5);

  late DateTime _lastInteraction;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _lastInteraction = widget.now();
    _timer = Timer.periodic(_tick, (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _touch() => _lastInteraction = widget.now();

  void _check() {
    final limit = widget.idleLimit;
    if (limit == null || limit.inSeconds <= 0) return;
    if (widget.now().difference(_lastInteraction) < limit) return;
    // 先重置时间戳：回调是异步的，别在它跑的时候又触发一次
    _lastInteraction = widget.now();
    unawaited(widget.onIdle());
  }

  @override
  Widget build(BuildContext context) {
    if (widget.idleLimit == null) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _touch(),
      onPointerMove: (_) => _touch(),
      onPointerSignal: (_) => _touch(),
      child: Focus(
        onKeyEvent: (node, event) {
          _touch();
          return KeyEventResult.ignored;
        },
        child: widget.child,
      ),
    );
  }
}
