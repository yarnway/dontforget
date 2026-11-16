#!/usr/bin/env python3
"""Prepare verified desktop/Android assets and optional unsigned iOS from one CI run."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import urllib.error
import zipfile
from android_release_signing import certificate, verify_android_signatures
from android_apk_variants import requires_arm64
from package_artifacts import ROOT, digest, version
from verify_artifacts import verify, verify_tag

PLATFORMS = ('android', 'windows', 'linux')
REPOSITORY = 'yarnway/dontforget'


def platforms(include_ios=False):
    return (*PLATFORMS, 'ios') if include_ios else PLATFORMS


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None and urllib.parse.urlparse(req.full_url).hostname != urllib.parse.urlparse(newurl).hostname:
            redirected.remove_header('Authorization')
        return redirected


class Github:
    def __init__(self, token):
        if not token:
            raise ValueError('A GitHub workflow token is required')
        self.headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
                        'User-Agent': 'dontforget-platform-release'}
        self.opener = urllib.request.build_opener(SafeRedirect())

    def request(self, path):
        return urllib.request.Request('https://api.github.com/repos/' + REPOSITORY + '/' + path, headers=self.headers)

    def get(self, path):
        for attempt in range(3):
            try:
                with self.opener.open(self.request(path), timeout=40) as stream:
                    return json.load(stream)
            except Exception:
                if attempt == 2: raise
                time.sleep(2)

    def download(self, artifact, path):
        if not 0 < artifact['size_in_bytes'] <= 1024 ** 3:
            raise ValueError('Invalid artifact size')
        checksum = hashlib.sha256()
        size = 0
        with self.opener.open(self.request('actions/artifacts/' + str(artifact['id']) + '/zip'), timeout=90) as stream, path.open('xb') as out:
            while block := stream.read(1024 * 1024):
                size += len(block)
                if size > artifact['size_in_bytes']: raise ValueError('Artifact exceeds its declared size')
                checksum.update(block)
                out.write(block)
        if size != artifact['size_in_bytes'] or artifact.get('digest') != 'sha256:' + checksum.hexdigest():
            raise ValueError('Artifact archive checksum mismatch')


def validate_run(run, jobs, include_ios=False):
    if (run.get('status') != 'completed' or run.get('conclusion') != 'success' or
            run.get('head_branch') != 'main' or run.get('event') not in ('push', 'workflow_dispatch') or
            run.get('path') != '.github/workflows/build_and_release.yml' or
            run.get('repository', {}).get('full_name') != REPOSITORY or
            run.get('head_repository', {}).get('full_name') != REPOSITORY or
            not re.fullmatch('[0-9a-f]{40}', run.get('head_sha', ''))):
        raise ValueError('Release source is not a successful trusted main build')
    expected = {'Analyze and test', 'Windows analyze and test', *('Build ' + p + ' candidate' for p in platforms(include_ios))}
    for name in expected:
        matches = [job for job in jobs if job.get('name') == name]
        if len(matches) != 1 or matches[0].get('conclusion') != 'success' or matches[0].get('status') != 'completed':
            raise ValueError('A required platform or quality job did not pass')
    return run['head_sha']


def select_artifacts(artifacts, run_id, revision, include_ios=False):
    selected = []
    for platform in platforms(include_ios):
        matches = [a for a in artifacts if a.get('name') == platform + '-deliverables']
        if len(matches) != 1: raise ValueError('Missing or ambiguous platform artifact')
        item = matches[0]
        if (item.get('expired') is not False or item.get('workflow_run', {}).get('id') != run_id or
                item.get('workflow_run', {}).get('head_sha') != revision or
                not re.fullmatch('sha256:[a-f0-9]{64}', item.get('digest', ''))):
            raise ValueError('Artifact provenance mismatch')
        selected.append(item)
    return selected


def verify_existing_tag(github, tag, revision, required=False):
    try:
        ref = github.get('git/ref/tags/' + tag)
    except urllib.error.HTTPError as error:
        if error.code == 404 and not required: return
        raise
    target = ref['object']
    for _ in range(4):
        if target['type'] != 'tag': break
        target = github.get('git/tags/' + target['sha'])['object']
    if target.get('type') != 'commit' or target.get('sha') != revision:
        raise ValueError('Existing release tag points to a different source')


def extract_archive(archive, output):
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if not 1 <= len(entries) <= 20 or sum(x.file_size for x in entries) > 1024 ** 3:
            raise ValueError('Invalid artifact inventory size')
        names = set()
        for item in entries:
            name = item.filename
            mode = item.external_attr >> 16
            if (not re.fullmatch(r'[A-Za-z0-9_.+ -]+', name) or name in ('.', '..') or
                    PurePosixPath(name).name != name or name in names or
                    item.is_dir() or stat.S_ISLNK(mode)):
                raise ValueError('Unsafe or duplicated artifact entry')
            names.add(name)
        for item in entries:
            with source.open(item) as incoming, (output / item.filename).open('xb') as target:
                while block := incoming.read(1024 * 1024): target.write(block)


def verify_ios_package(path, release_version, build_number):
    """Read the actual unsigned host/widget; never infer installation or signing."""
    host_path = 'Payload/Runner.app/'
    widget_path = host_path + 'PlugIns/ReminderActivity.appex/'
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if (not 1 <= len(entries) <= 10000 or len(set(names)) != len(names) or
                sum(entry.file_size for entry in entries) > 1024 ** 3):
            raise ValueError('Invalid iOS archive inventory')
        for name in names:
            parsed = PurePosixPath(name)
            if (parsed.is_absolute() or '..' in parsed.parts or '\\' in name or
                    name.endswith('embedded.mobileprovision')):
                raise ValueError('Unsafe or unexpectedly provisioned unsigned IPA')
        hosts = {name for name in names if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', name)}
        if hosts != {host_path + 'Info.plist'} or archive.testzip() is not None:
            raise ValueError('iOS host inventory or CRC mismatch')
        for prefix, identity in [(host_path, 'com.yarnway.dontforget'),
                                 (widget_path, 'com.yarnway.dontforget.ReminderActivity')]:
            info = plistlib.loads(archive.read(prefix + 'Info.plist'))
            if (info.get('CFBundleIdentifier'), info.get('CFBundleShortVersionString'),
                    info.get('CFBundleVersion')) != (identity, release_version, build_number):
                raise ValueError('iOS host/widget identity or version mismatch')
            executable = info.get('CFBundleExecutable', '')
            if (not executable or PurePosixPath(executable).name != executable or
                    '\\' in executable or executable in ('.', '..') or
                    prefix + executable not in names or archive.getinfo(prefix + executable).file_size == 0):
                raise ValueError('Missing or unsafe iOS executable')
            if prefix == widget_path and info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension':
                raise ValueError('iOS Live Activity is not a WidgetKit extension')


def validate_files(directory, revision, release_version, build_number, expected_certificate, include_ios=False):
    directory = Path(directory)
    expected = set()
    reports = {}
    for platform in platforms(include_ios):
        verify(directory, release_version, build_number, revision, platform)
        manifest = json.loads((directory / (platform + '-manifest.json')).read_text(encoding='utf-8-sig'))
        expected.update([platform + '-manifest.json', platform + '-SHA256SUMS.txt'])
        expected.update(entry['file'] for entry in manifest['artifacts'])
        if platform == 'android':
            if (manifest.get('signing') != 'release-key' or
                    certificate(manifest.get('certificate_sha256', '')) != certificate(expected_certificate) or
                    {entry['file'] for entry in manifest['artifacts']} !=
                    ({f'DontForget_Android_v{release_version}.{ext}' for ext in ('apk', 'aab')} |
                     ({f'DontForget_Android_arm64_v{release_version}.apk'} if requires_arm64(release_version) else set()))):
                raise ValueError('A distribution-signed Android package is required')
        elif platform == 'ios':
            filename = f'DontForget_iOS_unsigned_v{release_version}.ipa'
            if (manifest.get('signing') != 'unsigned' or
                    {entry['file'] for entry in manifest['artifacts']} != {filename}):
                raise ValueError('Only explicitly unsigned iOS packages can be distributed here')
            verify_ios_package(directory / filename, release_version, build_number)
        else:
            name = platform + '-startup.json'
            report = json.loads((directory / name).read_text(encoding='utf-8-sig'))
            if (report.get('revision') != revision or report.get('version') != release_version or
                    any(report.get(k) != 'PASS' for k in ('result', 'startup_result', 'cleanup_result'))):
                raise ValueError('Desktop startup or isolated cleanup did not pass')
            expected.add(name)
            reports[name] = report
    name = 'windows-installation.json'
    report = json.loads((directory / name).read_text(encoding='utf-8-sig'))
    if (report.get('result'), report.get('revision'), report.get('version'), report.get('build_number')) != ('PASS', revision, release_version, build_number):
        raise ValueError('Windows installer acceptance did not pass')
    expected.add(name)
    reports[name] = report
    if {p.name for p in directory.iterdir()} != expected:
        raise ValueError('Unexpected or missing release files')
    return reports


def read_release_notes(root, release_version, include_ios=False):
    # Never reuse an older release's body when preparing a new stable tag.
    path = Path(root) / 'docs' / f'Release_Notes_v{release_version}.md'
    notes = path.read_text(encoding='utf-8')
    heading = f'# DontForget v{release_version} · Android / Windows / Linux' + (' / iOS' if include_ios else '')
    if not notes.splitlines() or notes.splitlines()[0].strip() != heading:
        raise ValueError('Release notes do not match the verified version')
    if include_ios and not all(marker in notes for marker in ('未签名', 'AltStore', '7天')):
        raise ValueError('iOS release notes must explain personal resigning and expiry')
    return notes


def prepare(run_id, directory, github, include_ios=False):
    run = github.get('actions/runs/' + str(run_id))
    jobs = github.get('actions/runs/' + str(run_id) + '/jobs?per_page=100')['jobs']
    revision = validate_run(run, jobs, include_ios)
    if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() != revision:
        raise ValueError('Checked out source must equal the verified CI revision')
    release_version, build_number = version(ROOT)
    verify_tag('v' + release_version, release_version, build_number)
    verify_existing_tag(github, 'v' + release_version, revision)
    notes = read_release_notes(ROOT, release_version, include_ios)
    selected = select_artifacts(github.get('actions/runs/' + str(run_id) + '/artifacts?per_page=100')['artifacts'], run_id, revision, include_ios)
    expected_certificate = certificate((ROOT / 'android/release-certificate.sha256').read_text())
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='dontforget-release-download-') as work:
        for artifact in selected:
            archive = Path(work) / (artifact['name'] + '.zip')
            github.download(artifact, archive)
            extract_archive(archive, directory)
    reports = validate_files(directory, revision, release_version, build_number, expected_certificate, include_ios)
    verify_android_signatures(directory / f'DontForget_Android_v{release_version}.apk',
                              directory / f'DontForget_Android_v{release_version}.aab', expected_certificate,
                              **({'additional_apks': [directory / f'DontForget_Android_arm64_v{release_version}.apk']}
                                 if requires_arm64(release_version) else {}))
    receipt = {'version': release_version, 'build_number': build_number, 'revision': revision,
               'ci_run': run_id, 'ci_url': run['html_url'], 'platforms': list(platforms(include_ios)),
               'android_certificate_sha256': expected_certificate,
               'archives': [{'name': a['name'], 'sha256': a['digest'], 'bytes': a['size_in_bytes']} for a in selected],
               'acceptance_reports': list(reports), 'full_runtime_matrix': 'NOT_PERFORMED',
               'publisher_script_sha256': digest(Path(__file__)),
               'files': [{'file': p.name, 'sha256': digest(p), 'bytes': p.stat().st_size} for p in sorted(directory.iterdir())]}
    if include_ios:
        receipt['ios_distribution'] = {'signing': 'unsigned', 'requires_personal_resigning': True,
                                       'runtime_acceptance': 'NOT_PERFORMED',
                                       'app_store_or_testflight_distribution': False}
    (directory / 'release-provenance.json').write_text(json.dumps(receipt, indent=2) + '\n')
    (directory / 'SHA256SUMS.txt').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in sorted(directory.iterdir())))
    Path('release-notes.md').write_text(notes + f'\n构建号：{build_number}；源码：`{revision}`；[完整CI]({run["html_url"]})。\n', encoding='utf-8')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write('tag=v' + release_version + '\nrevision=' + revision + '\n')
            stream.write('platform_title=Android / Windows / Linux' + (' / iOS' if include_ios else '') + '\n')
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--include-ios', action='store_true', help='Include the verified unsigned IPA for personal resigning')
    args = parser.parse_args()
    receipt = prepare(args.run_id, args.output, Github(os.environ.get('GH_TOKEN', '')), args.include_ios)
    print(json.dumps({k: receipt[k] for k in ('version', 'build_number', 'revision', 'platforms')}))
