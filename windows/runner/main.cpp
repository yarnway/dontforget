#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shobjidl.h>
#include <windows.h>

#include <cwchar>

#include "flutter_window.h"
#include "utils.h"

namespace {

// The CLI entry points reuse the same executable. They must be allowed to run
// while the GUI owns local storage so the existing "data in use" error stays
// reachable (exit code 75) instead of silently activating the window.
bool IsCliInvocation(const wchar_t *command_line) {
  static const wchar_t *kCliFlags[] = {L"--add", L"-a",   L"--list",
                                       L"-l",    L"--help", L"-h"};
  if (command_line == nullptr) {
    return false;
  }
  for (const wchar_t *flag : kCliFlags) {
    if (::wcsstr(command_line, flag) != nullptr) {
      return true;
    }
  }
  return false;
}

// A second GUI launch activates the instance that already owns the database
// instead of opening a second editor over the same store.
void ActivateExistingWindow(const wchar_t *command_line) {
  // The window may still be under construction when a double launch races in.
  for (int attempt = 0; attempt < 40; ++attempt) {
    HWND existing =
        ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"DontForget");
    if (existing != nullptr) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      } else {
        ::ShowWindow(existing, SW_SHOW);
      }
      ::SetForegroundWindow(existing);

      if (command_line != nullptr && wcslen(command_line) > 0) {
        COPYDATASTRUCT cds;
        cds.dwData = 0x4446;  // 'DF' (DontForget)
        cds.cbData = static_cast<DWORD>((wcslen(command_line) + 1) * sizeof(wchar_t));
        cds.lpData = const_cast<wchar_t*>(command_line);
        ::SendMessageW(existing, WM_COPYDATA, reinterpret_cast<WPARAM>(existing),
                       reinterpret_cast<LPARAM>(&cds));
      }
      return;
    }
    ::Sleep(100);
  }
}

// Registers the `dontforget://` custom protocol scheme in HKCU so that toast
// notification clicks and external links can activate the application.
void RegisterProtocolHandler() {
  wchar_t exe_path[MAX_PATH];
  if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) == 0) {
    return;
  }

  HKEY hKey;
  LSTATUS status = ::RegCreateKeyExW(
      HKEY_CURRENT_USER,
      L"Software\\Classes\\dontforget",
      0, nullptr, REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &hKey, nullptr);
  if (status != ERROR_SUCCESS) return;

  const wchar_t* desc = L"URL:DontForget Protocol";
  ::RegSetValueExW(hKey, nullptr, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(desc),
                   static_cast<DWORD>((wcslen(desc) + 1) * sizeof(wchar_t)));

  const wchar_t* empty = L"";
  ::RegSetValueExW(hKey, L"URL Protocol", 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(empty),
                   sizeof(wchar_t));

  HKEY hCmdKey;
  status = ::RegCreateKeyExW(
      hKey, L"shell\\open\\command", 0, nullptr,
      REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &hCmdKey, nullptr);
  if (status == ERROR_SUCCESS) {
    wchar_t cmd_value[MAX_PATH + 16];
    swprintf_s(cmd_value, L"\"%s\" \"%%1\"", exe_path);
    ::RegSetValueExW(
        hCmdKey, nullptr, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(cmd_value),
        static_cast<DWORD>((wcslen(cmd_value) + 1) * sizeof(wchar_t)));
    ::RegCloseKey(hCmdKey);
  }
  ::RegCloseKey(hKey);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., terminal CLI invocation)
  if (::AttachConsole(ATTACH_PARENT_PROCESS)) {
    HANDLE hOut = CreateFile(L"CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (hOut != INVALID_HANDLE_VALUE) {
      SetStdHandle(STD_OUTPUT_HANDLE, hOut);
      SetStdHandle(STD_ERROR_HANDLE, hOut);
    }
    FILE* fp;
    freopen_s(&fp, "CONOUT$", "w", stdout);
    freopen_s(&fp, "CONOUT$", "w", stderr);
    freopen_s(&fp, "CONIN$", "r", stdin);
  } else if (::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Give the process the same AppUserModelID the installer writes on its
  // shortcuts, so toasts raised through the Windows toast API are attributed to
  // DontForget instead of being dropped for an unknown application identity.
  ::SetCurrentProcessExplicitAppUserModelID(L"DontForget");

  // Ensure protocol handler is registered in HKCU for toast activation & custom URL scheme.
  RegisterProtocolHandler();

  // One GUI instance per user session. The mutex is intentionally kept open for
  // the process lifetime; Windows releases it on exit.
  HANDLE single_instance_mutex = nullptr;
  if (!IsCliInvocation(command_line)) {
    single_instance_mutex =
        ::CreateMutexW(nullptr, FALSE, L"Local\\DontForget.SingleInstance");
    if (single_instance_mutex != nullptr &&
        ::GetLastError() == ERROR_ALREADY_EXISTS) {
      ActivateExistingWindow(command_line);
      ::CloseHandle(single_instance_mutex);
      ::CoUninitialize();
      return EXIT_SUCCESS;
    }
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"DontForget", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
