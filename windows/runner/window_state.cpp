#include "window_state.h"

#include <windows.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace window_state {
namespace {

// 尺寸的合理下限。比这更小的窗口没有使用价值，多半是文件被改坏了。
constexpr int kMinWindowWidth = 400;
constexpr int kMinWindowHeight = 300;

// 夹取后至少要留在屏幕上的量（逻辑单位）。
// 「标题栏那块可见」的判断标准就是这两条：夹取后窗口与工作区的交集
// 在横向上不小于 kMinVisibleWidth，纵向上不小于 kMinVisibleHeight。
// 只要标题栏横着有一截露在外面，用户就能把它拖回来。
constexpr int kMinVisibleWidth = 120;
constexpr int kMinVisibleHeight = 40;

// 防止明显是垃圾的尺寸（例如 2000000000）在换算里溢出。
constexpr int kMaxWindowWidth = 100000;
constexpr int kMaxWindowHeight = 100000;

constexpr const wchar_t kAppDirName[] = L"riji";
constexpr const wchar_t kStateFileName[] = L"window.txt";

// thread_local 是为了不引入 C++11 之外的并发假设：这个模块只在主线程调用。
std::wstring& MutableStateFilePath() {
  static std::wstring path;
  return path;
}

// GetDpiForWindow 是 Windows 10 1607 才有的，声明时直接写字面量，避免依赖
// 新 SDK 的头文件。老系统上取不到就退回「按显示器取 DPI」。
//
// 函数指针缓存在函数内静态变量里：C++11 起局部静态初始化是线程安全的，
// 而且只查一次 —— 逐个窗口关闭时反复 LoadLibrary/GetProcAddress 是不必要的开销。
using GetDpiForMonitorFn = HRESULT(WINAPI*)(HMONITOR, int, UINT*, UINT*);

GetDpiForMonitorFn GetDpiForMonitorCached() {
  static GetDpiForMonitorFn cached = []() -> GetDpiForMonitorFn {
    HMODULE shcore = ::LoadLibraryW(L"shcore.dll");
    if (shcore == nullptr) {
      return nullptr;
    }
    return reinterpret_cast<GetDpiForMonitorFn>(
        ::GetProcAddress(shcore, "GetDpiForMonitor"));
  }();
  return cached;
}

// 把物理像素换算成逻辑单位（DIP）。必须四舍五入而不是截断：截断会让
// 每存一次就少 1px 以内的一点点，反复启停后会缓慢漂移。
int PhysicalToLogical(int physical, double scale_factor) {
  if (scale_factor <= 0.0) {
    return physical;
  }
  return static_cast<int>(std::lround(physical / scale_factor));
}

// 把逻辑单位换算成物理像素。
int LogicalToPhysical(int logical, double scale_factor) {
  if (scale_factor <= 0.0) {
    return logical;
  }
  return static_cast<int>(std::lround(logical * scale_factor));
}

// 按和 Create 完全相同的规则挑显示器：把逻辑单位当坐标用，
// 取「最近的」显示器（GetWindowPlacement / Create 都是这个语义）。
// 单位虽然是错的，但两边错得一样，所以夹取结论和最终落点是一致的。
HMONITOR MonitorForLogicalOrigin(const WindowGeometry& geometry) {
  POINT point = {static_cast<LONG>(geometry.x), static_cast<LONG>(geometry.y)};
  return ::MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
}

int ParseInt(const std::string& token, bool* ok) {
  errno = 0;
  char* end = nullptr;
  long long value = std::strtoll(token.c_str(), &end, 10);
  if (errno != 0 || end == token.c_str() || *end != '\0') {
    *ok = false;
    return 0;
  }
  // 超出 32 位范围的直接当垃圾丢掉，别让它去参与后面的乘法。
  if (value < -1000000LL || value > 1000000LL) {
    *ok = false;
    return 0;
  }
  *ok = true;
  return static_cast<int>(value);
}

}  // namespace

UINT DpiForMonitorCompat(HMONITOR monitor) {
  GetDpiForMonitorFn get_dpi_for_monitor = GetDpiForMonitorCached();
  if (monitor == nullptr || get_dpi_for_monitor == nullptr) {
    return 96;
  }
  UINT dpi_x = 0;
  UINT dpi_y = 0;
  // 0 == MDT_EFFECTIVE_DPI
  if (FAILED(get_dpi_for_monitor(monitor, 0, &dpi_x, &dpi_y)) || dpi_x == 0) {
    return 96;
  }
  return dpi_x;
}

UINT DpiForWindowCompat(HWND hwnd) {
  using GetDpiForWindowFn = UINT(WINAPI*)(HWND);
  static GetDpiForWindowFn get_dpi_for_window = []() -> GetDpiForWindowFn {
    HMODULE user32 = ::GetModuleHandleW(L"user32.dll");
    if (user32 == nullptr) {
      return nullptr;
    }
    return reinterpret_cast<GetDpiForWindowFn>(
        ::GetProcAddress(user32, "GetDpiForWindow"));
  }();

  if (get_dpi_for_window != nullptr && hwnd != nullptr) {
    UINT dpi = get_dpi_for_window(hwnd);
    if (dpi != 0) {
      return dpi;
    }
  }
  return DpiForMonitorCompat(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
}

WindowGeometry DefaultGeometry() {
  return WindowGeometry{};
}

std::wstring GetStateFilePath() {
  std::wstring& cached = MutableStateFilePath();
  if (!cached.empty()) {
    return cached;
  }

  DWORD needed = ::GetEnvironmentVariableW(L"APPDATA", nullptr, 0);
  if (needed == 0) {
    return std::wstring();
  }
  std::vector<wchar_t> buffer(needed, L'\0');
  DWORD written = ::GetEnvironmentVariableW(L"APPDATA", buffer.data(), needed);
  if (written == 0 || written >= needed) {
    return std::wstring();
  }

  std::wstring path(buffer.data());
  if (!path.empty() && path.back() != L'\\') {
    path += L'\\';
  }
  // 和 Dart 侧同一个目录：%APPDATA%\riji\
  // （platform_io.dart 里 settings.json / instance.lock 也在那儿）。
  path += kAppDirName;
  path += L'\\';
  path += kStateFileName;

  cached = path;
  return cached;
}

WindowGeometry LoadGeometryClampedToVisibleArea() {
  WindowGeometry geometry = DefaultGeometry();

  const std::wstring path = GetStateFilePath();
  if (path.empty()) {
    return geometry;
  }

  // 用 _wfopen 而不是 ifstream(path)：MSVC 的 ifstream 只认窄字符路径，
  // APPDATA 里万一有非 ASCII 字符（换台机器就可能）就会读不到。
  FILE* file = nullptr;
  if (::_wfopen_s(&file, path.c_str(), L"rb") != 0 || file == nullptr) {
    return geometry;  // 文件不存在 / 打不开 → 静默默认
  }

  std::string content;
  char chunk[256];
  size_t read = 0;
  while ((read = std::fread(chunk, 1, sizeof(chunk), file)) > 0) {
    content.append(chunk, read);
    if (content.size() > 1024) {
      break;  // 这个文件只该有几十个字节，多出来的部分是垃圾
    }
  }
  std::fclose(file);

  // 逐个 token 解析：允许换行、制表符、连续空格，也容忍后面多余的列
  // （纯文本是刻意选的：可手改，用户遇到怪问题能自己修）。
  std::istringstream stream(content);
  std::vector<std::string> tokens;
  std::string token;
  while (stream >> token) {
    tokens.push_back(token);
  }

  if (tokens.size() < 5) {
    return geometry;  // 内容不合法 → 静默默认
  }

  bool ok = false;
  int values[5] = {0, 0, 0, 0, 0};
  for (int i = 0; i < 5; ++i) {
    values[i] = ParseInt(tokens[static_cast<size_t>(i)], &ok);
    if (!ok) {
      return geometry;
    }
  }

  geometry.x = values[0];
  geometry.y = values[1];
  geometry.width = values[2];
  geometry.height = values[3];
  // 第 5 项只接受 0 / 1，其它一律当文件损坏。
  if (values[4] != 0 && values[4] != 1) {
    return geometry;
  }
  geometry.maximized = values[4] == 1;

  if (geometry.width <= 0 || geometry.height <= 0) {
    return geometry;
  }

  // 尺寸抬到合理下限、压到合理上限。
  if (geometry.width < kMinWindowWidth) {
    geometry.width = kMinWindowWidth;
  }
  if (geometry.height < kMinWindowHeight) {
    geometry.height = kMinWindowHeight;
  }
  if (geometry.width > kMaxWindowWidth) {
    geometry.width = kMaxWindowWidth;
  }
  if (geometry.height > kMaxWindowHeight) {
    geometry.height = kMaxWindowHeight;
  }

  return ClampToVisibleArea(geometry);
}

WindowGeometry ClampToVisibleArea(const WindowGeometry& geometry) {
  WindowGeometry result = geometry;

  HMONITOR monitor = MonitorForLogicalOrigin(geometry);
  if (monitor == nullptr) {
    return result;
  }

  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!::GetMonitorInfoW(monitor, &monitor_info)) {
    return result;
  }

  // ⚠️ 这里是同一个坑的二阶版本：GetMonitorInfo 给的是**物理像素**，
  // geometry 是**逻辑单位**。先按这个显示器自己的缩放把工作区换成逻辑单位，
  // 再在同一套单位里比较。混着比的话夹取本身就算错了。
  const double scale_factor = DpiForMonitorCompat(monitor) / 96.0;

  // 工作区（物理像素）→ 逻辑单位。
  const RECT work = monitor_info.rcWork;
  const int work_left = PhysicalToLogical(work.left, scale_factor);
  const int work_top = PhysicalToLogical(work.top, scale_factor);
  const int work_right = PhysicalToLogical(work.right, scale_factor);
  const int work_bottom = PhysicalToLogical(work.bottom, scale_factor);
  const int work_width = work_right - work_left;
  const int work_height = work_bottom - work_top;

  // 横向夹取：先保证至少 kMinVisibleWidth 宽露在工作区里，再尽量不越界。
  // 顺序很重要 —— 窗口比工作区还宽的时候，必须以「左边缘对齐」为准，
  // 否则先右对齐、再左对齐会来回抖，每次启动都换一个位置。
  if (result.width >= work_width) {
    result.x = work_left;
  } else if (result.x + result.width > work_right) {
    result.x = work_right - result.width;
  } else if (result.x + result.width < work_left + kMinVisibleWidth) {
    result.x = work_left;
  }

  // 纵向同理：标题栏在最上面，所以优先保住上边缘。
  if (result.height >= work_height) {
    result.y = work_top;
  } else if (result.y < work_top) {
    result.y = work_top;
  } else if (result.y + result.height > work_bottom) {
    result.y = work_bottom - result.height;
  }

  // 尺寸再压一次：工作区本身很小时（例如手改出来的迷你分辨率），
  // 保证窗口不超出工作区，免得刚夹好的位置又被尺寸顶出去。
  if (result.width > work_width && work_width > 0) {
    result.width = work_width;
  }
  if (result.height > work_height && work_height > 0) {
    result.height = work_height;
  }
  if (result.width < 1) {
    result.width = 1;
  }
  if (result.height < 1) {
    result.height = 1;
  }

  return result;
}

void SaveGeometry(const WindowGeometry& geometry) {
  const std::wstring path = GetStateFilePath();
  if (path.empty()) {
    return;
  }

  // 目录理论上已经存在（Dart 侧会把 settings.json / instance.lock 写在那儿），
  // 但这里不假设顺序，自己确保一次。
  std::wstring directory = path;
  const size_t separator = directory.find_last_of(L'\\');
  if (separator != std::wstring::npos) {
    directory.resize(separator);
    ::CreateDirectoryW(directory.c_str(), nullptr);
  }

  FILE* file = nullptr;
  if (::_wfopen_s(&file, path.c_str(), L"wb") != 0 || file == nullptr) {
    return;  // 写不进去就静默放弃，绝不因为记不住窗口位置去打扰用户
  }

  char buffer[128];
  int length = std::snprintf(buffer, sizeof(buffer), "%d %d %d %d %d\n",
                             geometry.x, geometry.y, geometry.width,
                             geometry.height, geometry.maximized ? 1 : 0);
  if (length > 0) {
    std::fwrite(buffer, 1, static_cast<size_t>(length), file);
  }
  std::fclose(file);
}

}  // namespace window_state
