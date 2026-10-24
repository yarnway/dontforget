#!/usr/bin/env python3
"""准备具有独立沙箱和通知身份的 Mac 派生验收副本；不会启动或注册应用。"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile


ORIGINAL_ID = 'com.example.dontForget'
ACCEPTANCE_PREFIX = ORIGINAL_ID + '.acceptance.'
APP_NAME = 'dont_forget.app'


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def validate_run_id(value):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,47}', value):
        raise ValueError('run ID 必须为 1–48 个小写字母、数字或连字符，首位不能是连字符')
    return value


def assert_unused_identity(bundle_id, home=None):
    """Check only directory existence, never open another session's data."""
    home = Path.home() if home is None else Path(home)
    for directory in [home / 'Library/Containers' / bundle_id,
                      home / 'Library/Application Support' / bundle_id]:
        if directory.exists() or directory.is_symlink():
            raise ValueError('验收 bundle ID 已有数据目录；必须使用新的 run ID')


def assert_non_temporary_output(output):
    # LaunchServices labels apps in these locations "in-temp-dir". usernoted
    # can then reject the app before showing a notification permission prompt.
    roots = {Path(value).resolve() for value in
             [tempfile.gettempdir(), '/tmp', '/private/tmp', '/var/tmp',
              '/private/var/tmp', '/var/folders', '/private/var/folders']}
    target = Path(output).resolve()
    if any(target == root or root in target.parents for root in roots):
        raise ValueError(
            '不能在系统临时目录准备原生验收应用：macOS 可能拒绝其通知身份。'
            '请使用仓库的 build/native_acceptance/<run-id>，父目录需已存在。'
        )


def _read_manifest(path, revision):
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('必须指定完整的 40 位源码 revision')
    if path.is_symlink() or not path.is_file():
        raise ValueError('manifest 必须是普通文件')
    raw = path.read_bytes()
    manifest = json.loads(raw)
    if manifest.get('platform') != 'macos' or manifest.get('revision') != revision:
        raise ValueError('manifest 平台或源码 revision 不匹配')
    artifacts = manifest.get('artifacts', [])
    if len(artifacts) != 1:
        raise ValueError('Mac manifest 必须且只能包含一个 ZIP')
    entry = artifacts[0]
    filename = entry['file']
    if Path(filename).name != filename or not filename.endswith('.zip'):
        raise ValueError('ZIP 名称不能包含路径')
    archive = path.parent / filename
    if archive.is_symlink() or not archive.is_file():
        raise ValueError('候选 ZIP 必须是普通文件')
    archive_bytes = archive.read_bytes()
    if (len(archive_bytes) != entry['bytes'] or
            sha256(archive_bytes) != entry['sha256']):
        raise ValueError('候选 ZIP 大小或 SHA-256 与 manifest 不匹配')
    _validate_zip(archive)
    return manifest, archive, sha256(raw)


def _validate_zip(path):
    """Validate paths before ditto handles the archive's framework symlinks."""
    with zipfile.ZipFile(path) as archive:
        seen = set()
        links = {}
        for entry in archive.infolist():
            name = entry.filename.rstrip('/')
            parts = PurePosixPath(name).parts
            if (not parts or name.startswith('/') or '\\' in name or
                    any(part in {'.', '..'} for part in name.split('/')) or
                    parts[0] not in {APP_NAME, '__MACOSX'} or name in seen):
                raise ValueError('ZIP 包含重复或不安全路径')
            seen.add(name)
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                target = archive.read(entry).decode('utf-8')
                if (not target or target.startswith('/') or '\\' in target or
                        '\x00' in target):
                    raise ValueError('ZIP 包含不安全符号链接')
                links[name] = target
            elif stat.S_IFMT(mode) not in {0, stat.S_IFREG, stat.S_IFDIR}:
                raise ValueError('ZIP 包含不支持的文件类型')
        # Resolve links, including chained directory links, without extracting.
        def resolve(parts, depth=0):
            if depth > 40:
                raise ValueError('ZIP 符号链接循环或过深')
            result = []
            for part in parts:
                if part == '..':
                    if len(result) <= 1:
                        raise ValueError('ZIP 符号链接越界')
                    result.pop()
                elif part not in {'', '.'}:
                    result.append(part)
                    current = '/'.join(result)
                    if current in links:
                        result = resolve(result[:-1] + links[current].split('/'), depth + 1)
            return result
        for name in seen:
            resolved = resolve(name.split('/'))
            if resolved[0] != name.split('/')[0]:
                raise ValueError('ZIP 符号链接越界')
        if archive.testzip() is not None:
            raise ValueError('ZIP CRC 校验失败')


def _macho_slice(data):
    """Hash every non-signature byte, normalizing only signature-size metadata."""
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('仅支持 little-endian 64 位 Mach-O')
    header = struct.unpack_from('<8I', data)
    command_end = 32 + header[5]
    if command_end > len(data) or header[4] > 1024:
        raise ValueError('Mach-O load commands 越界')
    cursor = 32
    signature = None
    linkedit = None
    for _ in range(header[4]):
        if cursor + 8 > command_end:
            raise ValueError('Mach-O load commands 损坏')
        command, size = struct.unpack_from('<II', data, cursor)
        if size < 8 or cursor + size > command_end:
            raise ValueError('Mach-O load command 大小无效')
        if command == 0x1d:  # LC_CODE_SIGNATURE
            if signature is not None or size != 16:
                raise ValueError('Mach-O 签名命令无效')
            offset, length = struct.unpack_from('<II', data, cursor + 8)
            signature = (cursor, offset, length)
        elif command == 0x19 and data[cursor + 8:cursor + 24].rstrip(b'\0') == b'__LINKEDIT':
            if linkedit is not None or size != 72:
                raise ValueError('Mach-O __LINKEDIT 命令无效')
            linkedit = cursor
        cursor += size
    if cursor != command_end or signature is None or linkedit is None:
        raise ValueError('Mach-O 缺少有效签名边界')
    sig_command, offset, length = signature
    file_offset, file_size = struct.unpack_from('<QQ', data, linkedit + 40)
    if (offset < command_end or length < 8 or offset + length != len(data) or
            file_offset > offset or file_offset + file_size != len(data)):
        raise ValueError('Mach-O 签名必须位于 __LINKEDIT 的文件末尾')
    normalized = bytearray(data[:offset])
    # codesign can resize its final signature and the containing segment only.
    normalized[sig_command + 12:sig_command + 16] = b'\0' * 4
    normalized[linkedit + 32:linkedit + 40] = b'\0' * 8  # vmsize
    normalized[linkedit + 48:linkedit + 56] = b'\0' * 8  # filesize
    return {'cpu': header[1], 'subtype': header[2],
            'signature_offset': offset, 'non_signature_sha256': sha256(normalized)}


def macho_identity(data):
    """A universal executable may move slices when their signatures grow."""
    if data[:4] == b'\xcf\xfa\xed\xfe':
        return [_macho_slice(data)]
    if data[:4] != b'\xca\xfe\xba\xbe' or len(data) < 8:
        raise ValueError('不支持的 Mach-O 文件格式')
    count = struct.unpack_from('>I', data, 4)[0]
    if not 1 <= count <= 32 or 8 + count * 20 > len(data):
        raise ValueError('Mach-O FAT 头无效')
    identities = []
    ranges = []
    for index in range(count):
        cpu, subtype, offset, size, alignment = struct.unpack_from('>5I', data, 8 + index * 20)
        if (alignment > 30 or offset % (1 << alignment) or
                offset < 8 + count * 20 or offset + size > len(data)):
            raise ValueError('Mach-O FAT slice 越界或未对齐')
        identity = _macho_slice(data[offset:offset + size])
        if identity['cpu'] != cpu or identity['subtype'] != subtype:
            raise ValueError('Mach-O FAT 架构身份不匹配')
        identity['alignment'] = alignment
        identities.append(identity)
        ranges.append((offset, offset + size))
    cursor = 8 + count * 20
    for start, end in sorted(ranges):
        if start < cursor or any(data[cursor:start]):
            raise ValueError('Mach-O FAT slice 重叠或 padding 非零')
        cursor = end
    if any(data[cursor:]):
        raise ValueError('Mach-O FAT 尾部 padding 非零')
    return identities


def tree_identity(directory):
    records = {}
    for path in sorted(directory.rglob('*')):
        relative = path.relative_to(directory).as_posix()
        if path.is_symlink():
            records[relative] = {'symlink': os.readlink(path)}
        elif path.is_file():
            records[relative] = {'sha256': sha256(path.read_bytes()),
                                 'mode': stat.S_IMODE(path.stat().st_mode)}
        elif path.is_dir():
            records[relative] = {'directory': True}
        else:
            raise ValueError('应用包包含不支持的文件类型')
    return records


def _run(arguments):
    return subprocess.run(arguments, check=True, capture_output=True).stdout


def verified_upgrade_identity(path, bundle_id):
    """Read only a previously prepared acceptance package, never its sandbox."""
    path = Path(path).absolute()
    if path.resolve() != path or not path.is_file():
        raise ValueError('升级来源必须是未经过符号链接的验收准备记录')
    raw = path.read_bytes()
    evidence = json.loads(raw)
    app = path.parent / APP_NAME
    if (evidence.get('scope') != 'derived-isolated-acceptance-copy-not-original-signed-candidate' or
            evidence.get('bundle_id') != bundle_id or
            not bundle_id.startswith(ACCEPTANCE_PREFIX) or
            evidence.get('app') != str(app) or app.resolve() != app or
            evidence.get('codesign_verify') != 'PASS' or
            evidence.get('frameworks_and_resources_unchanged') is not True):
        raise ValueError('升级来源不是同一隔离身份的已核验包')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    source = evidence['source_manifest']
    if (info.get('CFBundleIdentifier') != bundle_id or
            info.get('CFBundleExecutable') != 'dont_forget' or
            info.get('CFBundleShortVersionString') != source.get('version') or
            info.get('CFBundleVersion') != source.get('build_number') or
            source.get('revision') != evidence.get('source_revision')):
        raise ValueError('升级来源身份或版本已改变')
    _run(['codesign', '--verify', '--deep', '--strict', str(app)])
    entitlements = plistlib.loads(_run(['codesign', '-d', '--entitlements', ':-', str(app)]))
    if (entitlements != evidence.get('entitlements') or
            entitlements.get('com.apple.security.app-sandbox') is not True):
        raise ValueError('升级来源沙箱权限与记录不符')
    protected = {key: value for key, value in tree_identity(app).items()
                 if key.startswith(('Contents/Frameworks/', 'Contents/Resources/'))}
    if (protected != evidence.get('protected_tree') or
            sha256(json.dumps(protected, sort_keys=True).encode()) != evidence.get('protected_tree_sha256') or
            macho_identity((app / 'Contents/MacOS/dont_forget').read_bytes()) !=
            evidence.get('native_non_signature_identity')):
        raise ValueError('升级来源可执行文件或受保护资源已改变')
    return {'preparation_sha256': sha256(raw), 'app': str(app),
            'source_revision': evidence['source_revision'], 'bundle_id': bundle_id}


def prepare(manifest_path, output, run_id, revision, upgrade_from=None):
    if sys.platform != 'darwin':
        raise RuntimeError('此准备操作只能在 macOS 上执行')
    validate_run_id(run_id)
    manifest_path = Path(manifest_path).absolute()
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('输出目录已存在；请提供全新目录，脚本不会覆盖或清理')
    assert_non_temporary_output(output)
    if not output.parent.is_dir() or output.parent.resolve() != output.parent:
        raise ValueError('输出父目录必须存在且使用真实路径（例如仓库的 build/native_acceptance）')
    bundle_id = ACCEPTANCE_PREFIX + run_id
    previous = None
    if upgrade_from is None:
        assert_unused_identity(bundle_id)
    else:
        previous = verified_upgrade_identity(upgrade_from, bundle_id)
    manifest, archive, manifest_digest = _read_manifest(manifest_path, revision)
    original_archive_digest = sha256(archive.read_bytes())
    # mkdir is exclusive, so an existing output is never overwritten.
    output.mkdir(mode=0o700)
    _run(['ditto', '-x', '-k', str(archive), str(output)])
    app = output / APP_NAME
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    if (info.get('CFBundleIdentifier') != ORIGINAL_ID or
            info.get('CFBundleExecutable') != 'dont_forget' or
            info.get('CFBundleShortVersionString') != manifest['version'] or
            info.get('CFBundleVersion') != manifest['build_number']):
        raise ValueError('解包应用身份或版本与预期不符')
    _run(['codesign', '--verify', '--deep', '--strict', str(app)])
    entitlement_bytes = _run(['codesign', '-d', '--entitlements', ':-', str(app)])
    entitlements = plistlib.loads(entitlement_bytes)
    if entitlements.get('com.apple.security.app-sandbox') is not True:
        raise ValueError('候选未开启 macOS App Sandbox，拒绝派生验收副本')
    forbidden = {'com.apple.security.application-groups', 'keychain-access-groups',
                 'application-identifier', 'com.apple.application-identifier'}
    if (forbidden.intersection(entitlements) or
            any(key.startswith('com.apple.security.temporary-exception.files.') for key in entitlements)):
        raise ValueError('候选含共享身份、容器或文件例外权限，无法证明隔离')
    original_tree = tree_identity(app)
    executable = app / 'Contents/MacOS/dont_forget'
    original_code = macho_identity(executable.read_bytes())
    original_info = dict(info)
    info['CFBundleIdentifier'] = bundle_id
    info['CFBundleDisplayName'] = f'别忘了·隔离验收 {run_id}'
    info_path.write_bytes(plistlib.dumps(info))
    entitlements_path = output / 'original-entitlements.plist'
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    _run(['codesign', '--force', '--sign', '-', '--identifier', bundle_id,
          '--entitlements', str(entitlements_path), '--preserve-metadata=flags,runtime', str(app)])
    _run(['codesign', '--verify', '--deep', '--strict', str(app)])
    signed_entitlements = plistlib.loads(_run(['codesign', '-d', '--entitlements', ':-', str(app)]))
    if signed_entitlements != entitlements:
        raise ValueError('重新签名后 entitlements 发生变化')
    final_code = macho_identity(executable.read_bytes())
    if final_code != original_code:
        raise ValueError('重新签名改变了原生可执行文件的非签名字节')
    final_info = plistlib.loads(info_path.read_bytes())
    changed_info = sorted(key for key in original_info.keys() | final_info.keys()
                          if original_info.get(key) != final_info.get(key))
    if (set(changed_info) != {'CFBundleIdentifier', 'CFBundleDisplayName'} or
            final_info['CFBundleIdentifier'] != bundle_id):
        raise ValueError('外层 Info.plist 的非验收字段发生变化')
    final_tree = tree_identity(app)
    allowed = {'Contents/Info.plist', 'Contents/MacOS/dont_forget', 'Contents/_CodeSignature/CodeResources'}
    changed = sorted(key for key in original_tree.keys() | final_tree.keys()
                     if original_tree.get(key) != final_tree.get(key))
    if set(changed) - allowed:
        raise ValueError('重新签名改变了允许范围外的应用内容')
    if (sha256(archive.read_bytes()) != original_archive_digest or
            sha256(manifest_path.read_bytes()) != manifest_digest):
        raise ValueError('原 ZIP 或 manifest 在准备过程中发生变化')
    if previous is not None and verified_upgrade_identity(upgrade_from, bundle_id) != previous:
        raise ValueError('旧验收包在升级准备过程中发生变化')
    protected = {key: value for key, value in original_tree.items()
                 if key.startswith(('Contents/Frameworks/', 'Contents/Resources/'))}
    evidence = {
        'scope': 'derived-isolated-acceptance-copy-not-original-signed-candidate',
        'source_revision': revision, 'source_manifest_sha256': manifest_digest,
        'source_archive_sha256': original_archive_digest,
        'source_manifest': manifest, 'bundle_id': bundle_id, 'app': str(app),
        'upgrades_isolated_identity': previous,
        'entitlements': entitlements, 'changed_bundle_paths': changed,
        'changed_info_keys': changed_info,
        'frameworks_and_resources_unchanged': True,
        'protected_tree_sha256': sha256(json.dumps(protected, sort_keys=True).encode()),
        'protected_tree': protected, 'native_non_signature_identity': final_code,
        'codesign_verify': 'PASS', 'app_started': False, 'app_registered': False,
        'database_acceptance': 'NOT_PERFORMED', 'notification_acceptance': 'NOT_PERFORMED',
        'restart_acceptance': 'NOT_PERFORMED',
        'launch_requirement': 'Register and launch only this exact non-temporary app through macOS; '
                              'verify its independent sandbox container and database before restoring '
                              'synthetic fixtures. macOS sandbox launch supplies the container Data '
                              'working directory; no CUA cwd override is required. '
                              'Do not invoke smoke_desktop.py or start the original bundle ID.',
    }
    (output / 'acceptance-preparation.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        '只生成派生副本与证据，不启动应用、不访问用户库。默认要求全新 bundle ID；'
        '仅 --upgrade-from 可复用记录核验通过的同一隔离身份，旧包不改动，输出仍须全新；'
        '输出不能位于系统临时目录，避免 macOS 拒绝通知身份；'
        '失败时保留输出供检查，不自动删除。示例：python3 scripts/prepare_macos_acceptance.py '
        '--manifest /private/tmp/candidate/macos-manifest.json --revision <40位SHA> '
        '--run-id recovery-20261021 --output build/native_acceptance/recovery-20261021'))
    parser.add_argument('--manifest', required=True, type=Path, help='已下载候选的 macos-manifest.json')
    parser.add_argument('--revision', required=True, help='预期的完整 40 位源码 SHA')
    parser.add_argument('--run-id', required=True, help='验收 ID；升级时必须与旧包一致，默认必须全新')
    parser.add_argument('--upgrade-from', type=Path,
                        help='可选：旧隔离包的 acceptance-preparation.json；核验旧包后复用其身份，不读写沙箱')
    parser.add_argument('--output', required=True, type=Path,
                        help='尚不存在的非临时输出目录；建议 build/native_acceptance/<run-id>，父目录必须存在')
    args = parser.parse_args()
    evidence = prepare(args.manifest, args.output, args.run_id, args.revision, args.upgrade_from)
    print(json.dumps({key: evidence[key] for key in ('scope', 'bundle_id', 'app', 'codesign_verify')}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
