import copy
import hashlib
import json
import os
import plistlib
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import urllib.error
import zipfile
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_platform_release import (REPOSITORY, PLATFORMS, validate_run, select_artifacts,
                                      extract_archive, validate_files, verify_existing_tag)
from verify_published_release import verify_release
from prepare_platform_release import prepare, read_release_notes

REV = 'b' * 40
CERT = 'a' * 64


def run_fixture():
    return {'status': 'completed', 'conclusion': 'success', 'head_branch': 'main',
            'event': 'push', 'path': '.github/workflows/build_and_release.yml',
            'repository': {'full_name': REPOSITORY}, 'head_repository': {'full_name': REPOSITORY}, 'head_sha': REV}


def job_fixture():
    return [{'name': name, 'status': 'completed', 'conclusion': 'success'} for name in
            ['Analyze and test', 'Windows analyze and test', *('Build ' + p + ' candidate' for p in PLATFORMS)]]


class SourceGateTest(unittest.TestCase):
    def test_ios_release_requires_its_successful_job_and_artifact_provenance(self):
        with self.assertRaises(ValueError):
            validate_run(run_fixture(), job_fixture(), include_ios=True)
        jobs = job_fixture() + [{'name': 'Build ios candidate', 'status': 'completed', 'conclusion': 'success'}]
        self.assertEqual(validate_run(run_fixture(), jobs, include_ios=True), REV)
        jobs[-1]['conclusion'] = 'failure'
        with self.assertRaises(ValueError):
            validate_run(run_fixture(), jobs, include_ios=True)
        artifacts = [{'name': p + '-deliverables', 'expired': False, 'workflow_run': {'id': 42, 'head_sha': REV},
                      'digest': 'sha256:' + CERT} for p in (*PLATFORMS, 'ios')]
        self.assertEqual(len(select_artifacts(artifacts, 42, REV, include_ios=True)), 4)
        artifacts[-1]['workflow_run']['head_sha'] = 'c' * 40
        with self.assertRaises(ValueError):
            select_artifacts(artifacts, 42, REV, include_ios=True)

    def test_successful_main_source_requires_both_quality_and_three_builds(self):
        self.assertEqual(validate_run(run_fixture(), job_fixture()), REV)
        for key, value in [('head_branch', 'other'), ('status', 'queued'), ('conclusion', 'failure'),
                           ('event', 'pull_request'), ('head_sha', 'invalid'),
                           ('head_repository', {'full_name': 'other/fork'})]:
            run = run_fixture(); run[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): validate_run(run, job_fixture())

    def test_missing_failed_and_duplicate_quality_jobs_rejected(self):
        for jobs in [job_fixture()[1:], job_fixture() + job_fixture()[:1]]:
            with self.assertRaises(ValueError): validate_run(run_fixture(), jobs)
        jobs = job_fixture(); jobs[1]['conclusion'] = 'failure'
        with self.assertRaises(ValueError): validate_run(run_fixture(), jobs)

    def test_artifact_source_expiry_and_digest_are_required(self):
        artifacts = [{'name': p + '-deliverables', 'expired': False, 'workflow_run': {'id': 42, 'head_sha': REV},
                      'digest': 'sha256:' + CERT} for p in PLATFORMS]
        self.assertEqual(len(select_artifacts(artifacts, 42, REV)), 3)
        mutations = [('expired', True), ('workflow_run', {'id': 41, 'head_sha': REV}),
                     ('workflow_run', {'id': 42, 'head_sha': 'c' * 40}), ('digest', '')]
        for key, value in mutations:
            bad = copy.deepcopy(artifacts); bad[0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): select_artifacts(bad, 42, REV)
        with self.assertRaises(ValueError): select_artifacts(artifacts + artifacts[:1], 42, REV)

    def test_tag_must_resolve_to_exact_source_and_required_tag_cannot_be_absent(self):
        class Fake:
            def get(self, path):
                return {'object': {'type': 'commit', 'sha': REV}}
        verify_existing_tag(Fake(), 'v1.7.0', REV, required=True)
        with self.assertRaises(ValueError): verify_existing_tag(Fake(), 'v1.7.0', 'c' * 40)
        class Absent:
            def get(self, path): raise urllib.error.HTTPError('synthetic', 404, '', None, None)
        verify_existing_tag(Absent(), 'v1.7.0', REV)
        with self.assertRaises(urllib.error.HTTPError): verify_existing_tag(Absent(), 'v1.7.0', REV, required=True)


class ReleaseNotesTest(unittest.TestCase):
    def test_ios_scope_and_resigning_limitations_cannot_be_omitted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'docs').mkdir()
            path = root / 'docs/Release_Notes_v1.8.11.md'
            heading = '# DontForget v1.8.11 · Android / Windows / Linux / iOS\n'
            for notes in [heading, heading + '未签名 AltStore',
                          '# DontForget v1.8.11 · Android / Windows / Linux\n未签名 AltStore 7天']:
                path.write_text(notes, encoding='utf-8')
                with self.assertRaises(ValueError): read_release_notes(root, '1.8.11', include_ios=True)
            path.write_text(heading + '未签名 IPA，使用AltStore个人重签，免费账号7天续期。', encoding='utf-8')
            self.assertIn('AltStore', read_release_notes(root, '1.8.11', include_ios=True))

    def test_new_version_selects_its_own_utf8_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'docs').mkdir()
            for version in ['1.7.0', '1.7.1']:
                (root / f'docs/Release_Notes_v{version}.md').write_text(
                    f'# DontForget v{version} · Android / Windows / Linux\n版本{version}\n', encoding='utf-8')
            notes = read_release_notes(root, '1.7.1')
            self.assertIn('版本1.7.1', notes)
            self.assertNotIn('1.7.0', notes)

    def test_missing_or_wrong_version_notes_fail_without_using_old_body(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'docs').mkdir()
            old = '# DontForget v1.7.0 · Android / Windows / Linux\n旧说明\n'
            (root / 'docs/Release_Notes_v1.7.0.md').write_text(old, encoding='utf-8')
            with self.assertRaises(FileNotFoundError):
                read_release_notes(root, '1.7.1')
            path = root / 'docs/Release_Notes_v1.7.1.md'
            for body in [old, '', '# DontForget v1.7.1rc1 · Android / Windows / Linux\n']:
                path.write_text(body, encoding='utf-8')
                with self.assertRaises(ValueError):
                    read_release_notes(root, '1.7.1')


class ReleaseFilesTest(unittest.TestCase):
    def add_ios_package(self, fault=None):
        filename = 'DontForget_iOS_unsigned_v1.7.0.ipa'
        host = {'CFBundleIdentifier': 'com.yarnway.dontforget', 'CFBundleShortVersionString': '1.7.0',
                'CFBundleVersion': '59', 'CFBundleExecutable': 'Runner'}
        widget = {**host, 'CFBundleIdentifier': host['CFBundleIdentifier'] + '.ReminderActivity',
                  'CFBundleExecutable': 'ReminderActivity',
                  'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}}
        if fault == 'version': widget['CFBundleVersion'] = '58'
        if fault == 'identity': host['CFBundleIdentifier'] += '.unexpected'
        if fault == 'extension_type': widget['NSExtension'] = {}
        with zipfile.ZipFile(self.files / filename, 'w') as archive:
            archive.writestr('Payload/Runner.app/Info.plist', plistlib.dumps(host))
            archive.writestr('Payload/Runner.app/Runner', b'synthetic-executable')
            if fault != 'missing_widget':
                archive.writestr('Payload/Runner.app/PlugIns/ReminderActivity.appex/Info.plist', plistlib.dumps(widget))
                archive.writestr('Payload/Runner.app/PlugIns/ReminderActivity.appex/ReminderActivity', b'synthetic-widget')
            if fault == 'profile': archive.writestr('Payload/Runner.app/embedded.mobileprovision', b'synthetic')
            if fault == 'traversal': archive.writestr('Payload/../private', b'synthetic')
        path = self.files / filename
        entry = {'file': filename, 'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        (self.files / 'ios-manifest.json').write_text(json.dumps(
            {'platform': 'ios', 'version': '1.7.0', 'build_number': '59', 'revision': REV,
             'signing': 'unsigned', 'artifacts': [entry]}))
        (self.files / 'ios-SHA256SUMS.txt').write_text(f'{entry["sha256"]}  {filename}\n')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.files = self.root / 'files'; self.files.mkdir()
        for platform in PLATFORMS:
            names = {'android': ['DontForget_Android_v1.7.0.apk', 'DontForget_Android_v1.7.0.aab'],
                     'windows': ['DontForget_Setup_v1.7.0.exe', 'DontForget_Windows_Portable_v1.7.0.zip'],
                     'linux': ['DontForget_Linux_x64_v1.7.0.tar.gz']}[platform]
            entries = []
            for name in names:
                data = ('synthetic ' + name).encode(); (self.files / name).write_bytes(data)
                entries.append({'file': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
            manifest = {'platform': platform, 'version': '1.7.0', 'build_number': '59', 'revision': REV,
                        'signing': 'release-key' if platform == 'android' else 'unsigned',
                        'certificate_sha256': CERT, 'artifacts': entries}
            (self.files / (platform + '-manifest.json')).write_text(json.dumps(manifest))
            (self.files / (platform + '-SHA256SUMS.txt')).write_text(''.join(f'{x["sha256"]}  {x["file"]}\n' for x in entries))
            if platform != 'android':
                (self.files / (platform + '-startup.json')).write_text(json.dumps(
                    {'revision': REV, 'version': '1.7.0', 'result': 'PASS', 'startup_result': 'PASS', 'cleanup_result': 'PASS',
                     'ui_acceptance': 'NOT_PERFORMED', 'notification_acceptance': 'NOT_PERFORMED'}))
        (self.files / 'windows-installation.json').write_text(json.dumps(
            {'revision': REV, 'version': '1.7.0', 'build_number': '59', 'result': 'PASS'}))

    def validate(self): return validate_files(self.files, REV, '1.7.0', '59', CERT)

    def test_exact_three_platform_inventory_and_reports_pass(self):
        self.assertEqual(len(self.validate()), 3)

    def test_complete_prepare_writes_provenance_checksums_and_utf8_notes(self):
        self.check_complete_prepare(False)

    def test_complete_four_platform_prepare_keeps_ios_explicitly_unsigned(self):
        self.check_complete_prepare(True)

    def check_complete_prepare(self, include_ios):
        if include_ios: self.add_ios_package()
        (self.root / 'pubspec.yaml').write_text('version: 1.7.0+59\n')
        (self.root / 'android').mkdir()
        (self.root / 'android/release-certificate.sha256').write_text(CERT)
        (self.root / 'docs').mkdir()
        (self.root / 'docs/Release_Notes_v1.7.0.md').write_text(
            '# DontForget v1.7.0 · Android / Windows / Linux' +
            (' / iOS\n四平台发行说明；未签名 IPA，AltStore免费账号7天续期。\n' if include_ios else '\n三平台发行说明\n'), encoding='utf-8')
        archives = {}
        artifacts = []
        for platform in (*PLATFORMS, 'ios') if include_ios else PLATFORMS:
            name = platform + '-deliverables'
            archive = self.root / (name + '.zip')
            with zipfile.ZipFile(archive, 'w') as target:
                for file in self.files.iterdir():
                    if file.name.startswith(platform + '-') or file.name.startswith('DontForget_' + {'android': 'Android', 'linux': 'Linux', 'windows': 'Windows', 'ios': 'iOS'}[platform]) or (platform == 'windows' and file.name.startswith('DontForget_Setup')):
                        target.write(file, file.name)
            archives[name] = archive
            artifacts.append({'name': name, 'expired': False, 'size_in_bytes': archive.stat().st_size, 'workflow_run': {'id': 42, 'head_sha': REV},
                              'digest': 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()})
        class Fake:
            def get(self, path):
                if path.startswith('git/ref/'):
                    raise urllib.error.HTTPError('synthetic', 404, '', None, None)
                if '/jobs?' in path: return {'jobs': job_fixture() + ([{'name': 'Build ios candidate', 'status': 'completed', 'conclusion': 'success'}] if include_ios else [])}
                if '/artifacts?' in path: return {'artifacts': artifacts}
                return {**run_fixture(), 'html_url': 'https://example.com/synthetic'}
            def download(self, item, path): path.write_bytes(archives[item['name']].read_bytes())
        previous = Path.cwd()
        try:
            os.chdir(self.root)
            with patch('prepare_platform_release.ROOT', self.root), \
                 patch('prepare_platform_release.subprocess.check_output', return_value=REV), \
                 patch('prepare_platform_release.verify_android_signatures', return_value=CERT):
                result = prepare(42, self.root / 'prepared', Fake(), include_ios=include_ios)
            self.assertEqual(len(result['files']), 17 if include_ios else 14)
            self.assertTrue(all(isinstance(item['bytes'], int) for item in result['files']))
            self.assertEqual(len((self.root / 'prepared/SHA256SUMS.txt').read_text().splitlines()), 18 if include_ios else 15)
            self.assertIn('四平台发行说明' if include_ios else '三平台发行说明', (self.root / 'release-notes.md').read_text(encoding='utf-8'))
            if include_ios:
                self.assertEqual(result['platforms'], [*PLATFORMS, 'ios'])
                self.assertEqual(result['ios_distribution']['signing'], 'unsigned')
                self.assertFalse(result['ios_distribution']['app_store_or_testflight_distribution'])
        finally:
            os.chdir(previous)

    def test_actual_ios_identity_versions_profile_and_paths_are_checked(self):
        self.add_ios_package()
        self.assertEqual(len(validate_files(self.files, REV, '1.7.0', '59', CERT, include_ios=True)), 3)
        for fault in ['version', 'identity', 'extension_type', 'missing_widget', 'profile', 'traversal']:
            self.add_ios_package(fault)
            with self.subTest(fault=fault), self.assertRaises((ValueError, KeyError)):
                validate_files(self.files, REV, '1.7.0', '59', CERT, include_ios=True)

    def test_signed_or_unrequested_ios_inventory_is_rejected(self):
        self.add_ios_package()
        with self.assertRaises(ValueError): self.validate()
        manifest = self.files / 'ios-manifest.json'; data = json.loads(manifest.read_text())
        data['signing'] = 'development'; manifest.write_text(json.dumps(data))
        with self.assertRaises(ValueError): validate_files(self.files, REV, '1.7.0', '59', CERT, include_ios=True)

    def test_debug_android_or_wrong_certificate_cannot_be_published(self):
        path = self.files / 'android-manifest.json'; original = path.read_text()
        for key, value in [('signing', 'test-key'), ('certificate_sha256', 'c' * 64)]:
            data = json.loads(original); data[key] = value; path.write_text(json.dumps(data))
            with self.subTest(key=key), self.assertRaises(ValueError): self.validate()

    def test_extra_private_or_unselected_platform_file_rejected(self):
        (self.files / 'private.db').write_bytes(b'synthetic')
        with self.assertRaises(ValueError): self.validate()

    def test_stale_report_and_failed_cleanup_rejected(self):
        path = self.files / 'linux-startup.json'; original = path.read_text()
        for key, value in [('revision', 'c' * 40), ('cleanup_result', 'FAIL')]:
            report = json.loads(original); report[key] = value; path.write_text(json.dumps(report))
            with self.subTest(key=key), self.assertRaises(ValueError): self.validate()

    def test_archive_paths_symlinks_and_duplicate_entries_fail_before_extraction(self):
        for name in ['../outside', '/absolute', 'folder/file', 'C:\\outside', 'folder\\file']:
            archive = self.root / 'bad.zip'
            with zipfile.ZipFile(archive, 'w') as output: output.writestr(name, 'synthetic')
            with self.subTest(name=name), self.assertRaises(ValueError): extract_archive(archive, self.files)
        archive = self.root / 'bad.zip'; info = zipfile.ZipInfo('link'); info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(archive, 'w') as output: output.writestr(info, '/outside')
        with self.assertRaises(ValueError): extract_archive(archive, self.files)
        self.assertFalse((self.files / 'link').exists())

    def test_valid_archive_extracts_and_never_overwrites_existing_files(self):
        archive = self.root / 'good.zip'
        with zipfile.ZipFile(archive, 'w') as output: output.writestr('new.txt', 'synthetic')
        extract_archive(archive, self.files)
        self.assertEqual((self.files / 'new.txt').read_text(), 'synthetic')
        with self.assertRaises(FileExistsError): extract_archive(archive, self.files)

    def test_published_release_requires_exact_body_inventory_sizes_and_hashes(self):
        notes = self.root / 'notes.md'; notes.write_text('Synthetic release notes\n')
        release = {'draft': False, 'prerelease': False, 'tag_name': 'v1.7.0', 'body': notes.read_text(),
                   'html_url': 'https://example.com/synthetic', 'assets': []}
        for path in self.files.iterdir():
            release['assets'].append({'name': path.name, 'state': 'uploaded', 'size': path.stat().st_size,
                                      'digest': 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()})
        class Fake:
            def get(self, path):
                return release if path.startswith('releases/') else {'object': {'type': 'commit', 'sha': REV}}
        self.assertEqual(len(verify_release(Fake(), 'v1.7.0', REV, self.files, notes)['assets']), 14)
        original = copy.deepcopy(release)
        mutations = [('body', 'wrong'), ('draft', True), ('prerelease', True), ('assets', [])]
        for key, value in mutations:
            release.clear(); release.update(copy.deepcopy(original)); release[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): verify_release(Fake(), 'v1.7.0', REV, self.files, notes)
        release.clear(); release.update(original); release['assets'][0]['digest'] = 'sha256:' + 'c' * 64
        with self.assertRaises(ValueError): verify_release(Fake(), 'v1.7.0', REV, self.files, notes)
