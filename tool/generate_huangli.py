# -*- coding: utf-8 -*-
"""生成黄历数据表。

## 数据来源与可验证性（这是本文件最要紧的说明）

黄历里有两类内容，**性质完全不同**，不能一视同仁：

  * **干支（年/月/日）、冲煞** —— 本质是算术。实测 lunar_python 与 cnlunar
    两个独立实现在 730 天里 **100% 一致**，所以这部分是**可验证的**。
    `--verify` 会重新跑这个交叉检查。
  * **宜 / 忌** —— 本质是择日学的规则体系（通书），**没有唯一正确答案**。
    同样两个实现在同一年里**完全一致的日子是 0%**，「宜」条目交并比只有 10.3%。
    所以这部分是**不可验证的**：程序只能如实标注它依据哪一套规则，
    不能把它当成客观事实呈现。

## 为什么宜忌只能查表，不能推算

实测（2026 全年）：365 天里有 **338 种不同的「宜」组合**；相隔 60 天（一个完整
干支周期）的两天，「宜」相同率 **0.0%**；相隔 360 天也只有 82.5%——
接近周期但并不严格，所以压缩不成「一个周期的表 + 索引」。

## 年干支用的是哪种分界

`getYearInGanZhi()` 是**春节分界**：实测 2026-02-05（已过立春、未到春节）仍是
乙巳，2026-02-18 才变丙午；cnlunar 的 `year8Char` 也是这个约定，所以两边 100% 一致。

另一派是**立春分界**（`getYearInGanZhiByLiChun()`，八字/命理用），两者在立春到
春节之间那十几天会不同。本表**刻意选春节分界**：它和界面上显示的农历年一致，
不会出现「农历还写着腊月、年干支却已经翻篇」的观感矛盾。

日干支没有约定歧义（它是一个连续的六十甲子循环），所以它是
「两个实现一致」这件事里最有说服力的一项。

## 输出格式（assets/huangli.tsv）

每个公历日一行，从起始日期起**连续**，所以不需要存日期：

    年干支\t月干支\t日干支\t冲(地支)\t煞(方位)\t宜索引串\t忌索引串

索引串里每个词是 **2 位 36 进制**（`00`-`zz`，可表示 1296 个词，词表共 100 多个）。
词表按 Unicode 排序后写在 lib/core/huangli_data.dart 里——用排序而不是按出现
顺序，是为了让词表与年份范围无关，重新生成时不会整体错位。

冲那里存的是**地支**（如 `巳`）而不是生肖，生肖由 Dart 侧用固定的十二支映射推出来，
这样「冲 = 日支 + 6」这条不变量可以被测试直接验证。
"""
import argparse
import datetime
import sys

from lunar_python import Solar

FIRST_YEAR = 2000
LAST_YEAR = 2060

# 词表用 2 位 36 进制索引
_ALPHABET = '0123456789abcdefghijklmnopqrstuvwxyz'


def encode_indices(indices):
    return ''.join(_ALPHABET[i // 36] + _ALPHABET[i % 36] for i in indices)


def decode_indices(text):
    out = []
    for i in range(0, len(text), 2):
        out.append(_ALPHABET.index(text[i]) * 36 + _ALPHABET.index(text[i + 1]))
    return out


def days_in_range():
    start = datetime.date(FIRST_YEAR, 1, 1)
    end = datetime.date(LAST_YEAR, 12, 31)
    day = start
    while day <= end:
        yield day
        day += datetime.timedelta(days=1)


def collect():
    """返回 [(date, 年干支, 月干支, 日干支, 冲(地支), 煞, 宜list, 忌list)]"""
    rows = []
    for day in days_in_range():
        lunar = Solar.fromYmd(day.year, day.month, day.day).getLunar()
        rows.append((
            day,
            lunar.getYearInGanZhi(),
            lunar.getMonthInGanZhi(),
            lunar.getDayInGanZhi(),
            lunar.getDayChong(),
            lunar.getDaySha(),
            list(lunar.getDayYi()),
            list(lunar.getDayJi()),
        ))
    return rows


def self_check(rows):
    """结构不变量。这些不需要第二个实现就能验证，而且能抓住绝大多数编码错误。"""
    problems = []
    if not rows:
        return ['没有数据']

    # 1. 日干支必须每天正好前进一位（六十甲子循环）
    stems = '甲乙丙丁戊己庚辛壬癸'
    branches = '子丑寅卯辰巳午未申酉戌亥'
    def ganzhi_index(text):
        return (stems.index(text[0]), branches.index(text[1]))

    for i in range(1, len(rows)):
        prev = ganzhi_index(rows[i - 1][3])
        cur = ganzhi_index(rows[i][3])
        expected = ((prev[0] + 1) % 10, (prev[1] + 1) % 12)
        if cur != expected:
            problems.append('日干支在第 %d 天断了：%s -> %s'
                            % (i, rows[i - 1][3], rows[i][3]))
            break

    # 2. 冲必须是日支的对面（相隔 6 位）
    for date, _y, _m, day_gz, chong, _sha, _yi, _ji in rows:
        day_branch = branches.index(day_gz[1])
        if branches.index(chong) != (day_branch + 6) % 12:
            problems.append('%s 的冲「%s」不是日支「%s」的对面'
                            % (date, chong, day_gz[1]))
            break

    # 3. 日期连续
    for i in range(1, len(rows)):
        if (rows[i][0] - rows[i - 1][0]).days != 1:
            problems.append('日期不连续：%s -> %s' % (rows[i - 1][0], rows[i][0]))
            break

    return problems


def verify_ganzhi(rows):
    """把干支和另一个独立实现对拍。宜忌对拍的结果也会一起报出来，
    好让「哪个能验证、哪个不能」这件事有据可查。"""
    try:
        import cnlunar
    except Exception as exc:  # noqa: BLE001
        return '  cnlunar 不可用，跳过：%s' % exc

    total = 0
    same = {'year': 0, 'month': 0, 'day': 0}
    yi_exact = 0
    yi_hits = 0
    yi_union = 0

    for date, gy, gm, gd, _c, _s, yi, _ji in rows:
        other = cnlunar.Lunar(datetime.datetime(date.year, date.month, date.day),
                              godType='8char')
        total += 1
        if gy == other.year8Char:
            same['year'] += 1
        if gm == other.month8Char:
            same['month'] += 1
        if gd == other.day8Char:
            same['day'] += 1

        left, right = set(yi), set(other.goodThing)
        if left == right:
            yi_exact += 1
        yi_hits += len(left & right)
        yi_union += len(left | right)

    lines = ['  对拍天数：%d' % total]
    for key in ['year', 'month', 'day']:
        lines.append('  干支(%s) 一致：%d / %d = %.1f%%'
                     % (key, same[key], total, 100.0 * same[key] / total))
    lines.append('  —— 以上应当接近 100%（干支是算术，有唯一答案）')
    lines.append('  宜 完全一致的日子：%d / %d = %.1f%%'
                 % (yi_exact, total, 100.0 * yi_exact / total))
    lines.append('  宜 条目交并比：%.1f%%'
                 % (100.0 * yi_hits / yi_union if yi_union else 0))
    lines.append('  —— 以上说明宜忌**没有唯一答案**，只能标注来源，不能当成事实')
    return '\n'.join(lines)


def emit(rows, asset_path, dart_path, fixture_path):
    vocab = sorted({word for row in rows for word in row[6] + row[7]})
    index_of = {word: i for i, word in enumerate(vocab)}
    if len(vocab) > 36 * 36:
        raise SystemExit('词表太大，2 位 36 进制装不下：%d' % len(vocab))

    with open(asset_path, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(
            '# 黄历数据表。由 tool/generate_huangli.py 生成，请勿手工编辑。\n'
            '# 每个公历日一行，从 %04d-01-01 起连续，所以不存日期。\n'
            '# 字段：年干支 \\t 月干支 \\t 日干支 \\t 冲(地支) \\t 煞(方位) '
            '\\t 宜索引串 \\t 忌索引串\n'
            '# 索引串每词 2 位 36 进制，词表见 lib/core/huangli_data.dart。\n'
            '#\n'
            '# 干支与冲煞是可验证的（两个独立实现 100%% 一致）。\n'
            '# 宜忌**不可验证**（同两个实现完全一致的日子是 0%%），是传统历注。\n'
            % FIRST_YEAR
        )
        for _date, gy, gm, gd, chong, sha, yi, ji in rows:
            handle.write('%s\t%s\t%s\t%s\t%s\t%s\t%s\n' % (
                gy, gm, gd, chong, sha,
                encode_indices([index_of[w] for w in yi]),
                encode_indices([index_of[w] for w in ji]),
            ))

    with open(dart_path, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(
            '// 本文件由 tool/generate_huangli.py 自动生成，请勿手工编辑。\n'
            'library;\n\n'
            '/// 黄历覆盖的公历年份。范围外界面不显示黄历。\n'
            'const int kHuangliFirstYear = %d;\n'
            'const int kHuangliLastYear = %d;\n\n'
            '/// 宜忌词表，按 Unicode 排序。\n'
            '///\n'
            '/// 用排序而不是按出现顺序：这样词表与年份范围无关，\n'
            '/// 重新生成数据时索引不会整体错位。\n'
            'const List<String> kHuangliTerms = <String>[\n'
            % (FIRST_YEAR, LAST_YEAR)
        )
        for word in vocab:
            handle.write("  '%s',\n" % word)
        handle.write('];\n')

    # 测试夹具：均匀取样 + 首尾 + 几个固定日期，用来钉住解析和取值
    picked = []
    step = max(1, len(rows) // 60)
    for i in range(0, len(rows), step):
        picked.append(rows[i])
    picked.append(rows[-1])
    for date, gy, gm, gd, chong, sha, yi, ji in rows:
        if date in (datetime.date(2026, 10, 4), datetime.date(2026, 1, 1),
                    datetime.date(2000, 1, 1)):
            picked.append((date, gy, gm, gd, chong, sha, yi, ji))
    seen = set()
    unique = []
    for row in picked:
        if row[0] in seen:
            continue
        seen.add(row[0])
        unique.append(row)

    with open(fixture_path, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(
            '// 本文件由 tool/generate_huangli.py 自动生成，请勿手工编辑。\n'
            '//\n'
            '// 黄历夹具：取样日期 + 首尾 + 几个固定日期。\n'
            'library;\n\n'
            '/// [公历年, 月, 日, 年干支, 月干支, 日干支, 冲(地支), 煞(方位),'
            ' 宜用逗号连接, 忌用逗号连接]\n'
            'const List<List<String>> kHuangliFixture = <List<String>>[\n'
        )
        for date, gy, gm, gd, chong, sha, yi, ji in unique:
            handle.write("  ['%04d', '%d', '%d', '%s', '%s', '%s', '%s', '%s',"
                         " '%s', '%s'],\n"
                         % (date.year, date.month, date.day, gy, gm, gd,
                            chong, sha, ','.join(yi), ','.join(ji)))
        handle.write('];\n')

    print('词表 %d 个词' % len(vocab))
    print('写出 %s（%d 天）' % (asset_path, len(rows)))
    print('写出 %s' % dart_path)
    print('写出 %s（%d 条夹具）' % (fixture_path, len(unique)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--asset', default='assets/huangli.tsv')
    parser.add_argument('--dart', default='lib/core/huangli_data.dart')
    parser.add_argument('--fixture', default='test/huangli_fixture.dart')
    parser.add_argument('--verify', action='store_true',
                        help='把干支和宜忌分别与 cnlunar 对拍')
    parser.add_argument('--verify-days', type=int, default=730)
    args = parser.parse_args()

    rows = collect()
    print('收集 %d 天（%d-%d）' % (len(rows), FIRST_YEAR, LAST_YEAR))

    problems = self_check(rows)
    if problems:
        for problem in problems:
            print('自检失败：%s' % problem)
        return 1
    print('自检通过：日干支逐日 +1、冲为日支对面、日期连续')

    if args.verify:
        print('与 cnlunar 对拍（前 %d 天）：' % args.verify_days)
        print(verify_ganzhi(rows[:args.verify_days]))

    emit(rows, args.asset, args.dart, args.fixture)
    return 0


if __name__ == '__main__':
    sys.exit(main())
