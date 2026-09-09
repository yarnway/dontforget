# DontForget 快速卸载脚本 (PowerShell)
param(
    [string]$TargetDir = "$env:LOCALAPPDATA\Programs\DontForget"
)

Write-Host "======================================" -ForegroundColor Yellow
Write-Host "  DontForget (别忘了) 卸载程序" -ForegroundColor Yellow
Write-Host "======================================" -ForegroundColor Yellow

# 1. 退出正在运行的进程
Write-Host "[1/3] 正在关闭运行中的程序..." -ForegroundColor Gray
Get-Process dont_forget -ErrorAction SilentlyContinue | Stop-Process -Force

# 2. 删除快捷方式
Write-Host "[2/3] 正在清理快捷方式..." -ForegroundColor Gray
$desktopPath = [System.Environment]::GetFolderPath('Desktop')
Remove-Item "$desktopPath\DontForget.lnk" -ErrorAction SilentlyContinue

$programsPath = [System.Environment]::GetFolderPath('Programs')
Remove-Item "$programsPath\DontForget" -Recurse -Force -ErrorAction SilentlyContinue

# 3. 注销 Windows 注册表卸载项
Write-Host "[3/3] 正在注销 Windows 卸载项并删除文件..." -ForegroundColor Gray
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DontForget"
Remove-Item -Path $regPath -Force -ErrorAction SilentlyContinue

# 延迟删除自身目录
Start-Process powershell.exe -ArgumentList "-NoProfile -Command `"Start-Sleep -Seconds 1; Remove-Item -Path '$TargetDir' -Recurse -Force -ErrorAction SilentlyContinue`"" -WindowStyle Hidden

Write-Host "DontForget (别忘了) 已从您的计算机中完全卸载！" -ForegroundColor Green