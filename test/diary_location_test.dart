import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/diary_location.dart';

/// 「能不能切到这个位置、切了会怎样」是纯函数，所以可以彻底测。
/// 这一层的每条判断都关系到用户会不会以为自己的日记丢了，不能靠手点界面去试。
void main() {
  const currentRoot = r'C:\Users\someone\Documents\riji';

  DiaryLocationFacts facts({
    String raw = r'D:\日记',
    String? normalized,
    String current = currentRoot,
    int currentEntryCount = 10,
    bool exists = true,
    bool isDirectory = true,
    bool writable = true,
    int entryCount = 0,
    int conflictCount = 0,
    int foreignMarkdown = 0,
    int subdirectoryCount = 5,
    DriveKind driveKind = DriveKind.fixed,
    bool inspectionFailed = false,
  }) {
    return DiaryLocationFacts(
      rawPath: raw,
      normalizedPath: normalized ?? raw,
      currentRoot: current,
      currentEntryCount: currentEntryCount,
      exists: exists,
      isDirectory: isDirectory,
      writable: writable,
      entryCount: entryCount,
      conflictCount: conflictCount,
      foreignMarkdownCount: foreignMarkdown,
      subdirectoryCount: subdirectoryCount,
      driveKind: driveKind,
      inspectionFailed: inspectionFailed,
    );
  }

  bool hasError(DiaryLocationAssessment a, String fragment) =>
      a.errors.any((n) => n.message.contains(fragment));

  bool hasWarning(DiaryLocationAssessment a, String fragment) =>
      a.warnings.any((n) => n.message.contains(fragment));

  bool hasInfo(DiaryLocationAssessment a, String fragment) => a.notices
      .any((n) => n.severity == NoticeSeverity.info && n.message.contains(fragment));

  group('looksAbsolute', () {
    test('Windows 盘符路径', () {
      expect(looksAbsolute(r'D:\日记'), isTrue);
      expect(looksAbsolute(r'D:/日记'), isTrue);
      expect(looksAbsolute('c:\\x'), isTrue);
    });

    test('UNC 网络路径', () {
      expect(looksAbsolute(r'\\server\share'), isTrue);
    });

    test('POSIX 路径（将来手机端要用）', () {
      expect(looksAbsolute('/home/user/diary'), isTrue);
    });

    test('相对路径要被拒绝', () {
      expect(looksAbsolute('日记'), isFalse);
      expect(looksAbsolute(r'日记\子目录'), isFalse);
      expect(looksAbsolute(r'..\diary'), isFalse);
    });

    test('光有盘符没有分隔符不算绝对路径', () {
      // D: 表示"当前盘上的当前位置"，含义会变，不能用
      expect(looksAbsolute('D:'), isFalse);
    });

    test('空串', () {
      expect(looksAbsolute(''), isFalse);
    });
  });

  group('硬性错误：必须拦住，不能切换', () {
    test('路径为空', () {
      final a = assessDiaryLocation(facts(raw: '', normalized: ''));
      expect(a.canSwitch, isFalse);
      expect(hasError(a, '请填写'), isTrue);
    });

    test('相对路径', () {
      final a = assessDiaryLocation(facts(raw: '日记', normalized: '日记'));
      expect(a.canSwitch, isFalse);
      expect(hasError(a, '完整路径'), isTrue);
    });

    test('路径指向文件而不是文件夹', () {
      final a = assessDiaryLocation(facts(isDirectory: false));
      expect(a.canSwitch, isFalse);
      expect(hasError(a, '不是文件夹'), isTrue);
    });

    test('没有写入权限', () {
      final a = assessDiaryLocation(facts(writable: false));
      expect(a.canSwitch, isFalse);
      expect(hasError(a, '没有写入权限'), isTrue);
    });

    test('和当前位置相同（大小写不敏感）', () {
      final a = assessDiaryLocation(facts(
        normalized: r'c:\users\SOMEONE\documents\Riji',
      ));
      expect(a.canSwitch, isFalse);
      expect(hasError(a, '已经是当前'), isTrue);
    });

    test('检查过程失败', () {
      final a = assessDiaryLocation(facts(inspectionFailed: true));
      expect(a.canSwitch, isFalse);
      expect(hasError(a, '无法检查'), isTrue);
    });
  });

  group('最关键的一条：不能让用户以为日记丢了', () {
    test('目标为空而当前位置有内容 → 警告，并明说文件没被删除', () {
      final a = assessDiaryLocation(facts(entryCount: 0, currentEntryCount: 10));

      expect(a.canSwitch, isTrue, reason: '这是合法操作，不该拦住');
      expect(hasWarning(a, '一篇日记都没有'), isTrue);
      expect(hasWarning(a, '没有被删除'), isTrue);
      expect(hasWarning(a, '复制'), isTrue, reason: '要告诉用户怎么把日记搬过去');
    });

    test('目标已有日记 → 中性说明，同样不阻塞', () {
      final a = assessDiaryLocation(facts(entryCount: 7, currentEntryCount: 10));

      expect(a.canSwitch, isTrue);
      expect(hasInfo(a, '已经有 7 篇日记'), isTrue);
      expect(hasInfo(a, '不会被删除'), isTrue);
      expect(hasWarning(a, '一篇日记都没有'), isFalse);
    });

    test('当前位置本来就是空的，就不用吓唬用户', () {
      final a = assessDiaryLocation(facts(entryCount: 0, currentEntryCount: 0));
      expect(hasWarning(a, '一篇日记都没有'), isFalse);
    });
  });

  group('通用文件夹的风险', () {
    test('里面有别的 .md 文件 → 警告会被误当成日记', () {
      final a = assessDiaryLocation(facts(foreignMarkdown: 3));
      expect(hasWarning(a, 'YYYY-MM-DD.md'), isTrue);
    });

    test('子文件夹很多 → 警告像个通用目录', () {
      final a = assessDiaryLocation(facts(subdirectoryCount: 200));
      expect(hasWarning(a, '通用目录'), isTrue);
    });

    test('正常的专用文件夹不该有这些警告', () {
      final a = assessDiaryLocation(facts(foreignMarkdown: 0, subdirectoryCount: 3));
      expect(a.warnings.where((n) => n.message.contains('通用目录')), isEmpty);
      expect(a.warnings.where((n) => n.message.contains('YYYY-MM-DD.md')), isEmpty);
    });
  });

  group('磁盘类型', () {
    test('可移动磁盘', () {
      final a = assessDiaryLocation(facts(driveKind: DriveKind.removable));
      expect(hasWarning(a, '可移动磁盘'), isTrue);
      expect(a.canSwitch, isTrue);
    });

    test('网络磁盘', () {
      final a = assessDiaryLocation(facts(driveKind: DriveKind.network));
      expect(hasWarning(a, '网络磁盘'), isTrue);
    });

    test('本地固定磁盘不该报这两条', () {
      final a = assessDiaryLocation(facts(driveKind: DriveKind.fixed));
      expect(hasWarning(a, '可移动磁盘'), isFalse);
      expect(hasWarning(a, '网络磁盘'), isFalse);
    });
  });

  group('加密提醒', () {
    test('始终提醒无法检测磁盘加密状态', () {
      final a = assessDiaryLocation(facts());
      expect(hasInfo(a, 'BitLocker'), isTrue);
      expect(hasInfo(a, '明文'), isTrue);
    });

    test('有错误时不提加密（先解决问题）', () {
      final a = assessDiaryLocation(facts(writable: false));
      // 加密提醒只在 canSwitch 时给出，避免在用户还没法切换时堆一堆话
      expect(hasInfo(a, 'BitLocker'), isFalse);
    });
  });

  group('suggestCopy：决定界面要不要默认勾选复制', () {
    test('目标为空且当前位置有内容 → 建议复制', () {
      final a = assessDiaryLocation(facts(entryCount: 0, currentEntryCount: 10));
      expect(a.suggestCopy, isTrue);
    });

    test('目标已有内容 → 不建议复制，避免覆盖目标位置的东西', () {
      final a = assessDiaryLocation(facts(entryCount: 5, currentEntryCount: 10));
      expect(a.suggestCopy, isFalse);
    });

    test('当前位置是空的 → 没什么可复制的', () {
      final a = assessDiaryLocation(facts(entryCount: 0, currentEntryCount: 0));
      expect(a.suggestCopy, isFalse);
    });

    test('目标还不存在 → 算空目标', () {
      final a = assessDiaryLocation(facts(
        exists: false,
        isDirectory: false,
        writable: true,
        entryCount: 0,
        currentEntryCount: 10,
      ));
      expect(a.canSwitch, isTrue);
      expect(a.suggestCopy, isTrue);
    });

    test('有硬性错误时绝不建议复制', () {
      final a = assessDiaryLocation(facts(writable: false));
      expect(a.canSwitch, isFalse);
      expect(a.suggestCopy, isFalse);
    });
  });

  group('冲突文件与新位置不存在', () {
    test('新位置有冲突文件时给出中性提示', () {
      final a = assessDiaryLocation(facts(conflictCount: 2));
      expect(hasInfo(a, '冲突'), isTrue);
    });

    test('目标不存在时说明会被创建', () {
      final a = assessDiaryLocation(facts(exists: false, isDirectory: false));
      expect(hasInfo(a, '会被创建'), isTrue);
    });
  });
}
