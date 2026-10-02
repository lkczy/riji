/// 编辑器排版设置：只决定「怎么显示」，不决定「存了什么」。
///
/// 刻意和日记数据完全分开，而且**永远不写进日记文件**。
/// 正文是纯文本，换台机器、换个程序打开，内容都一样；
/// 排版是各人看着舒服就好的事，不该跟着文件跑，也不该在同步时互相覆盖。
library;

class EditorTypography {
  const EditorTypography({
    this.fontSize = defaultFontSize,
    this.lineHeight = defaultLineHeight,
    this.fontWeightValue = defaultFontWeight,
    this.lineWidth = defaultLineWidth,
  });

  static const double minFontSize = 13;
  static const double maxFontSize = 28;
  static const double defaultFontSize = 16;

  static const double minLineHeight = 1.3;
  static const double maxLineHeight = 2.8;
  static const double defaultLineHeight = 1.9;

  /// 只给三档：再多就容易陷入"哪个更好看"的纠结，
  /// 而正文粗细的区别也就只有这几档是肉眼可辨的。
  static const List<int> allowedWeights = <int>[400, 500, 600];
  static const int defaultFontWeight = 400;

  static const double minLineWidth = 520;
  static const double maxLineWidth = 1100;
  static const double defaultLineWidth = 760;

  /// 正文字号，逻辑像素。
  final double fontSize;

  /// 行距倍数，直接对应 `TextStyle.height`。
  final double lineHeight;

  /// 字重，取值为 [allowedWeights] 里的一个（对应 FontWeight.w400/w500/w600）。
  final int fontWeightValue;

  /// 正文最大行宽。横跨 4K 屏幕的一行字没法读，所以要限制。
  final double lineWidth;

  static const EditorTypography defaults = EditorTypography();

  EditorTypography copyWith({
    double? fontSize,
    double? lineHeight,
    int? fontWeightValue,
    double? lineWidth,
  }) {
    return EditorTypography(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      fontWeightValue: fontWeightValue ?? this.fontWeightValue,
      lineWidth: lineWidth ?? this.lineWidth,
    );
  }

  bool get isDefault => this == defaults;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'fontWeight': fontWeightValue,
        'lineWidth': lineWidth,
      };

  /// 从设置里还原。
  ///
  /// 每个值都**夹回合法范围**：设置文件被手工改坏、或者以后调整了取值范围，
  /// 都不该让界面出现 0 号字、10 倍行距这种把正文彻底毁掉的状态。
  static EditorTypography fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return EditorTypography(
      fontSize: _clampDouble(
        json['fontSize'], minFontSize, maxFontSize, defaultFontSize),
      lineHeight: _clampDouble(
        json['lineHeight'], minLineHeight, maxLineHeight, defaultLineHeight),
      fontWeightValue: _clampWeight(json['fontWeight']),
      lineWidth: _clampDouble(
        json['lineWidth'], minLineWidth, maxLineWidth, defaultLineWidth),
    );
  }

  static double _clampDouble(
    Object? value,
    double min,
    double max,
    double fallback,
  ) {
    if (value is! num) return fallback;
    final asDouble = value.toDouble();
    if (asDouble.isNaN || asDouble.isInfinite) return fallback;
    return asDouble.clamp(min, max);
  }

  static int _clampWeight(Object? value) {
    if (value is! num) return defaultFontWeight;
    final asInt = value.toInt();
    return allowedWeights.contains(asInt) ? asInt : defaultFontWeight;
  }

  @override
  bool operator ==(Object other) =>
      other is EditorTypography &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.fontWeightValue == fontWeightValue &&
      other.lineWidth == lineWidth;

  @override
  int get hashCode =>
      Object.hash(fontSize, lineHeight, fontWeightValue, lineWidth);

  @override
  String toString() => 'EditorTypography(${fontSize}px, 行距 $lineHeight, '
      '字重 $fontWeightValue, 行宽 ${lineWidth.toInt()})';
}
