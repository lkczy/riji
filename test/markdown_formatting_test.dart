import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riji/ui/markdown_formatting.dart';

TextEditingValue _value(String text, int start, int end) => TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: start, extentOffset: end),
    );

String _selectedIn(TextEditingValue value) =>
    value.selection.textInside(value.text);

void main() {
  const bold = MarkdownFormatter.bold;
  const italic = MarkdownFormatter.italic;

  group('套上标记', () {
    test('选中文字后包起来，并保持选中原来的内容', () {
      final result = MarkdownFormatter.toggleWrap(
        _value('今天很好', 0, 2),
        open: bold,
        close: bold,
      );

      expect(result.text, '**今天**很好');
      expect(_selectedIn(result), '今天',
          reason: '保持选中内容本身，再按一次才能取消格式');
    });

    test('只影响选中的那一段', () {
      final result = MarkdownFormatter.toggleWrap(
        _value('前面中间后面', 2, 4),
        open: bold,
        close: bold,
      );
      expect(result.text, '前面**中间**后面');
    });

    test('光标折叠时插一对空标记，光标落在两个标记之间', () {
      final result = MarkdownFormatter.toggleWrap(
        _value('abc', 1, 1),
        open: bold,
        close: bold,
      );

      expect(result.text, 'a****bc');
      // 这里**不能**选中整对标记：那样一打字就把标记全替掉了，
      // 结果只是普通文字，格式反而没了。
      expect(result.selection.isCollapsed, isTrue);
      expect(result.selection.baseOffset, 3, reason: '落在 a** 和 **bc 之间');

      // 模拟用户接着敲一个字
      final typed = result.replaced(result.selection, 'x');
      expect(typed.text, 'a**x**bc');
    });

    test('行首行尾都能处理', () {
      expect(
        MarkdownFormatter.toggleWrap(_value('abc', 0, 3), open: bold, close: bold)
            .text,
        '**abc**',
      );
      expect(
        MarkdownFormatter.toggleWrap(_value('abc', 3, 3), open: bold, close: bold)
            .text,
        'abc****',
      );
    });
  });

  group('再按一次取消', () {
    test('标记被包含在选区里', () {
      final result = MarkdownFormatter.toggleWrap(
        _value('**今天**很好', 0, 6),
        open: bold,
        close: bold,
      );

      expect(result.text, '今天很好');
      expect(_selectedIn(result), '今天');
    });

    test('只选中中间的字（标记在选区两侧）', () {
      final result = MarkdownFormatter.toggleWrap(
        _value('**今天**很好', 2, 4),
        open: bold,
        close: bold,
      );

      expect(result.text, '今天很好');
    });

    test('先加粗再取消，不留残余', () {
      var value = _value('abc', 0, 1);
      value = MarkdownFormatter.toggleWrap(value, open: bold, close: bold);
      expect(value.text, '**a**bc');

      value = MarkdownFormatter.toggleWrap(value, open: bold, close: bold);
      expect(value.text, 'abc', reason: '不能套成 ****a****');
    });

    test('旁边的同类标记不会被拆坏', () {
      // 这是最容易出错的一处：斜体和粗体共用星号。
      // 选中 **今天** 里的"今天"再按斜体，如果直接按"外侧有星号"就拆，
      // 会把粗体拆成一个残缺的 *今天*。正确行为是再包一层。
      final result = MarkdownFormatter.toggleWrap(
        _value('**今天**', 2, 4),
        open: italic,
        close: italic,
      );

      expect(result.text, '***今天***');
      expect(result.text, isNot('*今天*'));
    });

    test('前后紧邻的另一个加粗不会被误伤', () {
      final result = MarkdownFormatter.toggleWrap(
        _value('**a****b**', 5, 6),
        open: bold,
        close: bold,
      );
      // 选中 b，它两边都是 **：外侧仍是同字符，所以走"再包一层"而不是拆
      expect(result.text, contains('b'));
      expect(result.text.startsWith('**a**'), isTrue,
          reason: '前面的 **a** 不能被改动');
    });
  });

  group('下划线用 <u> 标签', () {
    test('加下划线和取消下划线', () {
      final wrapped = MarkdownFormatter.toggleWrap(
        _value('重点', 0, 2),
        open: MarkdownFormatter.underlineOpen,
        close: MarkdownFormatter.underlineClose,
      );
      expect(wrapped.text, '<u>重点</u>');

      final unwrapped = MarkdownFormatter.toggleWrap(
        wrapped,
        open: MarkdownFormatter.underlineOpen,
        close: MarkdownFormatter.underlineClose,
      );
      expect(unwrapped.text, '重点');
    });

    test('下划线和粗体可以叠加（后加的套在外面）', () {
      final bolded = MarkdownFormatter.toggleWrap(
        _value('重点', 0, 2),
        open: bold,
        close: bold,
      );
      expect(bolded.text, '**重点**');

      final underlined = MarkdownFormatter.toggleWrap(
        bolded,
        open: MarkdownFormatter.underlineOpen,
        close: MarkdownFormatter.underlineClose,
      );
      // 后按的那个套在外层：先加粗再加下划线就是 **<u>重点</u>**
      expect(underlined.text, '**<u>重点</u>**');
    });
  });

  group('边界情况', () {
    test('选区无效时原样返回，不去猜光标在哪', () {
      const invalid = TextEditingValue(text: '内容');
      expect(invalid.selection.isValid, isFalse);

      final result = MarkdownFormatter.toggleWrap(
        invalid,
        open: bold,
        close: bold,
      );
      expect(result, invalid);
    });

    test('空文本上折叠光标也能用', () {
      final result = MarkdownFormatter.toggleWrap(
        _value('', 0, 0),
        open: bold,
        close: bold,
      );
      expect(result.text, '****');
      expect(result.selection.baseOffset, 2);
    });

    test('内容里本来就有标记符号也不会算错位置', () {
      // 'a**b' 里选中末尾的 b：外侧虽然看着像标记，但右侧越界了，
      // 所以应该走"包一层"而不是"拆"
      final result = MarkdownFormatter.toggleWrap(
        _value('a**b', 3, 4),
        open: bold,
        close: bold,
      );
      expect(result.text, 'a****b**');
      expect(_selectedIn(result), 'b');
    });
  });
}
