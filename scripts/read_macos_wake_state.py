#!/usr/bin/env python3
"""Collect read-only wake evidence; never certify a hardware alarm as cleared."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import uuid
from xml.parsers.expat import ExpatError


def query(command, run):
    result = run(command, capture_output=True, timeout=15, check=False)
    if result.returncode != 0:
        raise ValueError(f'{command[0]} failed with exit {result.returncode}')
    if result.stderr.strip():
        raise ValueError(f'{command[0]} returned diagnostics; inspect separately')
    return result.stdout


def root_evidence(raw):
    rows = plistlib.loads(raw)
    if (not isinstance(rows, list) or len(rows) != 1 or
            not isinstance(rows[0], dict) or
            rows[0].get('IORegistryEntryName') != 'IOPMrootDomain'):
        raise ValueError('Expected exactly one IOPMrootDomain registry entry')
    root = rows[0]
    key = 'WakeRelativeToSleep'
    relative = {'propertyPublished': key in root, 'seconds': None}
    if key in root:
        value = root[key]
        if type(value) is not int or not 0 <= value <= 0xffffffff:
            raise ValueError('Invalid WakeRelativeToSleep software value')
        relative['seconds'] = value
    disabled = root.get('SleepDisabled')
    if disabled is not None and not (
            type(disabled) is bool or type(disabled) is int and disabled in (0, 1)):
        raise ValueError('Invalid SleepDisabled value')
    return {'sleepDisabled': None if disabled is None else bool(disabled),
            'relativeWakeSoftwareProperty': relative}


def collect(run=subprocess.run):
    result = {
        'schema': 1,
        'checkedAt': datetime.now(timezone.utc).isoformat(),
        'readOnly': True,
        'collectionStatus': 'INCOMPLETE',
        'relativeWakeVerdict': 'UNCONFIRMED',
        'hardwareReadbackAvailable': False,
        'boundary': 'An empty schedule or a software zero is not hardware readback.',
    }
    boot_command = ['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid']
    try:
        before = str(uuid.UUID(query(boot_command, run).decode('ascii').strip()))
        schedule = query(['/usr/bin/pmset', '-g', 'sched'], run).decode('utf-8')
        root = root_evidence(query(
            ['/usr/sbin/ioreg', '-a', '-r', '-n', 'IOPMrootDomain', '-d', '1'], run))
        after = str(uuid.UUID(query(boot_command, run).decode('ascii').strip()))
        if before != after:
            raise ValueError('Host restarted during collection')
        result.update(collectionStatus='COLLECTED', bootUUID=before,
                      scheduledEvents={'emptyOutput': not schedule.strip(),
                                       'raw': schedule}, **root)
    except (OSError, subprocess.SubprocessError, ValueError,
            plistlib.InvalidFileException, ExpatError) as error:
        result['error'] = str(error)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True,
                        help='New JSON evidence file; existing files are never overwritten')
    args = parser.parse_args(argv)
    if platform.system() != 'Darwin':
        parser.error('This read-only probe requires macOS')
    # Reserve the evidence path before running commands. Failed probes remain
    # explicit evidence, and neither a symlink nor an existing file is replaced.
    try:
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError as error:
        parser.error(str(error))
    with os.fdopen(fd, 'w', encoding='utf-8') as destination:
        result = collect()
        json.dump(result, destination, ensure_ascii=False, indent=2)
        destination.write('\n')
    print(f"{result['collectionStatus']}; relative wake UNCONFIRMED; {args.output}")
    return 0 if result['collectionStatus'] == 'COLLECTED' else 2


if __name__ == '__main__':
    sys.exit(main())
