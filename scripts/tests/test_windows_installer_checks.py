"""Exercise candidate checks against real Windows PE metadata, without installs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(os.name == 'nt' and shutil.which('powershell.exe'),
                     'Requires Windows PowerShell and native PE version metadata')
class WindowsInstallerVersionTest(unittest.TestCase):
    def test_local_installation_is_rejected_before_acceptance_outputs_change(self):
        evidence = ROOT / 'dist/windows-installation.json'
        before = evidence.read_bytes() if evidence.exists() else None
        env = dict(os.environ)
        env.pop('GITHUB_ACTIONS', None)
        env.pop('RUNNER_TEMP', None)
        result = subprocess.run([
            'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', str(ROOT / 'scripts/smoke_windows_installer.ps1'),
        ], capture_output=True, timeout=15, text=True, errors='replace', env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Installer acceptance must run on an isolated GitHub runner',
                      result.stdout + result.stderr)
        self.assertEqual(evidence.read_bytes() if evidence.exists() else None, before)

    def test_real_pe_accepts_exact_build_and_rejects_same_version_wrong_build(self):
        # Use the OS executable only for read-only metadata. Never launch it.
        script = r'''
param([string]$Checks)
$ErrorActionPreference = 'Stop'
. $Checks
$exe = Join-Path $env:WINDIR 'System32\cmd.exe'
$v = (Get-Item -LiteralPath $exe).VersionInfo
$core = '{0}.{1}.{2}' -f $v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart
$manifest = [pscustomobject]@{ platform='windows'; version=$core; build_number=$v.FilePrivatePart }
$actual = Assert-WindowsCandidateVersion -Executable $exe -Manifest $manifest
if ($actual -ne "$core.$($v.FilePrivatePart)") { throw 'Exact version check failed' }
$manifest.version = "$core-rc.1"
$null = Assert-WindowsCandidateVersion -Executable $exe -Manifest $manifest
$manifest.build_number = if ($v.FilePrivatePart -eq 0) { 1 } else { 0 }
$rejected = $false
try { $null = Assert-WindowsCandidateVersion -Executable $exe -Manifest $manifest }
catch { $rejected = $_.Exception.Message -like 'Installed executable version mismatch:*' }
if (-not $rejected) { throw 'Same version with wrong build was accepted' }
foreach ($bad in @('', '-1', '65536', 'not-a-number')) {
    $manifest.build_number = $bad
    $rejected = $false
    try { $null = Assert-WindowsCandidateVersion -Executable $exe -Manifest $manifest }
    catch { $rejected = $_.Exception.Message -like 'Invalid Windows candidate*' }
    if (-not $rejected) { throw "Bad build accepted: $bad" }
}
'PASS exact, prerelease, wrong-build and invalid-build PE checks'
'''
        with tempfile.TemporaryDirectory(prefix='dontforget-version-check-') as tmp:
            harness = Path(tmp) / 'check.ps1'
            harness.write_text(script, encoding='utf-8')
            result = subprocess.run([
                'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', str(harness), '-Checks',
                str(ROOT / 'scripts/windows_installer_checks.ps1'),
            ], capture_output=True, timeout=30, text=True, errors='replace')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS exact', result.stdout)


if __name__ == '__main__':
    unittest.main()
