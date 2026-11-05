// Native registration and lifecycle test. No keyboard injection or visible UI.
#include "global_capture_hotkey.h"
#include <iostream>
#include <stdexcept>

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
int main() {
  HWND first = ::CreateWindowExW(0, L"STATIC", L"capture-test", 0,
      0, 0, 0, 0, HWND_MESSAGE, nullptr, ::GetModuleHandleW(nullptr), nullptr);
  HWND second = ::CreateWindowExW(0, L"STATIC", L"capture-test-peer", 0,
      0, 0, 0, 0, HWND_MESSAGE, nullptr, ::GetModuleHandleW(nullptr), nullptr);
  try {
    Require(first && second, "Owned message-only windows unavailable");
    UINT key = 0;
    for (UINT candidate = VK_F13; candidate <= VK_F24; ++candidate) {
      if (::RegisterHotKey(second, 17, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, candidate)) {
        Require(::UnregisterHotKey(second, 17) != 0, "Probe cleanup failed");
        key = candidate;
        break;
      }
    }
    Require(key != 0, "No unused test shortcut available");
    {
      GlobalCaptureHotkey binding(first, key);
      Require(!binding.Enable(""), "Empty token accepted");
      Require(!binding.Enable(std::string(129, 'x')), "Oversized token accepted");
      Require(binding.Enable("session-one"), "Registration failed");
      const LPARAM keys = MAKELPARAM(MOD_CONTROL | MOD_ALT, key);
      Require(binding.Matches(0x6000, keys), "Current native message rejected");
      Require(!binding.Matches(0x6000, MAKELPARAM(MOD_CONTROL, key)), "Wrong modifiers accepted");
      Require(!binding.Matches(0x6000, MAKELPARAM(MOD_CONTROL | MOD_ALT, VK_SPACE)), "Wrong key accepted");
      Require(!::RegisterHotKey(second, 18, MOD_CONTROL | MOD_ALT, key), "Conflict was stolen");
      Require(binding.Enable("session-one"), "Idempotent enable failed");
      Require(!binding.Enable("another-session"), "Existing session silently replaced");
      Require(binding.Disable(), "Disable failed");
      Require(!binding.Matches(0x6000, keys), "Disabled message accepted");
      Require(::RegisterHotKey(second, 18, MOD_CONTROL | MOD_ALT, key) != 0, "Disabled binding not released");
      Require(!binding.Enable("blocked-session"), "Competing binding was replaced");
      Require(::UnregisterHotKey(second, 18) != 0, "Peer cleanup failed");
      Require(binding.Enable("session-two"), "Rebind failed");
      Require(!binding.Matches(0x6000, keys), "Stale message ID accepted");
      Require(binding.nonce() == "session-two", "Session nonce incorrect");
    }
    Require(::RegisterHotKey(second, 19, MOD_CONTROL | MOD_ALT, key) != 0, "Destructor did not release binding");
    Require(::UnregisterHotKey(second, 19) != 0, "Final cleanup failed");
    ::DestroyWindow(first);
    ::DestroyWindow(second);
    std::cout << "PASS: OS registration, conflict, disable, stale IDs and destructor cleanup\n";
    return 0;
  } catch (const std::exception& error) {
    if (first) ::DestroyWindow(first);
    if (second) ::DestroyWindow(second);
    std::cerr << error.what() << '\n';
    return 1;
  }
}
