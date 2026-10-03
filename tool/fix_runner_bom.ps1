# 给 windows\runner 下的 C++ 源文件补 UTF-8 BOM。
#
# 为什么必须有 BOM：
#   windows\CMakeLists.txt 里是 /W4 /WX（警告即错误）。本机代码页是 936，
#   MSVC 读**没有 BOM 的** UTF-8 文件时会按 CP936 解码，里面的中文就会触发
#       warning C4819: 该文件包含不能在当前代码页(936)中表示的字符
#   而 /WX 把它升级成 error C2220 —— 编译直接失败。
#   带上 BOM 之后 MSVC 就按 UTF-8 读，警告消失。
#
#   ⚠️ 用编辑器/工具改完这些文件后 BOM 可能被丢掉（本项目就发生过），
#   所以每次构建前跑一次这个脚本是廉价的保险。
#
# 用法：powershell -File tool\fix_runner_bom.ps1

$ErrorActionPreference = 'Stop'

$runnerDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\runner'
if (-not (Test-Path $runnerDir)) { throw "找不到目录：$runnerDir" }

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$strict = New-Object System.Text.UTF8Encoding($false, $true)
$fixed = 0

foreach ($file in (Get-ChildItem $runnerDir -File -Include *.cpp,*.h -Recurse)) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)

    # 只处理有非 ASCII 内容的文件：纯 ASCII 文件加不加 BOM 都一样。
    $hasNonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 127) { $hasNonAscii = $true; break } }
    if (-not $hasNonAscii) { continue }

    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBom) { continue }

    # 只认确定是 UTF-8 的文件。不是 UTF-8 的（例如 GBK）**不要动** ——
    # 按 UTF-8 解码再写回会把中文彻底写坏。
    try { $text = $strict.GetString($bytes) }
    catch {
        Write-Host ('跳过（不是 UTF-8，可能是 GBK）：' + $file.Name) -ForegroundColor Yellow
        continue
    }

    [System.IO.File]::WriteAllText($file.FullName, $text, $utf8Bom)
    Write-Host ('已补 BOM：' + $file.Name) -ForegroundColor Green
    $fixed++
}

if ($fixed -eq 0) {
    Write-Host '所有需要 BOM 的 runner 源文件都已带 BOM。'
} else {
    Write-Host ("补了 $fixed 个文件的 BOM。")
}