# Read-only PE metadata validation, also usable before installing a candidate.
function Assert-WindowsCandidateVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)]$Manifest
    )
    if ($Manifest.platform -ne 'windows') { throw 'Expected a Windows manifest' }
    $match = [regex]::Match([string]$Manifest.version, '^(\d+\.\d+\.\d+)(?:-[0-9A-Za-z.-]+)?$')
    $candidateBuild = 0
    if (-not $match.Success -or
        -not [int]::TryParse([string]$Manifest.build_number, [ref]$candidateBuild) -or
        $candidateBuild -lt 0 -or $candidateBuild -gt 65535) {
        throw 'Invalid Windows candidate version or build number'
    }
    $expected = [version]("{0}.{1}" -f $match.Groups[1].Value, $candidateBuild)
    $info = (Get-Item -LiteralPath $Executable -ErrorAction Stop).VersionInfo
    $actual = [version]("{0}.{1}.{2}.{3}" -f $info.FileMajorPart,
        $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
    if ($actual -ne $expected) {
        throw "Installed executable version mismatch: expected $expected, got $actual"
    }
    return $actual.ToString()
}
