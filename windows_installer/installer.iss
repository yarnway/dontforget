; Inno Setup Script for DontForget
; Defines packaging, installation, shortcuts, and full uninstallation

#define MyAppName "DontForget"
#define MyAppVersion "1.2.7"
#define MyAppPublisher "DontForget Team"
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
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
DisableProgramGroupPage=auto
MinVersion=6.1sp1

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

[Files]
; Main executable and all dependencies in the Release folder
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.db,*.log,.dart_tool\*,.dart_tool,*.pdb,run.log,error_log.txt"

[Icons]
; Single English Start Menu shortcut
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
; Single English Desktop shortcut
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent; WorkingDir: "{app}"

[UninstallDelete]
Type: files; Name: "{autodesktop}\别忘了.lnk"
Type: files; Name: "{autodesktop}\DontForget.lnk"
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}"

[Code]
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