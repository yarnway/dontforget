import contextlib
import io
import json
from pathlib import Path
import plistlib
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_ios_device as ios


SECRET = 'private-device-serial-must-not-be-recorded'
DEVICE = {'connection': 'USB', 'details': 'READ', 'ProductType': 'iPhone16,2',
          'ProductVersion': '27.0.1', 'BuildVersion': '24A446'}


def mux_frame(value):
    data = plistlib.dumps(value)
    return struct.pack('<IIII', len(data) + 16, 1, 8, 1) + data


def value_frame(value):
    data = plistlib.dumps(value)
    return struct.pack('>I', len(data)) + data


class Connection:
    def __init__(self, data, fragment=7):
        self.data, self.fragment, self.sent, self.closed = data, fragment, [], False

    def recv(self, count):
        size = min(count, self.fragment)
        part, self.data = self.data[:size], self.data[size:]
        return part

    def sendall(self, data):
        self.sent.append(data)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.closed = True


def inventory(properties=None):
    return {'DeviceList': [{'DeviceID': 7, 'Properties': properties or {
        'ConnectionType': 'USB', 'SerialNumber': SECRET}}]}


def runner(outputs=None):
    values = iter(outputs or ['Xcode 27.1\nBuild version 18B14\n', '27.1\n',
                              '/Applications/Xcode.app/Contents/Developer/usr/bin/devicectl\n',
                              '  1) ' + 'A' * 40 + ' "Apple Development: Private Name"\n'
                              '     1 valid identities found\n'])
    def run(command, **kwargs):
        value = next(values)
        return subprocess.CompletedProcess(command, 0 if value is not None else 1,
                                           value or '', '')
    return run


class IOSPreflightTest(unittest.TestCase):
    def test_fragmented_usb_frames_and_only_allowlisted_read_requests(self):
        initial = Connection(mux_frame(inventory()))
        detail = Connection(mux_frame({'Number': 0}) + b''.join(
            value_frame({'Value': DEVICE[key]}) for key in ios.DEVICE_KEYS))
        connections = iter([initial, detail])
        result = ios.usb_devices(lambda: next(connections))
        self.assertEqual(result, [DEVICE])
        self.assertNotIn(SECRET, json.dumps(result))
        self.assertTrue(initial.closed and detail.closed)
        requests = [plistlib.loads(initial.sent[0][16:]),
                    plistlib.loads(detail.sent[0][16:])]
        self.assertEqual([r['MessageType'] for r in requests], ['ListDevices', 'Connect'])
        self.assertEqual(requests[1]['PortNumber'], socket.htons(62078))
        fields = [plistlib.loads(raw[4:]) for raw in detail.sent[1:]]
        self.assertEqual([f['Key'] for f in fields], list(ios.DEVICE_KEYS))
        self.assertTrue(all(f['Request'] == 'GetValue' for f in fields))

    def test_network_devices_are_not_mistaken_for_usb(self):
        initial = Connection(mux_frame(inventory({'ConnectionType': 'Network',
                                                  'SerialNumber': SECRET})))
        self.assertEqual(ios.usb_devices(lambda: initial), [])

    def test_unavailable_metadata_still_records_usb_without_pairing(self):
        for response in (mux_frame({'Number': 3}), mux_frame({'Number': 0}) +
                         value_frame({'Error': SECRET})):
            with self.subTest(response=response):
                connections = iter([Connection(mux_frame(inventory())), Connection(response)])
                result = ios.usb_devices(lambda: next(connections))
                self.assertEqual(result, [{'connection': 'USB', 'details': 'UNAVAILABLE'}])
                self.assertNotIn(SECRET, json.dumps(result))

    def test_bad_headers_truncation_and_large_payloads_fail_closed(self):
        for data in (b'', b'partial', struct.pack('<IIII', 15, 1, 8, 1),
                     struct.pack('<IIII', ios.MAX_FRAME + 1, 1, 8, 1),
                     struct.pack('<IIII', 16, 2, 8, 1),
                     struct.pack('<IIII', 16, 1, 8, 9), mux_frame([])):
            with self.subTest(data=data), self.assertRaises(ValueError):
                ios.mux_request(Connection(data), {'MessageType': 'ListDevices'})
        with self.assertRaises(ValueError):
            ios.device_value(Connection(struct.pack('>I', ios.MAX_FRAME + 1)), 'ProductType')

    def test_invalid_inventory_does_not_report_no_device(self):
        for value in ({}, {'DeviceList': 'invalid'}, {'DeviceList': [False]},
                      {'DeviceList': [{'DeviceID': True, 'Properties': {'ConnectionType': 'USB'}}]}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                ios.usb_devices(lambda: Connection(mux_frame(value)))

    def test_probe_cannot_request_pairing_or_private_fields(self):
        connection = Connection(b'')
        for request in ('Pair', 'ReadPairRecord', 'SavePairRecord', 'ReadBUID'):
            with self.assertRaises(ValueError):
                ios.mux_request(connection, {'MessageType': request})
        for key in ('SerialNumber', 'DeviceName', 'UniqueDeviceID'):
            with self.assertRaises(ValueError):
                ios.device_value(connection, key)
        self.assertEqual(connection.sent, [])

    def test_tools_and_identity_are_not_installation_or_runtime_acceptance(self):
        result = ios.collect(runner(), lambda: [DEVICE])
        self.assertEqual(result['installationStatus'], 'REQUIRES_SIGNED_INSTALL')
        self.assertEqual(result['runtimeAcceptance'], 'NOT_PERFORMED')
        self.assertEqual(result['pairing'], 'NOT_VERIFIED')
        self.assertEqual(result['developerMode'], 'NOT_VERIFIED')
        self.assertEqual(result['signing']['matchingProvisioningProfile'], 'NOT_VERIFIED')
        self.assertNotIn('Private Name', json.dumps(result))

    def test_connected_iphone_with_command_line_tools_is_blocked(self):
        result = ios.collect(runner([None, None, None, '0 valid identities found\n']), lambda: [DEVICE])
        self.assertEqual(result['installationStatus'], 'BLOCKED')
        self.assertEqual(result['usbDevices'], [DEVICE])
        self.assertEqual(result['blockers'], ['FULL_XCODE_UNAVAILABLE', 'IPHONEOS_SDK_UNAVAILABLE',
                                            'DEVICECTL_UNAVAILABLE', 'DEVELOPMENT_IDENTITY_UNAVAILABLE'])

    def test_mac_only_identity_does_not_enable_iphone_signing(self):
        values = ['Xcode 27.1\nBuild version 18B14\n', '27.1\n', '/bin/devicectl\n',
                  '1) ' + 'A' * 40 + ' "Developer ID Application: Name"\n']
        result = ios.collect(runner(values), lambda: [DEVICE])
        self.assertEqual(result['signing']['validDevelopmentIdentities'], 0)
        self.assertIn('DEVELOPMENT_IDENTITY_UNAVAILABLE', result['blockers'])

    def test_inventory_error_is_not_an_empty_successful_inventory(self):
        def failed():
            raise OSError(SECRET)
        result = ios.collect(runner(), failed)
        self.assertEqual(result['collectionStatus'], 'INCOMPLETE')
        self.assertEqual(result['blockers'], ['USB_INVENTORY_UNAVAILABLE'])
        self.assertNotIn('usbDevices', result)
        self.assertNotIn(SECRET, json.dumps(result))
        result = ios.collect(runner(), lambda: [])
        self.assertEqual(result['collectionStatus'], 'COLLECTED')
        self.assertEqual(result['blockers'], ['NO_USB_DEVICE'])

    def test_timeout_and_warnings_do_not_prove_available_tools(self):
        for error in (FileNotFoundError(), subprocess.TimeoutExpired('xcodebuild', 20)):
            def run(*args, **kwargs):
                raise error
            self.assertIsNone(ios.command_output(['xcodebuild'], run))
        run = lambda *args, **kwargs: subprocess.CompletedProcess([], 0, 'output', 'warning')
        self.assertIsNone(ios.command_output(['xcodebuild'], run))

    def test_existing_evidence_and_symlinks_are_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / 'original.json'
            original.write_text('retain')
            link = Path(directory) / 'link.json'
            link.symlink_to(original)
            for target in (original, link):
                with patch.object(ios.platform, 'system', return_value='Darwin'), \
                        patch.object(ios, 'collect') as collect, \
                        contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    ios.main(['--output', str(target)])
                collect.assert_not_called()
            self.assertEqual(original.read_text(), 'retain')

    def test_report_is_private_and_blocked_exit_is_nonzero(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'result.json'
            result = ios.collect(runner([None] * 4), lambda: [DEVICE])
            with patch.object(ios.platform, 'system', return_value='Darwin'), \
                    patch.object(ios, 'collect', return_value=result), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ios.main(['--output', str(target)]), 2)
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(target.read_text()), result)


if __name__ == '__main__':
    unittest.main()
