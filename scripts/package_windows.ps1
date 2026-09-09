# DontForget Release Packaging Script
$ErrorActionPreference = "Stop"

Write-Host "[1/3] Building Flutter Windows Release..." -ForegroundColor Cyan
& C:\src\flutter\bin\flutter.bat build windows --release

Write-Host "[1.5/3] Injecting VC++ CRT & DirectX runtime DLLs for Windows 7/8/10/11 standalone compatibility..." -ForegroundColor Cyan
$releaseDir = "$PSScriptRoot\..\build\windows\x64\runner\Release"
$redistDir = "$PSScriptRoot\..\windows_redist\x64"

# Copy from project windows_redist folder
if (Test-Path $redistDir) {
    Copy-Item "$redistDir\*.dll" -Destination $releaseDir -Force
    Write-Host "  -> Bundled runtime DLLs from windows_redist\x64 successfully." -ForegroundColor Gray
}

# Fallback: ensure critical DLLs are present from System32 or VS if not already copied
$criticalDlls = @("vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll", "msvcp140_atomic_wait.dll", "msvcp140_codecvt_ids.dll", "d3dcompiler_47.dll")
foreach ($dll in $criticalDlls) {
    if (-not (Test-Path "$releaseDir\$dll")) {
        if (Test-Path "C:\Windows\System32\$dll") {
            Copy-Item "C:\Windows\System32\$dll" -Destination $releaseDir -Force
            Write-Host "  -> Fallback copied $dll from System32." -ForegroundColor Gray
        }
    }
}

Write-Host "[1.8/3] Purging test databases and dev logs for clean product build..." -ForegroundColor Cyan
Get-ChildItem -Path $releaseDir -Include "*.db","*.log","run.log","error_log.txt" -Recurse -Force | Remove-Item -Force -ErrorAction SilentlyContinue
if (Test-Path "$releaseDir\.dart_tool") {
    Remove-Item "$releaseDir\.dart_tool" -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[2/3] Compiling Inno Setup package (Setup.exe)..." -ForegroundColor Cyan
$isccPath = "C:\Users\Wayne\AppData\Local\Programs\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $isccPath)) {
    $isccCmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($isccCmd) { $isccPath = $isccCmd.Source }
}

if (Test-Path $isccPath) {
    & $isccPath "$PSScriptRoot\..\windows_installer\installer.iss"
    Write-Host "[OK] Setup installer created: dist\DontForget_Setup_v1.2.2.exe" -ForegroundColor Green
} else {
    Write-Warning "ISCC.exe not found, skipping Inno Setup."
}

Write-Host "[3/3] Creating portable zip archive (Portable.zip)..." -ForegroundColor Cyan
$zipOutput = "$PSScriptRoot\..\dist\DontForget_Portable_v1.2.2.zip"
if (Test-Path $zipOutput) { Remove-Item $zipOutput -Force }
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipOutput -Force
Write-Host "[OK] Portable zip created: dist\DontForget_Portable_v1.2.2.zip" -ForegroundColor Green

Write-Host "==================================================" -ForegroundColor Green
Write-Host "Build complete! Production deliverables in dist:" -ForegroundColor Green
Get-ChildItem "$PSScriptRoot\..\dist" | Format-Table Name, Length, LastWriteTime
Write-Host "==================================================" -ForegroundColor Green