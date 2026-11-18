#include "native_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <vector>

#include "window_metrics.h"

namespace {

constexpr int kGetAdvancedColorInfo = 9;
constexpr int kSetAdvancedColorState = 10;
constexpr int kGetAdvancedColorInfo2 = 15;
constexpr int kSetHdrState = 16;

flutter::EncodableValue RectValue(const RECT& rc) {
  return flutter::EncodableValue(flutter::EncodableList{
      flutter::EncodableValue(static_cast<int64_t>(rc.left)),
      flutter::EncodableValue(static_cast<int64_t>(rc.top)),
      flutter::EncodableValue(static_cast<int64_t>(rc.right)),
      flutter::EncodableValue(static_cast<int64_t>(rc.bottom)),
  });
}

struct AdvancedColorInfo {
  DISPLAYCONFIG_DEVICE_INFO_HEADER header;
  UINT32 flags;
  UINT32 color_encoding;
  UINT32 bits_per_color_channel;
};

struct AdvancedColorInfo2 {
  DISPLAYCONFIG_DEVICE_INFO_HEADER header;
  UINT32 flags;
  UINT32 color_encoding;
  UINT32 bits_per_color_channel;
  UINT32 active_color_mode;
};

struct SetColorState {
  DISPLAYCONFIG_DEVICE_INFO_HEADER header;
  UINT32 flags;
};

struct Target {
  LUID adapter;
  UINT32 id;
};

std::optional<Target> TargetFor(HWND window) {
  MONITORINFOEXW mi = {};
  mi.cbSize = sizeof(mi);
  if (!GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &mi)) return std::nullopt;

  UINT32 path_count = 0, mode_count = 0;
  if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count) != ERROR_SUCCESS) {
    return std::nullopt;
  }
  std::vector<DISPLAYCONFIG_PATH_INFO> paths(path_count);
  std::vector<DISPLAYCONFIG_MODE_INFO> modes(mode_count);
  if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &path_count, paths.data(), &mode_count, modes.data(),
                         nullptr) != ERROR_SUCCESS) {
    return std::nullopt;
  }
  for (UINT32 i = 0; i < path_count; i++) {
    const auto& path = paths[i];
    DISPLAYCONFIG_SOURCE_DEVICE_NAME source = {};
    source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
    source.header.size = sizeof(source);
    source.header.adapterId = path.sourceInfo.adapterId;
    source.header.id = path.sourceInfo.id;
    if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS) continue;
    if (wcscmp(source.viewGdiDeviceName, mi.szDevice) == 0) {
      return Target{path.targetInfo.adapterId, path.targetInfo.id};
    }
  }
  return std::nullopt;
}

template <typename T>
void InitHeader(T& info, int type, const Target& target) {
  info.header.type = static_cast<DISPLAYCONFIG_DEVICE_INFO_TYPE>(type);
  info.header.size = sizeof(T);
  info.header.adapterId = target.adapter;
  info.header.id = target.id;
}

}

NativeWindow::NativeWindow(HWND window, flutter::BinaryMessenger* messenger) : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "zerk/window", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    const auto* arg = std::get_if<bool>(call.arguments());
    if (method == "isFullScreen") {
      result->Success(flutter::EncodableValue(fullscreen_));
    } else if (method == "setFullScreen" && arg) {
      // Report what actually happened. Dart treats false as "state did not
      // change" and re-reads the native value instead of trusting its cache.
      result->Success(flutter::EncodableValue(SetFullScreen(*arg)));
    } else if (method == "diag") {
      RECT window_rect = {};
      RECT client_rect = {};
      MONITORINFO mi = {sizeof(mi)};
      LONG_PTR style = 0;
      if (window_) {
        GetWindowRect(window_, &window_rect);
        GetClientRect(window_, &client_rect);
        style = GetWindowLongPtr(window_, GWL_STYLE);
        GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &mi);
      }
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("fullscreen"), flutter::EncodableValue(fullscreen_)},
          {flutter::EncodableValue("style"), flutter::EncodableValue(static_cast<int64_t>(style))},
          {flutter::EncodableValue("windowRect"), RectValue(window_rect)},
          {flutter::EncodableValue("clientRect"), RectValue(client_rect)},
          {flutter::EncodableValue("monitorRect"), RectValue(mi.rcMonitor)},
          {flutter::EncodableValue("wmSize"),
           flutter::EncodableValue(static_cast<int64_t>(window_metrics::wm_size_count.load()))},
          {flutter::EncodableValue("minimizedResize"),
           flutter::EncodableValue(static_cast<int64_t>(window_metrics::minimized_resize_count.load()))},
          {flutter::EncodableValue("moveWindows"),
           flutter::EncodableValue(static_cast<int64_t>(window_metrics::move_window_count.load()))},
          {flutter::EncodableValue("coalesced"),
           flutter::EncodableValue(static_cast<int64_t>(window_metrics::coalesced_resize_count.load()))},
          {flutter::EncodableValue("mismatch"),
           flutter::EncodableValue(static_cast<int64_t>(window_metrics::fullscreen_rect_mismatch.load()))},
          {flutter::EncodableValue("setWindowPosFailures"),
           flutter::EncodableValue(
               static_cast<int64_t>(window_metrics::set_window_pos_failure_count.load()))},
      }));
    } else if (method == "hdrStatus") {
      const auto status = GetHdrStatus();
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("supported"), flutter::EncodableValue(status.supported)},
          {flutter::EncodableValue("enabled"), flutter::EncodableValue(status.enabled)},
      }));
    } else if (method == "setHdr" && arg) {
      result->Success(flutter::EncodableValue(SetHdr(*arg)));
    } else {
      result->NotImplemented();
    }
  });
}

NativeWindow::~NativeWindow() {
  channel_->SetMethodCallHandler(nullptr);
  if (hdr_enabled_by_app_) SetHdr(false);
}

bool NativeWindow::CaptureWindowedState() {
  if (windowed_state_valid_) return true;
  saved_placement_.length = sizeof(saved_placement_);
  if (!GetWindowPlacement(window_, &saved_placement_)) return false;
  saved_style_ = GetWindowLongPtr(window_, GWL_STYLE);
  windowed_state_valid_ = true;
  return true;
}

bool NativeWindow::CoversMonitor() const {
  if (!window_ || !IsWindow(window_)) return false;
  MONITORINFO mi = {sizeof(mi)};
  if (!GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &mi)) return false;
  RECT rc = {};
  if (!GetWindowRect(window_, &rc)) return false;
  constexpr int kTolerance = 2;
  return rc.left <= mi.rcMonitor.left + kTolerance && rc.top <= mi.rcMonitor.top + kTolerance &&
         rc.right >= mi.rcMonitor.right - kTolerance &&
         rc.bottom >= mi.rcMonitor.bottom - kTolerance;
}

void NativeWindow::RestoreWindowedState() {
  if (!windowed_state_valid_) return;
  SetWindowLongPtr(window_, GWL_STYLE, saved_style_);
  // SetWindowPlacement restores the saved show command, which is what makes a
  // window that was maximized before fullscreen come back maximized.
  SetWindowPlacement(window_, &saved_placement_);
  windowed_state_valid_ = false;
}

bool NativeWindow::SetFullScreen(bool fullscreen) {
  if (!window_ || !IsWindow(window_)) return false;
  if (fullscreen == fullscreen_) return true;

  if (fullscreen) {
    MONITORINFO mi = {sizeof(mi)};
    if (!GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &mi)) {
      // No monitor means no target rect. Reporting failure is the whole point of
      // the bool: the old code returned void after a silent no-op, and Dart kept
      // a fullscreen belief that mpv and the layout code then acted on.
      return false;
    }
    if (!CaptureWindowedState()) return false;

    const RECT& rc = mi.rcMonitor;
    // Drop the frame styles but keep the window itself. WS_OVERLAPPEDWINDOW is
    // caption + thick frame + sysmenu + min/max boxes.
    const LONG_PTR style = saved_style_ & ~static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW);
    SetWindowLongPtr(window_, GWL_STYLE, style);
    // SWP_FRAMECHANGED is back on purpose. v1.0.9 removed it based on a dump
    // reading that turned out to be wrong: amdxx64+0x124815 was a return address
    // on the stack, not the faulting PC, so the crash never came from the
    // non-client recompute. Without the flag the client area stays sized for the
    // old frame and only gets corrected by some later unrelated resize, which is
    // the "first fullscreen is wrong" symptom. SWP_NOSENDCHANGING stops a
    // WM_WINDOWPOSCHANGING handler from vetoing the transition halfway through.
    if (!SetWindowPos(window_, HWND_TOP, rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top,
                      SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_NOSENDCHANGING)) {
      window_metrics::set_window_pos_failure_count++;
      return false;
    }
    if (!CoversMonitor()) {
      // Applied, but the window does not cover the monitor: recorded rather than
      // hidden, because this is exactly the geometry a soak can assert on.
      window_metrics::fullscreen_rect_mismatch++;
    }
    fullscreen_ = true;
    return true;
  }

  if (!windowed_state_valid_) {
    // Nothing to restore: already windowed, or the window was created fullscreen
    // by some other path. The state is consistent, so this is a success.
    fullscreen_ = false;
    return true;
  }
  RestoreWindowedState();
  // Force the non-client area to be recomputed for the restored style; without
  // it the frame comes back but the client rect keeps the fullscreen size until
  // the next unrelated resize.
  if (!SetWindowPos(window_, nullptr, 0, 0, 0, 0,
                    SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                        SWP_NOSENDCHANGING)) {
    window_metrics::set_window_pos_failure_count++;
    return false;
  }
  fullscreen_ = false;
  return true;
}

NativeWindow::HdrStatus NativeWindow::GetHdrStatus() const {
  HdrStatus status;
  const auto target = TargetFor(window_);
  if (!target) return status;

  AdvancedColorInfo2 info2 = {};
  InitHeader(info2, kGetAdvancedColorInfo2, *target);
  if (DisplayConfigGetDeviceInfo(&info2.header) == ERROR_SUCCESS) {
    status.supported = (info2.flags & (1u << 4)) != 0;
    status.enabled = info2.active_color_mode == 2;
    return status;
  }
  AdvancedColorInfo info = {};
  InitHeader(info, kGetAdvancedColorInfo, *target);
  if (DisplayConfigGetDeviceInfo(&info.header) == ERROR_SUCCESS) {
    const bool wide_color_only = (info.flags & (1u << 2)) != 0;
    status.supported = (info.flags & 1u) != 0 && !wide_color_only;
    status.enabled = (info.flags & (1u << 1)) != 0 && !wide_color_only;
  }
  return status;
}

bool NativeWindow::SetHdr(bool enabled) {
  const auto target = TargetFor(window_);
  if (!target) return false;
  const auto before = GetHdrStatus();
  if (!before.supported) return false;
  if (before.enabled == enabled) {
    if (!enabled) hdr_enabled_by_app_ = false;
    return true;
  }

  SetColorState state = {};
  InitHeader(state, kSetHdrState, *target);
  state.flags = enabled ? 1u : 0u;
  LONG rc = DisplayConfigSetDeviceInfo(&state.header);
  if (rc != ERROR_SUCCESS) {
    InitHeader(state, kSetAdvancedColorState, *target);
    rc = DisplayConfigSetDeviceInfo(&state.header);
  }
  if (rc != ERROR_SUCCESS) return false;
  hdr_enabled_by_app_ = enabled;
  return true;
}
