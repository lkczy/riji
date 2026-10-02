# 构建 Windows release 版，并验证图标字体确实覆盖了程序用到的每一个图标。
#
# 为什么必须 clean：
#   Flutter 的**增量构建不会重新生成图标字体子集**。新加或改动的图标会被
#   静默丢掉，界面上显示成空白方框，而构建日志里没有任何提示。
#   这个坑真实发生过：外观菜单的三个图标（跟随系统/浅色/深色）全都不可见，
#   而同一个版本里其它 22 个图标完全正常——因为那些图标在上一次完整构建时
#   就已经被写进字体子集了。
#
# 为什么必须审计：
#   上面那个问题不会让构建失败，也不会有警告。只有把字体子集和代码里实际
#   用到的图标做交集，才能发现它。
#
# 用法：
#   powershell -File tool\build_release.ps1
# 可选：用环境变量覆盖 Flutter 位置
#   $env:FLUTTER_ROOT = 'D:\Dev\flutter'
#
# 编码要求：本文件必须保存为 **UTF-8 with BOM**。
# Windows PowerShell 5.1 会把没有 BOM 的 .ps1 当成本地 ANSI 代码页去读，
# 中文全部乱码并直接导致语法错误。用编辑器改完这个文件后，
# 一定要确认 BOM（EF BB BF）还在，否则脚本会以莫名其妙的方式报错。

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot

# 注意：PowerShell 5.1 不支持把 if 当表达式用（`$x = if (...) {...}`），
# 必须分开写，否则脚本第一行就报错。
$flutterRoot = $env:FLUTTER_ROOT
if (-not $flutterRoot) { $flutterRoot = 'D:\Dev\flutter' }

$flutter = Join-Path $flutterRoot 'bin\flutter.bat'
$iconsDart = Join-Path $flutterRoot 'packages\flutter\lib\src\material\icons.dart'
$fontPath = Join-Path $projectRoot 'build\windows\x64\runner\Release\data\flutter_assets\fonts\MaterialIcons-Regular.otf'
$auditScript = Join-Path $PSScriptRoot 'icon_audit.py'

function Write-Step($text) {
    Write-Host ''
    Write-Host "=== $text ===" -ForegroundColor Cyan
}

if (-not (Test-Path $flutter)) { throw "找不到 flutter：$flutter（可用 `$env:FLUTTER_ROOT 覆盖）" }
if (-not (Test-Path $auditScript)) { throw "找不到审计脚本：$auditScript" }

# 1. 关掉正在运行的程序，否则 exe 被占用会导致链接失败
Write-Step '关闭正在运行的程序'
$running = Get-Process -Name riji -ErrorAction SilentlyContinue
if ($running) {
    $running.CloseMainWindow() | Out-Null
    Start-Sleep -Seconds 3
    $still = Get-Process -Name riji -ErrorAction SilentlyContinue
    if ($still) {
        Stop-Process -Id $still.Id -Force
        Write-Host "已强制结束 PID=$($still.Id)"
    } else {
        Write-Host '已正常退出'
    }
} else {
    Write-Host '未在运行'
}

# 2. 必须完整清理，否则图标字体子集是陈旧的
Write-Step 'flutter clean（这一步不能省）'
& $flutter clean
if ($LASTEXITCODE -ne 0) { throw 'flutter clean 失败' }

# 3. 构建
Write-Step 'flutter build windows --release'
& $flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw '构建失败' }

# 4. 审计图标字体
Write-Step '审计图标字体覆盖'
if (-not (Test-Path $fontPath)) { throw "找不到构建出的字体：$fontPath" }
python $auditScript $iconsDart (Join-Path $projectRoot 'lib') $fontPath
if ($LASTEXITCODE -ne 0) { throw '图标审计失败' }

Write-Host ''
Write-Host '完成。如果上面显示 "app icons MISSING : 0"，字体就没问题。' -ForegroundColor Green

# 5. 重新生成项目根目录的启动器
#
# 程序不是一个单独的 exe：riji.exe 运行时要加载同目录的
# flutter_windows.dll 和 data\，所以不能把 exe 单独拷到浅一点的地方。
# 结论就是在项目根目录放一个快捷方式，双击即可启动。
# 快捷方式里存的是绝对路径，所以每次构建都重建一次，免得它指向旧位置。
Write-Step '生成启动器 日迹.lnk'
$exePath = Join-Path $projectRoot 'build\windows\x64\runner\Release\riji.exe'
$lnkPath = Join-Path $projectRoot '日迹.lnk'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($lnkPath)
$link.TargetPath = $exePath
$link.WorkingDirectory = (Split-Path $exePath)
$link.IconLocation = "$exePath,0"
$link.Description = 'riji - local Markdown diary'
$link.Save()
Write-Host "已生成 $lnkPath"

Write-Host ''
Write-Host '双击启动（任选其一）：' -ForegroundColor Green
Write-Host "  $lnkPath"
Write-Host "  $(Join-Path $projectRoot 'riji.bat')"
