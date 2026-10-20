$ErrorActionPreference = "Stop"
$rootDir = Split-Path $PSScriptRoot -Parent
Push-Location $rootDir
try {
    & flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw "Dependency resolution failed" }
    & flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw "Windows build failed" }
    $releaseDir = Join-Path $rootDir "build\windows\x64\runner\Release"
    $redistDir = Join-Path $rootDir "windows_redist\x64"
    if (Test-Path $redistDir) {
        Copy-Item "$redistDir\*.dll" -Destination $releaseDir -Force
    }
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
