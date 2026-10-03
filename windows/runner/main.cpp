#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "window_state.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);

  // 窗口在 Dart 起来之前就创建了，所以初始几何只能由 runner 自己决定：
  // 读上一次关闭时记下的位置 / 大小（%APPDATA%\riji\window.txt）。
  //
  // 这里拿到的坐标是**逻辑单位（DIP）**，原样交给 Create 就好 ——
  // Create 内部会乘一次 dpi/96。绝对不要在这里再乘一次，也不能把
  // GetWindowPlacement 的物理像素原样传进来（详见 window_state.h 和
  // docs/开发须知.md §1.4）。
  //
  // 任何读取失败都已经在 LoadGeometryClampedToVisibleArea 里静默回退成
  // 默认的 (10,10) 1280x720，并且夹取回了可见区域。
  window_state::WindowGeometry geometry =
      window_state::LoadGeometryClampedToVisibleArea();

  Win32Window::Point origin(geometry.x, geometry.y);
  Win32Window::Size size(geometry.width, geometry.height);
  if (!window.Create(L"日迹", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  // 上一次是最大化的话，等第一帧出来时直接最大化显示（窗口仍然只出现一次，
  // 不会先小后大跳一下）。
  window.SetShowCommand(geometry.maximized ? SW_SHOWMAXIMIZED
                                           : SW_SHOWNORMAL);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
