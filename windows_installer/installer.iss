; Inno Setup Script for DontForget
; Defines packaging, installation, shortcuts, and full uninstallation

#define MyAppName "DontForget"
#ifndef MyAppVersion
  #error Pass /DMyAppVersion from pubspec.yaml using scripts/package_windows.ps1
#endif
#define MyAppPublisher "Yarnway"
#define MyAppExeName "dont_forget.exe"
#define SourceDir "..\build\windows\x64\runner\Release"

[Setup]
; Unique application GUID
AppId={{E8B3A8C1-82A4-4519-97FA-0D71CB72E9D4}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
; Output setup file
OutputDir=..\dist
OutputBaseFilename=DontForget_Setup_v{#MyAppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2/ultra64
LZMADictionarySize=65536
LZMANumFastBytes=273
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
DisableProgramGroupPage=auto
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Actively remove legacy Chinese shortcuts from earlier installations
Type: files; Name: "{autodesktop}\别忘了.lnk"
Type: files; Name: "{group}\别忘了.lnk"
Type: files; Name: "{userdesktop}\别忘了.lnk"
Type: files; Name: "{commondesktop}\别忘了.lnk"
Type: files; Name: "{userprograms}\DontForget\别忘了.lnk"
Type: files; Name: "{commonprograms}\DontForget\别忘了.lnk"
; Remove unused CRT/shim DLLs and removed package assets left by pre-v1.8.21 versions
Type: files; Name: "{app}\concrt140.dll"
Type: files; Name: "{app}\dartjni.dll"
Type: files; Name: "{app}\msvcp140_1.dll"
Type: files; Name: "{app}\msvcp140_2.dll"
Type: files; Name: "{app}\msvcp140_atomic_wait.dll"
Type: files; Name: "{app}\msvcp140_codecvt_ids.dll"
Type: files; Name: "{app}\vccorlib140.dll"
Type: files; Name: "{app}\vcruntime140_threads.dll"
Type: filesandordirs; Name: "{app}\data\flutter_assets\packages\cupertino_icons"
Type: filesandordirs; Name: "{app}\data\flutter_assets\packages\record_web"

[Registry]
; Register dontforget:// protocol for Toast notification activation and custom URL scheme
Root: HKCU; Subkey: "Software\Classes\dontforget"; ValueType: string; ValueName: ""; ValueData: "URL:DontForget Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\dontforget"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\dontforget\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Flags: uninsdeletekey
; Register AppUserModelId metadata so Windows 10/11 Toast notifications display the app name and brand icon
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\DontForget"; ValueType: string; ValueName: "DisplayName"; ValueData: "{#MyAppName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\DontForget"; ValueType: string; ValueName: "IconUri"; ValueData: "{app}\data\flutter_assets\assets\app_icon.png"; Flags: uninsdeletekey

[Files]
; Main executable and all dependencies in the Release folder
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.db,*.log,.dart_tool\*,.dart_tool,*.pdb,run.log,error_log.txt"

[Icons]
; Single English Start Menu shortcut. The AppUserModelID must match
; WindowsToast.appUserModelId and windows/runner/main.cpp so Windows attributes
; toasts to this application.
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; AppUserModelID: "DontForget"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
; Single English Desktop shortcut
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon; AppUserModelID: "DontForget"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent; WorkingDir: "{app}"

[UninstallDelete]
Type: files; Name: "{autodesktop}\别忘了.lnk"
Type: files; Name: "{autodesktop}\DontForget.lnk"
; Inno removes files it installed. Preserve unknown files and legacy user data.

[Code]
const
  EVENT_MODIFY_STATE = $0002;
  SYNCHRONIZE = $00100000;

function OpenEventW(dwDesiredAccess: DWORD; bInheritHandle: BOOL; lpName: string): THandle;
  external 'OpenEventW@kernel32.dll stdcall';
function SetEvent(hEvent: THandle): BOOL;
  external 'SetEvent@kernel32.dll stdcall';
function OpenMutexW(dwDesiredAccess: DWORD; bInheritHandle: BOOL; lpName: string): THandle;
  external 'OpenMutexW@kernel32.dll stdcall';
function CloseHandle(hObject: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';

function HasNoCloseApplicationsFlag(): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    if CompareText(ParamStr(I), '/NOCLOSEAPPLICATIONS') = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function IsDontForgetRunning(): Boolean;
var
  HMutex: THandle;
begin
  HMutex := OpenMutexW(SYNCHRONIZE, False, 'Local\DontForget.SingleInstance');
  if HMutex <> 0 then
  begin
    CloseHandle(HMutex);
    Result := True;
  end
  else
    Result := False;
end;

procedure RequestGracefulAppExit();
var
  HEvent: THandle;
  Attempt: Integer;
begin
  if HasNoCloseApplicationsFlag() then
    Exit;
  if not IsDontForgetRunning() then
    Exit;
  HEvent := OpenEventW(EVENT_MODIFY_STATE, False, 'Local\DontForget.GracefulUpgradeExit');
  if HEvent = 0 then
    Exit;
  try
    Log('Signaling Local\DontForget.GracefulUpgradeExit for tray-safe graceful shutdown.');
    SetEvent(HEvent);
  finally
    CloseHandle(HEvent);
  end;
  // Wait up to 8 seconds for DontForget to flush drafts/SQLite and exit on its own.
  // Never force-terminate: if still running, fall back to standard Restart Manager.
  for Attempt := 1 to 40 do
  begin
    Sleep(200);
    if not IsDontForgetRunning() then
    begin
      Log('DontForget released single-instance mutex gracefully.');
      Exit;
    end;
  end;
  Log('DontForget did not exit within 8s after graceful signal; continuing to Restart Manager.');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  RequestGracefulAppExit();
  Result := '';
end;

procedure CleanLegacyRegistry();
begin
  // Remove conflicting manual registry key registered by legacy Install.ps1 so Windows Settings only displays one clean DontForget entry
  RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\DontForget');
  RegDeleteKeyIncludingSubkeys(HKLM, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\DontForget');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    CleanLegacyRegistry();
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    CleanLegacyRegistry();
  end;
end;
