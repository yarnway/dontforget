import base64
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from android_release_signing import signing_environment, verify_android_signatures
import test_packaging as fixtures

CERT = 'a' * 64

def environment():
    return {
        'DONTFORGET_ANDROID_KEYSTORE_BASE64': base64.b64encode(b'synthetic-keystore' * 20).decode(),
        'DONTFORGET_ANDROID_STORE_PASSWORD': 'synthetic-password',
        'DONTFORGET_ANDROID_KEY_ALIAS': 'synthetic-alias',
        'DONTFORGET_ANDROID_KEY_PASSWORD': 'synthetic-password',
        'DONTFORGET_ANDROID_CERT_SHA256': CERT,
    }

class AndroidSigningTest(unittest.TestCase):
    def test_candidate_without_credentials_keeps_environment(self):
        with signing_environment({'PATH': 'synthetic'}) as env:
            self.assertEqual(env, {'PATH': 'synthetic'})

    def test_required_or_partial_configuration_fails_closed(self):
        for env in [{}, {'DONTFORGET_ANDROID_STORE_PASSWORD': 'synthetic-password'}]:
            with self.subTest(env=bool(env)), self.assertRaises(ValueError):
                with signing_environment(env, required=True): self.fail('must not run')

    def test_pinned_identity_base64_size_and_alias_are_checked(self):
        for name, value in [('CERT_SHA256', 'b' * 64), ('KEYSTORE_BASE64', '!invalid!'),
                            ('KEYSTORE_BASE64', base64.b64encode(b'short').decode()),
                            ('KEY_ALIAS', '../unsafe')]:
            env = environment(); env['DONTFORGET_ANDROID_' + name] = value
            with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                with signing_environment(env, expected_certificate=CERT): self.fail('must not run')

    def test_ephemeral_file_cleaned_after_success_or_build_failure(self):
        for failure in [False, True]:
            path = None
            try:
                with signing_environment(environment(), expected_certificate=CERT) as env:
                    path = Path(env['DONTFORGET_ANDROID_KEYSTORE_PATH'])
                    self.assertTrue(path.is_file())
                    self.assertEqual(path.read_bytes(), b'synthetic-keystore' * 20)
                    self.assertNotIn('DONTFORGET_ANDROID_KEYSTORE_BASE64', env)
                    self.assertEqual(env['DONTFORGET_REQUIRE_RELEASE_SIGNING'], '1')
                    if os.name != 'nt': self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                    if failure: raise RuntimeError('synthetic build failure')
            except RuntimeError:
                self.assertTrue(failure)
            self.assertFalse(path.exists())

    def check(self, apk_code=0, apk_cert=CERT, aab_code=4, aab_cert=CERT):
        outputs = [subprocess.CompletedProcess([], apk_code, f'Signer #1 certificate SHA-256 digest: {apk_cert}', ''),
                   subprocess.CompletedProcess([], aab_code, 'jar verified, with signer errors.', ''),
                   subprocess.CompletedProcess([], 0, 'SHA256: ' + aab_cert, '')]
        with patch('android_release_signing.Path.glob', return_value=[Path('synthetic-apksigner')]), \
             patch('android_release_signing.tool', return_value='synthetic-java-tool'), \
             patch('android_release_signing.subprocess.run', side_effect=outputs):
            return verify_android_signatures('app.apk', 'app.aab', CERT, {'ANDROID_HOME': 'synthetic-sdk'})

    def test_both_signatures_checked_with_self_signed_certificate(self):
        self.assertEqual(self.check(), CERT)

    def test_tampered_apk_wrong_certificate_or_unsigned_aab_rejected(self):
        for arguments in [{'apk_code': 1}, {'apk_cert': 'b' * 64}, {'aab_code': 20}, {'aab_cert': 'b' * 64}]:
            with self.subTest(arguments=arguments), self.assertRaises(ValueError): self.check(**arguments)

class DistributionPackageTest(unittest.TestCase):
    def setUp(self):
        fixture = fixtures.PackagingTest()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.root, self.revision, self.write = fixture.root, fixture.revision, fixture.write

    def test_distribution_package_records_certificate_and_checks_both_binaries(self):
        self.write('build/app/outputs/flutter-apk/app-release.apk')
        self.write('build/app/outputs/bundle/release/app-release.aab')
        with patch.dict(os.environ, {'DONTFORGET_REQUIRE_RELEASE_SIGNING': '1', 'DONTFORGET_ANDROID_CERT_SHA256': CERT}), \
             patch('package_artifacts.verify_android_signatures', return_value=CERT) as checked:
            from package_artifacts import package
            manifest = package(self.root, 'android', self.revision)
        checked.assert_called_once()
        self.assertEqual(manifest['signing'], 'release-key')
        self.assertEqual(manifest['certificate_sha256'], CERT)
        self.assertTrue(all('test-signed' not in a['file'] for a in manifest['artifacts']))

    def test_failed_signature_verification_produces_no_deliverables(self):
        self.write('build/app/outputs/flutter-apk/app-release.apk')
        self.write('build/app/outputs/bundle/release/app-release.aab')
        with patch.dict(os.environ, {'DONTFORGET_REQUIRE_RELEASE_SIGNING': '1'}), \
             patch('package_artifacts.verify_android_signatures', side_effect=ValueError('synthetic mismatch')):
            from package_artifacts import package
            with self.assertRaises(ValueError): package(self.root, 'android', self.revision)
        self.assertEqual(list((self.root / 'dist').iterdir()), [])
