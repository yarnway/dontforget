#!/usr/bin/env python3
"""Join an isolated startup report to macOS's precise live process birth time.

Usage: python3 scripts/read_macos_startup_measurement.py --report /absolute/container/startup-traces/report.json
Run while that exact candidate process is alive. Reads only the given report,
its executable identity and process metadata; does not launch or control UI.
Output is JSON to stdout. A new process is not a disk-cache flush or OS reboot.
"""
import argparse
import ctypes
from datetime import datetime
import json
from pathlib import Path
import plistlib
import re
import sys


def merge(report, process_start_us):
    stamp = report['dart_entry_utc']
    # macOS's bundled Python 3.9 does not accept Dart's UTC Z suffix yet.
    if not isinstance(stamp, str):
        raise ValueError('Entry timestamp must be text')
    entry = datetime.fromisoformat(stamp[:-1] + '+00:00' if stamp.endswith('Z') else stamp)
    if entry.utcoffset() is None:
        raise ValueError('Entry timestamp needs a timezone')
    entry_us = round(entry.timestamp() * 1_000_000)
    offset = entry_us - process_start_us
    if offset < 0 or offset > 180_000_000:
        raise ValueError('Process/report clock or identity mismatch')
    marks = report['milestones_us']
    if any(type(v) is not int or v < 0 for v in marks.values()):
        raise ValueError('Invalid elapsed milestone')
    return {**report, 'process_start_epoch_us': process_start_us,
            'process_to_dart_entry_us': offset,
            'process_to_milestones_us': {k: offset + v for k, v in marks.items()},
            'process_to_outcome_us': offset + report['elapsed_to_outcome_us'],
            'cold_scope': 'New product process; OS caches retained. Kernel birth timestamp plus Dart elapsed milestones; excludes automation tool latency.'}


class ProcBSDInfo(ctypes.Structure):
    # sys/proc_info.h: PROC_PIDTBSDINFO=3, proc_bsdinfo, MAXCOMLEN=16.
    _fields_ = [(name, ctypes.c_uint32) for name in
                ['flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid',
                 'ruid', 'rgid', 'svuid', 'svgid', 'reserved']]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in
                 ['nfiles', 'pgid', 'pjobc', 'e_tdev', 'e_tpgid']]
    _fields_ += [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64),
                ('start_usec', ctypes.c_uint64)]


def read_report(path):
    if sys.platform != 'darwin':
        raise ValueError('macOS is required for process metadata')
    path = Path(path).absolute()
    if path.resolve() != path or path.stat().st_size > 65536:
        raise ValueError('Report must be a small regular file without path aliases')
    match = re.search(r'/Containers/(com\.example\.dontForget\.acceptance\.[a-zA-Z0-9-]+)/Data/', str(path))
    if not match or path.parent.name != 'startup-traces':
        raise ValueError('An isolated acceptance report is required')
    report = json.loads(path.read_text())
    pid = report['pid']
    if type(pid) is not int or pid <= 0:
        raise ValueError('Invalid candidate PID')
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    executable = ctypes.create_string_buffer(4096)
    if lib.proc_pidpath(pid, executable, len(executable)) <= 0:
        raise ValueError('Exact candidate process is no longer running')
    binary = Path(executable.value.decode())
    if binary.name != 'dont_forget' or binary.parent.name != 'MacOS':
        raise ValueError('Unexpected process executable')
    info = plistlib.loads((binary.parent.parent / 'Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != match.group(1):
        raise ValueError('Process does not belong to the report container')
    bsd = ProcBSDInfo()
    if lib.proc_pidinfo(pid, 3, 0, ctypes.byref(bsd), ctypes.sizeof(bsd)) != ctypes.sizeof(bsd) or bsd.pid != pid:
        raise ValueError('Cannot read exact process birth metadata')
    return merge(report, bsd.start_sec * 1_000_000 + bsd.start_usec)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(read_report(args.report), ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f'Startup report unavailable: {error}\n')
