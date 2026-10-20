$ErrorActionPreference = "Stop"
$rootDir = Split-Path $PSScriptRoot -Parent
Push-Location $rootDir
try {
    & flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw "Dependency resolution failed" }
    & flutter build apk --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw "APK build failed" }
    & flutter build appbundle --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw "AAB build failed" }
    & python scripts/package_artifacts.py --platform android
    if ($LASTEXITCODE -ne 0) { throw "Android packaging failed" }
} finally { Pop-Location }
