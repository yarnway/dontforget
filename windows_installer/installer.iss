; Inno Setup Script for DontForget (别忘了)
; Defines packaging, installation, shortcuts, and full uninstallation

#define MyAppName "DontForget"
#define MyAppVersion "1.2.5"
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
; Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Main executable and all dependencies in the Release folder (Strict product build: exclude any dev/test databases and logs)
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.db,*.log,.dart_tool\*,.dart_tool,*.pdb,run.log,error_log.txt"

[Icons]
; Start Menu shortcuts with explicitly defined WorkingDir
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{group}\别忘了"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
; Desktop shortcut with explicitly defined WorkingDir
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{autodesktop}\别忘了"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent; WorkingDir: "{app}"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}"