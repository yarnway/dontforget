param(
    # Reuse dependencies already resolved and verified by local tests.
    [switch]$NoPub
)

$ErrorActionPreference = "Stop"
$rootDir = Split-Path $PSScriptRoot -Parent
Push-Location $rootDir
try {
    if (-not $NoPub) {
        & flutter --no-version-check pub get --enforce-lockfile
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "flutter pub get --enforce-lockfile failed (e.g. local Flutter SDK version differences). Falling back to flutter pub get."
            & flutter --no-version-check pub get
            if ($LASTEXITCODE -ne 0) { throw "Dependency resolution failed" }
        }
    }
    $releaseDir = Join-Path $rootDir "build\windows\x64\runner\Release"
    foreach ($staleAssets in @(
        (Join-Path $rootDir "build\flutter_assets"),
        (Join-Path $releaseDir "data\flutter_assets")
    )) {
        if (Test-Path -LiteralPath $staleAssets) {
            Remove-Item -Recurse -Force -LiteralPath $staleAssets
        }
    }
    $symbolsDir = Join-Path $rootDir "build\symbols\windows"
    New-Item -ItemType Directory -Force -Path $symbolsDir | Out-Null
    & flutter --no-version-check build windows --release --no-pub "--split-debug-info=$symbolsDir"
    if ($LASTEXITCODE -ne 0) { throw "Windows build failed" }
    # Work around Flutter 3.44.9 tool_backend.dart quoting -dTreeShakeIcons="true"
    # which silently disables MaterialIcons tree-shaking on desktop builds.
    $treeShakeOut = Join-Path $rootDir "build\windows\tree_shaken_assets"
    if (Test-Path -LiteralPath $treeShakeOut) { Remove-Item -Recurse -Force -LiteralPath $treeShakeOut }
    & flutter --no-version-check assemble "--output=$treeShakeOut" "-dTargetPlatform=windows-x64" "-dBuildMode=release" "-dTargetFile=lib/main.dart" "-dTreeShakeIcons=true" "release_bundle_windows-x64_assets"
    if ($LASTEXITCODE -ne 0) { throw "Windows icon tree-shaking assemble failed" }
    $shakenFont = Join-Path $treeShakeOut "flutter_assets\fonts\MaterialIcons-Regular.otf"
    $targetFont = Join-Path $releaseDir "data\flutter_assets\fonts\MaterialIcons-Regular.otf"
    if (-not (Test-Path -LiteralPath $shakenFont)) { throw "Tree-shaken MaterialIcons font missing: $shakenFont" }
    $shakenBytes = (Get-Item -LiteralPath $shakenFont).Length
    if ($shakenBytes -le 0 -or $shakenBytes -ge 200000) { throw "MaterialIcons font was not tree-shaken ($shakenBytes bytes)" }
    Copy-Item -LiteralPath $shakenFont -Destination $targetFont -Force
    Remove-Item -Recurse -Force -LiteralPath $treeShakeOut
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
    & python scripts/prune_windows_bundle.py --release-dir $releaseDir --redist-dir $redistDir.FullName
    if ($LASTEXITCODE -ne 0) { throw "Windows CRT pruning failed" }
    & python scripts/package_artifacts.py --check-clean $releaseDir
    if ($LASTEXITCODE -ne 0) { throw "Runtime data found in build output; packaging stopped" }
    foreach ($requiredOutput in @('dont_forget.exe', 'flutter_windows.dll', 'data\flutter_assets')) {
        if (-not (Test-Path -LiteralPath (Join-Path $releaseDir $requiredOutput))) {
            throw "Incomplete Windows bundle: $requiredOutput. Packaging stopped before compiling the installer."
        }
    }
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
