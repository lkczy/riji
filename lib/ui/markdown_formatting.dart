import 'package:flutter/services.dart';

/// 在正文里插入 Markdown 标记。
///
/// **为什么不做成富文本**：那意味着正文要存成带格式的数据结构，而
/// Markdown 源码本身就是最好的格式——几十年后还能读、能 grep、能 diff、
/// 能用任何编辑器打开。所以这里的"加粗"是**插入 `** **`**，
/// 而不是修改某个 bold 属性。
///
/// 代价是源码里能看到标记符号；换来的是文件永远是纯文本。
class MarkdownFormatter {
  const MarkdownFormatter._();

  static const String bold = '**';
  static const String italic = '*';
  static const String underlineOpen = '<u>';
  static const String underlineClose = '</u>';

  /// 按一次就包上标记，再按一次就拆掉。
  ///
  /// 支持两种"已经包着"的情形，因为用户两种都会遇到：
  ///   1. 把 `**粗体**` 连标记一起选中，再按一次；
  ///   2. 只选中中间的字（标记在选区两侧），再按一次。
  ///
  /// 选区无效时原样返回：此时不知道光标在哪，猜一个位置只会更糟。
  static TextEditingValue toggleWrap(
    TextEditingValue value, {
    required String open,
    required String close,
  }) {
    final selection = value.selection;
    if (!selection.isValid) return value;

    final text = value.text;
    final start = selection.start;
    final end = selection.end;
    final selected = text.substring(start, end);

    // 情形一：标记被包含在选区里
    if (selected.length >= open.length + close.length &&
        selected.startsWith(open) &&
        selected.endsWith(close)) {
      final inner =
          selected.substring(open.length, selected.length - close.length);
      return TextEditingValue(
        text: text.replaceRange(start, end, inner),
        selection: TextSelection(
          baseOffset: start,
          extentOffset: start + inner.length,
        ),
      );
    }

    // 情形二：标记紧贴在选区两侧
    final outerStart = start - open.length;
    final outerEnd = end + close.length;
    final markersFitOutside = outerStart >= 0 &&
        outerEnd <= text.length &&
        text.substring(outerStart, start) == open &&
        text.substring(end, outerEnd) == close;

    // 但别把 `**粗体**` 里的星号误当成斜体标记拆掉：
    // 拆之前确认外侧没有相邻的同类标记字符。
    final markerChar = open[0];
    final hasAdjacentMarker = markersFitOutside &&
        ((outerStart > 0 && text[outerStart - 1] == markerChar) ||
            (outerEnd < text.length && text[outerEnd] == markerChar));

    if (markersFitOutside && !hasAdjacentMarker) {
      return TextEditingValue(
        text: text.replaceRange(outerStart, outerEnd, selected),
        selection: TextSelection(
          baseOffset: outerStart,
          extentOffset: outerStart + selected.length,
        ),
      );
    }

    // 其余情况：包起来。
    final wrapped = '$open$selected$close';
    final newText = text.replaceRange(start, end, wrapped);

    // 选区怎么摆很关键：
    //   * 没选中东西（只是光标）：把光标放在**两个标记之间**。
    //     如果改成选中整对标记，用户一打字就把标记全替掉了，
    //     结果只是普通文字，格式反而没了。
    //   * 选中了东西：保持选中**原来的内容**（位置后移开标记的长度），
    //     这样再按一次同一个快捷键就能取消格式，符合直觉。
    final newSelection = selected.isEmpty
        ? TextSelection.collapsed(offset: start + open.length)
        : TextSelection(
            baseOffset: start + open.length,
            extentOffset: start + open.length + selected.length,
          );

    return TextEditingValue(text: newText, selection: newSelection);
  }
}
