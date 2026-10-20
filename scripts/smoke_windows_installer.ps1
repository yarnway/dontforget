# Install/upgrade/uninstall only in an owned directory on an isolated CI runner.
$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true" -or -not $env:RUNNER_TEMP) {
    throw "Installer acceptance must run on an isolated GitHub runner"
}
$rootDir = Split-Path $PSScriptRoot -Parent
$manifestPath = Join-Path $rootDir "dist\windows-manifest.json"
$manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
$setup = Join-Path $rootDir "dist\DontForget_Setup_v$($manifest.version).exe"
$work = Join-Path $env:RUNNER_TEMP ("dontforget-install-" + [guid]::NewGuid().ToString())
$target = Join-Path $work "Application With Spaces"
$result = [ordered]@{
    revision = $manifest.revision
    version = $manifest.version
    scope = "installer-upgrade-uninstall-with-legacy-file-preservation"
    result = "FAIL"
    real_database_migration = "NOT_PERFORMED"
}
function Invoke-Installer([string]$file, [string[]]$arguments) {
    $process = Start-Process -FilePath $file -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Installer exited with code $($process.ExitCode)" }
}
try {
    $legacy = Join-Path $target ".dart_tool\sqflite_common_ffi\databases\dont_forget_v3.db"
    New-Item -ItemType Directory -Path (Split-Path $legacy -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($legacy, "legacy-preservation-fixture-not-a-real-database")
    $before = (Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash
    $arguments = @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CURRENTUSER", "/DIR=`"$target`"")
    # First install and then an in-place upgrade with the same candidate.
    foreach ($pass in 1..2) {
        Invoke-Installer $setup $arguments
        $executable = Join-Path $target "dont_forget.exe"
        if (-not (Test-Path -LiteralPath $executable)) { throw "Installed executable missing" }
        $nativeVersion = (Get-Item -LiteralPath $executable).VersionInfo.ProductVersion
        if (-not $nativeVersion.StartsWith($manifest.version)) { throw "Installed executable version mismatch: $nativeVersion" }
        if ((Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash -ne $before) { throw "Install changed legacy data" }
    }
    Invoke-Installer (Join-Path $target "unins000.exe") @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART")
    if (Test-Path -LiteralPath $executable) { throw "Uninstall left the installed executable" }
    if ((Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash -ne $before) { throw "Uninstall changed legacy data" }
    $result.result = "PASS"
    $manifest | Add-Member -NotePropertyName installation_acceptance -NotePropertyValue "INSTALL_UPGRADE_UNINSTALL_SMOKE_ONLY" -Force
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $manifestPath
} catch {
    $result.error = $_.Exception.Message
    throw
} finally {
    $result | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $rootDir "dist\windows-installation.json")
    # This UUID directory and all its files were created by this check.
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
