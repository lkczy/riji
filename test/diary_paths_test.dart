import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/diary_paths.dart';

void main() {
  group('日期到路径', () {
    test('文件名', () {
      expect(DiaryPaths.fileNameFor(DateTime(2026, 2, 14)), '2026-02-14.md');
    });

    test('路径片段按年分目录，避免单目录堆上万个文件', () {
      expect(
        DiaryPaths.segmentsFor(DateTime(2026, 2, 14)),
        <String>['2026', '2026-02-14.md'],
      );
      expect(
        DiaryPaths.segmentsFor(DateTime(2026, 1, 5)),
        <String>['2026', '2026-01-05.md'],
      );
    });

    test('从文件名还原日期', () {
      expect(DiaryPaths.dateFromFileName('2026-02-14.md'), DateTime(2026, 2, 14));
      expect(DiaryPaths.dateFromFileName('随便.md'), isNull);
      expect(DiaryPaths.dateFromFileName('2026-13-01.md'), isNull);
      expect(DiaryPaths.dateFromFileName('2026-02-14.txt'), isNull);
    });
  });

  group('冲突文件识别', () {
    test('识别我们自己产生的冲突文件', () {
      final name = DiaryPaths.conflictFileNameFor(
        DateTime(2026, 2, 14),
        DateTime(2026, 2, 14, 21, 40, 2),
        'desktop-abc123',
      );
      expect(name, '2026-02-14.conflict-20260214T214002-desktop-abc123.md');
      expect(DiaryPaths.isConflictFileName(name), isTrue);
      expect(DiaryPaths.conflictDateFromFileName(name), DateTime(2026, 2, 14));
    });

    test('识别 Syncthing 产生的冲突文件', () {
      const name = '2026-02-14.sync-conflict-20260214-214002-ABCDEFG.md';
      expect(DiaryPaths.isConflictFileName(name), isTrue);
      expect(DiaryPaths.conflictDateFromFileName(name), DateTime(2026, 2, 14));
    });

    test('冲突文件不能被当成正常日记加载', () {
      const name = '2026-02-14.sync-conflict-20260214-214002-ABCDEFG.md';
      expect(DiaryPaths.isDiaryFileName(name), isFalse);
    });

    test('正常日记不算冲突', () {
      expect(DiaryPaths.isConflictFileName('2026-02-14.md'), isFalse);
    });

    test('冲突文件名里的设备名已净化，不会产生非法路径', () {
      final name = DiaryPaths.conflictFileNameFor(
        DateTime(2026, 2, 14),
        DateTime(2026, 2, 14, 1, 2, 3),
        r'我的电脑\C:',
      );
      for (final illegal in <String>['\\', '/', ':', '*', '?', '"', '<', '>', '|']) {
        expect(name.contains(illegal), isFalse, reason: '不该含 $illegal：$name');
      }
      expect(DiaryPaths.isConflictFileName(name), isTrue);
    });
  });

  group('设备名净化', () {
    test('去掉 Windows 文件名非法字符', () {
      expect(
        DiaryPaths.sanitizeDevice(r'a\b/c:d*e?f"g<h>i|j'),
        'a-b-c-d-e-f-g-h-i-j',
      );
    });

    test('空名字回退成 unknown', () {
      expect(DiaryPaths.sanitizeDevice(''), 'unknown');
    });
  });

  group('草稿与同步忽略', () {
    test('草稿路径', () {
      expect(
        DiaryPaths.draftSegmentsFor(DateTime(2026, 2, 14)),
        <String>['.drafts', '2026-02-14.draft'],
      );
    });

    test('派生物都在同步忽略列表里', () {
      expect(DiaryPaths.syncIgnorePatterns, contains('.index.sqlite'));
      expect(DiaryPaths.syncIgnorePatterns, contains('.drafts'));
    });
  });
}
