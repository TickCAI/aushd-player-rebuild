#ifndef RUNNER_NATIVE_WINDOW_H_
#define RUNNER_NATIVE_WINDOW_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class NativeWindow {
 public:
  NativeWindow(HWND window, flutter::BinaryMessenger* messenger);

  ~NativeWindow();

  bool fullscreen() const { return fullscreen_; }

 private:
  // Returns true only when the requested state was actually applied. The
  // previous version returned void and reported success on every call, so a
  // failed GetMonitorInfo left Dart believing the window was fullscreen while
  // the native side had changed nothing.
  bool SetFullScreen(bool fullscreen);

  // True when the window rect covers the monitor rect within a pixel or two.
  bool CoversMonitor() const;

  // Resting state captured on the first enter, restored on exit.
  bool CaptureWindowedState();
  void RestoreWindowedState();

  struct HdrStatus {
    bool supported = false;
    bool enabled = false;
  };
  HdrStatus GetHdrStatus() const;
  bool SetHdr(bool enabled);

  HWND window_;
  bool fullscreen_ = false;
  // A second enter must not overwrite the state we have to return to.
  bool windowed_state_valid_ = false;
  LONG_PTR saved_style_ = 0;
  WINDOWPLACEMENT saved_placement_ = {sizeof(WINDOWPLACEMENT)};
  bool hdr_enabled_by_app_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_NATIVE_WINDOW_H_
