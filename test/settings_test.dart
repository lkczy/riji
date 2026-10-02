import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/editor_typography.dart';
import 'package:riji/data/settings.dart';
import 'package:riji/state/settings_controller.dart';

/// 偏好逻辑的纯 Dart 测试。不碰真实文件系统，也不碰 `%APPDATA%`。
class _FakeSettingsRepository extends SettingsRepository {
  AppSettings? saved;
  int saveCount = 0;

  @override
  Future<AppSettings> load() async =>
      saved ?? const AppSettings(diaryRoot: '/fallback');

  @override
  Future<void> save(AppSettings settings) async {
    saved = settings;
    saveCount++;
  }
}

void main() {
  group('AppThemeMode 序列化', () {
    test('每个模式的存储值唯一', () {
      final values =
          AppThemeMode.values.map((m) => m.storageValue).toSet();
      expect(values.length, AppThemeMode.values.length);
    });

    test('往返一致', () {
      for (final mode in AppThemeMode.values) {
        expect(AppThemeMode.fromStorage(mode.storageValue), mode);
      }
    });

    test('不认识的值退回跟随系统，而不是崩掉', () {
      // 将来更高版本可能写入新值，旧版本必须能安全打开
      expect(AppThemeMode.fromStorage('solarized'), AppThemeMode.system);
      expect(AppThemeMode.fromStorage(null), AppThemeMode.system);
      expect(AppThemeMode.fromStorage(42), AppThemeMode.system);
      expect(AppThemeMode.fromStorage(''), AppThemeMode.system);
    });
  });

  group('AppSettings 序列化', () {
    test('往返保留主题模式与日记目录', () {
      const original = AppSettings(
        diaryRoot: r'D:\日记',
        themeMode: AppThemeMode.dark,
      );
      final restored = AppSettings.fromJson(
        original.toJson(),
        fallbackRoot: '/fallback',
      );

      expect(restored.diaryRoot, original.diaryRoot);
      expect(restored.themeMode, AppThemeMode.dark);
    });

    test('缺字段时用默认值', () {
      final restored = AppSettings.fromJson(
        <String, dynamic>{},
        fallbackRoot: '/fallback',
      );
      expect(restored.diaryRoot, '/fallback');
      expect(restored.themeMode, AppThemeMode.system);
    });

    test('日记目录为空串时回退', () {
      final restored = AppSettings.fromJson(
        <String, dynamic>{'diaryRoot': '   '},
        fallbackRoot: '/fallback',
      );
      expect(restored.diaryRoot, '/fallback');
    });

    test('排版设置能往返', () {
      const typography = EditorTypography(
        fontSize: 20,
        lineHeight: 2.2,
        fontWeightValue: 600,
        lineWidth: 900,
      );
      const original = AppSettings(diaryRoot: '/diary', typography: typography);

      final restored = AppSettings.fromJson(
        original.toJson(),
        fallbackRoot: '/x',
      );

      expect(restored.typography, typography);
    });

    test('没有排版字段时用默认值（老设置文件要能继续用）', () {
      final restored = AppSettings.fromJson(
        <String, dynamic>{'diaryRoot': '/diary', 'themeMode': 'dark'},
        fallbackRoot: '/x',
      );
      expect(restored.typography, EditorTypography.defaults);
      expect(restored.themeMode, AppThemeMode.dark);
    });
  });

  group('SettingsController', () {
    test('默认跟随系统', () {
      final controller = SettingsController(
        initial: const AppSettings(diaryRoot: '/diary'),
        repository: _FakeSettingsRepository(),
      );
      expect(controller.themeMode, AppThemeMode.system);
      expect(controller.materialThemeMode, ThemeMode.system);
    });

    test('三种模式映射到对应的 Material ThemeMode', () {
      for (final entry in <AppThemeMode, ThemeMode>{
        AppThemeMode.system: ThemeMode.system,
        AppThemeMode.light: ThemeMode.light,
        AppThemeMode.dark: ThemeMode.dark,
      }.entries) {
        final controller = SettingsController(
          initial: AppSettings(diaryRoot: '/diary', themeMode: entry.key),
          repository: _FakeSettingsRepository(),
        );
        expect(controller.materialThemeMode, entry.value);
      }
    });

    test('切换模式会通知监听者并落盘', () async {
      final repository = _FakeSettingsRepository();
      final controller = SettingsController(
        initial: const AppSettings(diaryRoot: '/diary'),
        repository: repository,
      );

      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.setThemeMode(AppThemeMode.dark);

      expect(controller.themeMode, AppThemeMode.dark);
      expect(notifications, 1);
      expect(repository.saved?.themeMode, AppThemeMode.dark);
      expect(repository.saved?.diaryRoot, '/diary',
          reason: '改外观不能把日记目录一起改掉');
    });

    test('切成同一个模式不会重复通知、也不会重复写盘', () async {
      final repository = _FakeSettingsRepository();
      final controller = SettingsController(
        initial: const AppSettings(diaryRoot: '/diary', themeMode: AppThemeMode.dark),
        repository: repository,
      );

      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.setThemeMode(AppThemeMode.dark);
      await controller.setThemeMode(AppThemeMode.dark);

      expect(notifications, 0);
      expect(repository.saveCount, 0);
    });

    test('连续切换都能落盘', () async {
      final repository = _FakeSettingsRepository();
      final controller = SettingsController(
        initial: const AppSettings(diaryRoot: '/diary'),
        repository: repository,
      );

      await controller.setThemeMode(AppThemeMode.dark);
      await controller.setThemeMode(AppThemeMode.light);
      await controller.setThemeMode(AppThemeMode.system);

      expect(repository.saved?.themeMode, AppThemeMode.system);
      expect(repository.saveCount, 3);
    });

    test('调排版会落盘，且不影响主题和日记目录', () async {
      final repository = _FakeSettingsRepository();
      final controller = SettingsController(
        initial: const AppSettings(
          diaryRoot: '/diary',
          themeMode: AppThemeMode.dark,
        ),
        repository: repository,
      );

      await controller.setTypography(const EditorTypography(fontSize: 22));

      expect(controller.typography.fontSize, 22);
      expect(repository.saved?.typography.fontSize, 22);
      expect(repository.saved?.themeMode, AppThemeMode.dark,
          reason: '改字号不能顺手把主题改掉');
      expect(repository.saved?.diaryRoot, '/diary');
    });

    test('排版设成同一个值不重复写盘', () async {
      final repository = _FakeSettingsRepository();
      final controller = SettingsController(
        initial: const AppSettings(
          diaryRoot: '/diary',
          typography: EditorTypography(fontSize: 20),
        ),
        repository: repository,
      );

      await controller.setTypography(const EditorTypography(fontSize: 20));

      expect(repository.saveCount, 0);
    });

    test('恢复默认排版', () async {
      final repository = _FakeSettingsRepository();
      final controller = SettingsController(
        initial: const AppSettings(
          diaryRoot: '/diary',
          typography: EditorTypography(
            fontSize: 24,
            lineHeight: 2.4,
            fontWeightValue: 600,
            lineWidth: 900,
          ),
        ),
        repository: repository,
      );

      await controller.resetTypography();

      expect(controller.typography, EditorTypography.defaults);
      expect(repository.saved?.typography, EditorTypography.defaults);
    });
  });
}
