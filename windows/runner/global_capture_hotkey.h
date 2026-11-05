#ifndef RUNNER_GLOBAL_CAPTURE_HOTKEY_H_
#define RUNNER_GLOBAL_CAPTURE_HOTKEY_H_

#include <windows.h>
#include <string>

// One opt-in binding per window. Rotating IDs reject messages queued before
// disable/recovery; registering never replaces another application's shortcut.
class GlobalCaptureHotkey {
 public:
  explicit GlobalCaptureHotkey(HWND window, UINT key = VK_SPACE)
      : window_(window), key_(key) {}
  ~GlobalCaptureHotkey() { Disable(); }
  GlobalCaptureHotkey(const GlobalCaptureHotkey&) = delete;
  GlobalCaptureHotkey& operator=(const GlobalCaptureHotkey&) = delete;

  bool Enable(const std::string& nonce) {
    if (nonce.empty() || nonce.size() > 128) return false;
    if (enabled_) return nonce == nonce_;
    if (next_id_ > 0xBFFF) return false;
    const int id = next_id_++;
    if (!::RegisterHotKey(window_, id, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT,
                          key_)) return false;
    id_ = id;
    nonce_ = nonce;
    enabled_ = true;
    return true;
  }

  bool Disable() {
    if (!enabled_) return true;
    if (!::UnregisterHotKey(window_, id_) &&
        ::GetLastError() != ERROR_HOTKEY_NOT_REGISTERED) return false;
    enabled_ = false;
    nonce_.clear();
    return true;
  }

  bool Matches(WPARAM id, LPARAM keys) const {
    return enabled_ && static_cast<int>(id) == id_ &&
           (LOWORD(keys) & ~MOD_NOREPEAT) == (MOD_CONTROL | MOD_ALT) &&
           HIWORD(keys) == key_;
  }
  const std::string& nonce() const { return nonce_; }

 private:
  HWND window_;
  UINT key_;
  int next_id_ = 0x6000;
  int id_ = 0;
  bool enabled_ = false;
  std::string nonce_;
};
#endif  // RUNNER_GLOBAL_CAPTURE_HOTKEY_H_
