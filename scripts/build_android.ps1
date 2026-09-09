# Android Release Packaging Script for DontForget (别忘了)
$ErrorActionPreference = "Stop"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  DontForget - Android Build & Packaging" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$distDir = "$PSScriptRoot\..\dist"
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }

Write-Host "[1/2] Building Android Release APK..." -ForegroundColor Cyan
& C:\src\flutter\bin\flutter.bat build apk --release

$apkSource = "$PSScriptRoot\..\build\app\outputs\flutter-apk\app-release.apk"
if (Test-Path $apkSource) {
    $apkTarget = "$distDir\DontForget_Android_v1.0.0.apk"
    Copy-Item $apkSource -Destination $apkTarget -Force
    Write-Host "[OK] Release APK created: $apkTarget" -ForegroundColor Green
} else {
    Write-Warning "APK build output not found at $apkSource"
}

Write-Host "[2/2] Building Android App Bundle (AAB)..." -ForegroundColor Cyan
& C:\src\flutter\bin\flutter.bat build appbundle --release

$aabSource = "$PSScriptRoot\..\build\app\outputs\bundle\release\app-release.aab"
if (Test-Path $aabSource) {
    $aabTarget = "$distDir\DontForget_Android_v1.0.0.aab"
    Copy-Item $aabSource -Destination $aabTarget -Force
    Write-Host "[OK] Release AAB created: $aabTarget" -ForegroundColor Green
}

Write-Host "=============================================" -ForegroundColor Green
Write-Host "Android deliverables ready in dist directory." -ForegroundColor Green
