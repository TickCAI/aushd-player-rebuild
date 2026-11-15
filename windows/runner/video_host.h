#ifndef RUNNER_VIDEO_HOST_H_
#define RUNNER_VIDEO_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <initializer_list>
#include <memory>
#include <string>

class VideoHost {
 public:
  VideoHost(HWND parent, HWND flutter_view, flutter::BinaryMessenger* messenger);
  ~VideoHost();

  bool visible() const { return hwnd_ != nullptr && IsWindowVisible(hwnd_); }

  /// True when the legacy WS_CHILD embedding is in use (AUSHD_VIDEO_CHILD=1).
  bool legacy_child() const { return legacy_child_; }

  /// Re-align the VO with the Flutter window's client area. Called on every
  /// parent resize/move. While a fullscreen transition is in flight the new
  /// bounds are only recorded; applying them is deferred until the parent's
  /// frame has settled.
  void OnParentResized();

  /// Bracket a fullscreen toggle. The parent window changes style and size in
  /// one message cascade; resizing the mpv swapchain in that same cascade put
  /// two D3D11 clients (ANGLE + mpv) into a concurrent rebuild that faults in
  /// amdxx64.dll. Hiding the VO first and re-syncing it on a short timer
  /// serializes the two rebuilds.
  void BeginFullscreenTransition();
  void EndFullscreenTransition();

  void Focus();

 private:
  void EnsureCreated();
  void Show();
  void Hide();
  void ApplyBounds(bool redraw);
  void SendInput(std::initializer_list<std::string> args);
  void SendKey(const std::string& name);
  bool HandleMouseMessage(UINT message, WPARAM wparam, LPARAM lparam);
  void ShowCursorNow();

  bool HandleKeyMessage(UINT message, WPARAM wparam);

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  HWND parent_;
  HWND flutter_view_;
  HWND hwnd_ = nullptr;
  bool legacy_child_ = false;
  bool transitioning_ = false;
  bool restore_visible_ = false;
  RECT pending_bounds_ = {};
  bool suppress_char_ = false;
  bool cursor_hidden_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
