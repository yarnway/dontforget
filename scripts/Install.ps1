# Use the versioned Inno installer; never purge existing application databases.
param(
    [string]$TargetDir = "$env:LOCALAPPDATA\Programs\DontForget"
)
$ErrorActionPreference = "Stop"
$rootDir = Split-Path $PSScriptRoot -Parent
Push-Location $rootDir
try {
    $version = & python scripts/package_artifacts.py --version-only
    if ($LASTEXITCODE -ne 0) { throw "Version lookup failed" }
    $revision = & git rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw "Source revision lookup failed" }
    & python scripts/verify_artifacts.py dist --platform windows --revision $revision
    if ($LASTEXITCODE -ne 0) { throw "Package verification failed; rebuild the installer first" }
    $installer = Join-Path $rootDir "dist\DontForget_Setup_v$version.exe"
    $process = Start-Process -FilePath $installer -ArgumentList "/DIR=`"$TargetDir`"" -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Installer did not complete: $($process.ExitCode)" }
} finally { Pop-Location }
