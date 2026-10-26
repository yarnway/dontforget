#!/usr/bin/env python3
"""Read-only iOS installation prerequisites; never pair, sign, install or certify a device."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import socket
import struct
import subprocess
import sys
from xml.parsers.expat import ExpatError


MAX_FRAME = 1024 * 1024
DEVICE_KEYS = ('ProductType', 'ProductVersion', 'BuildVersion')


def receive_exact(connection, size):
    data = bytearray()
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise ValueError('Device connection closed')
        data.extend(chunk)
    return bytes(data)


def mux_request(connection, message):
    # Use only ListDevices and Connect. No pairing records or credentials are read.
    if message.get('MessageType') not in ('ListDevices', 'Connect'):
        raise ValueError('Unsupported read-only request')
    payload = plistlib.dumps(dict(
        ClientVersionString='DontForgetPreflight', ProgName='DontForgetPreflight',
        kLibUSBMuxVersion=3, **message))
    connection.sendall(struct.pack('<IIII', len(payload) + 16, 1, 8, 1) + payload)
    size, version, kind, tag = struct.unpack('<IIII', receive_exact(connection, 16))
    if not 16 <= size <= MAX_FRAME or (version, kind, tag) != (1, 8, 1):
        raise ValueError('Invalid usbmuxd response frame')
    result = plistlib.loads(receive_exact(connection, size - 16))
    if not isinstance(result, dict):
        raise ValueError('Invalid usbmuxd response')
    return result


def connect_mux():
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(5)
        connection.connect('/var/run/usbmuxd')
        return connection
    except OSError:
        connection.close()
        raise


def device_value(connection, key):
    if key not in DEVICE_KEYS:
        raise ValueError('Unsupported device field')
    payload = plistlib.dumps({
        'Request': 'GetValue', 'Key': key, 'Label': 'DontForgetPreflight'})
    connection.sendall(struct.pack('>I', len(payload)) + payload)
    size, = struct.unpack('>I', receive_exact(connection, 4))
    if not 0 < size <= MAX_FRAME:
        raise ValueError('Invalid device response frame')
    result = plistlib.loads(receive_exact(connection, size))
    if not isinstance(result, dict):
        raise ValueError('Invalid device response')
    value = result.get('Value')
    if ('Error' in result or not isinstance(value, str) or
            not re.fullmatch(r'[A-Za-z0-9.,_-]{1,64}', value)):
        raise ValueError('Device field unavailable')
    return value


def usb_devices(connect=connect_mux):
    with connect() as connection:
        rows = mux_request(connection, {'MessageType': 'ListDevices'}).get('DeviceList')
    if not isinstance(rows, list):
        raise ValueError('Device inventory unavailable')
    devices = []
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('Properties'), dict):
            raise ValueError('Invalid device inventory')
        properties = row['Properties']
        if properties.get('ConnectionType') != 'USB':
            continue
        device_id = row.get('DeviceID')
        if type(device_id) is not int or not 0 < device_id <= 0xffffffff:
            raise ValueError('Invalid USB device identifier')
        device = {'connection': 'USB', 'details': 'UNAVAILABLE'}
        try:
            with connect() as connection:
                response = mux_request(connection, {
                    'MessageType': 'Connect', 'DeviceID': device_id,
                    'PortNumber': socket.htons(62078)})
                if type(response.get('Number')) is not int or response['Number'] != 0:
                    raise ValueError('Device connection refused')
                values = {key: device_value(connection, key) for key in DEVICE_KEYS}
            device.update(details='READ', **values)
        except (OSError, ValueError, plistlib.InvalidFileException, ExpatError):
            # No raw errors, UDIDs, serial numbers, device names or pairing keys.
            pass
        devices.append(device)
    return devices


def command_output(arguments, run):
    try:
        result = run(arguments, capture_output=True, text=True, check=False, timeout=20)
        return result.stdout if result.returncode == 0 and not result.stderr.strip() else None
    except (OSError, subprocess.SubprocessError):
        return None


def collect(run=subprocess.run, devices=usb_devices):
    result = {
        'schema': 1, 'checkedAt': datetime.now(timezone.utc).isoformat(),
        'readOnly': True, 'collectionStatus': 'COLLECTED',
        'installationStatus': 'BLOCKED', 'runtimeAcceptance': 'NOT_PERFORMED',
        'pairing': 'NOT_VERIFIED', 'developerMode': 'NOT_VERIFIED',
        'boundary': ('USB device metadata does not prove pairing, Developer Mode, '
                     'a matching provisioning profile or an installed runnable app.'),
    }
    xcode = command_output(['/usr/bin/xcodebuild', '-version'], run)
    match = re.fullmatch(r'Xcode ([0-9.]+)\nBuild version ([A-Za-z0-9]+)\s*', xcode or '')
    sdk = command_output(['/usr/bin/xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], run)
    sdk_version = sdk.strip() if sdk and re.fullmatch(r'[0-9.]+\s*', sdk) else None
    devicectl = command_output(['/usr/bin/xcrun', '--find', 'devicectl'], run)
    identities = command_output(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], run)
    identity_names = re.findall(r'^\s*\d+\)\s+[A-Fa-f0-9]{40}\s+"([^"]+)"',
                                identities or '', re.M)
    development_count = sum(name.startswith(('Apple Development:', 'iPhone Developer:'))
                            for name in identity_names)
    result['toolchain'] = {
        'xcodeVersion': match.group(1) if match else None,
        'xcodeBuild': match.group(2) if match else None,
        'iPhoneOSSDK': sdk_version,
        'devicectlAvailable': bool(devicectl and Path(devicectl.strip()).is_absolute()
                                  and Path(devicectl.strip()).name == 'devicectl'),
    }
    result['signing'] = {
        'identityQuery': 'READ' if identities is not None else 'UNAVAILABLE',
        'validDevelopmentIdentities': development_count if identities is not None else None,
        'matchingProvisioningProfile': 'NOT_VERIFIED',
    }
    blockers = []
    if not match:
        blockers.append('FULL_XCODE_UNAVAILABLE')
    if not sdk_version:
        blockers.append('IPHONEOS_SDK_UNAVAILABLE')
    if not result['toolchain']['devicectlAvailable']:
        blockers.append('DEVICECTL_UNAVAILABLE')
    if identities is None:
        blockers.append('SIGNING_QUERY_UNAVAILABLE')
    elif development_count == 0:
        blockers.append('DEVELOPMENT_IDENTITY_UNAVAILABLE')
    try:
        result['usbDevices'] = devices()
        if not result['usbDevices']:
            blockers.append('NO_USB_DEVICE')
        elif not any(d.get('ProductType', '').startswith('iPhone') for d in result['usbDevices']):
            blockers.append('IPHONE_NOT_IDENTIFIED')
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError):
        result['collectionStatus'] = 'INCOMPLETE'
        blockers.append('USB_INVENTORY_UNAVAILABLE')
    result['blockers'] = blockers
    if not blockers:
        result['installationStatus'] = 'REQUIRES_SIGNED_INSTALL'
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True,
                        help='New private JSON report; never overwrite existing evidence')
    args = parser.parse_args(argv)
    if platform.system() != 'Darwin':
        parser.error('This read-only preflight requires macOS')
    try:
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError as error:
        parser.error(str(error))
    with os.fdopen(fd, 'w', encoding='utf-8') as destination:
        result = collect()
        json.dump(result, destination, ensure_ascii=False, indent=2)
        destination.write('\n')
    print(f"{result['installationStatus']}; runtime NOT_PERFORMED; {args.output}")
    # Zero means only that the locally observable prerequisites are present.
    return 0 if result['installationStatus'] == 'REQUIRES_SIGNED_INSTALL' else 2


if __name__ == '__main__':
    sys.exit(main())
