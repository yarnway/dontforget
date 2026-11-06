#!/usr/bin/env python3
"""Prepare only Android/Windows/Linux assets from one successful trusted CI run."""
import argparse
import hashlib
import json
import os
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
from package_artifacts import ROOT, digest, version
from verify_artifacts import verify, verify_tag

PLATFORMS = ('android', 'windows', 'linux')
REPOSITORY = 'yarnway/dontforget'


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


def validate_run(run, jobs):
    if (run.get('status') != 'completed' or run.get('conclusion') != 'success' or
            run.get('head_branch') != 'main' or run.get('event') not in ('push', 'workflow_dispatch') or
            run.get('path') != '.github/workflows/build_and_release.yml' or
            run.get('repository', {}).get('full_name') != REPOSITORY or
            run.get('head_repository', {}).get('full_name') != REPOSITORY or
            not re.fullmatch('[0-9a-f]{40}', run.get('head_sha', ''))):
        raise ValueError('Release source is not a successful trusted main build')
    expected = {'Analyze and test', 'Windows analyze and test', *('Build ' + p + ' candidate' for p in PLATFORMS)}
    for name in expected:
        matches = [job for job in jobs if job.get('name') == name]
        if len(matches) != 1 or matches[0].get('conclusion') != 'success' or matches[0].get('status') != 'completed':
            raise ValueError('A required platform or quality job did not pass')
    return run['head_sha']


def select_artifacts(artifacts, run_id, revision):
    selected = []
    for platform in PLATFORMS:
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


def validate_files(directory, revision, release_version, build_number, expected_certificate):
    directory = Path(directory)
    expected = set()
    reports = {}
    for platform in PLATFORMS:
        verify(directory, release_version, build_number, revision, platform)
        manifest = json.loads((directory / (platform + '-manifest.json')).read_text(encoding='utf-8-sig'))
        expected.update([platform + '-manifest.json', platform + '-SHA256SUMS.txt'])
        expected.update(entry['file'] for entry in manifest['artifacts'])
        if platform == 'android':
            if (manifest.get('signing') != 'release-key' or
                    certificate(manifest.get('certificate_sha256', '')) != certificate(expected_certificate) or
                    {entry['file'] for entry in manifest['artifacts']} !=
                    {f'DontForget_Android_v{release_version}.{ext}' for ext in ('apk', 'aab')}):
                raise ValueError('A distribution-signed Android package is required')
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


def read_release_notes(root, release_version):
    # Never reuse an older release's body when preparing a new stable tag.
    path = Path(root) / 'docs' / f'Release_Notes_v{release_version}.md'
    notes = path.read_text(encoding='utf-8')
    heading = f'# DontForget v{release_version} · Android / Windows / Linux'
    if not notes.splitlines() or notes.splitlines()[0].strip() != heading:
        raise ValueError('Release notes do not match the verified version')
    return notes


def prepare(run_id, directory, github):
    run = github.get('actions/runs/' + str(run_id))
    jobs = github.get('actions/runs/' + str(run_id) + '/jobs?per_page=100')['jobs']
    revision = validate_run(run, jobs)
    if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() != revision:
        raise ValueError('Checked out source must equal the verified CI revision')
    release_version, build_number = version(ROOT)
    verify_tag('v' + release_version, release_version, build_number)
    verify_existing_tag(github, 'v' + release_version, revision)
    notes = read_release_notes(ROOT, release_version)
    selected = select_artifacts(github.get('actions/runs/' + str(run_id) + '/artifacts?per_page=100')['artifacts'], run_id, revision)
    expected_certificate = certificate((ROOT / 'android/release-certificate.sha256').read_text())
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='dontforget-release-download-') as work:
        for artifact in selected:
            archive = Path(work) / (artifact['name'] + '.zip')
            github.download(artifact, archive)
            extract_archive(archive, directory)
    reports = validate_files(directory, revision, release_version, build_number, expected_certificate)
    verify_android_signatures(directory / f'DontForget_Android_v{release_version}.apk',
                              directory / f'DontForget_Android_v{release_version}.aab', expected_certificate)
    receipt = {'version': release_version, 'build_number': build_number, 'revision': revision,
               'ci_run': run_id, 'ci_url': run['html_url'], 'platforms': list(PLATFORMS),
               'android_certificate_sha256': expected_certificate,
               'archives': [{'name': a['name'], 'sha256': a['digest'], 'bytes': a['size_in_bytes']} for a in selected],
               'acceptance_reports': list(reports), 'full_runtime_matrix': 'NOT_PERFORMED',
               'publisher_script_sha256': digest(Path(__file__)),
               'files': [{'file': p.name, 'sha256': digest(p), 'bytes': p.stat().st_size} for p in sorted(directory.iterdir())]}
    (directory / 'release-provenance.json').write_text(json.dumps(receipt, indent=2) + '\n')
    (directory / 'SHA256SUMS.txt').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in sorted(directory.iterdir())))
    Path('release-notes.md').write_text(notes + f'\n构建号：{build_number}；源码：`{revision}`；[完整CI]({run["html_url"]})。\n', encoding='utf-8')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write('tag=v' + release_version + '\nrevision=' + revision + '\n')
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    receipt = prepare(args.run_id, args.output, Github(os.environ.get('GH_TOKEN', '')))
    print(json.dumps({k: receipt[k] for k in ('version', 'build_number', 'revision', 'platforms')}))
