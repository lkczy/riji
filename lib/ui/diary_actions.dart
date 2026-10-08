/// 一批「动作」的**唯一实现**。
///
/// 为什么单独立一个文件：这些动作原本是 `EditorPanel` 的私有方法，而命令面板
/// 挂在 `HomePage` 上（面板必须在**侧栏搜索框有焦点时**也能唤出，所以它不能
/// 待在 `EditorPanel` 的子树里）。让菜单和面板各留一份实现，迟早会分叉——
/// 一处改了 SnackBar 文案、另一处忘了，两边行为就不一样了。
///
/// 所以实现只留一份：`EditorPanel` 的菜单和 `HomePage` 的命令表都调这里。
///
/// 这些函数都要求传入一个**活着的** `BuildContext`（要有 `Navigator` 和
/// `ScaffoldMessenger`）。跨 `await` 之后一律用 `context.mounted` 判断，
/// 而不是 `State.mounted` —— 这里没有 State。
library;

import 'package:flutter/material.dart';

import '../core/day.dart';
import '../state/diary_controller.dart';
import '../state/settings_controller.dart';
import 'backup_dialog.dart';
import 'filter_dialog.dart';
import 'history_dialog.dart';
import 'markdown_formatting.dart';
import 'reminder_dialog.dart';
import 'trash_dialog.dart';
import 'typography_dialog.dart';

/// 在资源管理器里定位日记文件夹。失败要说话：静默失败会让用户以为程序卡了。
Future<void> revealDiaryFolderAction(
  BuildContext context,
  DiaryController controller,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await controller.revealDiaryFolder();
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('打开文件夹失败：$error')));
  }
}

/// 把这一天导出成单个 Markdown 文件。
///
/// 导出功能必须第一天就有：数据被锁死在程序里是这类项目最大的风险。
Future<void> exportDiaryAction(
  BuildContext context,
  DiaryController controller,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final path = await controller.exportAsMarkdown();
    messenger.showSnackBar(
      SnackBar(
        content: Text('已导出到：$path'),
        action: SnackBarAction(
          label: '打开位置',
          onPressed: controller.revealLastExport,
        ),
      ),
    );
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('导出失败：$error')));
  }
}

/// 打开备份对话框（设位置、立即备份、从备份恢复）。
Future<void> openBackupAction(
  BuildContext context, {
  required SettingsController settings,
  required DiaryController controller,
}) {
  return showBackupDialog(context, settings: settings, controller: controller);
}

/// 每日提醒设置。
///
/// 和别的动作一样只放一份实现：「⋮」菜单和命令面板都走这里。
/// 入口只在支持的平台出现（见 [platform.supportsReminder]）。
Future<void> openReminderSettingsAction(
  BuildContext context,
  SettingsController settings,
) {
  return showReminderDialog(context, settings);
}

/// 历史版本。对话框关掉时可能带回来一句话，要转达给用户。
Future<void> showHistoryAction(
  BuildContext context,
  DiaryController controller,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final message = await showDialog<String>(
    context: context,
    builder: (_) => HistoryDialog(controller: controller),
  );
  if (message != null && message.isNotEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 回收站。同上，恢复和永久删除都会带话回来。
Future<void> showTrashAction(
  BuildContext context,
  DiaryController controller,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final message = await showDialog<String>(
    context: context,
    builder: (_) => TrashDialog(controller: controller),
  );
  if (message != null && message.isNotEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 按标签 / 心情 / 天气筛选。
Future<void> showFilterAction(
  BuildContext context,
  DiaryController controller,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => DiaryFilterDialog(controller: controller),
  );
}

/// 字体与行距（字号 / 行距 / 字重 / 行宽）。
///
/// 这些设置**永远不写进日记文件**：正文是纯文本，排版是各人看着舒服就好，
/// 不该跟着文件跑，也不该在同步时互相覆盖。
Future<void> showTypographyAction(
  BuildContext context,
  SettingsController settings,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => TypographyDialog(settings: settings),
  );
}

/// 删除当前这一天的日记。**删之前必须确认**，命令面板也不能绕过这道闸门。
Future<void> deleteCurrentEntryAction(
  BuildContext context,
  DiaryController controller,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final date = controller.selectedDate;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除这一天的日记？'),
      content: Text(
        '${formatIsoDate(date)} 的这一篇会被移进回收站。\n\n'
        '**内容不会被抹掉**，你可以随时在「回收站」里把它找回来。',
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
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  await controller.deleteCurrentEntry();
  messenger.showSnackBar(
    SnackBar(content: Text('已删除 ${formatIsoDate(date)} 的日记，可在「回收站」里找回。')),
  );
}

/// 时光机：随机翻到一篇以前写过的日记。
///
/// 只挑**正文非空**的条目（`pickRandomEntry` 负责），翻到空白的一天
/// 反而会让人以为自己的日记丢了。
Future<void> travelToRandomEntryAction(
  BuildContext context,
  DiaryController controller,
) async {
  final messenger = ScaffoldMessenger.of(context);

  final entry = controller.pickRandomEntry();
  if (entry == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('还没有以前写过的日记可以翻。')),
    );
    return;
  }

  await controller.openDate(entry.date);
  if (!context.mounted) return;

  // 连续点「再翻一篇」时不要排队堆一堆提示
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text('时光机：翻到了 ${formatIsoDate(entry.date)}'),
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
        label: '再翻一篇',
        onPressed: () {
          // 这个回调可能在很久之后才被点到，界面未必还活着。
          if (!context.mounted) return;
          travelToRandomEntryAction(context, controller);
        },
      ),
    ),
  );
}

/// 对正文当前选区套一对 Markdown 标记；再按一次取消。
///
/// 做的是**插入标记**，不是改某个加粗属性——正文永远是纯文本。
void applyMarkdownFormat({
  required TextEditingController bodyController,
  required DiaryController controller,
  required FocusNode bodyFocus,
  required String open,
  required String close,
}) {
  final updated = MarkdownFormatter.toggleWrap(
    bodyController.value,
    open: open,
    close: close,
  );
  if (updated == bodyController.value) return;

  bodyController.value = updated;
  // 直接改 controller 不会触发 TextField 的 onChanged，所以必须手动通知一次。
  // 漏掉这一步的表现是：格式改了，但不会被保存——下次打开发现改动没了。
  controller.updateBody(updated.text);
  bodyFocus.requestFocus();
}
