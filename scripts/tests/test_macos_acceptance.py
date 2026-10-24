import hashlib
import json
from pathlib import Path
import plistlib
import stat
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_macos_acceptance as acceptance


def macho(signature=b'original-signature', code=b'fixture-code'):
    signature_offset = 160
    length = signature_offset + len(signature)
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 2, 88, 0, 0)
    segment = struct.pack('<II16s4Q4I', 0x19, 72, b'__LINKEDIT',
                          4096, length, 128, length - 128, 1, 1, 0, 0)
    command = struct.pack('<4I', 0x1d, 16, signature_offset, len(signature))
    return (header + segment + command + code).ljust(signature_offset, b'\0') + signature


def fat(slices):
    # Slices use distinct CPU subtypes, and real codesign can move later ones.
    result = bytearray(b'\xca\xfe\xba\xbe' + struct.pack('>I', len(slices)))
    offset = 8 + 20 * len(slices)
    blobs = []
    for index, value in enumerate(slices):
        value = bytearray(value)
        struct.pack_into('<I', value, 8, index)
        start = (offset + 15) // 16 * 16
        result.extend(struct.pack('>5I', 0x100000c, index, start, len(value), 4))
        blobs.append((start, value))
        offset = start + len(value)
    for start, value in blobs:
        result.extend(b'\0' * (start - len(result)))
        result.extend(value)
    return bytes(result)


class MacAcceptanceTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.archive = self.root / 'candidate.zip'
        self.manifest = self.root / 'macos-manifest.json'
        self.output = self.root / 'acceptance'
        self.revision = 'a' * 40
        self.entitlements = {'com.apple.security.app-sandbox': True,
                             'com.apple.security.files.user-selected.read-write': True}
        self.info = {'CFBundleIdentifier': acceptance.ORIGINAL_ID,
                     'CFBundleExecutable': 'dont_forget', 'CFBundleDisplayName': '别忘了',
                     'CFBundleVersion': '3', 'CFBundleShortVersionString': '1.5.2'}
        self.calls = []
        self.extra_change = None
        self.write_archive()

    def write_archive(self, extra=None):
        with zipfile.ZipFile(self.archive, 'w') as archive:
            files = {'Contents/Info.plist': plistlib.dumps(self.info),
                     'Contents/MacOS/dont_forget': macho(),
                     'Contents/_CodeSignature/CodeResources': b'original-seal',
                     'Contents/Frameworks/App.framework/App': b'compiled-dart',
                     'Contents/Resources/MainMenu.nib': b'interface'}
            for name, value in files.items():
                archive.writestr(acceptance.APP_NAME + '/' + name, value)
            if extra:
                for name, value in extra:
                    archive.writestr(name, value)
        self.write_manifest()

    def write_manifest(self):
        self.manifest.write_text(json.dumps({
            'version': '1.5.2', 'build_number': '3', 'platform': 'macos',
            'revision': self.revision,
            'artifacts': [{'file': self.archive.name, 'bytes': self.archive.stat().st_size,
                           'sha256': hashlib.sha256(self.archive.read_bytes()).hexdigest()}]}))

    def command(self, arguments):
        self.calls.append(arguments)
        app = self.output / acceptance.APP_NAME
        if arguments[0] == 'ditto':
            with zipfile.ZipFile(arguments[3]) as archive:
                archive.extractall(arguments[4])
        elif arguments[:2] == ['codesign', '-d']:
            return plistlib.dumps(self.entitlements)
        elif arguments[:2] == ['codesign', '--force']:
            (app / 'Contents/MacOS/dont_forget').write_bytes(macho(b'new-longer-ad-hoc-signature'))
            (app / 'Contents/_CodeSignature/CodeResources').write_bytes(b'new-seal')
            if self.extra_change:
                (app / self.extra_change).write_bytes(b'unexpected-change')
        return b''

    def prepare(self, upgrade_from=None):
        # Unit fixtures live in TemporaryDirectory; no real app is signed or
        # launched. The actual location guard has separate negative tests.
        with patch.object(acceptance.sys, 'platform', 'darwin'), \
                patch.object(acceptance, 'assert_non_temporary_output'), \
                patch.object(acceptance, '_run', self.command):
            return acceptance.prepare(self.manifest, self.output, 'recovery-test', self.revision, upgrade_from)

    def prepare_upgrade(self):
        previous = self.output
        self.prepare()
        self.output = self.root / 'upgraded'
        return previous, previous / 'acceptance-preparation.json'

    def test_explicit_upgrade_preserves_old_package_and_reuses_only_its_identity(self):
        previous, record = self.prepare_upgrade()
        before = acceptance.tree_identity(previous)
        self.revision = 'b' * 40
        self.write_manifest()
        with patch.object(acceptance, 'assert_unused_identity', side_effect=AssertionError('fresh-only guard')):
            result = self.prepare(record)
        self.assertEqual(result['bundle_id'], acceptance.ACCEPTANCE_PREFIX + 'recovery-test')
        self.assertEqual(result['upgrades_isolated_identity']['source_revision'], 'a' * 40)
        self.assertEqual(result['upgrades_isolated_identity']['preparation_sha256'],
                         hashlib.sha256(record.read_bytes()).hexdigest())
        self.assertEqual(acceptance.tree_identity(previous), before)
        self.assertEqual(result['source_revision'], 'b' * 40)
        self.assertFalse(result['app_started'])
        self.assertFalse(result['app_registered'])

    def test_upgrade_rejects_different_or_production_identity_before_creating_output(self):
        _, record = self.prepare_upgrade()
        original = json.loads(record.read_text())
        for identity in [acceptance.ORIGINAL_ID, acceptance.ACCEPTANCE_PREFIX + 'other']:
            evidence = {**original, 'bundle_id': identity}
            record.write_text(json.dumps(evidence))
            with self.subTest(identity=identity), self.assertRaisesRegex(ValueError, '同一隔离身份'):
                self.prepare(record)
            self.assertFalse(self.output.exists())

    def test_upgrade_rejects_changed_framework_or_native_code(self):
        previous, record = self.prepare_upgrade()
        for relative in ['Contents/Frameworks/App.framework/App', 'Contents/MacOS/dont_forget']:
            target = previous / acceptance.APP_NAME / relative
            original = target.read_bytes()
            target.write_bytes(macho(code=b'tampered') if '/MacOS/' in relative else b'tampered')
            with self.subTest(path=relative), self.assertRaisesRegex(ValueError, '受保护资源'):
                self.prepare(record)
            self.assertFalse(self.output.exists())
            target.write_bytes(original)

    def test_upgrade_rejects_symlinked_record(self):
        _, record = self.prepare_upgrade()
        link = self.root / 'record-link.json'
        link.symlink_to(record)
        with self.assertRaisesRegex(ValueError, '符号链接'):
            self.prepare(link)
        self.assertFalse(self.output.exists())

    def test_upgrade_rejects_changed_sandbox_entitlements(self):
        _, record = self.prepare_upgrade()
        self.entitlements['com.apple.security.app-sandbox'] = False
        with self.assertRaisesRegex(ValueError, '沙箱权限'):
            self.prepare(record)
        self.assertFalse(self.output.exists())

    def test_upgrade_still_refuses_existing_output(self):
        _, record = self.prepare_upgrade()
        self.output.mkdir()
        with self.assertRaisesRegex(ValueError, '输出目录已存在'):
            self.prepare(record)

    def test_prepares_independent_identity_without_launching_or_mutating_source(self):
        old_zip = self.archive.read_bytes()
        old_manifest = self.manifest.read_bytes()
        evidence = self.prepare()
        info = plistlib.loads((self.output / acceptance.APP_NAME / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], acceptance.ACCEPTANCE_PREFIX + 'recovery-test')
        self.assertIn('隔离验收', info['CFBundleDisplayName'])
        self.assertEqual(evidence['codesign_verify'], 'PASS')
        self.assertFalse(evidence['app_started'])
        self.assertFalse(evidence['app_registered'])
        self.assertEqual(evidence['database_acceptance'], 'NOT_PERFORMED')
        self.assertEqual(self.archive.read_bytes(), old_zip)
        self.assertEqual(self.manifest.read_bytes(), old_manifest)
        self.assertNotIn('empty owned working directory', evidence['launch_requirement'])
        self.assertIn('sandbox container', evidence['launch_requirement'])
        self.assertTrue(all(command[0] in {'ditto', 'codesign'} for command in self.calls))
        signing = next(command for command in self.calls if '--sign' in command)
        self.assertNotIn('--deep', signing)
        self.assertEqual(evidence['native_non_signature_identity'], acceptance.macho_identity(macho()))

    def test_existing_output_is_never_overwritten(self):
        self.output.mkdir()
        keep = self.output / 'keep'
        keep.write_text('preserved')
        with self.assertRaisesRegex(ValueError, '输出目录已存在'):
            self.prepare()
        self.assertEqual(keep.read_text(), 'preserved')
        self.assertEqual(self.calls, [])

    def test_run_id_cannot_choose_original_or_escape_namespace(self):
        for run_id in ['', '../original', 'com.example.dontForget', 'a/b', 'A', '-a']:
            with self.subTest(run_id=run_id), self.assertRaises(ValueError):
                acceptance.validate_run_id(run_id)

    def test_existing_identity_is_rejected_without_reading_content(self):
        bundle_id = acceptance.ACCEPTANCE_PREFIX + 'used'
        acceptance.assert_unused_identity(bundle_id, self.root)
        directory = self.root / 'Library/Containers' / bundle_id
        directory.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, '已有数据目录'):
            acceptance.assert_unused_identity(bundle_id, self.root)

    def test_system_temporary_output_rejected_before_signing_or_creating_output(self):
        with patch.object(acceptance.sys, 'platform', 'darwin'), \
                patch.object(acceptance, '_run', self.command):
            with self.assertRaisesRegex(ValueError, 'build/native_acceptance'):
                acceptance.prepare(self.manifest, self.output, 'recovery-test', self.revision)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.calls, [])
        for path in ['/tmp/qa', '/private/tmp/qa', '/var/tmp/qa',
                     '/private/var/tmp/qa', '/private/var/folders/qa']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                acceptance.assert_non_temporary_output(path)

    def test_repository_build_output_is_accepted(self):
        with patch.object(acceptance.tempfile, 'gettempdir', return_value='/private/tmp'):
            acceptance.assert_non_temporary_output('/Users/qa/project/build/native_acceptance/run')

    def test_source_mismatch_rejected_before_creating_output(self):
        for change in ['hash', 'revision', 'platform', 'path']:
            with self.subTest(change=change):
                self.write_manifest()
                content = json.loads(self.manifest.read_text())
                if change == 'hash':
                    content['artifacts'][0]['sha256'] = '0' * 64
                elif change == 'path':
                    content['artifacts'][0]['file'] = '../candidate.zip'
                else:
                    content[change] = 'wrong'
                self.manifest.write_text(json.dumps(content))
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse(self.output.exists())

    def test_original_bundle_identity_must_match(self):
        self.info['CFBundleIdentifier'] = 'another.app'
        self.write_archive()
        with self.assertRaisesRegex(ValueError, '解包应用身份'):
            self.prepare()

    def test_sandbox_and_shared_groups_fail_closed(self):
        for value in [{}, {'com.apple.security.app-sandbox': False},
                      {'com.apple.security.app-sandbox': True, 'com.apple.security.application-groups': ['shared']}]:
            with self.subTest(value=value), tempfile.TemporaryDirectory(dir=self.root) as parent:
                self.output = Path(parent) / 'copy'
                self.entitlements = value
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse((self.output / 'acceptance-preparation.json').exists())

    def test_framework_or_resource_mutation_rejected(self):
        for file in ['Contents/Frameworks/App.framework/App', 'Contents/Resources/MainMenu.nib']:
            with self.subTest(file=file), tempfile.TemporaryDirectory(dir=self.root) as parent:
                self.output = Path(parent) / 'copy'
                self.extra_change = file
                with self.assertRaisesRegex(ValueError, '允许范围外'):
                    self.prepare()
                self.assertFalse((self.output / 'acceptance-preparation.json').exists())

    def test_zip_traversal_and_duplicate_names_rejected(self):
        for name in ['../escape', '/absolute', acceptance.APP_NAME + '/../../escape',
                     acceptance.APP_NAME + '/Contents/Info.plist']:
            with self.subTest(name=name):
                self.write_archive([(name, b'invalid')])
                with self.assertRaisesRegex(ValueError, '不安全路径'):
                    self.prepare()
                self.assertFalse(self.output.exists())

    def test_zip_symlink_escape_or_loop_rejected(self):
        for target in ['../../escape', '/private/tmp/escape', 'link']:
            with self.subTest(target=target):
                link = zipfile.ZipInfo(acceptance.APP_NAME + '/link')
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                self.write_archive([(link, target.encode())])
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse(self.output.exists())

    def test_framework_relative_symlink_chain_is_accepted(self):
        links = []
        for name, target in [('Foo.framework/Versions/Current', 'A'),
                             ('Foo.framework/Foo', 'Versions/Current/Foo')]:
            link = zipfile.ZipInfo(acceptance.APP_NAME + '/Contents/Frameworks/' + name)
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            links.append((link, target.encode()))
        self.write_archive(links)
        acceptance._validate_zip(self.archive)

    def test_macho_accepts_only_signature_and_size_metadata_changes(self):
        original = acceptance.macho_identity(macho())
        self.assertEqual(original, acceptance.macho_identity(macho(b'larger signature blob')))
        self.assertNotEqual(original, acceptance.macho_identity(macho(code=b'changed-code')))
        changed_header = bytearray(macho())
        struct.pack_into('<I', changed_header, 24, 1)
        self.assertNotEqual(original, acceptance.macho_identity(changed_header))

    def test_universal_macho_accepts_signature_growth_and_slice_relocation(self):
        original = fat([macho(), macho()])
        signed = fat([macho(b'larger' * 30), macho(b'other-signature')])
        self.assertEqual(acceptance.macho_identity(original), acceptance.macho_identity(signed))
        modified = fat([macho(), macho(code=b'modified')])
        self.assertNotEqual(acceptance.macho_identity(original), acceptance.macho_identity(modified))

    def test_macho_bad_boundaries_and_hidden_padding_rejected(self):
        for data in [b'invalid', macho() + b'extra', macho()[:100]]:
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                acceptance.macho_identity(data)
        data = bytearray(fat([macho()]))
        data[28] = 1
        with self.assertRaisesRegex(ValueError, 'padding'):
            acceptance.macho_identity(data)


if __name__ == '__main__':
    unittest.main()
