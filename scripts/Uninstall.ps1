# Delegate deletion to Inno's installation ledger; never recursively erase user data.
param(
    [string]$TargetDir = "$env:LOCALAPPDATA\Programs\DontForget"
)
$ErrorActionPreference = "Stop"
$uninstaller = Join-Path $TargetDir "unins000.exe"
if (-not (Test-Path -LiteralPath $uninstaller)) {
    throw "No managed uninstaller found. Back up legacy application data and migrate using the current installer before uninstalling."
}
$process = Start-Process -FilePath $uninstaller -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Uninstaller did not complete: $($process.ExitCode)" }
