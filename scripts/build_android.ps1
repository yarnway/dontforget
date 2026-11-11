param(
    [switch]$NoPub,
    # Kotlin's relative-path cache cannot span a C: Pub cache and a D: project.
    [switch]$DisableKotlinIncremental
)

$ErrorActionPreference = "Stop"
$rootDir = Split-Path $PSScriptRoot -Parent
Push-Location $rootDir
try {
    if (-not $NoPub) {
        & flutter --no-version-check pub get --enforce-lockfile
        if ($LASTEXITCODE -ne 0) { throw "Dependency resolution failed" }
    }
    $registrant = Join-Path $rootDir 'android\app\src\main\java\io\flutter\plugins\GeneratedPluginRegistrant.java'
    if (-not (Test-Path -LiteralPath $registrant -PathType Leaf)) {
        throw "Android plugin registration is missing. Run flutter pub get before building with -NoPub."
    }
    $variantArgs = if ($DisableKotlinIncremental) { @('--disable-kotlin-incremental') } else { @() }
    & python scripts/build_android_variants.py @variantArgs
    if ($LASTEXITCODE -ne 0) { throw "Android variants build failed" }
    & python scripts/package_artifacts.py --platform android
    if ($LASTEXITCODE -ne 0) { throw "Android packaging failed" }
} finally { Pop-Location }
