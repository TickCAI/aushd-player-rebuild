#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Optional diagnostic escape hatch, off by default. Setting
  // AUSHD_ANGLE_PLATFORM=swiftshader (or gl) asks ANGLE to keep the Flutter
  // UI off D3D11, which leaves mpv as the only D3D11 client in the process.
  // Useful only if 1.0.10's window-layer fix still trips the AMD UMD on a
  // particular system; software UI rendering is noticeably slower.
  wchar_t angle_platform[64] = {};
  if (GetEnvironmentVariableW(L"AUSHD_ANGLE_PLATFORM", angle_platform, 64) > 0 &&
      angle_platform[0] != L'\0') {
    SetEnvironmentVariableW(L"ANGLE_DEFAULT_PLATFORM", angle_platform);
  }

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"zerk_play", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
