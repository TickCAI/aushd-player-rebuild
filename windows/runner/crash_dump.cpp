#include "crash_dump.h"

#include <windows.h>
#include <dbghelp.h>
#include <shlobj.h>
#include <shellscalingapi.h>
#include <stdio.h>

namespace aushd {
namespace {

constexpr wchar_t kLogDir[] = L"\\AusHD\\AusHD Player\\logs";

LONG(WINAPI* g_previous_filter)(EXCEPTION_POINTERS*) = nullptr;

// Every helper below is heap-free on purpose. The filter runs after a native
// crash (often heap corruption), so malloc/new/std::wstring may already be
// broken. Stack buffers + WriteFile are the only safe primitives here.
bool LogDirectory(wchar_t* out, DWORD out_chars) {
  wchar_t appdata[MAX_PATH] = {};
  if (FAILED(::SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr,
                                SHGFP_TYPE_CURRENT, appdata))) {
    return false;
  }
  const int written = ::swprintf_s(out, out_chars, L"%s%s", appdata, kLogDir);
  if (written <= 0) {
    return false;
  }
  ::CreateDirectoryW(out, nullptr);
  return true;
}

void Timestamp(wchar_t* out, DWORD out_chars) {
  SYSTEMTIME st = {};
  ::GetLocalTime(&st);
  ::swprintf_s(out, out_chars, L"%04d%02d%02d-%02d%02d%02d", st.wYear,
               st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
}

void WriteLine(HANDLE file, const wchar_t* text) {
  wchar_t buffer[1024] = {};
  const int len = ::swprintf_s(buffer, 1024, L"%s\r\n", text);
  if (len > 0) {
    DWORD written = 0;
    ::WriteFile(file, buffer, static_cast<DWORD>(len * sizeof(wchar_t)),
                &written, nullptr);
  }
}

LONG WINAPI CrashFilter(EXCEPTION_POINTERS* info) {
  wchar_t directory[MAX_PATH] = {};
  wchar_t stamp[64] = {};
  Timestamp(stamp, 64);

  if (LogDirectory(directory, MAX_PATH)) {
    wchar_t path[MAX_PATH] = {};
    ::swprintf_s(path, MAX_PATH, L"%s\\aushd-crash-%s.dmp", directory, stamp);
    HANDLE file = ::CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
      MINIDUMP_EXCEPTION_INFORMATION exception_info = {};
      exception_info.ThreadId = ::GetCurrentThreadId();
      exception_info.ExceptionPointers = info;
      exception_info.ClientPointers = FALSE;

      const auto type = static_cast<MINIDUMP_TYPE>(
          MiniDumpNormal | MiniDumpWithProcessThreadData |
          MiniDumpWithThreadInfo | MiniDumpWithIndirectlyReferencedMemory);
      ::MiniDumpWriteDump(::GetCurrentProcess(), ::GetCurrentProcessId(), file,
                          type, info ? &exception_info : nullptr, nullptr,
                          nullptr);
      ::CloseHandle(file);

      wchar_t summary_path[MAX_PATH] = {};
      ::swprintf_s(summary_path, MAX_PATH, L"%s\\aushd-crash-%s.txt", directory,
                   stamp);
      HANDLE summary = ::CreateFileW(
          summary_path, GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
          FILE_ATTRIBUTE_NORMAL, nullptr);
      if (summary != INVALID_HANDLE_VALUE) {
        wchar_t line[1024] = {};
        ::swprintf_s(line, 1024, L"AusHD crash at %s, pid %u, tid %u", stamp,
                     ::GetCurrentProcessId(), ::GetCurrentThreadId());
        WriteLine(summary, line);

        if (info && info->ExceptionRecord) {
          const EXCEPTION_RECORD* record = info->ExceptionRecord;
#if defined(_WIN64)
          ::swprintf_s(line, 1024,
                       L"exception 0x%016llX flags 0x%08X address %p params %u",
                       static_cast<unsigned long long>(record->ExceptionCode),
                       record->ExceptionFlags, record->ExceptionAddress,
                       record->NumberParameters);
#else
          ::swprintf_s(line, 1024,
                       L"exception 0x%08X flags 0x%08X address %p params %u",
                       record->ExceptionCode, record->ExceptionFlags,
                       record->ExceptionAddress, record->NumberParameters);
#endif
          WriteLine(summary, line);

          for (DWORD i = 0; i < record->NumberParameters && i < 15; ++i) {
#if defined(_WIN64)
            ::swprintf_s(
                line, 1024, L"  param[%u] = 0x%016llX", i,
                static_cast<unsigned long long>(record->ExceptionInformation[i]));
#else
            ::swprintf_s(line, 1024, L"  param[%u] = 0x%08X", i,
                         static_cast<unsigned int>(record->ExceptionInformation[i]));
#endif
            WriteLine(summary, line);
          }
        }
        ::swprintf_s(line, 1024, L"dump: %s", path);
        WriteLine(summary, line);
        ::CloseHandle(summary);
      }
    }
  }

  if (g_previous_filter) {
    return g_previous_filter(info);
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

void AppendDisplayDevices(HANDLE file) {
  DISPLAY_DEVICEW device = {};
  device.cb = sizeof(device);
  for (DWORD i = 0; ::EnumDisplayDevicesW(nullptr, i, &device, 0); ++i) {
    wchar_t line[1024] = {};
    const bool attached =
        (device.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;
    ::swprintf_s(line, 1024, L"gpu[%u]: %s | %s | attached=%d", i,
                 device.DeviceString, device.DeviceName, attached ? 1 : 0);
    WriteLine(file, line);
    device = {};
    device.cb = sizeof(device);
  }
}

void AppendMonitors(HANDLE file) {
  ::EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR monitor, HDC, LPRECT, LPARAM context) -> BOOL {
        HANDLE target = reinterpret_cast<HANDLE>(context);
        MONITORINFOEXW info = {};
        info.cbSize = sizeof(info);
        if (::GetMonitorInfoW(monitor, &info)) {
          UINT dpi_x = 0;
          UINT dpi_y = 0;
          ::GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
          wchar_t line[1024] = {};
          ::swprintf_s(
              line, 1024,
              L"monitor: %s rect=%ld,%ld-%ld,%ld primary=%d dpi=%u,%u",
              info.szDevice, info.rcMonitor.left, info.rcMonitor.top,
              info.rcMonitor.right, info.rcMonitor.bottom,
              (info.dwFlags & MONITORINFOF_PRIMARY) ? 1 : 0, dpi_x, dpi_y);
          WriteLine(target, line);
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(file));
}

void AppendVulkanLayers(HANDLE file) {
  struct KeyInfo {
    HKEY root;
    const wchar_t* path;
  };
  const KeyInfo keys[] = {
      {HKEY_LOCAL_MACHINE, L"SOFTWARE\\Khronos\\Vulkan\\ExplicitLayers"},
      {HKEY_LOCAL_MACHINE, L"SOFTWARE\\Khronos\\Vulkan\\ImplicitLayers"},
      {HKEY_CURRENT_USER, L"SOFTWARE\\Khronos\\Vulkan\\ImplicitLayers"},
  };
  for (const auto& key : keys) {
    HKEY handle = nullptr;
    if (::RegOpenKeyExW(key.root, key.path, 0, KEY_READ, &handle) !=
        ERROR_SUCCESS) {
      continue;
    }
    wchar_t line[1024] = {};
    ::swprintf_s(line, 1024, L"vulkan layers: %s\\%s",
                 key.root == HKEY_LOCAL_MACHINE ? L"HKLM" : L"HKCU", key.path);
    WriteLine(file, line);

    DWORD index = 0;
    wchar_t name[512] = {};
    DWORD name_length = 512;
    while (::RegEnumValueW(handle, index++, name, &name_length, nullptr,
                           nullptr, nullptr, nullptr) == ERROR_SUCCESS) {
      ::swprintf_s(line, 1024, L"  layer: %s", name);
      WriteLine(file, line);
      name_length = 512;
      name[0] = L'\0';
    }
    ::RegCloseKey(handle);
  }
}

void AppendEnvironmentSwitch(HANDLE file, const wchar_t* name) {
  wchar_t value[256] = {};
  const DWORD length = ::GetEnvironmentVariableW(name, value, 256);
  wchar_t line[1024] = {};
  ::swprintf_s(line, 1024, L"env %s = %s", name,
               length > 0 ? value : L"(unset)");
  WriteLine(file, line);
}

}  // namespace

void InstallCrashDumpHandler() {
  g_previous_filter = ::SetUnhandledExceptionFilter(&CrashFilter);
}

void WriteEnvironmentSnapshot() {
  wchar_t directory[MAX_PATH] = {};
  if (!LogDirectory(directory, MAX_PATH)) {
    return;
  }
  wchar_t stamp[64] = {};
  Timestamp(stamp, 64);
  wchar_t path[MAX_PATH] = {};
  ::swprintf_s(path, MAX_PATH, L"%s\\aushd-env-%s.txt", directory, stamp);

  HANDLE file = ::CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }

  WriteLine(file, L"AusHD Player environment snapshot");
  wchar_t line[1024] = {};
  ::swprintf_s(line, 1024, L"captured: %s", stamp);
  WriteLine(file, line);
  ::swprintf_s(line, 1024, L"system dpi: %u", ::GetDpiForSystem());
  WriteLine(file, line);

  AppendEnvironmentSwitch(file, L"AUSHD_VIDEO_CHILD");
  AppendEnvironmentSwitch(file, L"AUSHD_ANGLE_PLATFORM");
  AppendEnvironmentSwitch(file, L"ANGLE_DEFAULT_PLATFORM");
  AppendEnvironmentSwitch(file, L"VK_LOADER_LAYERS_DISABLE");

  AppendDisplayDevices(file);
  AppendMonitors(file);
  AppendVulkanLayers(file);

  ::CloseHandle(file);
}

}  // namespace aushd
