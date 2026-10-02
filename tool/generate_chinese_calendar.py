"""Generate the Chinese calendar data tables used by the Dart app.

Range: solar years 1950..2100. Chosen because it is comfortably inside the
support of BOTH reference implementations, so every single day can be checked.

Verification strategy (this is the whole point of the file):

  * LUNAR tables are cross-checked day by day against .NET's
    ChineseLunisolarCalendar -- an independent implementation shipped with
    Windows. Two unrelated implementations agreeing on ~55,000 consecutive
    days is strong evidence both are right.
  * SOLAR TERM tables come from lunar_python and are spot-checked against the
    Hong Kong Observatory's published calendar.

Storage format notes:

  * Solar terms only need the DAY stored: every term always falls in the same
    solar month (XiaoHan/DaHan in January, LiChun/YuShui in February, ...).
  * The lunar table packs one lunar year into a single 32-bit integer:
        bits  0..4   day of lunar new year (1..31)
        bit   5      lunar new year is in February (else January)
        bits  6..9   leap month number (0 = none)
        bits 10..22  month lengths, 1 = 30 days, 0 = 29 days (13 slots)

Usage:
    python generate_chinese_calendar.py --emit-dart <out.dart>
    python generate_chinese_calendar.py --dump-lunar <out.tsv>
"""
import argparse
import datetime
import sys

from lunar_python import Lunar, LunarYear, Solar

# 界面支持的公历范围。
SUPPORT_FIRST_YEAR = 1950
SUPPORT_LAST_YEAR = 2100

# 表里要多存前后各一个农历年。原因：判断某一天属于哪个农历年，需要拿
# 相邻两年的正月初一来夹；而且 1950 年 1 月 1 日到 2 月 16 日其实属于
# 农历 1949 年。少了这两个边界年，范围内的开头和结尾就会解不出农历。
LUNAR_FIRST_YEAR = SUPPORT_FIRST_YEAR - 1
LUNAR_LAST_YEAR = SUPPORT_LAST_YEAR + 1

# Canonical order of the 24 solar terms within a solar year, with the solar
# month each one always falls in. Used to validate what we scraped.
TERM_NAMES = [
    "小寒", "大寒", "立春", "雨水", "惊蛰", "春分",
    "清明", "谷雨", "立夏", "小满", "芒种", "夏至",
    "小暑", "大暑", "立秋", "处暑", "白露", "秋分",
    "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
]
TERM_MONTHS = [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
               7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12]


def solar_terms_for_year(year):
    """All 24 solar terms of a solar year, in canonical order.

    Rather than matching on term names (the library's keys mix Chinese names
    and pinyin constants), we take every entry whose solar year matches and
    sort by date. There are exactly 24 of them, and their chronological order
    IS the canonical order.
    """
    table = Solar.fromYmd(year, 6, 1).getLunar().getJieQiTable()
    dates = []
    for _name, solar in table.items():
        if solar.getYear() == year:
            dates.append(datetime.date(solar.getYear(), solar.getMonth(), solar.getDay()))
    dates.sort()
    if len(dates) != 24:
        raise SystemExit("year %d: expected 24 solar terms, got %d" % (year, len(dates)))
    days = []
    for index, d in enumerate(dates):
        if d.month != TERM_MONTHS[index]:
            raise SystemExit(
                "year %d: term #%d (%s) landed in month %d, expected %d"
                % (year, index, TERM_NAMES[index], d.month, TERM_MONTHS[index])
            )
        days.append(d.day)
    return days


def lunar_year_packed(year):
    """Pack one lunar year (starting in solar year `year`) into an int.

    Month lengths are derived by walking every day of the lunar year and
    counting days per month, rather than asking the library for its month
    list. Reason: LunarYear.getMonths() returns a window of months spanning
    more than the year itself (15 entries for 1950), and relying on its exact
    semantics is a guess. Walking the days uses the very data we already
    cross-checked against .NET.
    """
    start = _lunar_new_year(year)
    end = _lunar_new_year(year + 1)
    if start.month not in (1, 2):
        raise SystemExit("lunar year %d starts in month %d" % (year, start.month))

    order = []
    counts = {}
    d = start
    while d < end:
        _ly, m, _day = lunar_of(d)
        if m not in counts:
            order.append(m)
            counts[m] = 0
        counts[m] += 1
        d += datetime.timedelta(days=1)

    lengths = [counts[m] for m in order]
    if len(lengths) not in (12, 13):
        raise SystemExit("lunar year %d has %d months" % (year, len(lengths)))

    # 次序必须是 1..12，闰月只有一个且紧跟在它的本位月之后
    positives = [m for m in order if m > 0]
    if positives != list(range(1, 13)):
        raise SystemExit("lunar year %d: month order %s" % (year, order))
    negatives = [m for m in order if m < 0]
    if len(negatives) > 1:
        raise SystemExit("lunar year %d has %d leap months" % (year, len(negatives)))

    leap = 0
    if negatives:
        leap = -negatives[0]
        index = order.index(negatives[0])
        if index == 0 or order[index - 1] != leap:
            raise SystemExit("lunar year %d: leap month %d out of place" % (year, leap))

    for length in lengths:
        if length not in (29, 30):
            raise SystemExit("lunar year %d: month length %d" % (year, length))

    while len(lengths) < 13:
        lengths.append(29)  # unused slot when the year has no leap month

    value = start.day & 0x1F
    if start.month == 2:
        value |= 1 << 5
    value |= (leap & 0xF) << 6
    for index, length in enumerate(lengths):
        if length == 30:
            value |= 1 << (10 + index)
    return value


def _lunar_new_year(year):
    solar = Lunar.fromYmd(year, 1, 1).getSolar()
    return datetime.date(solar.getYear(), solar.getMonth(), solar.getDay())


def lunar_of(d):
    """(lunarYear, signed lunar month, lunar day) for a solar date.

    Leap months are reported with a NEGATIVE month number, matching how
    lunar_python and the reference dump represent them.
    """
    lunar = Solar.fromYmd(d.year, d.month, d.day).getLunar()
    return lunar.getYear(), lunar.getMonth(), lunar.getDay()


def emit_dart(path):
    term_lines = []
    lunar_lines = []
    for year in range(SUPPORT_FIRST_YEAR, SUPPORT_LAST_YEAR + 1):
        days = solar_terms_for_year(year)
        term_lines.append("  %d: '%s'," % (year, "".join("%02d" % d for d in days)))
    for year in range(LUNAR_FIRST_YEAR, LUNAR_LAST_YEAR + 1):
        lunar_lines.append("  %d: 0x%08X," % (year, lunar_year_packed(year)))

    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(
            "// 本文件由 tool/generate_chinese_calendar.py 自动生成，请勿手工编辑。\n"
            "//\n"
            "// 数据范围：公历 %d–%d 年。\n"
            "//\n"
            "// 为什么是查表而不是推算：农历和节气都是天文推算的结果，\n"
            "// 精度不够会在个别年份差一天，而日记里显示错日期比不显示更糟。\n"
            "// 表里的数据经过两个独立实现逐日对拍（见生成脚本的说明）。\n"
            "library;\n\n"
            % (SUPPORT_FIRST_YEAR, SUPPORT_LAST_YEAR)
        )
        handle.write(
            "/// 每年 24 个节气，按 [小寒, 大寒, 立春, ... 冬至] 的顺序，\n"
            "/// 每个两位数字是该节气所在的「日」。月份是固定的，不需要存。\n"
            "const Map<int, String> kSolarTermDays = <int, String>{\n"
        )
        handle.write("\n".join(term_lines))
        handle.write("\n};\n\n")
        handle.write(
            "/// 每个农历年打包成一个整数：\n"
            "///   bit 0..4   正月初一的「日」\n"
            "///   bit 5      正月初一在二月（否则在一月）\n"
            "///   bit 6..9   闰月月份，0 表示不闰\n"
            "///   bit 10..22 十三个月的天数，1 = 30 天，0 = 29 天\n"
            "const Map<int, int> kLunarYearTable = <int, int>{\n"
        )
        handle.write("\n".join(lunar_lines))
        handle.write("\n};\n")

    print("wrote %s (support %d..%d, lunar table %d..%d)"
          % (path, SUPPORT_FIRST_YEAR, SUPPORT_LAST_YEAR,
             LUNAR_FIRST_YEAR, LUNAR_LAST_YEAR))


def dump_lunar(path):
    # 覆盖到表里多存的那两个边界年，这样边界年份也能和 .NET 逐日对拍。
    # .NET 的农历日历最晚只支持到 2101-01-28，所以取到 2101-01-27。
    start = datetime.date(LUNAR_FIRST_YEAR, 1, 1)
    end = datetime.date(LUNAR_LAST_YEAR, 1, 27)
    written = 0
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        d = start
        while d <= end:
            y, m, day = lunar_of(d)
            handle.write("%04d-%02d-%02d\t%d\t%d\t%d\n" % (d.year, d.month, d.day, y, m, day))
            written += 1
            d += datetime.timedelta(days=1)
    print("wrote %s (%d days)" % (path, written))


def emit_fixture(path):
    """Emit boundary-date fixtures so the Dart decoder can be tested.

    The generated tables themselves come from a verified source; what still
    needs testing is the *decoding* -- unpacking the bit fields and walking
    from the lunar new year. These boundary dates (first day of each lunar
    year, each leap month's first day, and the last day of each year) are
    exactly where a decoding bug would show up first.
    """
    lunar_rows = []
    start = datetime.date(SUPPORT_FIRST_YEAR, 1, 1)
    end = datetime.date(SUPPORT_LAST_YEAR, 12, 31)
    d = start
    while d <= end:
        y, m, day = lunar_of(d)
        # 每个农历年的正月初一、每个闰月的初一
        if day == 1 and (m == 1 or m < 0):
            lunar_rows.append((d, y, m, day))
        # 每年的最后一天（除夕）
        ny, nm, nday = lunar_of(d + datetime.timedelta(days=1))
        if nm == 1 and nday == 1:
            lunar_rows.append((d, y, m, day))
        d += datetime.timedelta(days=1)

    term_years = [1950, 1975, 2000, 2026, 2050, 2075, 2100]
    term_rows = []
    for year in term_years:
        for index, day in enumerate(solar_terms_for_year(year)):
            term_rows.append((year, index, TERM_MONTHS[index], day))

    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(
            "// 本文件由 tool/generate_chinese_calendar.py 自动生成，请勿手工编辑。\n"
            "//\n"
            "// 边界日期夹具：农历每年正月初一、每个闰月初一、以及每年的最后一天。\n"
            "// 解码表的时候，出错最先会表现在这些位置上。\n"
            "library;\n\n"
        )
        handle.write(
            "/// [公历年, 月, 日, 农历年, 农历月（负数表示闰月）, 农历日]\n"
            "const List<List<int>> kLunarBoundaryFixture = <List<int>>[\n"
        )
        for d, y, m, day in lunar_rows:
            handle.write("  [%d, %d, %d, %d, %d, %d],\n" % (d.year, d.month, d.day, y, m, day))
        handle.write("];\n\n")

        handle.write(
            "/// [公历年, 节气序号（0 = 小寒）, 月, 日]\n"
            "const List<List<int>> kSolarTermFixture = <List<int>>[\n"
        )
        for year, index, month, day in term_rows:
            handle.write("  [%d, %d, %d, %d],\n" % (year, index, month, day))
        handle.write("];\n")

    print("wrote %s (%d lunar boundary rows, %d solar term rows)"
          % (path, len(lunar_rows), len(term_rows)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--emit-dart")
    parser.add_argument("--emit-fixture")
    parser.add_argument("--dump-lunar")
    parser.add_argument("--dump-terms")
    args = parser.parse_args()

    if args.emit_dart:
        emit_dart(args.emit_dart)
    if args.emit_fixture:
        emit_fixture(args.emit_fixture)
    if args.dump_lunar:
        dump_lunar(args.dump_lunar)
    if args.dump_terms:
        with open(args.dump_terms, "w", encoding="utf-8", newline="\n") as handle:
            for year in range(SUPPORT_FIRST_YEAR, SUPPORT_LAST_YEAR + 1):
                days = solar_terms_for_year(year)
                for index, day in enumerate(days):
                    handle.write("%d\t%s\t%d-%02d-%02d\n"
                                 % (year, TERM_NAMES[index], year, TERM_MONTHS[index], day))
        print("wrote %s" % args.dump_terms)

    if not any([args.emit_dart, args.emit_fixture, args.dump_lunar, args.dump_terms]):
        parser.print_help()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
