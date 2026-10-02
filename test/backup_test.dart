import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/backup.dart';

void main() {
  group('哪些东西进备份', () {
    test('历史版本和回收站要进备份（和同步的规则相反）', () {
      expect(isExcludedFromBackup('2026/2026-10-02.md'), isFalse);
      expect(
        isExcludedFromBackup('.history/2026-10-02/113000-opened.md'),
        isFalse,
        reason: '出错之后最想要的就是历史版本，必须进备份',
      );
      expect(isExcludedFromBackup('.trash/2026-10-02.md.123.deleted'), isFalse);
    });

    test('过程痕迹不进备份', () {
      expect(isExcludedFromBackup('.drafts/2026-10-02.md'), isTrue);
      expect(isExcludedFromBackup('2026/2026-10-02.md.tmp-a1b2'), isTrue);
      expect(isExcludedFromBackup('.index.sqlite'), isTrue);
      expect(isExcludedFromBackup('.stfolder'), isTrue);
      expect(isExcludedFromBackup('.stversions/2026-10-02.md'), isTrue);
    });

    test('反斜杠路径也认（Windows）', () {
      expect(isExcludedFromBackup(r'2026\2026-10-02.md'), isFalse);
      expect(isExcludedFromBackup(r'.drafts\2026-10-02.md'), isTrue);
    });
  });

  group('快照命名', () {
    final at = DateTime(2026, 10, 2, 22, 10);

    test('自动快照只到日期（一天至多一份）', () {
      expect(snapshotDirName(SnapshotKind.auto, at), '2026-10-02');
    });

    test('手动快照到分钟，可带说明', () {
      expect(snapshotDirName(SnapshotKind.manual, at), '2026-10-02 2210');
      expect(
        snapshotDirName(SnapshotKind.manual, at, label: '改主题之前'),
        '2026-10-02 2210 改主题之前',
      );
    });

    test('同一分钟再备份一次会补后缀', () {
      expect(
        snapshotDirName(SnapshotKind.manual, at, collision: true),
        '2026-10-02 2210-2',
      );
    });

    test('说明里的非法字符会被换掉（否则整个备份会失败）', () {
      expect(sanitizeLabel('a/b:c*d?e"f<g>h|i'), 'a_b_c_d_e_f_g_h_i');
      expect(sanitizeLabel('结尾有点...'), '结尾有点');
      expect(sanitizeLabel('  多余   空格  '), '多余 空格');
      expect(snapshotDirName(SnapshotKind.manual, at, label: 'a/b'),
          '2026-10-02 2210 a_b');
    });
  });

  group('解析目录名', () {
    test('认得出自动和手动', () {
      final auto = SnapshotName.parse('2026-10-02')!;
      expect(auto.at, DateTime(2026, 10, 2));
      expect(auto.label, isNull);

      final manual = SnapshotName.parse('2026-10-02 2210 改主题之前')!;
      expect(manual.at, DateTime(2026, 10, 2, 22, 10));
      expect(manual.label, '改主题之前');

      expect(SnapshotName.parse('2026-10-02 2210-2')!.sequence, 2);
    });

    test('认不出来的一律返回 null', () {
      for (final bad in <String>[
        '随便一个名字',
        '我的照片',
        '2026-10-02 备份',
        '2026-13-45',
        '2026-10-02 2500',
        '',
      ]) {
        expect(SnapshotName.parse(bad), isNull, reason: '不该认出来：$bad');
      }
    });
  });

  group('保留策略', () {
    // 用真实日期算，避免生成 10-32 这种非法日期（那会被解析器正确拒掉，
    // 于是测出来的是"测试写错了"，而不是代码有问题）
    List<String> days(int count) => List<String>.generate(count, (i) {
          final d = DateTime(2026, 1, 1).add(Duration(days: i));
          return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
              '${d.day.toString().padLeft(2, '0')}';
        });

    test('不超过上限时一份都不删', () {
      expect(autoSnapshotsToDelete(days(30)), isEmpty);
      expect(autoSnapshotsToDelete(days(30), limit: 5).length, 25);
    });

    test('超出时删最旧的，保留最新的', () {
      final victims = autoSnapshotsToDelete(days(35));
      expect(victims.length, 5);
      expect(victims, days(5), reason: '删的应该是最早那 5 天');
    });

    test('认不出名字的目录绝不删（备份根里可能有别的东西）', () {
      const protected = <String>[
        '我的照片',
        '重要资料',
        '2026-13-45',
        // 带说明、但没时间的目录名 —— 用户很可能自己这么起名。
        // 解析器必须认不出来，否则它会被当成快照删掉。
        '2026-10-02 我的备份',
      ];
      final names = <String>[...days(35), ...protected];

      final victims = autoSnapshotsToDelete(names);
      expect(victims.length, 5, reason: '只该删那 5 个超期的快照');
      for (final name in protected) {
        expect(victims, isNot(contains(name)), reason: '$name 不该被删');
      }
    });

    test('今天有没有自动快照', () {
      final today = DateTime(2026, 10, 2);
      expect(hasAutoSnapshotToday(<String>['2026-10-02'], today), isTrue);
      expect(hasAutoSnapshotToday(<String>['2026-10-01'], today), isFalse);
      expect(hasAutoSnapshotToday(<String>['乱名字'], today), isFalse);
    });
  });

  group('备份位置检查', () {
    test('备份目录在日记目录里面 → 拒绝（会递归）', () {
      final check = checkBackupTarget(
        diaryRoot: r'D:\someone\MyData',
        backupRoot: r'D:\someone\MyData\备份',
      );
      expect(check.allowed, isFalse);
      expect(check.nested, isTrue);
    });

    test('日记目录在备份目录里面 → 也拒绝（下一份会把上一份拷进去）', () {
      final check = checkBackupTarget(
        diaryRoot: r'D:\someone\MyData',
        backupRoot: r'D:\someone',
      );
      expect(check.allowed, isFalse);
    });

    test('同一个目录 → 拒绝', () {
      expect(
        checkBackupTarget(
          diaryRoot: r'D:\someone\MyData',
          backupRoot: r'D:\someone\MyData',
        ).allowed,
        isFalse,
      );
    });

    test('完全分开 → 允许；大小写和结尾斜杠不影响判断', () {
      expect(
        checkBackupTarget(
          diaryRoot: r'D:\someone\MyData',
          backupRoot: r'E:\日记备份',
        ).allowed,
        isTrue,
      );
      expect(
        checkBackupTarget(
          diaryRoot: r'D:\someone\MyData',
          backupRoot: r'D:\someone\MyData备份\',
        ).allowed,
        isTrue,
        reason: 'MyData备份 不是 MyData 的子目录，名字像而已',
      );
    });

    test('同卷只提示、不拒绝（并如实说明判断不了物理盘）', () {
      final check = checkBackupTarget(
        diaryRoot: r'D:\someone\MyData',
        backupRoot: r'D:\日记备份',
      );
      expect(check.allowed, isTrue, reason: '同盘挡不住盘坏，但那是警告不是禁止');
      expect(check.sameVolume, isTrue);

      expect(
        checkBackupTarget(
          diaryRoot: r'D:\someone\MyData',
          backupRoot: r'E:\日记备份',
        ).sameVolume,
        isFalse,
      );
    });
  });

  group('内容有没有变', () {
    FileStamp stamp(String path, int size, DateTime modified) =>
        FileStamp(path: path, size: size, modified: modified);

    final base = <FileStamp>[
      stamp('2026/2026-10-02.md', 100, DateTime(2026, 10, 2, 10)),
      stamp('2026/2026-10-01.md', 200, DateTime(2026, 10, 1, 10)),
    ];

    test('一模一样 → 没变（自动备份据此跳过，不产生多余文件）', () {
      expect(hasChanges(base, List<FileStamp>.of(base)), isFalse);
      expect(hasChanges(base, base.reversed.toList()), isFalse, reason: '顺序不该影响判断');
    });

    test('内容改了 / 多了 / 少了 → 变了', () {
      expect(
        hasChanges(base, <FileStamp>[
          stamp('2026/2026-10-02.md', 101, DateTime(2026, 10, 2, 10)),
          base[1],
        ]),
        isTrue,
      );
      expect(hasChanges(base, <FileStamp>[base[0]]), isTrue);
      expect(
        hasChanges(base, <FileStamp>[...base, stamp('2026/2026-10-03.md', 1, DateTime(2026, 10, 3))]),
        isTrue,
      );
    });

    test('修改时间变了 → 算变了（内容可能没变，但这个判断不该读内容）', () {
      expect(
        hasChanges(base, <FileStamp>[
          stamp('2026/2026-10-02.md', 100, DateTime(2026, 10, 2, 11)),
          base[1],
        ]),
        isTrue,
      );
    });
  });

  group('清单', () {
    test('写出来再读回去，指纹一致', () {
      final files = <FileStamp>[
        FileStamp(
          path: '2026/2026-10-02.md',
          size: 1234,
          modified: DateTime(2026, 10, 2, 10, 30),
        ),
        FileStamp(
          path: '.trash/2026-10-01.md.1.deleted',
          size: 567,
          modified: DateTime(2026, 10, 1, 21),
        ),
      ];
      final text = renderManifest(
        kind: SnapshotKind.manual,
        at: DateTime(2026, 10, 2, 22, 10),
        source: r'D:\someone\MyData',
        label: '改主题之前',
        files: files,
        checksums: <String, String>{'2026/2026-10-02.md': 'abc123'},
      );

      expect(text, contains('riji 备份清单'));
      expect(text, contains('类型: 手动'));
      expect(text, contains('说明: 改主题之前'));
      expect(text, contains(r'来源: D:\someone\MyData'));
      expect(text, contains('文件数: 2'));
      expect(text, contains('总字节: 1801'));
      expect(text, contains('abc123'));

      final stamps = parseManifestStamps(text);
      expect(stamps.length, 2);
      // 清单按路径排序，`.` (0x2E) < `2` (0x32)，所以 .trash 在前面
      expect(
        stamps.map((s) => s.path).toList(),
        <String>['.trash/2026-10-01.md.1.deleted', '2026/2026-10-02.md'],
      );
      final diary = stamps.firstWhere((s) => s.path == '2026/2026-10-02.md');
      expect(diary.size, 1234);
      expect(diary.modified, DateTime(2026, 10, 2, 10, 30));
    });

    test('清单读不动不该让流程崩（解析不了的行跳过）', () {
      final broken = 'riji 备份清单\n时间: 2026-10-02 2210\n---\n'
          '这是垃圾行\n'
          '路径\t不是数字\t也不是时间\n'
          '2026/2026-10-02.md\t100\t2026-10-02T10:00:00.000\n';
      final stamps = parseManifestStamps(broken);
      expect(stamps.length, 1);
      expect(stamps.single.path, '2026/2026-10-02.md');
    });
  });
}
