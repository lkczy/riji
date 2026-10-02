# 一条命令跑完这个项目的验收检查。
#
# 为什么存在：这个项目的验收门槛比一般项目高（analyze + 全套测试，改界面还要
# 重建和图标审计），而"改完随手跑一下"是最容易省掉的一步。把它变成一次敲击。
#
# ⚠️ 判断失败用的是**退出码**，不是匹配输出文字。
# 原因：PowerShell 的 -match 是大小写不敏感的，'issues found' 会匹配上
# 'No issues found!' —— 这个坑本项目栽过一次，把通过判成了失败。

$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$flutterRoot = $env:FLUTTER_ROOT
if (-not $flutterRoot) { $flutterRoot = 'D:\Dev\flutter' }
$flutter = Join-Path $flutterRoot 'bin\flutter.bat'

if (-not (Test-Path $flutter)) {
  Write-Host ('✗ 找不到 flutter：' + $flutter) -ForegroundColor Red
  Write-Host '  可以用环境变量 FLUTTER_ROOT 指定。'
  exit 1
}

Write-Host ('项目：' + $root)
Write-Host ('flutter：' + $flutter)
Write-Host ''

Push-Location $root
try {
  # ---- analyze ----
  Write-Host '== flutter analyze ==' -ForegroundColor Cyan
  & $flutter analyze
  if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '✗ analyze 失败 —— 不继续跑测试。' -ForegroundColor Red
    Write-Host '  （先修到 No issues found，再谈测试。）'
    exit 1
  }
  Write-Host '✓ analyze 通过' -ForegroundColor Green

  # ---- 全套测试 ----
  Write-Host ''
  Write-Host '== flutter test ==' -ForegroundColor Cyan
  $log = Join-Path $env:TEMP ('riji_check_' + [guid]::NewGuid().ToString('N') + '.txt')
  & $flutter test *> $log
  $testExit = $LASTEXITCODE

  # 只打印最后几行（里面就是 "All tests passed!" 或失败统计）
  Get-Content $log -Tail 3 | ForEach-Object { Write-Host ('  ' + $_) }

  if ($testExit -ne 0) {
    Write-Host ''
    Write-Host '✗ 测试失败，失败用例：' -ForegroundColor Red
    Get-Content $log |
      Select-String -Pattern '^  D:/' |
      Select-Object -First 10 |
      ForEach-Object { Write-Host ('    ' + $_.Line.Trim()) }
    Write-Host ''
    Write-Host ('  完整输出：' + $log)
    exit 1
  }

  Remove-Item $log -Force -ErrorAction SilentlyContinue

  Write-Host ''
  Write-Host '✓ 全部通过' -ForegroundColor Green
  Write-Host ''
  Write-Host '提醒：' -ForegroundColor Yellow
  Write-Host '  · 改了界面 → 还要跑 tool\build_release.ps1（图标审计必须 MISSING : 0）+ 真机启动'
  Write-Host '  · 碰了备份/同步/删除这类保护 → 做反向验证（故意去掉保护，确认测试会红）'
  exit 0
}
finally {
  Pop-Location
}
