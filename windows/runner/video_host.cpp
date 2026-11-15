#include "video_host.h"

#include <flutter/standard_method_codec.h>

#include <string>
#include <vector>
#include <windowsx.h>

namespace {

constexpr wchar_t kClassName[] = L"ZERK_VIDEO_HOST";
constexpr UINT_PTR kCursorTimer = 1;
constexpr UINT_PTR kSyncTimer = 2;
constexpr UINT kCursorHideMs = 1500;
// Let the Flutter view finish its ANGLE swapchain rebuild before the VO
// swapchain is resized. Two DXGI resizes in one WM_SIZE cascade is what the
// AMD 32.0.32015.7029 user-mode driver cannot survive.
constexpr UINT kFullscreenSyncDelayMs = 180;
constexpr wchar_t kLegacyChildEnv[] = L"AUSHD_VIDEO_CHILD";

const char* SpecialKeyName(WPARAM vk) {
  switch (vk) {
    case VK_LEFT: return "LEFT";
    case VK_RIGHT: return "RIGHT";
    case VK_UP: return "UP";
    case VK_DOWN: return "DOWN";
    case VK_RETURN: return "ENTER";
    case VK_ESCAPE: return "ESC";
    case VK_BACK: return "BS";
    case VK_SPACE: return "SPACE";
    case VK_TAB: return "TAB";
    case VK_HOME: return "HOME";
    case VK_END: return "END";
    case VK_PRIOR: return "PGUP";
    case VK_NEXT: return "PGDWN";
    case VK_DELETE: return "DEL";
    case VK_INSERT: return "INS";
    case VK_MEDIA_PLAY_PAUSE: return "PLAYPAUSE";
    case VK_MEDIA_STOP: return "STOP";
    case VK_MEDIA_NEXT_TRACK: return "NEXT";
    case VK_MEDIA_PREV_TRACK: return "PREV";
    case VK_VOLUME_MUTE: return "MUTE";
    case VK_VOLUME_DOWN: return "VOLUME_DOWN";
    case VK_VOLUME_UP: return "VOLUME_UP";
    case VK_BROWSER_BACK: return "ESC";
    case VK_NUMPAD0: return "KP0";
    case VK_NUMPAD1: return "KP1";
    case VK_NUMPAD2: return "KP2";
    case VK_NUMPAD3: return "KP3";
    case VK_NUMPAD4: return "KP4";
    case VK_NUMPAD5: return "KP5";
    case VK_NUMPAD6: return "KP6";
    case VK_NUMPAD7: return "KP7";
    case VK_NUMPAD8: return "KP8";
    case VK_NUMPAD9: return "KP9";
  }
  return nullptr;
}

std::string Modifiers(bool include_shift) {
  std::string m;
  if (GetKeyState(VK_CONTROL) & 0x8000) m += "ctrl+";
  if (GetKeyState(VK_MENU) & 0x8000) m += "alt+";
  if (include_shift && (GetKeyState(VK_SHIFT) & 0x8000)) m += "shift+";
  return m;
}

std::string Utf8(wchar_t c) {
  char buf[8] = {};
  int n = WideCharToMultiByte(CP_UTF8, 0, &c, 1, buf, sizeof(buf), nullptr, nullptr);
  return std::string(buf, n > 0 ? n : 0);
}

}

VideoHost::VideoHost(HWND parent, HWND flutter_view, flutter::BinaryMessenger* messenger)
    : parent_(parent), flutter_view_(flutter_view) {
  // Escape hatch for diagnosis: AUSHD_VIDEO_CHILD=1 restores the pre-1.0.10
  // WS_CHILD embedding (and skips the fullscreen serialization) so a failed
  // experiment can be compared side by side without rebuilding.
  wchar_t flag[8] = {};
  legacy_child_ = GetEnvironmentVariableW(kLegacyChildEnv, flag, 8) > 0 && flag[0] == L'1';
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "zerk/video_host", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    if (method == "create") {
      EnsureCreated();
      result->Success(flutter::EncodableValue(reinterpret_cast<int64_t>(hwnd_)));
    } else if (method == "show") {
      Show();
      result->Success();
    } else if (method == "hide") {
      Hide();
      result->Success();
    } else if (method == "focus") {
      Focus();
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

VideoHost::~VideoHost() {
  channel_->SetMethodCallHandler(nullptr);
  if (hwnd_) DestroyWindow(hwnd_);
}

void VideoHost::EnsureCreated() {
  if (hwnd_) return;
  static bool registered = false;
  if (!registered) {
    WNDCLASSEX wc = {};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS;
    wc.lpfnWndProc = VideoHost::WndProc;
    wc.hInstance = GetModuleHandle(nullptr);
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    wc.lpszClassName = kClassName;
    RegisterClassEx(&wc);
    registered = true;
  }
  RECT rc;
  GetClientRect(parent_, &rc);
  POINT origin = {rc.left, rc.top};
  if (!legacy_child_) ClientToScreen(parent_, &origin);

  // Phase B: the VO used to be a WS_CHILD of the Flutter top-level window.
  // Every fullscreen toggle then changed that window's GWL_STYLE and size,
  // and the resulting WM_SIZE cascade resized both the ANGLE swapchain and
  // the mpv swapchain in the same thread, same frame. A standalone mpv in its
  // own top-level window survived 40 toggles on the same AMD driver, so the
  // coupling - not the driver API - is what trips amdxx64+0x124815.
  //
  // An owned WS_POPUP keeps the VO out of the child window tree while Windows
  // still guarantees it stays above its owner, follows minimize/restore and
  // never gets its own taskbar button. Bounds are in screen coordinates and
  // are re-synced by OnParentResized() whenever the owner moves or resizes.
  const DWORD style = legacy_child_
                          ? (WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS)
                          : (WS_POPUP | WS_CLIPCHILDREN | WS_CLIPSIBLINGS);
  hwnd_ = CreateWindowEx(0, kClassName, L"", style,
                         origin.x, origin.y, rc.right - rc.left, rc.bottom - rc.top,
                         parent_, nullptr, GetModuleHandle(nullptr), this);
  SetWindowLongPtr(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
}

void VideoHost::ApplyBounds(bool redraw) {
  if (!hwnd_ || pending_bounds_.right <= pending_bounds_.left ||
      pending_bounds_.bottom <= pending_bounds_.top) {
    return;
  }
  const int width = pending_bounds_.right - pending_bounds_.left;
  const int height = pending_bounds_.bottom - pending_bounds_.top;
  const int x = legacy_child_ ? 0 : pending_bounds_.left;
  const int y = legacy_child_ ? 0 : pending_bounds_.top;
  MoveWindow(hwnd_, x, y, width, height, redraw ? TRUE : FALSE);
  if (HWND child = GetWindow(hwnd_, GW_CHILD)) {
    MoveWindow(child, 0, 0, width, height, redraw ? TRUE : FALSE);
  }
}

void VideoHost::BeginFullscreenTransition() {
  if (legacy_child_ || !hwnd_) return;
  if (!transitioning_) {
    restore_visible_ = visible();
    if (restore_visible_) ShowWindow(hwnd_, SW_HIDE);
    transitioning_ = true;
  }
  // Re-arm on every toggle so a rapid F11 -> F11 pair still waits for the
  // last parent resize to settle before the VO is sized and shown again.
  SetTimer(hwnd_, kSyncTimer, kFullscreenSyncDelayMs, nullptr);
}

void VideoHost::EndFullscreenTransition() {
  if (!transitioning_) return;
  KillTimer(hwnd_, kSyncTimer);
  transitioning_ = false;
  OnParentResized();
  if (restore_visible_) {
    SetWindowPos(hwnd_, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_SHOWWINDOW);
    Focus();
  }
  restore_visible_ = false;
}

void VideoHost::Show() {
  EnsureCreated();
  OnParentResized();
  SetWindowPos(hwnd_, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_SHOWWINDOW);
  Focus();
}

void VideoHost::Hide() {
  if (!hwnd_) return;
  ShowWindow(hwnd_, SW_HIDE);
  SetFocus(flutter_view_);
}

void VideoHost::OnParentResized() {
  if (!hwnd_) return;
  RECT rc;
  GetClientRect(parent_, &rc);
  POINT origin = {rc.left, rc.top};
  if (!legacy_child_) ClientToScreen(parent_, &origin);
  const int width = rc.right - rc.left;
  const int height = rc.bottom - rc.top;
  pending_bounds_ = {origin.x, origin.y, origin.x + width, origin.y + height};

  // During a fullscreen toggle the parent's WM_SIZE is still being processed
  // and ANGLE is rebuilding its swapchain. Do not resize the VO in this same
  // cascade: just remember the bounds. EndFullscreenTransition() applies them
  // once the timer fires (or immediately if this call came from Show()).
  if (transitioning_) return;
  ApplyBounds(true);
}

void VideoHost::Focus() {
  if (visible()) SetFocus(hwnd_);
}

void VideoHost::SendInput(std::initializer_list<std::string> args) {
  flutter::EncodableList list;
  for (const auto& a : args) list.emplace_back(a);
  channel_->InvokeMethod("input", std::make_unique<flutter::EncodableValue>(list));
}

void VideoHost::SendKey(const std::string& name) { SendInput({"keypress", name}); }

bool VideoHost::HandleMouseMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  const std::string x = std::to_string(GET_X_LPARAM(lparam));
  const std::string y = std::to_string(GET_Y_LPARAM(lparam));
  switch (message) {
    case WM_MOUSEMOVE:
      ShowCursorNow();
      SendInput({"mouse", x, y});
      return true;
    case WM_LBUTTONDOWN:
      SetFocus(hwnd_);
      SendInput({"mouse", x, y, "0", "single"});
      return true;
    case WM_LBUTTONDBLCLK:
      SendInput({"mouse", x, y, "0", "double"});
      return true;
    case WM_RBUTTONDOWN:
      SendInput({"mouse", x, y, "2", "single"});
      return true;
    case WM_MOUSEWHEEL:
      SendKey(GET_WHEEL_DELTA_WPARAM(wparam) > 0 ? "WHEEL_UP" : "WHEEL_DOWN");
      return true;
    case WM_XBUTTONDOWN:
      SendKey(GET_XBUTTON_WPARAM(wparam) == XBUTTON1 ? "MBTN_BACK" : "MBTN_FORWARD");
      return true;
    case WM_LBUTTONUP:
    case WM_RBUTTONUP:
    case WM_XBUTTONUP:
      return true;
  }
  return false;
}

void VideoHost::ShowCursorNow() {
  cursor_hidden_ = false;
  SetCursor(LoadCursor(nullptr, IDC_ARROW));
  SetTimer(hwnd_, kCursorTimer, kCursorHideMs, nullptr);
}

bool VideoHost::HandleKeyMessage(UINT message, WPARAM wparam) {
  switch (message) {
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN: {
      if (const char* special = SpecialKeyName(wparam)) {
        SendKey(Modifiers(true) + special);
        suppress_char_ = true;
        return true;
      }
      std::string mods = Modifiers(false);
      if (!mods.empty() && ((wparam >= 'A' && wparam <= 'Z') || (wparam >= '0' && wparam <= '9'))) {
        SendKey(mods + static_cast<char>(wparam >= 'A' && wparam <= 'Z' ? wparam - 'A' + 'a' : wparam));
        suppress_char_ = true;
        return true;
      }
      if (wparam >= VK_F1 && wparam <= VK_F24) {
        SendKey(Modifiers(true) + "F" + std::to_string(wparam - VK_F1 + 1));
        return true;
      }
      suppress_char_ = false;
      return message == WM_KEYDOWN;
    }
    case WM_CHAR:
    case WM_SYSCHAR: {
      if (suppress_char_) {
        suppress_char_ = false;
        return true;
      }
      wchar_t c = static_cast<wchar_t>(wparam);
      if (c < 0x20) return true;
      SendKey(c == L'#' ? std::string("SHARP") : Utf8(c));
      return true;
    }
    case WM_KEYUP:
    case WM_SYSKEYUP:
      return message == WM_KEYUP;
  }
  return false;
}

LRESULT CALLBACK VideoHost::WndProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<VideoHost*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  switch (message) {
    case WM_KEYDOWN:
    case WM_KEYUP:
    case WM_SYSKEYDOWN:
    case WM_SYSKEYUP:
    case WM_CHAR:
    case WM_SYSCHAR:
      if (self && self->HandleKeyMessage(message, wparam)) return 0;
      break;
    case WM_MOUSEMOVE:
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
    case WM_MOUSEWHEEL:
    case WM_XBUTTONDOWN:
    case WM_XBUTTONUP:
      if (self && self->HandleMouseMessage(message, wparam, lparam)) return 0;
      break;
    case WM_TIMER:
      if (wparam == kSyncTimer && self) {
        self->EndFullscreenTransition();
        return 0;
      }
      if (wparam == kCursorTimer && self) {
        KillTimer(hwnd, kCursorTimer);
        self->cursor_hidden_ = true;
        SetCursor(nullptr);
        return 0;
      }
      break;
    case WM_SETCURSOR:
      if (self && self->cursor_hidden_ && LOWORD(lparam) == HTCLIENT) {
        SetCursor(nullptr);
        return TRUE;
      }
      break;
    case WM_GETDLGCODE:
      return DLGC_WANTALLKEYS;
    case WM_ERASEBKGND: {
      RECT rc;
      GetClientRect(hwnd, &rc);
      FillRect(reinterpret_cast<HDC>(wparam), &rc, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
      return 1;
    }
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
