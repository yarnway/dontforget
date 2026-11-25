#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <io.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <stdio.h>
#include <windows.h>

#include <cwchar>
#include <iostream>

#include "flutter_window.h"
#include "utils.h"

namespace {

bool HasValidStdHandle(DWORD std_handle_id) {
  HANDLE handle = ::GetStdHandle(std_handle_id);
  if (handle == nullptr || handle == INVALID_HANDLE_VALUE) {
    return false;
  }
  return ::GetFileType(handle) != FILE_TYPE_UNKNOWN;
}

bool IsRedirectedFileOrPipe(DWORD std_handle_id) {
  HANDLE handle = ::GetStdHandle(std_handle_id);
  if (handle == nullptr || handle == INVALID_HANDLE_VALUE) {
    return false;
  }
  const DWORD type = ::GetFileType(handle);
  return type == FILE_TYPE_PIPE || type == FILE_TYPE_DISK;
}

void AttachConsoleDeviceToStream(DWORD std_handle_id,
                                 FILE* stream,
                                 const wchar_t* wide_device,
                                 const char* narrow_device,
                                 DWORD access,
                                 const char* mode) {
  HANDLE handle = ::CreateFileW(
      wide_device, access, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
      OPEN_EXISTING, 0, nullptr);
  if (handle != INVALID_HANDLE_VALUE) {
    ::SetStdHandle(std_handle_id, handle);
  }
  FILE* unused = nullptr;
  (void)freopen_s(&unused, narrow_device, mode, stream);
  if (stream != stdin) {
    ::setvbuf(stream, nullptr, _IONBF, 0);
  }
}

void ConfigureStandardStreams() {
  const bool had_stdout = HasValidStdHandle(STD_OUTPUT_HANDLE);
  const bool had_stderr = HasValidStdHandle(STD_ERROR_HANDLE);
  const bool had_stdin = HasValidStdHandle(STD_INPUT_HANDLE);
  const bool any_redirected_output =
      IsRedirectedFileOrPipe(STD_OUTPUT_HANDLE) ||
      IsRedirectedFileOrPipe(STD_ERROR_HANDLE);

  bool attached_parent = false;
  if (!had_stdout || !had_stderr || !had_stdin) {
    attached_parent = ::AttachConsole(ATTACH_PARENT_PROCESS) != FALSE;
  }

  if (!attached_parent && !had_stdout && !had_stderr && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
    return;
  }

  if (!attached_parent) {
    return;
  }

  bool attached_console_output = false;
  if (!had_stdout) {
    AttachConsoleDeviceToStream(
        STD_OUTPUT_HANDLE, stdout, L"CONOUT$", "CONOUT$",
        GENERIC_READ | GENERIC_WRITE, "w");
    attached_console_output = true;
  }
  if (!had_stderr) {
    AttachConsoleDeviceToStream(
        STD_ERROR_HANDLE, stderr, L"CONOUT$", "CONOUT$",
        GENERIC_READ | GENERIC_WRITE, "w");
    attached_console_output = true;
  }
  if (!had_stdin) {
    AttachConsoleDeviceToStream(
        STD_INPUT_HANDLE, stdin, L"CONIN$", "CONIN$",
        GENERIC_READ | GENERIC_WRITE, "r");
  }

  // Only resync Flutter engine CRT streams to the attached console when
  // neither stdout nor stderr is redirected to a pipe or file; otherwise
  // FlutterDesktopResyncOutputStreams() reopens CONOUT$ / fails without a
  // pure console target.
  if (attached_console_output && !any_redirected_output) {
    std::ios::sync_with_stdio();
    ::FlutterDesktopResyncOutputStreams();
  }
}

// The CLI entry points reuse the same executable. They must be allowed to run
// while the GUI owns local storage so the existing "data in use" error stays
// reachable (exit code 75) instead of silently activating the window.
bool IsCliInvocation() {
  static const wchar_t *kCliFlags[] = {L"--add", L"-a",   L"--list",
                                       L"-l",    L"--help", L"-h"};
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return false;
  }
  bool matched = false;
  for (int i = 1; i < argc && !matched; ++i) {
    for (const wchar_t *flag : kCliFlags) {
      if (::wcscmp(argv[i], flag) == 0) {
        matched = true;
        break;
      }
    }
  }
  ::LocalFree(argv);
  return matched;
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
  const DWORD path_len = ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (path_len == 0 || path_len >= MAX_PATH ||
      ::GetLastError() == ERROR_INSUFFICIENT_BUFFER) {
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
  ConfigureStandardStreams();

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Give the process the same AppUserModelID the installer writes on its
  // shortcuts, so toasts raised through the Windows toast API are attributed to
  // DontForget instead of being dropped for an unknown application identity.
  ::SetCurrentProcessExplicitAppUserModelID(L"DontForget");

  const bool is_cli = IsCliInvocation();
  // Ensure protocol handler is registered in HKCU for toast activation & custom URL scheme.
  if (!is_cli) {
    RegisterProtocolHandler();
  }

  // One GUI instance per user session. The mutex is intentionally kept open for
  // the process lifetime; Windows releases it on exit.
  HANDLE single_instance_mutex = nullptr;
  if (!is_cli) {
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

  FlutterWindow window(project, !is_cli);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"DontForget", origin, size)) {
    if (single_instance_mutex != nullptr) {
      ::CloseHandle(single_instance_mutex);
    }
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
