# DontForget Quick Install Script (PowerShell)
param(
    [string]$TargetDir = "$env:LOCALAPPDATA\Programs\DontForget"
)

Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  DontForget Application Installer" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

$sourceDir = "$PSScriptRoot\..\build\windows\x64\runner\Release"
if (-not (Test-Path "$sourceDir\dont_forget.exe")) {
    Write-Error "Release build not found. Please run package script first."
    exit 1
}

# 1. Stop running processes
Get-Process dont_forget -ErrorAction SilentlyContinue | Stop-Process -Force

# Ensure runtime DLLs are present in sourceDir from windows_redist before install
$redistDir = "$PSScriptRoot\..\windows_redist\x64"
if (Test-Path $redistDir) {
    Copy-Item "$redistDir\*.dll" -Destination $sourceDir -Force
}

# Purge any debug/test databases
if (Test-Path "$sourceDir\.dart_tool") { Remove-Item "$sourceDir\.dart_tool" -Recurse -Force -ErrorAction SilentlyContinue }
Get-ChildItem -Path $sourceDir -Include "*.db","*.log" -Recurse -Force | Remove-Item -Force -ErrorAction SilentlyContinue

# 2. Copy application files
Write-Host "[1/4] Installing application files to: $TargetDir ..." -ForegroundColor Green
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

# Clear any previous test database in target directory to ensure clean product launch
if (Test-Path "$TargetDir\.dart_tool") { Remove-Item "$TargetDir\.dart_tool" -Recurse -Force -ErrorAction SilentlyContinue }
Get-ChildItem -Path $TargetDir -Include "*.db" -Recurse -Force | Remove-Item -Force -ErrorAction SilentlyContinue

Copy-Item -Path "$sourceDir\*" -Destination $TargetDir -Recurse -Force

# Copy uninstaller script
Copy-Item -Path "$PSScriptRoot\Uninstall.ps1" -Destination "$TargetDir\Uninstall.ps1" -Force

# 3. Create desktop and start menu shortcuts
Write-Host "[2/4] Creating desktop and start menu shortcuts..." -ForegroundColor Green
$wsh = New-Object -ComObject WScript.Shell

$cnName = [System.Text.Encoding]::UTF8.GetString([byte[]](0xE5,0x88,0xAB,0xE5,0xBF,0x98,0xE4,0xBA,0x86))
$cnDesc = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('5Yir5b+Y5LqGIC0g5pm66IO95Zub6LGh6ZmQ5pel56iL5o+Q6YaS566h5a62'))

$desktopPath = [System.Environment]::GetFolderPath('Desktop')
$shortcutCnPath = Join-Path $desktopPath "$cnName.lnk"
$shortcutDesktopCn = $wsh.CreateShortcut($shortcutCnPath)
$shortcutDesktopCn.TargetPath = "$TargetDir\dont_forget.exe"
$shortcutDesktopCn.WorkingDirectory = $TargetDir
$shortcutDesktopCn.IconLocation = "$TargetDir\dont_forget.exe,0"
$shortcutDesktopCn.Description = $cnDesc
$shortcutDesktopCn.Save()

$shortcutEnPath = Join-Path $desktopPath "DontForget.lnk"
$shortcutDesktop = $wsh.CreateShortcut($shortcutEnPath)
$shortcutDesktop.TargetPath = "$TargetDir\dont_forget.exe"
$shortcutDesktop.WorkingDirectory = $TargetDir
$shortcutDesktop.IconLocation = "$TargetDir\dont_forget.exe,0"
$shortcutDesktop.Description = "DontForget - Intelligent Task Manager"
$shortcutDesktop.Save()

$programsPath = [System.Environment]::GetFolderPath('Programs')
$menuDir = Join-Path $programsPath "DontForget"
if (-not (Test-Path $menuDir)) { New-Item -ItemType Directory -Path $menuDir -Force | Out-Null }
$menuCnPath = Join-Path $menuDir "$cnName.lnk"
$shortcutMenu = $wsh.CreateShortcut($menuCnPath)
$shortcutMenu.TargetPath = "$TargetDir\dont_forget.exe"
$shortcutMenu.WorkingDirectory = $TargetDir
$shortcutMenu.IconLocation = "$TargetDir\dont_forget.exe,0"
$shortcutMenu.Save()

$shortcutUninst = $wsh.CreateShortcut("$menuDir\Uninstall DontForget.lnk")
$shortcutUninst.TargetPath = "powershell.exe"
$shortcutUninst.Arguments = "-ExecutionPolicy Bypass -NoProfile -File `"$TargetDir\Uninstall.ps1`""
$shortcutUninst.WorkingDirectory = $TargetDir
$shortcutUninst.Save()

# 4. Register uninstaller with Windows Control Panel / Settings
Write-Host "[3/4] Registering uninstall entry in Windows..." -ForegroundColor Green
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DontForget"
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}
Set-ItemProperty -Path $regPath -Name "DisplayName" -Value "DontForget ($cnName)"
Set-ItemProperty -Path $regPath -Name "DisplayVersion" -Value "1.0.0"
Set-ItemProperty -Path $regPath -Name "Publisher" -Value "DontForget Team"
Set-ItemProperty -Path $regPath -Name "DisplayIcon" -Value "$TargetDir\dont_forget.exe,0"
Set-ItemProperty -Path $regPath -Name "InstallLocation" -Value $TargetDir
Set-ItemProperty -Path $regPath -Name "UninstallString" -Value "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$TargetDir\Uninstall.ps1`""

Write-Host "[4/4] Installation completed successfully!" -ForegroundColor Cyan
Write-Host "Desktop and Start Menu shortcuts created." -ForegroundColor Green
Write-Host "Clean production installation ready." -ForegroundColor Green