#!/usr/bin/env python3
"""Run a bounded native startup check on an isolated CI runner, not user data."""
import argparse
import json
import os
from pathlib import Path
import platform as host_platform
import subprocess
import tempfile
import time
import tarfile
import zipfile
from package_artifacts import ROOT

EXECUTABLES = {
    'windows': 'dont_forget.exe',
    'linux': 'dont_forget',
    'macos': 'dont_forget.app/Contents/MacOS/dont_forget',
}


def smoke(platform):
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        raise RuntimeError('Run this startup smoke check on an isolated GitHub Actions runner')
    manifest_path = ROOT / f'dist/{platform}-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    extension = '.tar.gz' if platform == 'linux' else '.zip'
    archive = ROOT / 'dist' / next(
        entry['file'] for entry in manifest['artifacts'] if entry['file'].endswith(extension))
    result = {'platform': platform, 'revision': manifest['revision'],
              'version': manifest['version'], 'host': host_platform.platform(),
              'scope': 'unpacked-native-process-startup-only', 'seconds': 10,
              'result': 'FAIL', 'ui_acceptance': 'NOT_PERFORMED',
              'notification_acceptance': 'NOT_PERFORMED'}
    try:
        with tempfile.TemporaryDirectory(prefix='dontforget-smoke-') as work:
            data = Path(work)
            unpacked = data / 'unpacked'
            unpacked.mkdir()
            if platform == 'linux':
                with tarfile.open(archive) as bundle:
                    bundle.extractall(unpacked, filter='data')
            elif platform == 'macos':
                subprocess.run(['ditto', '-x', '-k', str(archive), str(unpacked)], check=True)
            else:
                with zipfile.ZipFile(archive) as bundle:
                    bundle.extractall(unpacked)
            executable = unpacked / EXECUTABLES[platform]
            if not executable.is_file():
                raise FileNotFoundError(executable)
            env = dict(os.environ)
            for variable, relative in {
                'XDG_CONFIG_HOME': 'config', 'XDG_DATA_HOME': 'data',
                'APPDATA': 'roaming', 'LOCALAPPDATA': 'local',
            }.items():
                path = data / relative
                path.mkdir(exist_ok=True)
                env[variable] = str(path)
            with (data / 'startup.log').open('w+b') as log:
                process = subprocess.Popen([str(executable)], cwd=data, env=env,
                                           stdout=log, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        if process.poll() is not None:
                            raise RuntimeError(f'Application exited during startup: {process.returncode}')
                        time.sleep(0.25)
                    result['result'] = 'PASS'
                finally:
                    # Only terminate the process this script owns.
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
                    log.seek(0)
                    result['startup_log'] = log.read(65536).decode(errors='replace')
                    if result['result'] != 'PASS':
                        print(result['startup_log'], flush=True)
                        if platform == 'windows':
                            events = subprocess.run(
                                ['powershell', '-NoProfile', '-Command',
                                 "Get-WinEvent -FilterHashtable @{LogName='Application';"
                                 "StartTime=(Get-Date).AddMinutes(-5);Id=1000,1001} "
                                 "-ErrorAction SilentlyContinue | Where-Object "
                                 "{$_.Message -match 'dont_forget'} | "
                                 "Select-Object TimeCreated,Id,Message | ConvertTo-Json"],
                                capture_output=True, text=True, timeout=30)
                            result['windows_crash_events'] = events.stdout[-32768:]
                            print(result['windows_crash_events'], flush=True)
    finally:
        output = ROOT / f'dist/{platform}-startup.json'
        output.write_text(json.dumps(result, indent=2) + '\n')
    manifest['runtime_acceptance'] = 'STARTUP_SMOKE_ONLY'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'{platform}: native process survived startup; UI and notifications remain unverified')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=sorted(EXECUTABLES), required=True)
    smoke(parser.parse_args().platform)
