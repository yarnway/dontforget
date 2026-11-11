"""Validate native libraries in universal and ARM64 APKs independently of filenames."""
from pathlib import PurePosixPath
import struct
import zipfile

ABIS = {'arm64-v8a': (2, 183), 'armeabi-v7a': (1, 40), 'x86_64': (2, 62)}


def requires_arm64(version):
    return tuple(map(int, version.split('.'))) >= (1, 8, 3)


def libraries(apk, expected):
    result = {}
    seen = set()
    with zipfile.ZipFile(apk) as archive:
        for entry in archive.infolist():
            name = entry.filename
            if name in seen:
                raise ValueError('Duplicate APK entry')
            seen.add(name)
            if not name.startswith('lib/') or entry.is_dir():
                continue
            parts = PurePosixPath(name).parts
            if (len(parts) != 3 or parts[1] not in ABIS or
                    not parts[2].endswith('.so') or '\\' in name):
                raise ValueError('Unexpected APK native library path')
            abi, filename = parts[1:]
            with archive.open(entry) as stream:
                header = stream.read(20)
            elf_class, machine = ABIS[abi]
            if (len(header) != 20 or header[:4] != b'\x7fELF' or
                    header[4:6] != bytes([elf_class, 1]) or
                    struct.unpack('<H', header[18:20])[0] != machine):
                raise ValueError('APK library ELF architecture mismatch')
            result.setdefault(abi, []).append(filename)
    if set(result) != set(expected):
        raise ValueError('APK ABI inventory mismatch')
    for files in result.values():
        if not {'libflutter.so', 'libapp.so'} <= set(files):
            raise ValueError('APK is missing Flutter runtime libraries')
    return {abi: sorted(files) for abi, files in sorted(result.items())}


def verify_pair(universal, arm64):
    full = libraries(universal, ABIS)
    compact = libraries(arm64, {'arm64-v8a'})
    if compact['arm64-v8a'] != full['arm64-v8a']:
        raise ValueError('ARM64 APK plugin library inventory differs from universal APK')
    return {'universal': full, 'arm64': compact}
