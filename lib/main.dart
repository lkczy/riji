import 'dart:async';

import 'package:flutter/material.dart';

import 'data/release_info.dart';
import 'data/settings.dart';
import 'core/diary_location.dart';
import 'platform/platform.dart' as platform;
import 'state/diary_controller.dart';
import 'state/settings_controller.dart';
import 'ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RijiBootstrap());
}

/// 先读设置（日记目录在哪），再建存储和控制器。
///
/// 设置读取是异步的，所以单独有个引导层：读设置的几十毫秒里显示一个
/// 极简加载态，而不是白屏、也不是先闪一个空界面。
class RijiBootstrap extends StatefulWidget {
  const RijiBootstrap({super.key});

  @override
  State<RijiBootstrap> createState() => _RijiBootstrapState();
}

class _RijiBootstrapState extends State<RijiBootstrap> {
  DiaryController? _controller;
  SettingsController? _settings;
  ReleaseInfo? _releaseInfo;
  Object? _error;
  bool _alreadyRunning = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    // 第一件事是抢单实例锁，早于读设置。
    //
    // 两个实例指向同一个日记目录时，各自的内存状态会互相过时，于是每次
    // 保存都把对方的版本判成"外部改动"，产出需要手工合并的冲突文件。
    // 数据不会丢（冲突文件把两边都保住了），但那个噪音完全没必要，
    // 而且会让人怀疑程序是不是坏了。
    final locked = await platform.acquireSingleInstanceLock();
    if (!locked) {
      if (!mounted) return;
      setState(() => _alreadyRunning = true);
      return;
    }

    try {
      const repository = SettingsRepository();
      final stored = await repository.load();
      final settings =
          SettingsController(initial: stored, repository: repository);

      final device = platform.deviceName;
      final store = platform.createStore(
        rootPath: stored.diaryRoot,
        device: device,
      );
      final controller = DiaryController(store: store, deviceName: device);

      // 版本与更新记录：和读日记**并行**，不拖慢启动。
      // 读不到就是 null，界面那边整个功能不出现——它是锦上添花，
      // 绝不能挡住"打开即写"。
      final releaseInfoFuture = loadReleaseInfo();

      // 不等它读完就先把窗口显示出来，读取过程由界面上的加载态体现。
      // 「打开即写」意味着启动不能有等待感。
      unawaited(controller.load());

      final releaseInfo = await releaseInfoFuture;

      if (!mounted) return;
      setState(() {
        _settings = settings;
        _controller = controller;
        _releaseInfo = releaseInfo;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  /// 切换日记保存位置。
  ///
  /// 顺序是这个功能里最关键的东西：
  ///   1. **先把待写内容落盘**。否则正在写的那句话要么丢，要么写到新位置去，
  ///      而且要复制的话，复制出来的就会缺掉最后一段。
  ///   2. **需要时复制旧数据**。复制失败就直接返回，**不碰设置**——
  ///      这样程序仍然指着原来的位置，用户的数据始终有一个可用的入口。
  ///   3. 用新位置建存储和控制器。
  ///   4. **最后才持久化设置**。放在最后是为了让"设置"永远只描述一个
  ///      确实可用的位置。
  Future<DiaryCopyOutcome> _switchDiaryRoot(
    String newRoot, {
    required bool copyExisting,
  }) async {
    final current = _controller;
    final settings = _settings;
    if (current == null || settings == null) {
      return const DiaryCopyOutcome(
        ok: false,
        filesCopied: 0,
        message: '程序还没准备好，请稍后再试。',
      );
    }

    final oldRoot = settings.settings.diaryRoot;

    // 1. 落盘（这样如果选了复制，最后一段内容也会被复制过去）
    await current.close();

    // 2. 复制
    var outcome = const DiaryCopyOutcome(
      ok: true,
      filesCopied: 0,
      message: '已切换日记位置。',
    );
    if (copyExisting) {
      outcome = await platform.copyDiaryTree(from: oldRoot, to: newRoot);
      if (!outcome.ok) return outcome;
    }

    // 3. 换存储和控制器
    final device = platform.deviceName;
    final store = platform.createStore(rootPath: newRoot, device: device);
    final controller = DiaryController(store: store, deviceName: device);
    await controller.load();

    // 4. 持久化
    await settings.setDiaryRoot(newRoot);

    if (!mounted) return outcome;
    setState(() => _controller = controller);

    // 旧控制器要等这一帧的 didUpdateWidget 先把监听摘掉，才能安全销毁。
    // 提前 dispose 会让 removeListener 撞上"已销毁"断言。
    WidgetsBinding.instance.addPostFrameCallback((_) => current.dispose());

    return outcome;
  }

  @override
  Widget build(BuildContext context) {
    if (_alreadyRunning) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text('程序已经在运行了', style: TextStyle(fontSize: 20)),
                    const SizedBox(height: 12),
                    const Text(
                      '同一个日记目录同时被两个实例写入，会产出一堆需要手工合并的'
                      '冲突文件。\n\n'
                      '请切换到已经打开的那个窗口。\n'
                      '如果你确实想同时开两个，请先把其中一个的「日记位置」'
                      '改到别的文件夹。',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: platform.quitApp,
                      child: const Text('关闭这个窗口'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final error = _error;
    if (error != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.error_outline, size: 48),
                  const SizedBox(height: 16),
                  const Text('启动失败', style: TextStyle(fontSize: 20)),
                  const SizedBox(height: 8),
                  SelectableText('$error', textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final controller = _controller;
    final settings = _settings;
    if (controller == null || settings == null) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return RijiApp(
      controller: controller,
      settings: settings,
      onSwitchDiaryRoot: _switchDiaryRoot,
      releaseInfo: _releaseInfo,
    );
  }
}
