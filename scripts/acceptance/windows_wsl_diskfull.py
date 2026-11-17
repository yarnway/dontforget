"""Run bounded real disk-full acceptance; never fill a host/application disk."""
from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid


# Only this new, uniquely named /tmp mount may be created or removed as root.
MOUNT_SCRIPT = r'''
import os,re,subprocess,sys
name,uid,gid=sys.argv[1:]
assert re.fullmatch(r'dontforget-diskfull-[a-f0-9]{32}',name)
assert uid.isdigit() and gid.isdigit()
path='/tmp/'+name
os.mkdir(path,0o700)
try:
    subprocess.run(['mount','-t','tmpfs','-o',
        'size=16m,mode=0700,uid='+uid+',gid='+gid,name,path],check=True)
except BaseException:
    os.rmdir(path)
    raise
'''

CLEANUP_SCRIPT = r'''
import os,re,stat,subprocess,sys
name=sys.argv[1]
assert re.fullmatch(r'dontforget-diskfull-[a-f0-9]{32}',name)
path='/tmp/'+name
if not os.path.lexists(path):
    sys.exit(0)
assert stat.S_ISDIR(os.lstat(path).st_mode) and not os.path.islink(path)
if os.path.ismount(path):
    records=[line.split() for line in open('/proc/self/mounts')]
    assert any(x[0]==name and x[1]==path and x[2]=='tmpfs' for x in records)
    subprocess.run(['umount',path],check=True)
os.rmdir(path)
assert not os.path.exists(path)
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--distro', required=True, help='Existing WSL distribution name')
    parser.add_argument('--output', required=True, type=Path,
                        help='New, nonexistent directory under this repository build/')
    args = parser.parse_args()
    if sys.platform != 'win32':
        parser.error('Run with native Windows Python; do not invoke a Windows SDK from Linux.')
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if not output.is_relative_to(root / 'build') or output == root / 'build':
        parser.error('--output must be inside this repository build/')
    if output.exists():
        parser.error('--output must not exist; preserve earlier evidence')
    if not args.distro or any(c in args.distro for c in '\\/:\r\n\0'):
        parser.error('Invalid WSL distribution name')
    sdk = root / 'build/stage120/flutter-3.44.9'
    flutter = sdk / 'bin/flutter.bat'
    if not flutter.is_file():
        parser.error('The isolated fixed Windows SDK build/stage120/flutter-3.44.9 is required')
    output.mkdir(parents=True)
    environment = dict(os.environ, PYTHONUTF8='1')
    wsl = str(Path(os.environ['SystemRoot']) / 'System32/wsl.exe')

    def wsl_run(*command: str, as_root: bool = False):
        return subprocess.run(
            [wsl, '-d', args.distro, *(['-u', 'root'] if as_root else []),
             '--exec', *command], capture_output=True, timeout=30, check=True)

    version = subprocess.run(
        [str(flutter), '--no-version-check', '--version', '--machine'], cwd=root,
        env=environment, capture_output=True, timeout=45, check=True)
    sdk_version = json.loads(version.stdout)
    if sdk_version['frameworkVersion'] != '3.44.9':
        raise RuntimeError('Unexpected SDK version; no mount created')
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root,
                                     text=True).strip()
    lib_tree = subprocess.check_output(['git', 'rev-parse', 'HEAD:lib'], cwd=root,
                                       text=True).strip()
    runtime_changes = subprocess.check_output(
        ['git', 'diff', 'HEAD', '--name-only', '--', 'lib', 'pubspec.yaml',
         'pubspec.lock'], cwd=root, text=True).strip()
    if runtime_changes:
        raise RuntimeError('Commit runtime changes before attributing this acceptance')
    uid = wsl_run('id', '-u').stdout.decode().strip()
    gid = wsl_run('id', '-g').stdout.decode().strip()
    name = 'dontforget-diskfull-' + uuid.uuid4().hex
    unc = Path('\\\\wsl.localhost\\' + args.distro + '\\tmp\\' + name)
    fixture = root / 'scripts/acceptance/real_disk_full_backup_test.dart'
    result_path = output / 'diskfull-result.json'
    report = {
        'source': source, 'runtime_lib_tree': lib_tree,
        'version': next(line.split(':', 1)[1].strip()
                        for line in (root / 'pubspec.yaml').read_text(encoding='utf-8').splitlines()
                        if line.startswith('version:')),
        'flutter': sdk_version['frameworkVersion'],
        'dart': sdk_version['dartSdkVersion'],
        'test_sha256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
        'capacity_bytes': 16 * 1024 * 1024,
        'cleanup_succeeded': False, 'outcome': 'FAIL',
    }
    exit_code = 1
    mount_attempted = False
    try:
        mount_attempted = True
        wsl_run('python3', '-c', MOUNT_SCRIPT, name, uid, gid, as_root=True)
        (unc / 'fixture-owner.json').write_text(json.dumps({
            'format': 'dontforget.diskfull.fixture', 'token': name,
            'capacity_bytes': 16 * 1024 * 1024}), encoding='utf-8')
        # Independently prove the cap through native Windows I/O before Dart.
        probe = unc / 'preflight-fill.bin'
        try:
            with probe.open('wb', buffering=0) as stream:
                for _ in range(18):
                    stream.write(b'x' * (1024 * 1024))
        except OSError as error:
            if error.errno != errno.ENOSPC:
                raise
            report['native_python_space_exhaustion'] = {
                'errno': error.errno, 'winerror': error.winerror}
        else:
            raise RuntimeError('The isolated filesystem did not enforce its capacity')
        finally:
            probe.unlink(missing_ok=True)
        environment.update(
            DONTFORGET_DISKFULL_ROOT=str(unc), DONTFORGET_DISKFULL_TOKEN=name,
            DONTFORGET_DISKFULL_REPORT=str(result_path))
        with (output / 'acceptance.log').open('wb') as log:
            completed = subprocess.run(
                [str(flutter), '--no-version-check', 'test', '--no-pub',
                 '--reporter', 'expanded', str(fixture)], cwd=root,
                env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=360)
        report['test_exit_code'] = completed.returncode
        if completed.returncode:
            raise RuntimeError('Native acceptance failed; retain the log')
        result = json.loads(result_path.read_text(encoding='utf-8'))
        cases = result['cases']
        if len(cases) != 6 or {(c['encrypted'], c['operation']) for c in cases} != {
                (encrypted, operation) for encrypted in [False, True]
                for operation in ['create', 'export', 'restore']}:
            raise RuntimeError('Incomplete real disk-full evidence')
        report['outcome'] = 'PASS'
        exit_code = 0
    except Exception as error:
        report['failure'] = type(error).__name__ + ': ' + str(error)
    finally:
        if mount_attempted:
            try:
                wsl_run('python3', '-c', CLEANUP_SCRIPT, name, as_root=True)
                report['cleanup_succeeded'] = True
            except Exception as error:
                report['cleanup_failure'] = type(error).__name__ + ': ' + str(error)
                report['outcome'] = 'FAIL'
                exit_code = 1
        (output / 'runner-result.json').write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False))
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
