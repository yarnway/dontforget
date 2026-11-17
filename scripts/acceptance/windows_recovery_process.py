"""Terminate only isolated recovery test workers and verify fresh-process repair."""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes as w
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

CHECKPOINTS = (
    'candidateReady', 'rollbackReady', 'journalPrepared', 'originalMoved',
    'candidateInstalled', 'candidateOpened', 'committed', 'rollbackStarted',
    'rollbackInstalled',
)


class NativeJob:
    """Own this invocation's descendants; never use global process-name kills."""

    def __init__(self):
        self.api = ctypes.WinDLL('kernel32', use_last_error=True)
        signatures = {
            'CreateJobObjectW': ([ctypes.c_void_p, w.LPCWSTR], w.HANDLE),
            'SetInformationJobObject': ([w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD], w.BOOL),
            'AssignProcessToJobObject': ([w.HANDLE, w.HANDLE], w.BOOL),
            'IsProcessInJob': ([w.HANDLE, w.HANDLE, ctypes.POINTER(w.BOOL)], w.BOOL),
            'OpenProcess': ([w.DWORD, w.BOOL, w.DWORD], w.HANDLE),
            'QueryFullProcessImageNameW': ([w.HANDLE, w.DWORD, w.LPWSTR, ctypes.POINTER(w.DWORD)], w.BOOL),
            'GetProcessTimes': ([w.HANDLE, *([ctypes.POINTER(w.FILETIME)] * 4)], w.BOOL),
            'TerminateProcess': ([w.HANDLE, w.UINT], w.BOOL),
            'WaitForSingleObject': ([w.HANDLE, w.DWORD], w.DWORD),
            'GetExitCodeProcess': ([w.HANDLE, ctypes.POINTER(w.DWORD)], w.BOOL),
            'CloseHandle': ([w.HANDLE], w.BOOL),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(self.api, name)
            function.argtypes, function.restype = arguments, result

        class BasicLimits(ctypes.Structure):
            _fields_ = [('process_time', ctypes.c_int64), ('job_time', ctypes.c_int64),
                        ('flags', w.DWORD), ('min_working', ctypes.c_size_t),
                        ('max_working', ctypes.c_size_t), ('active_limit', w.DWORD),
                        ('affinity', ctypes.c_size_t), ('priority', w.DWORD),
                        ('scheduling', w.DWORD)]

        class ExtendedLimits(ctypes.Structure):
            _fields_ = [('basic', BasicLimits), ('io', ctypes.c_uint64 * 6),
                        ('process_memory', ctypes.c_size_t), ('job_memory', ctypes.c_size_t),
                        ('peak_process_memory', ctypes.c_size_t), ('peak_job_memory', ctypes.c_size_t)]

        self.handle = self.api.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.api.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            self.close()
            raise ctypes.WinError(ctypes.get_last_error())

    def assign(self, child: subprocess.Popen):
        if not self.api.AssignProcessToJobObject(self.handle, int(child._handle)):
            # Only the just-created wrapper handle is touched on setup failure.
            child.terminate()
            child.wait(timeout=10)
            raise ctypes.WinError(ctypes.get_last_error())

    def terminate_worker(self, pid: int, engine: Path, launched_at: float):
        if pid == os.getpid():
            raise RuntimeError('Refusing the controller process')
        handle = self.api.OpenProcess(0x1000 | 0x100000 | 0x0001, False, pid)
        if not handle:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            owned = w.BOOL()
            if not self.api.IsProcessInJob(handle, self.handle, ctypes.byref(owned)) or not owned.value:
                raise RuntimeError('Worker is not in this invocation\'s private job')
            size = w.DWORD(32768)
            buffer = ctypes.create_unicode_buffer(size.value)
            if not self.api.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
                raise ctypes.WinError(ctypes.get_last_error())
            if Path(buffer.value).resolve() != engine.resolve():
                raise RuntimeError('Worker is not the fixed SDK Flutter test engine')
            times = [w.FILETIME() for _ in range(4)]
            if not self.api.GetProcessTimes(handle, *(ctypes.byref(v) for v in times)):
                raise ctypes.WinError(ctypes.get_last_error())
            created = ((times[0].dwHighDateTime << 32) | times[0].dwLowDateTime) / 1e7 - 11644473600
            if created < launched_at - 2:
                raise RuntimeError('Worker predates this explicit invocation')
            if not self.api.TerminateProcess(handle, 77):
                raise ctypes.WinError(ctypes.get_last_error())
            if self.api.WaitForSingleObject(handle, 10000) != 0:
                raise RuntimeError('Terminated worker did not exit')
            code = w.DWORD()
            if not self.api.GetExitCodeProcess(handle, ctypes.byref(code)) or code.value != 77:
                raise RuntimeError('Native termination exit code was not observed')
        finally:
            self.api.CloseHandle(handle)

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


def read_json(path: Path):
    return json.loads(path.read_text(encoding='utf-8'))


def write_json(path: Path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True,
                        help='New, nonexistent directory inside repository build/')
    parser.add_argument('--smoke', action='store_true', help='One boundary only; never report a full matrix')
    args = parser.parse_args()
    if sys.platform != 'win32':
        parser.error('Run with native Windows Python and the fixed Windows Flutter SDK')
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if not output.is_relative_to(root / 'build') or output == root / 'build' or output.exists():
        parser.error('--output must be a new directory inside repository build/')
    sdk = root / 'build/stage120/flutter-3.44.9'
    flutter = sdk / 'bin/flutter.bat'
    engine = sdk / 'bin/cache/artifacts/engine/windows-x64/flutter_tester.exe'
    if not flutter.is_file() or not engine.is_file():
        parser.error('The isolated fixed Windows Flutter SDK is required')
    env = dict(os.environ, PYTHONUTF8='1')
    sdk_version = json.loads(subprocess.check_output(
        [str(flutter), '--no-version-check', '--version', '--machine'],
        cwd=root, env=env, timeout=45))
    if sdk_version['frameworkVersion'] != '3.44.9':
        raise RuntimeError('Unexpected SDK version')
    if subprocess.check_output(['git', 'diff', 'HEAD', '--name-only', '--', 'lib',
                                'pubspec.yaml', 'pubspec.lock'], cwd=root, text=True).strip():
        raise RuntimeError('Commit runtime changes before attributing acceptance')
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    lib_tree = subprocess.check_output(['git', 'rev-parse', 'HEAD:lib'], cwd=root, text=True).strip()
    worker = root / 'scripts/acceptance/recovery_process_worker_test.dart'
    output.mkdir(parents=True)
    cases = [('json', 'candidateInstalled', None)] if args.smoke else [
        (format_name, point, None) for format_name in ['json', 'sqlite'] for point in CHECKPOINTS
    ] + [('json', 'candidateInstalled', negative) for negative in ['unknown-primary', 'corrupt-journal']]
    report = {
        'source': source, 'runtime_lib_tree': lib_tree,
        'flutter': sdk_version['frameworkVersion'], 'dart': sdk_version['dartSdkVersion'],
        'worker_sha256': hashlib.sha256(worker.read_bytes()).hexdigest(),
        'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'full_matrix': not args.smoke, 'cases': [], 'outcome': 'FAIL',
        'normal_application_processes_or_data_touched': False,
        'real_os_notifications_or_credentials_tested': False,
        'physical_power_loss_tested': False,
    }
    try:
        for format_name, point, negative in cases:
            label = format_name + '-' + point + ('-' + negative if negative else '')
            directory = output / label
            directory.mkdir()
            token = uuid.uuid4().hex
            write_json(directory / 'fixture-owner.json', {
                'format': 'dontforget.recovery-crash.fixture', 'token': token,
                'checkpoint': point, 'input_format': format_name})
            environment = dict(env, DONTFORGET_CRASH_CASE=str(directory), DONTFORGET_CRASH_TOKEN=token)

            def invoke(mode: str):
                job = NativeJob()
                child = None
                started = time.time()
                try:
                    with (directory / (mode + '.log')).open('wb') as log:
                        child = subprocess.Popen(
                            [str(flutter), '--no-version-check', 'test', '--no-pub',
                             '--reporter', 'expanded', str(worker)], cwd=root,
                            env=dict(environment, DONTFORGET_CRASH_MODE=mode),
                            stdout=log, stderr=subprocess.STDOUT)
                        job.assign(child)
                        if mode == 'crash':
                            marker = directory / 'ready.json'
                            while not marker.exists():
                                if child.poll() is not None:
                                    raise RuntimeError('Worker exited before its checkpoint; inspect ' + label)
                                if time.time() - started > 90:
                                    raise TimeoutError('Worker checkpoint not reached: ' + label)
                                time.sleep(.1)
                            ready = read_json(marker)
                            if ready['token'] != token or ready['checkpoint'] != point:
                                raise RuntimeError('Checkpoint ownership mismatch')
                            pending = directory / 'live/recovery.pending.json'
                            decision = read_json(pending) if pending.exists() else None
                            write_json(directory / 'boundary-before-kill.json', {
                                'checkpoint': point, 'pending': decision,
                                'primary_exists': (directory / 'live/dont_forget_v3.db').exists(),
                            })
                            job.terminate_worker(ready['pid'], engine, started)
                            if child.wait(timeout=30) == 0:
                                raise RuntimeError('Abrupt termination unexpectedly reported normal success')
                            if (directory / 'graceful-finally-ran.json').exists():
                                raise RuntimeError('Graceful cleanup ran; not a process-crash result')
                        elif child.wait(timeout=90) != 0:
                            raise RuntimeError('Fresh worker failed: ' + label + '/' + mode)
                finally:
                    # This private job contains only this invocation's test
                    # wrapper/engine descendants, including timeout cleanup.
                    job.close()
                    if child is not None:
                        child.wait(timeout=15)

            invoke('crash')
            if negative:
                target = directory / ('live/dont_forget_v3.db' if negative == 'unknown-primary'
                                      else 'live/recovery.pending.json')
                target.write_bytes(b'Synthetic unrecognized identity; preserve this evidence.')
                invoke('blocked')
                result = read_json(directory / 'blocked-result.json')
                result.pop('pid')
            else:
                invoke('recover')
                invoke('reopen')
                result = {key: value for key, value in read_json(directory / 'recover-result.json').items()
                          if key != 'pid'}
                result['second_fresh_process_reopen'] = {
                    key: value for key, value in read_json(directory / 'reopen-result.json').items()
                    if key != 'pid'}
            result.update(label=label, negative=negative,
                          actual_native_termination_exit_code=77,
                          target_owned_by_private_job_and_fixed_sdk_verified=True,
                          graceful_finally_did_not_run=True, outcome='PASS')
            report['cases'].append(result)
            write_json(directory / 'case-result.json', result)
            write_json(output / 'runner-result.json', report)
            print(json.dumps({'case': label, 'outcome': 'PASS'}), flush=True)
        report['outcome'] = 'PASS'
    except Exception as error:
        report['failure'] = type(error).__name__ + ': ' + str(error)
    write_json(output / 'runner-result.json', report)
    print(json.dumps({'outcome': report['outcome'], 'cases_passed': len(report['cases']),
                      'full_matrix': report['full_matrix']}), flush=True)
    return 0 if report['outcome'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
