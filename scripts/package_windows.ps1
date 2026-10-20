$ErrorActionPreference = "Stop"
$rootDir = Split-Path $PSScriptRoot -Parent
Push-Location $rootDir
try {
    & flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw "Dependency resolution failed" }
    & flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw "Windows build failed" }
    $releaseDir = Join-Path $rootDir "build\windows\x64\runner\Release"
    # Use the compiler's redistributables. Do not shadow Windows 10/11's UCRT
    # with the old system DLLs in windows_redist (which includes a 2015 UCRT).
    $legacyRuntime = Get-ChildItem -LiteralPath $releaseDir -File | Where-Object {
        $_.Name -eq "ucrtbase.dll" -or $_.Name -like "api-ms-win-crt-*.dll"
    }
    if ($legacyRuntime) { throw "Legacy system runtime DLLs in build output. Preserve needed files and rebuild in a fresh directory." }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) { throw "Visual Studio locator not found" }
    $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $visualStudio) { throw "Visual Studio C++ installation not found" }
    $redistRoot = Join-Path $visualStudio "VC\Redist\MSVC"
    $redistVersion = Get-ChildItem -LiteralPath $redistRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $redistVersion) { throw "VC redistributables missing from the installed toolchain" }
    $redistDir = Get-ChildItem -Path (Join-Path $redistVersion.FullName "x64") -Directory |
        Where-Object { $_.Name -like "Microsoft.VC*.CRT" } | Select-Object -First 1
    if (-not $redistDir) { throw "x64 VC CRT directory not found" }
    Copy-Item (Join-Path $redistDir.FullName "*.dll") -Destination $releaseDir -Force
    & python scripts/package_artifacts.py --check-clean $releaseDir
    if ($LASTEXITCODE -ne 0) { throw "Runtime data found in build output; packaging stopped" }
    $version = & python scripts/package_artifacts.py --version-only
    if ($LASTEXITCODE -ne 0) { throw "Version lookup failed" }
    $isccCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    $isccPath = if ($isccCommand) { $isccCommand.Source } else { $null }
    foreach ($candidate in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")) {
        if (-not $isccPath -and (Test-Path $candidate)) { $isccPath = $candidate }
    }
    if (-not $isccPath) { throw "Inno Setup 6 is required to produce the installer" }
    & $isccPath "/DMyAppVersion=$version" windows_installer/installer.iss
    if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed" }
    & python scripts/package_artifacts.py --platform windows
    if ($LASTEXITCODE -ne 0) { throw "Windows packaging failed" }
} finally { Pop-Location }
