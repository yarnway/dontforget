# DontForget 快速卸载脚本 (PowerShell)
param(
    [string]$TargetDir = "$env:LOCALAPPDATA\Programs\DontForget"
)

Write-Host "======================================" -ForegroundColor Yellow
Write-Host "  DontForget 卸载程序" -ForegroundColor Yellow
Write-Host "======================================" -ForegroundColor Yellow

# 1. 退出正在运行的进程
Write-Host "[1/3] 正在关闭运行中的程序..." -ForegroundColor Gray
Get-Process dont_forget -ErrorAction SilentlyContinue | Stop-Process -Force

# 2. 删除快捷方式 (同时清理 DontForget 与遗留的中文 别忘了)
Write-Host "[2/3] 正在清理桌面与开始菜单快捷方式..." -ForegroundColor Gray
$desktopPath = [System.Environment]::GetFolderPath('Desktop')
Remove-Item "$desktopPath\DontForget.lnk" -Force -ErrorAction SilentlyContinue
Remove-Item "$desktopPath\别忘了.lnk" -Force -ErrorAction SilentlyContinue

$publicDesktop = "C:\Users\Public\Desktop"
if (Test-Path $publicDesktop) {
    Remove-Item "$publicDesktop\DontForget.lnk" -Force -ErrorAction SilentlyContinue
    Remove-Item "$publicDesktop\别忘了.lnk" -Force -ErrorAction SilentlyContinue
}

$programsPath = [System.Environment]::GetFolderPath('Programs')
Remove-Item "$programsPath\DontForget" -Recurse -Force -ErrorAction SilentlyContinue

$commonPrograms = [System.Environment]::GetFolderPath('CommonPrograms')
if (Test-Path "$commonPrograms\DontForget") {
    Remove-Item "$commonPrograms\DontForget" -Recurse -Force -ErrorAction SilentlyContinue
}

# 3. 注销 Windows 注册表卸载项 (清理所有历史与安装器冲突键)
Write-Host "[3/3] 正在注销 Windows 卸载项并删除应用文件..." -ForegroundColor Gray
Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DontForget" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{E8B3A8C1-82A4-4519-97FA-0D71CB72E9D4}_is1" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DontForget" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{E8B3A8C1-82A4-4519-97FA-0D71CB72E9D4}_is1" -Recurse -Force -ErrorAction SilentlyContinue

# 延迟删除自身安装目录
Start-Process powershell.exe -ArgumentList "-NoProfile -Command `"Start-Sleep -Seconds 1; Remove-Item -Path '$TargetDir' -Recurse -Force -ErrorAction SilentlyContinue`"" -WindowStyle Hidden

Write-Host "DontForget 已从您的计算机中完全干净卸载！" -ForegroundColor Green