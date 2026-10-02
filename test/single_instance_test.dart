// 单实例锁的机制验证。
//
// 这个文件刻意用普通 test() 而不是 testWidgets()：要读写真实文件，
// 而 testWidgets 跑在假异步环境里，await 真实 dart:io 的 Future
// 会**永远不返回**（假异步不驱动真事件循环）。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('操作系统级文件锁', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('mydiary-lock-test');
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响测试结论
      }
    });

    test('第二个句柄拿不到锁（同进程）', () async {
      final file = File('${dir.path}${Platform.pathSeparator}instance.lock');

      final first = await file.open(mode: FileMode.append);
      await first.lock(FileLock.exclusive);

      final second = await file.open(mode: FileMode.append);
      var threw = false;
      var blocked = false;
      try {
        // 加超时是为了分辨"抛异常"和"阻塞等待"这两种语义：
        // FileLock.exclusive 按文档应当抛异常，如果实际是阻塞，
        // 这个测试就会以 blocked 结束而不是挂死。
        await second
            .lock(FileLock.exclusive)
            .timeout(const Duration(seconds: 3));
      } on TimeoutException {
        blocked = true;
      } catch (_) {
        threw = true;
      } finally {
        try {
          await second.close();
        } catch (_) {
          // 关不掉无所谓
        }
      }

      expect(blocked, isFalse,
          reason: 'FileLock.exclusive 不该是阻塞语义，否则程序会卡在启动上');
      expect(threw, isTrue, reason: '第二个句柄必须拿不到锁');

      await first.unlock();
      await first.close();
    });

    test('释放之后别人能拿到锁', () async {
      final file = File('${dir.path}${Platform.pathSeparator}instance.lock');

      final first = await file.open(mode: FileMode.append);
      await first.lock(FileLock.exclusive);
      await first.unlock();
      await first.close();

      final second = await file.open(mode: FileMode.append);
      var threw = false;
      try {
        await second.lock(FileLock.exclusive);
      } catch (_) {
        threw = true;
      }
      await second.close();

      expect(threw, isFalse, reason: '前一个句柄释放后，锁应该可以再拿到');
    });

    test('用 append 打开不会截断已有内容', () async {
      // 这点很重要：如果用 FileMode.write 打开，会在"别人正持锁"的时候
      // 先把文件截断——那等于去改别人锁着的文件。
      final file = File('${dir.path}${Platform.pathSeparator}instance.lock');
      await file.writeAsString('上一个实例留下的记录\n');

      final handle = await file.open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive);
      await handle.writeString('这一行是追加的\n');
      await handle.flush();
      await handle.unlock();
      await handle.close();

      final content = await file.readAsString();
      expect(content, contains('上一个实例留下的记录'));
      expect(content, contains('这一行是追加的'));
    });
  });
}
