import 'package:flutter/material.dart';

import '../core/editor_typography.dart';
import '../state/settings_controller.dart';
import 'theme.dart';

/// 字体与行距设置。
///
/// 改动**即时生效**，没有取消按钮：这类"看着调"的设置，先改再看的反馈回路
/// 越短越好，加一层"应用/取消"反而让人不敢动。想退回去就点「恢复默认」。
class TypographyDialog extends StatelessWidget {
  const TypographyDialog({super.key, required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    // 只订阅偏好控制器：调字号不该导致日记被重新读取。
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final typography = settings.typography;

        return AlertDialog(
          title: const Text('字体与行距'),
          content: SizedBox(
            width: 580,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _buildPreview(context, typography),
                  const SizedBox(height: 16),
                  _buildSlider(
                    context,
                    label: '字号',
                    value: typography.fontSize,
                    min: EditorTypography.minFontSize,
                    max: EditorTypography.maxFontSize,
                    display: '${typography.fontSize.round()} px',
                    onChanged: (value) => settings.setTypography(
                      typography.copyWith(fontSize: value),
                    ),
                  ),
                  _buildSlider(
                    context,
                    label: '行距',
                    value: typography.lineHeight,
                    min: EditorTypography.minLineHeight,
                    max: EditorTypography.maxLineHeight,
                    display: typography.lineHeight.toStringAsFixed(1),
                    onChanged: (value) => settings.setTypography(
                      typography.copyWith(lineHeight: value),
                    ),
                  ),
                  _buildSlider(
                    context,
                    label: '行宽',
                    value: typography.lineWidth,
                    min: EditorTypography.minLineWidth,
                    max: EditorTypography.maxLineWidth,
                    display: '${typography.lineWidth.round()} px',
                    onChanged: (value) => settings.setTypography(
                      typography.copyWith(lineWidth: value),
                    ),
                  ),
                  const SizedBox(height: 6),
                  _buildWeightPicker(context, typography),
                  const SizedBox(height: 10),
                  Text(
                    '这些设置只影响显示，不会写进日记文件——'
                    '正文始终是纯文本，换台机器打开看到的内容一模一样。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: typography.isDefault ? null : settings.resetTypography,
              child: const Text('恢复默认'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('完成'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPreview(BuildContext context, EditorTypography typography) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '预览',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '今天把字号和行距调了一下。\n'
            '一屏能看到的字少了，但一段话读起来顺多了。',
            style: TextStyle(
              fontSize: typography.fontSize,
              height: typography.lineHeight,
              fontWeight: fontWeightFor(typography.fontWeightValue),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSlider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    final theme = Theme.of(context);

    return Row(
      children: <Widget>[
        SizedBox(
          width: 48,
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWeightPicker(
    BuildContext context,
    EditorTypography typography,
  ) {
    final theme = Theme.of(context);

    return Row(
      children: <Widget>[
        SizedBox(
          width: 48,
          child: Text('字重', style: theme.textTheme.bodyMedium),
        ),
        Expanded(
          child: SegmentedButton<int>(
            segments: <ButtonSegment<int>>[
              for (final weight in EditorTypography.allowedWeights)
                ButtonSegment<int>(
                  value: weight,
                  label: Text(fontWeightLabel(weight)),
                ),
            ],
            selected: <int>{typography.fontWeightValue},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => settings.setTypography(
              typography.copyWith(fontWeightValue: selection.first),
            ),
          ),
        ),
      ],
    );
  }
}
