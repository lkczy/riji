/// 历史快照：什么时候留、为什么留、留多少。
///
/// 这个文件是纯逻辑，不碰文件系统，所以策略可以被完整地单测。
library;

/// 一份快照是因为什么留下来的。
enum SnapshotReason {
  /// 打开这一天的**那一刻**的样子。整条历史里最有价值的一份：
  /// 它回答"我今天坐下来写之前，这篇是什么样"。
  opened('打开时的样子', 'opened'),

  /// 编辑过程中的定时快照。
  auto('自动快照', 'auto'),

  /// 用户主动点「保存这个版本」留下的。
  manual('手动保存的版本', 'manual'),

  /// **恢复历史版本之前**，先把当前内容留一份。
  /// 没有它，"恢复"本身就会变成一次丢内容。
  beforeRestore('恢复之前的内容', 'before-restore');

  const SnapshotReason(this.label, this.tag);

  /// 给用户看的名字。
  final String label;

  /// 进文件名用的短标识（ASCII，方便在资源管理器里认）。
  final String tag;

  static SnapshotReason? fromTag(String tag) {
    for (final reason in SnapshotReason.values) {
      if (reason.tag == tag) return reason;
    }
    return null;
  }
}

/// 什么时候该留一份快照。
///
/// **这里最关键的一条：快照的粒度必须比保存频率粗得多。**
///
/// 本程序的自动保存是亚秒级的（防抖 900ms）。如果按"每次保存前留一份"来做，
/// 会得到一堆相隔一秒、彼此几乎完全相同的文件——看起来历史很丰富，
/// 实际上没有任何一份是有用的，而且列表会长到没法看。
/// 所以要按**会话**和**时间网格**来留，而不是按保存次数。
class SnapshotPolicy {
  /// 编辑过程中两份快照之间至少隔这么久。
  static const Duration minInterval = Duration(minutes: 10);

  /// 每天最多留多少份。超出后从**第二份**开始丢（见 [pruneIndex]）。
  static const int maxPerDay = 30;

  /// 现在该不该留一份快照。
  ///
  /// [contentDiffers] 表示"要留的内容和已有的最新一份确实不一样"。
  /// 内容完全相同就不留——快照的全部价值就在于它记录了**另一个样子**。
  static bool shouldSnapshot({
    required SnapshotReason reason,
    required DateTime now,
    required bool contentDiffers,
    DateTime? newestAt,
  }) {
    if (!contentDiffers) return false;

    switch (reason) {
      case SnapshotReason.opened:
      case SnapshotReason.manual:
      case SnapshotReason.beforeRestore:
        // 这三类是明确的"节点"，不受时间间隔限制。
        // 尤其 beforeRestore：它必须无条件成功，否则恢复就等于丢内容。
        return true;
      case SnapshotReason.auto:
        final last = newestAt;
        if (last == null) return true;
        return now.difference(last) >= minInterval;
    }
  }

  /// 数量超出上限时该删掉列表里的第几份（不需要删就返回 null）。
  ///
  /// 索引 0 通常是「打开时的样子」，是整条历史里最有用的一份，
  /// 所以**从第二份开始丢**，而不是丢最旧的。
  static int? pruneIndex(int count) => count > maxPerDay ? 1 : null;
}
