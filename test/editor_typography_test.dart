import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/editor_typography.dart';

void main() {
  group('默认值', () {
    test('默认是常规字重、16px、行距 1.9', () {
      const defaults = EditorTypography.defaults;
      expect(defaults.fontSize, EditorTypography.defaultFontSize);
      expect(defaults.lineHeight, EditorTypography.defaultLineHeight);
      expect(defaults.fontWeightValue, EditorTypography.defaultFontWeight);
      expect(defaults.lineWidth, EditorTypography.defaultLineWidth);
      expect(defaults.isDefault, isTrue);
    });

    test('只给三档字重，避免陷入"哪个更好看"的纠结', () {
      expect(EditorTypography.allowedWeights, <int>[400, 500, 600]);
    });
  });

  group('copyWith 与相等性', () {
    test('只改一个字段，其它保持不变', () {
      final changed = EditorTypography.defaults.copyWith(fontSize: 22);
      expect(changed.fontSize, 22);
      expect(changed.lineHeight, EditorTypography.defaultLineHeight);
      expect(changed.fontWeightValue, EditorTypography.defaultFontWeight);
      expect(changed.lineWidth, EditorTypography.defaultLineWidth);
      expect(changed.isDefault, isFalse);
    });

    test('字段全同才相等', () {
      const a = EditorTypography(fontSize: 20);
      const b = EditorTypography(fontSize: 20);
      const c = EditorTypography(fontSize: 21);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('JSON 往返', () {
    test('往返一致', () {
      const original = EditorTypography(
        fontSize: 20,
        lineHeight: 2.2,
        fontWeightValue: 500,
        lineWidth: 900,
      );
      expect(EditorTypography.fromJson(original.toJson()), original);
    });

    test('缺失或类型不对时退回默认', () {
      expect(EditorTypography.fromJson(null), EditorTypography.defaults);
      expect(
        EditorTypography.fromJson(<String, dynamic>{}),
        EditorTypography.defaults,
      );
      expect(
        EditorTypography.fromJson(<String, dynamic>{'fontSize': '大'}),
        EditorTypography.defaults,
      );
    });
  });

  group('越界的值必须夹回范围', () {
    test('否则设置文件一坏，正文就彻底没法看了', () {
      final restored = EditorTypography.fromJson(<String, dynamic>{
        'fontSize': 0,
        'lineHeight': 99,
        'lineWidth': -5,
        'fontWeight': 900,
      });

      expect(restored.fontSize, EditorTypography.minFontSize);
      expect(restored.lineHeight, EditorTypography.maxLineHeight);
      expect(restored.lineWidth, EditorTypography.minLineWidth);
      expect(restored.fontWeightValue, EditorTypography.defaultFontWeight,
          reason: '900 不在允许的三档里');
    });

    test('偏小的越界值被抬到下限', () {
      final restored = EditorTypography.fromJson(<String, dynamic>{
        'fontSize': 1,
        'lineHeight': 0.1,
      });
      expect(restored.fontSize, EditorTypography.minFontSize);
      expect(restored.lineHeight, EditorTypography.minLineHeight);
    });

    test('NaN 和无穷大退回默认（它们会直接把布局算崩）', () {
      final restored = EditorTypography.fromJson(<String, dynamic>{
        'fontSize': double.nan,
        'lineHeight': double.infinity,
        'lineWidth': double.negativeInfinity,
      });
      expect(restored.fontSize, EditorTypography.defaultFontSize);
      expect(restored.lineHeight, EditorTypography.defaultLineHeight);
      expect(restored.lineWidth, EditorTypography.defaultLineWidth);
    });

    test('范围内的值原样保留', () {
      final restored = EditorTypography.fromJson(<String, dynamic>{
        'fontSize': 20,
        'lineHeight': 2.0,
        'lineWidth': 800,
      });
      expect(restored.fontSize, 20);
      expect(restored.lineHeight, 2.0);
      expect(restored.lineWidth, 800);
    });
  });
}
