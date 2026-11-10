#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  protocol_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.yarnway.dontforget/protocol",
          &flutter::StandardMethodCodec::GetInstance());

  capture_hotkey_ = std::make_unique<GlobalCaptureHotkey>(GetHandle());
  capture_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.yarnway.dontforget/global_capture",
          &flutter::StandardMethodCodec::GetInstance());
  capture_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "setEnabled") {
          result->NotImplemented();
          return;
        }
        const auto* args = call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
        if (args == nullptr) {
          result->Error("invalid_capture_binding", "Invalid shortcut request");
          return;
        }
        const auto enabled = args->find(flutter::EncodableValue("enabled"));
        const auto nonce = args->find(flutter::EncodableValue("nonce"));
        const auto* value = enabled == args->end()
            ? nullptr : std::get_if<bool>(&enabled->second);
        const auto* token = nonce == args->end()
            ? nullptr : std::get_if<std::string>(&nonce->second);
        if (value == nullptr || token == nullptr || !capture_hotkey_) {
          result->Error("invalid_capture_binding", "Invalid shortcut request");
          return;
        }
        const bool success = *value ? capture_hotkey_->Enable(*token)
                                    : capture_hotkey_->Disable();
        result->Success(flutter::EncodableValue(success));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  capture_channel_ = nullptr;
  capture_hotkey_ = nullptr;
  protocol_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Restart Manager must not fall through to the ordinary close-to-tray path.
  // Query is consent only; another application can still cancel shutdown.
  if ((lparam & ENDSESSION_CLOSEAPP) != 0) {
    if (message == WM_QUERYENDSESSION) return TRUE;
    if (message == WM_ENDSESSION) {
      if (wparam && protocol_channel_) {
        protocol_channel_->InvokeMethod("onUpgradeExit", nullptr);
      }
      return 0;
    }
  }
  if (message == WM_HOTKEY && capture_hotkey_ && capture_channel_ &&
      capture_hotkey_->Matches(wparam, lparam)) {
    capture_channel_->InvokeMethod("onCapture",
        std::make_unique<flutter::EncodableValue>(capture_hotkey_->nonce()));
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
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
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_COPYDATA: {
      auto* cds = reinterpret_cast<PCOPYDATASTRUCT>(lparam);
      if (cds != nullptr && cds->dwData == 0x4446 && cds->lpData != nullptr) {
        const wchar_t* cmd = reinterpret_cast<const wchar_t*>(cds->lpData);
        std::string utf8_cmd = Utf8FromUtf16(cmd);
        if (protocol_channel_ && !utf8_cmd.empty()) {
          protocol_channel_->InvokeMethod(
              "onProtocolUrl",
              std::make_unique<flutter::EncodableValue>(utf8_cmd));
        }
        return TRUE;
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
