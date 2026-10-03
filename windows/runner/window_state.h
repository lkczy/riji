#ifndef RUNNER_WINDOW_STATE_H_
#define RUNNER_WINDOW_STATE_H_

#include <windows.h>

#include <string>

// 窗口几何的持久化：记住上次关闭时的位置、大小和「是否最大化」。
//
// ⚠️ 单位：WindowGeometry 里的**全部坐标都是逻辑单位（DIP）**，不是物理像素。
//
// 原因是 Win32Window::Create 收的就是逻辑单位，它在内部会乘一次 dpi/96
// （见 win32_window.cpp 的 Scale 调用）。这份文件的作用就是保证
// 「存 / 读 / Create」三个环节加起来**只乘一次**：
//
//     保存：物理像素 ÷ (GetDpiForWindow(hwnd)/96)  → 逻辑单位存盘
//     读取：逻辑单位原样交给 Create             → Create 内部乘一次
//
// 如果把 GetWindowPlacement 拿到的物理像素原样存下来再原样传回 Create，
// 就会在 150% 缩放下把 1280×720 变成 1920×1080，而且**每次启动都再放大一次**
// （累积）。开发机是 100% 缩放（scale_factor == 1.0），乘一次和乘两次结果
// 完全一样 → 这个 bug 在开发机上永远复现不了，只能靠单位纪律避免。
// 详见 docs/开发须知.md §1.4。
//
// 同样地，夹取时也不能把逻辑单位和物理像素混着比：MonitorFromPoint /
// GetMonitorInfo 给的是物理像素，必须先按同一套换算再比较（这是同一个坑的
// 二阶版本，见 window_state.cpp 的 ClampToVisibleArea）。
namespace window_state {

// 保存的窗口几何。所有字段都是**逻辑单位**。
struct WindowGeometry {
  int x = 10;
  int y = 10;
  int width = 1280;
  int height = 720;
  // 上次关闭时是否处于最大化。最小化**不算**最大化（见保存逻辑）。
  bool maximized = false;
};

// 首次运行 / 文件缺失 / 内容不合法 / 读不动时使用的默认几何。
WindowGeometry DefaultGeometry();

// window.txt 的完整路径：`%APPDATA%\riji\window.txt`。
// 取不到 APPDATA 时返回空串。
std::wstring GetStateFilePath();

// 从 window.txt 读回几何。
//
// 任何失败（文件不存在、内容不合法、读不动）都**静默返回默认几何**，
// 绝不阻止启动：这是个「锦上添花」的功能，坏了也不该让程序打不开。
//
// 读回来的结果已经：
//   · 把过小的尺寸抬到合理下限；
//   · 夹取回可见区域（显示器拔掉 / 分辨率变小 / 扩展坞没插都靠这一步救），
//     保证标题栏始终有点在屏幕上 —— 否则窗口跑到屏幕外，用户会以为程序启动失败。
WindowGeometry LoadGeometryClampedToVisibleArea();

// 保存几何（逻辑单位）。注意调用方必须已经把物理像素换算成逻辑单位。
// 任何失败都静默忽略。
void SaveGeometry(const WindowGeometry& geometry);

// 把一个（逻辑单位的）矩形夹取回可见区域。单独暴露出来是为了能直接验算。
WindowGeometry ClampToVisibleArea(const WindowGeometry& geometry);

// 下面两个是 DPI 兼容层：GetDpiForWindow 要 Windows 10 1607、
// GetDpiForMonitor 要 shcore.dll，都靠运行时动态取，取不到就退回 96。
// 之所以放在这里而不是各写一份，是为了让「保存」和「夹取」保证用的是
// 同一套换算 —— 单位只要有一处不一致就会静默错位。

// 窗口所在显示器的缩放（GetDpiForWindow 语义）。
UINT DpiForWindowCompat(HWND hwnd);

// 指定显示器的缩放（GetDpiForMonitor 语义，MDT_EFFECTIVE_DPI）。
UINT DpiForMonitorCompat(HMONITOR monitor);

}  // namespace window_state

#endif  // RUNNER_WINDOW_STATE_H_
