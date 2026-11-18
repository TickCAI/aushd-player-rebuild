#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  video_host_ = std::make_unique<VideoHost>(
      GetHandle(), flutter_controller_->view()->GetNativeWindow(),
      flutter_controller_->engine()->messenger());
  native_window_ = std::make_unique<NativeWindow>(
      GetHandle(), flutter_controller_->engine()->messenger());
  trailer_textures_ = std::make_unique<TrailerTextures>(
      flutter_controller_->engine()->messenger(),
      FlutterDesktopRegistrarGetTextureRegistrar(
          flutter_controller_->engine()->GetRegistrarForPlugin("ZerkTrailerTextures")));

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    if (detached_) return;
    this->Show();
  });

  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  detached_ = true;
  video_host_ = nullptr;
  native_window_ = nullptr;
  trailer_textures_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      // This arrives with no window lifetime guarantee; the handler is guarded
      // like the one above because after OnDestroy the controller is gone.
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
    case WM_SIZE:
      // The video host is a real child window, so Windows will not resize it for
      // us. The request is coalesced inside the host: one toggle produces one
      // resize instead of one per WM_SIZE round.
      if (video_host_) video_host_->OnParentResized();
      break;
    case WM_ACTIVATE:
      if (video_host_ && video_host_->visible()) {
        video_host_->Focus();
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
