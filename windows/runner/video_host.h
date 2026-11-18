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

  bool visible() const { return hwnd_ != nullptr && IsWindow(hwnd_) && IsWindowVisible(hwnd_); }

  // Requests a resize of the host and of the mpv VO child. The request is
  // coalesced: a fullscreen toggle delivers several WM_SIZE rounds, and the old
  // code synchronously moved the child on every one of them, which rebuilt the
  // mpv swapchain while the driver still had it referenced.
  void OnParentResized();

  // Performs the pending resize immediately. Used when the host is shown, where
  // waiting for the coalescing timer would show a stale-sized black frame.
  void FlushResize();

  void Focus();

 private:
  void EnsureCreated();
  void Show();
  void Hide();
  void SendInput(std::initializer_list<std::string> args);
  void SendKey(const std::string& name);
  bool HandleMouseMessage(UINT message, WPARAM wparam, LPARAM lparam);
  void ShowCursorNow();

  bool HandleKeyMessage(UINT message, WPARAM wparam);

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  HWND parent_;
  HWND flutter_view_;
  HWND hwnd_ = nullptr;
  bool suppress_char_ = false;
  bool cursor_hidden_ = false;
  bool resize_pending_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_VIDEO_HOST_H_
