#ifndef RUNNER_NATIVE_WINDOW_H_
#define RUNNER_NATIVE_WINDOW_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class VideoHost;

class NativeWindow {
 public:
  NativeWindow(HWND window, VideoHost* video_host,
               flutter::BinaryMessenger* messenger);

  ~NativeWindow();

  bool fullscreen() const { return fullscreen_; }

 private:
  void SetFullScreen(bool fullscreen);

  struct HdrStatus {
    bool supported = false;
    bool enabled = false;
  };
  HdrStatus GetHdrStatus() const;
  bool SetHdr(bool enabled);

  HWND window_;
  // Not owned. Used to park the VO while this window rebuilds its frame.
  VideoHost* video_host_ = nullptr;
  bool fullscreen_ = false;
  LONG_PTR saved_style_ = 0;
  WINDOWPLACEMENT saved_placement_ = {sizeof(WINDOWPLACEMENT)};
  bool hdr_enabled_by_app_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
