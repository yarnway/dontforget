#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <string>

#include "win32_window.h"
#include "global_capture_hotkey.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool show_on_create = true);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  static constexpr UINT kUpgradeExitMessage = WM_APP + 0x44;
  static VOID CALLBACK OnUpgradeExitEvent(PVOID context,
                                          BOOLEAN timer_or_wait_fired);

  // The project to run.
  flutter::DartProject project_;
  bool show_on_create_ = true;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Method channel for communicating protocol URI activations to Flutter.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      protocol_channel_;
  std::unique_ptr<GlobalCaptureHotkey> capture_hotkey_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      capture_channel_;

  // Per-user session event signaled by the Windows installer before Restart
  // Manager runs so tray-hidden GUI windows can still shut down gracefully.
  HANDLE upgrade_exit_event_ = nullptr;
  HANDLE upgrade_exit_wait_ = nullptr;

  // Buffers early WM_COPYDATA / upgrade-exit signals until Dart registers its
  // protocol channel handler and sends the "initialize" handshake.
  bool protocol_ready_ = false;
  std::optional<std::string> pending_protocol_url_;
  bool pending_upgrade_exit_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
