import 'package:flutter_test/flutter_test.dart';
import 'package:riji/core/command_palette.dart';

/// 命令面板的**搜索与排序**。
///
/// 这一层值得单独测，因为面板好不好用几乎全在这里：搜「深色」能不能命中
/// 「外观：深色」、它排第一条还是第五条。这类判断在界面上"看起来差不多"，
/// 只有量出来才知道改一行权重有没有把别的搜索弄坏。
void main() {
  /// 一份和真实命令表同构的样本：标题带全角冒号、别名是用户真会打的词。
  const commands = <PaletteCommand>[
    PaletteCommand(
      id: 'data.backup',
      title: '备份',
      subtitle: '还没设备份位置',
      keywords: <String>['备份', '快照', '存档', 'backup'],
    ),
    PaletteCommand(
      id: 'appearance.typography',
      title: '字体与行距',
      keywords: <String>['字体', '字号', '行距', '行宽', '字重', '排版'],
    ),
    PaletteCommand(
      id: 'appearance.dark',
      title: '外观：深色',
      keywords: <String>['外观', '主题', '深色', '暗色', '夜间', 'dark'],
    ),
    PaletteCommand(
      id: 'appearance.light',
      title: '外观：浅色',
      keywords: <String>['外观', '主题', '浅色', '白天', 'light'],
    ),
    PaletteCommand(
      id: 'format.underline',
      title: '下划线',
      keywords: <String>['下划线', 'underline', '格式'],
    ),
    PaletteCommand(
      id: 'data.delete',
      title: '删除这一天的日记',
      keywords: <String>['删除', '移除', '回收站', 'delete'],
      enabled: false,
      disabledReason: '这一天还没写东西',
    ),
  ];

  List<String> idsFor(String query) => <String>[
        for (final command in filterCommands(query, commands)) command.id,
      ];

  group('空查询', () {
    test('空查询返回全部，且保持注册顺序', () {
      // 注册顺序是刻意排的（日常在上、破坏性的在下），空查询时打乱它没有好处。
      expect(idsFor(''), <String>[
        'data.backup',
        'appearance.typography',
        'appearance.dark',
        'appearance.light',
        'format.underline',
        'data.delete',
      ]);
    });

    test('只有空格也算空查询', () {
      expect(idsFor('   ').length, commands.length);
    });
  });

  group('匹配', () {
    test('别名能命中：想切夜间模式的人会打「暗」或「夜间」', () {
      expect(idsFor('夜间'), <String>['appearance.dark']);
      expect(idsFor('暗色'), <String>['appearance.dark']);
    });

    test('子序列匹配：打「字行」也能搜到「字体与行距」', () {
      expect(idsFor('字行'), contains('appearance.typography'));
    });

    test('英文别名同样能命中，且大小写不敏感', () {
      expect(idsFor('DARK'), <String>['appearance.dark']);
      expect(idsFor('under'), <String>['format.underline']);
    });

    test('匹配不上就是空，不要硬塞几条无关的进来', () {
      expect(idsFor('这个程序里没有这种功能'), isEmpty);
    });

    test('关键词字符顺序不对就不该命中', () {
      // 「距行」不是「行距」的子序列
      expect(idsFor('距行'), isEmpty);
    });
  });

  group('排序', () {
    test('标题命中优先于别名命中', () {
      // 「深色」既是 dark 的标题一部分，也是它的别名。要验证的是：
      // 一条**只在别名里**出现「深色」的命令，不能挤到标题命中的前面。
      const withAliasOnly = <PaletteCommand>[
        PaletteCommand(
          id: 'aliasOnly',
          title: '别的东西',
          keywords: <String>['深色'],
        ),
        PaletteCommand(
          id: 'inTitle',
          title: '外观：深色',
          keywords: <String>['外观'],
        ),
      ];

      expect(
        <String>[
          for (final c in filterCommands('深色', withAliasOnly)) c.id,
        ],
        <String>['inTitle', 'aliasOnly'],
        reason: '用户打的是他在界面上看到的字，标题命中必须排在最前',
      );
    });

    test('连续命中优先于跳着命中', () {
      const scattered = <PaletteCommand>[
        // 「行」在第 0 位、「距」在第 3 位，中间隔着一个字
        PaletteCommand(id: 'scattered', title: '行程与距离'),
        // 「行距」连着
        PaletteCommand(id: 'contiguous', title: '字体与行距'),
      ];

      expect(
        <String>[
          for (final c in filterCommands('行距', scattered)) c.id,
        ],
        <String>['contiguous', 'scattered'],
        reason: '连续命中是最可靠的信号，权重必须压过"离词首更近"',
      );
    });

    test('同样命中时，名字短的排前面', () {
      const samePrefix = <PaletteCommand>[
        PaletteCommand(id: 'long', title: '备份（含历史快照与离线副本）'),
        PaletteCommand(id: 'short', title: '备份'),
      ];

      expect(
        <String>[
          for (final c in filterCommands('备份', samePrefix)) c.id,
        ],
        <String>['short', 'long'],
      );
    });
  });

  group('多词是「与」关系', () {
    test('两个词都命中才算命中', () {
      // 「外观 深色」只该剩下深色那一条：浅色那条虽然也是"外观"，
      // 但第二个词命中不了。
      expect(idsFor('外观 深色'), <String>['appearance.dark']);
    });

    test('词序无关', () {
      expect(idsFor('深色 外观'), idsFor('外观 深色'));
    });
  });

  group('禁用的命令', () {
    test('禁用不等于搜不到——禁用而不是隐藏', () {
      // 这一条守的是项目的既定原则：做不到的功能要**显示出来并说明原因**。
      // 如果搜索把禁用项滤掉了，「删除」在空日记那天就会凭空消失，
      // 用户会以为程序没这个功能。
      final results = filterCommands('删除', commands);
      expect(results.map((c) => c.id), contains('data.delete'));
      expect(results.first.enabled, isFalse);
      expect(results.first.disabledReason, '这一天还没写东西');
    });
  });

  group('稳定性', () {
    test('同一个查询每次得到同样的顺序', () {
      // 排序不稳定的话，用户会觉得列表在自己乱跳。
      expect(idsFor('外观'), idsFor('外观'));
      expect(idsFor('外观'), <String>['appearance.dark', 'appearance.light']);
    });
  });
}
