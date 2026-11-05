#!/usr/bin/env python3
"""Use an ephemeral CI keystore and independently verify APK/AAB certificates."""
import argparse
import base64
from contextlib import contextmanager
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PREFIX = 'DONTFORGET_ANDROID_'
FIELDS = ('KEYSTORE_BASE64', 'STORE_PASSWORD', 'KEY_ALIAS', 'KEY_PASSWORD', 'CERT_SHA256')


def certificate(value):
    value = value.replace(':', '').strip().lower()
    if not re.fullmatch(r'[a-f0-9]{64}', value):
        raise ValueError('Invalid Android signing certificate identity')
    return value


@contextmanager
def signing_environment(environment, required=False, expected_certificate=None):
    env = dict(environment)
    values = {name: env.get(PREFIX + name, '') for name in FIELDS}
    if not any(values.values()):
        if required:
            raise ValueError('Android distribution signing is required')
        yield env
        return
    if not all(values.values()):
        raise ValueError('Incomplete Android signing configuration')
    expected = certificate(expected_certificate or (ROOT / 'android/release-certificate.sha256').read_text())
    if certificate(values['CERT_SHA256']) != expected:
        raise ValueError('Android certificate does not match the pinned identity')
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,100}', values['KEY_ALIAS']):
        raise ValueError('Invalid Android signing alias')
    try:
        material = base64.b64decode(values['KEYSTORE_BASE64'], validate=True)
    except Exception:
        raise ValueError('Invalid Android signing material') from None
    if not 128 <= len(material) <= 131072:
        raise ValueError('Invalid Android signing material size')
    with tempfile.TemporaryDirectory(prefix='dontforget-signing-') as directory:
        key = Path(directory) / 'distribution.p12'
        key.write_bytes(material)
        key.chmod(0o600)
        env.pop(PREFIX + 'KEYSTORE_BASE64', None)
        env[PREFIX + 'KEYSTORE_PATH'] = str(key.resolve())
        env[PREFIX + 'CERT_SHA256'] = expected
        env['DONTFORGET_REQUIRE_RELEASE_SIGNING'] = '1'
        yield env


def tool(name, environment):
    suffix = '.exe' if os.name == 'nt' else ''
    java = environment.get('JAVA_HOME')
    path = Path(java) / 'bin' / (name + suffix) if java else None
    found = str(path) if path and path.is_file() else shutil.which(name, path=environment.get('PATH'))
    if not found:
        raise ValueError('Java signing verification tools are required')
    return found


def verify_android_signatures(apk, aab, expected, environment=None):
    env = dict(os.environ if environment is None else environment)
    expected = certificate(expected)
    sdk = env.get('ANDROID_SDK_ROOT') or env.get('ANDROID_HOME')
    candidates = list((Path(sdk) / 'build-tools').glob('*/apksigner' + ('.bat' if os.name == 'nt' else ''))) if sdk else []
    if not candidates:
        raise ValueError('Android SDK signature verifier is required')
    def run(args):
        return subprocess.run(args, env=env, capture_output=True, text=True, errors='replace', timeout=90)
    checked = run([str(sorted(candidates)[-1]), 'verify', '--verbose', '--print-certs', str(apk)])
    apk_certificates = re.findall(r'Signer #\d+ certificate SHA-256 digest:\s*([a-fA-F0-9]+)', checked.stdout)
    if checked.returncode or len(apk_certificates) != 1 or certificate(apk_certificates[0]) != expected:
        raise ValueError('APK signing verification failed')
    # A self-signed Android certificate has no public CA chain (strict code 4).
    # Other strict warnings, including unsigned entries (16), are rejected.
    checked = run([tool('jarsigner', env), '-J-Duser.language=en', '-J-Duser.country=US', '-verify', '-strict', str(aab)])
    if checked.returncode not in (0, 4) or 'jar verified' not in checked.stdout.lower():
        raise ValueError('AAB integrity verification failed')
    checked = run([tool('keytool', env), '-J-Duser.language=en', '-J-Duser.country=US', '-printcert', '-jarfile', str(aab)])
    aab_certificates = re.findall(r'SHA256:\s*([A-Fa-f0-9:]+)', checked.stdout)
    if checked.returncode or len(aab_certificates) != 1 or certificate(aab_certificates[0]) != expected:
        raise ValueError('AAB signing certificate verification failed')
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--required', action='store_true')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('A build command is required')
    try:
        with signing_environment(os.environ, required=args.required) as env:
            return subprocess.run(command, env=env).returncode
    except (ValueError, OSError):
        parser.exit(1, 'Android distribution signing setup failed; private configuration was not printed.\n')


if __name__ == '__main__':
    raise SystemExit(main())
