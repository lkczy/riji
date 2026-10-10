import 'package:flutter/material.dart';

import '../state/diary_controller.dart';
import '../state/settings_controller.dart';
import 'diary_actions.dart';

/// 一条加密菜单项。
///
/// 正文区的右键菜单和左侧日期的右键菜单**共用这一份定义**：两处各写一遍
/// 迟早会分叉（一处改了文案、另一处忘了），这和「动作只有一份实现」是同一个理由。
class VaultMenuAction {
  const VaultMenuAction({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.run,
    this.dividerBefore = false,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final Future<void> Function(BuildContext context) run;

  /// 在这一项**之前**画一条横线（用来和上面一组分开）。
  final bool dividerBefore;

  /// 危险操作：用错误色（红）显示。删除这种东西必须一眼看出来。
  final bool danger;
}

/// 收集当前状态下可用的加密菜单项。
///
/// [cursorLine] 只有在**正文里右键**时才有意义（段落级的三项要知道光标在哪一行）；
/// 从左侧列表右键时为 null，那就只给整天级的项。
/// [openFirst] 用来"先把这一天打开再做"——列表里右键别的日期时靠它。
List<VaultMenuAction> vaultMenuActions(
  DiaryController controller, {
  int? cursorLine,
  Future<void> Function()? openFirst,
  SettingsController? settings,
  /// 左侧日期栏里不需要「日记加密…」——那是设置，用「⋮」足够了。
  bool includeVaultDialog = true,
  /// 左侧日期栏里要能直接删掉这一天。
  bool includeDeleteDay = false,
}) {
  Future<void> Function(BuildContext) afterOpen(
    Future<void> Function(BuildContext) action,
  ) {
    return (BuildContext context) async {
      if (openFirst != null) await openFirst();
      if (!context.mounted) return;
      await action(context);
      return;
    };
  }

  final actions = <VaultMenuAction>[];

  // ---- 第一组：光标所在**这一段**的加密/解密（合成一项，按状态变）----
  if (cursorLine != null && !controller.currentDayIsWholeDayLocked) {
    final lineIsBar = controller.lineIsRedacted(cursorLine);
    if (lineIsBar) {
      actions.add(VaultMenuAction(
        label: '解密这段',
        icon: Icons.lock_open,
        enabled: controller.canLock,
        run: (context) => unlockLineAction(context, controller, cursorLine),
      ));
    } else if (controller.canLockLine(cursorLine)) {
      actions.add(VaultMenuAction(
        label: '加密这段',
        icon: Icons.visibility_off_outlined,
        enabled: true,
        run: (context) => lockLineAction(context, controller, cursorLine),
      ));
    }
  }

  // ---- 第二组：整天（同样是合成一项）----
  final wholeDayEncrypted = controller.currentDayIsWholeDayLocked;
  actions.add(VaultMenuAction(
    label: wholeDayEncrypted ? '解密这天' : '加密这天',
    icon: wholeDayEncrypted ? Icons.lock_open : Icons.lock_outline,
    enabled: controller.canLock,
    run: afterOpen((context) => wholeDayEncrypted
        ? unlockWholeDayAction(context, controller)
        : lockWholeDayAction(context, controller)),
  ));

  // ---- 第三组（横线隔开）：只是"看"，不改动任何东西 ----
  var thirdGroupStarted = false;
  if (cursorLine != null && controller.lineIsRedacted(cursorLine)) {
    actions.add(VaultMenuAction(
      label: '看这段的内容',
      icon: Icons.chrome_reader_mode_outlined,
      enabled: true,
      dividerBefore: true,
      run: (context) => revealRedactionAction(context, controller, cursorLine),
    ));
    thirdGroupStarted = true;
  }
  if (controller.currentDayIsLocked) {
    if (controller.revealMode) {
      actions.add(VaultMenuAction(
        label: '回到黑条视图',
        icon: Icons.visibility_off_outlined,
        enabled: true,
        dividerBefore: !thirdGroupStarted,
        run: (context) async => controller.exitRevealMode(),
      ));
    } else {
      actions.add(VaultMenuAction(
        label: '显示原文（只读）',
        icon: Icons.visibility_outlined,
        enabled: controller.canRevealOriginal,
        dividerBefore: !thirdGroupStarted,
        run: afterOpen((context) => revealWholeDayAction(context, controller)),
      ));
    }
  }

  if (includeVaultDialog) {
    actions.add(VaultMenuAction(
      label: '日记加密',
      icon: Icons.enhanced_encryption_outlined,
      enabled: true,
      dividerBefore: actions.isNotEmpty,
      run: (context) => openVaultAction(context, controller, settings: settings),
    ));
  }

  if (includeDeleteDay) {
    actions.add(VaultMenuAction(
      label: '删除这一天的日记',
      icon: Icons.delete_forever,
      enabled: !controller.isCurrentEntryEmpty,
      // 和上面加密那一组用横线隔开：删东西不该挨着常用操作
      dividerBefore: true,
      danger: true,
      run: afterOpen((context) => deleteCurrentEntryAction(context, controller)),
    ));
  }
  return actions;
}

/// 菜单项的颜色：灰掉的一律用 outline；危险操作用错误色（红）。
///
/// 红字只给"删掉东西"这类不可逆动作——满屏红字等于没有红字。
Color? _itemColor(BuildContext context, VaultMenuAction action) {
  final scheme = Theme.of(context).colorScheme;
  if (!action.enabled) return scheme.outline;
  if (action.danger) return scheme.error;
  return null;
}

/// 左侧日期列表用的右键菜单。
///
/// 用 [showMenu] 自己弹：`ListTile` 没有内置的右键菜单，而
/// `contextMenuBuilder` 那套只对文本输入框有效。
Future<void> showVaultMenuAt(
  BuildContext context, {
  required Offset globalPosition,
  required DiaryController controller,
  Future<void> Function()? openFirst,
  SettingsController? settings,
  String? title,
  bool includeVaultDialog = true,
  bool includeDeleteDay = false,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final actions = vaultMenuActions(
    controller,
    openFirst: openFirst,
    settings: settings,
    includeVaultDialog: includeVaultDialog,
    includeDeleteDay: includeDeleteDay,
  );

  final selected = await showMenu<int>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromPoints(globalPosition, globalPosition),
      Offset.zero & overlay.size,
    ),
    items: <PopupMenuEntry<int>>[
      if (title != null)
        PopupMenuItem<int>(
          enabled: false,
          height: 32,
          child: Text(
            title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ),
      for (var i = 0; i < actions.length; i++) ...<PopupMenuEntry<int>>[
        if (actions[i].dividerBefore) const PopupMenuDivider(),
        PopupMenuItem<int>(
          value: i,
          enabled: actions[i].enabled,
          child: Row(
            children: <Widget>[
              Icon(
                actions[i].icon,
                size: 16,
                color: _itemColor(context, actions[i]),
              ),
              const SizedBox(width: 10),
              Text(actions[i].label, style: TextStyle(color: _itemColor(context, actions[i]))),
            ],
          ),
        ),
      ],
    ],
  );

  if (selected == null || !context.mounted) return;
  final action = actions[selected];
  if (!action.enabled) return;
  await action.run(context);
}

/// 正文输入框的右键菜单项：把加密那几项接到系统自带的文本菜单后面。
///
/// 为什么用 `contextMenuBuilder` 而不是自己 `showMenu`：输入框自己会在右键时
/// 弹一个"复制/粘贴"菜单，自己再弹一个就会出现**两个菜单叠在一起**。
List<ContextMenuButtonItem> vaultContextMenuItems(
  BuildContext context, {
  required DiaryController controller,
  required int cursorLine,
  required VoidCallback onDone,
  SettingsController? settings,
}) {
  final actions = vaultMenuActions(
    controller,
    cursorLine: cursorLine,
    settings: settings,
    // 右键菜单里不放设置类入口（那是「⋮」的事）
    includeVaultDialog: false,
  );
  return <ContextMenuButtonItem>[
    for (final action in actions)
      ContextMenuButtonItem(
        label: action.label,
        onPressed: action.enabled
            ? () {
                onDone();
                action.run(context);
              }
            : null,
      ),
  ];
}

