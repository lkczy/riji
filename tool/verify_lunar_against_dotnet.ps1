# 用 .NET 的农历日历逐日对拍 gen 出来的农历表，验证数据没算错。
#
# 为什么需要这个：lib/core/chinese_calendar_data.dart 里的数据是用
# lunar_python 生成的。生成脚本自己没法证明自己算得对，所以这里用
# 一个**完全独立**的实现（Windows 自带的 ChineseLunisolarCalendar）
# 逐日比对。两边在 55544 天里只有 60 天不一致，集中在 2089 和 2097
# 各一处月首边界；那两处另有 lunar_python / cnlunar / zhdate 三个实现
# 与 .NET 意见相反，所以采用了多数派（即生成表所用的取值）。
#
# 出现新的分歧时，不要直接改这里的期望值——先查清楚哪一边是对的。
#
# 编码要求：本文件必须保存为 UTF-8 with BOM。
# Windows PowerShell 5.1 会把没有 BOM 的 .ps1 当成本地 ANSI 代码页读，
# 中文会乱码并直接导致语法错误。
#
# 用法：
#   powershell -File tool\verify_lunar_against_dotnet.ps1

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$tool = $PSScriptRoot
$reference = Join-Path $tool '_lunar_ref_python.tsv'
$generated = Join-Path $tool '_lunar_ref_dotnet.tsv'

# 已知的边界分歧：这几年的这几天允许不一致（原因见文件头注释）。
$knownDivergentYears = @('2089', '2097')

if (-not (Test-Path $reference)) {
    throw "找不到参考数据 $reference。先运行：`n  python tool\generate_chinese_calendar.py --dump-lunar `"$reference`""
}

Write-Host '=== 用 .NET 生成同一天的农历，逐日对拍 ===' -ForegroundColor Cyan

$calendar = New-Object System.Globalization.ChineseLunisolarCalendar
$writer = New-Object System.IO.StreamWriter($generated, $false, (New-Object System.Text.UTF8Encoding($false)))
$day = [datetime]'1949-01-01'
$end = [datetime]'2101-01-27'   # .NET 农历日历的最晚支持日期是 2101-01-28

while ($day -le $end) {
    $lunarYear = $calendar.GetYear($day)
    $month = $calendar.GetMonth($day)
    $dayOfMonth = $calendar.GetDayOfMonth($day)
    $leapOrdinal = $calendar.GetLeapMonth($lunarYear)

    # .NET 的月份编号在闰月之后会整体后移一位，要还原成实际月份；
    # 闰月用负数表示，和生成脚本、和 lunar_python 的约定一致。
    if ($leapOrdinal -eq 0) { $real = $month }
    elseif ($month -lt $leapOrdinal) { $real = $month }
    elseif ($month -eq $leapOrdinal) { $real = -($month - 1) }
    else { $real = $month - 1 }

    $writer.WriteLine(("{0:yyyy-MM-dd}`t{1}`t{2}`t{3}" -f $day, $lunarYear, $real, $dayOfMonth))
    $day = $day.AddDays(1)
}
$writer.Close()

$expected = [System.IO.File]::ReadAllLines($reference)
$actual = [System.IO.File]::ReadAllLines($generated)

Write-Host ("参考行数 {0}，生成行数 {1}" -f $expected.Count, $actual.Count)
if ($expected.Count -ne $actual.Count) { throw '行数不一致，无法比较' }

$mismatch = 0
$unexpected = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $expected.Count; $i++) {
    if ($expected[$i] -ne $actual[$i]) {
        $mismatch++
        $year = $expected[$i].Substring(0, 4)
        if ($knownDivergentYears -notcontains $year) {
            $unexpected.Add("  $($expected[$i])  vs  $($actual[$i])")
        }
    }
}

Write-Host ''
if ($unexpected.Count -eq 0) {
    Write-Host ("一致：{0} 天中有 {1} 天不一致，全部落在已知的边界分歧年份（{2}）" -f `
        $expected.Count, $mismatch, ($knownDivergentYears -join ', ')) -ForegroundColor Green
    exit 0
}

Write-Host ("出现了 {0} 处**新的**分歧（不在已知列表里）：" -f $unexpected.Count) -ForegroundColor Red
$unexpected | Select-Object -First 20 | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host '先查清楚哪一边对，再决定改数据还是改这里的已知列表。' -ForegroundColor Red
exit 1
