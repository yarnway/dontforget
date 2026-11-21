from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prune_windows_bundle import pe_imports, prune_and_stage_crt


ROOT = Path(__file__).resolve().parents[2]


def _make_minimal_pe64(imported_dlls: list[str]) -> bytes:
    """Build a minimal synthetic PE32+ binary whose import table lists imported_dlls."""
    pe_off = 0x80
    opt_size = 240  # PE32+ optional header with 16 data directories
    sec_off = pe_off + 24 + opt_size
    rptr = 0x400
    vrva = 0x1000

    # Layout inside .rdata at rptr: import descriptors followed by null terminator, then ASCII names.
    desc_bytes_len = (len(imported_dlls) + 1) * 20
    name_offset_in_sec = desc_bytes_len
    descriptors = bytearray()
    names_blob = bytearray()
    for dll in imported_dlls:
        name_rva = vrva + name_offset_in_sec + len(names_blob)
        descriptors += struct.pack('<IIIII', 0, 0, 0, name_rva, 0)
        names_blob += dll.encode('ascii') + b'\0'
    descriptors += b'\0' * 20
    rdata = bytes(descriptors) + bytes(names_blob)
    rdata_padded = rdata.ljust(((len(rdata) + 511) // 512) * 512, b'\0')

    buf = bytearray(rptr + len(rdata_padded))
    buf[0:2] = b'MZ'
    struct.pack_into('<I', buf, 0x3C, pe_off)
    buf[pe_off:pe_off + 4] = b'PE\0\0'
    struct.pack_into('<H', buf, pe_off + 6, 1)  # 1 section
    struct.pack_into('<H', buf, pe_off + 20, opt_size)
    opt_off = pe_off + 24
    struct.pack_into('<H', buf, opt_off, 0x20B)  # PE32+
    dd_off = opt_off + 112
    struct.pack_into('<II', buf, dd_off + 8, vrva, desc_bytes_len)  # Import table
    # Section header
    buf[sec_off:sec_off + 6] = b'.rdata'
    struct.pack_into('<IIII', buf, sec_off + 8, len(rdata), vrva, len(rdata_padded), rptr)
    buf[rptr:rptr + len(rdata_padded)] = rdata_padded
    return bytes(buf)


class BundleSizeOptimizationsTest(unittest.TestCase):
    def test_pe_imports_and_transitive_crt_pruning(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rel = root / 'Release'
            redist = root / 'CRT'
            rel.mkdir()
            redist.mkdir()
            (rel / 'data' / 'flutter_assets').mkdir(parents=True)
            (rel / 'data' / 'flutter_assets' / 'NativeAssetsManifest.json').write_text(
                '{"format-version":[1,0,0],"native-assets":{"windows_x64":'
                '{"package:sqlite3/src/ffi/libsqlite3.g.dart":["absolute","sqlite3.dll"]}}}',
                encoding='utf-8',
            )

            # App imports msvcp140.dll -> transitively imports vcruntime140.dll & vcruntime140_1.dll.
            (rel / 'dont_forget.exe').write_bytes(_make_minimal_pe64(['KERNEL32.dll', 'MSVCP140.dll']))
            (rel / 'flutter_windows.dll').write_bytes(_make_minimal_pe64(['KERNEL32.dll']))
            (rel / 'sqlite3.dll').write_bytes(_make_minimal_pe64(['KERNEL32.dll']))
            # Unused Android-only JNI shim and stale unused CRT DLL.
            (rel / 'dartjni.dll').write_bytes(_make_minimal_pe64(['VCRUNTIME140.dll']))
            (rel / 'concrt140.dll').write_bytes(_make_minimal_pe64(['MSVCP140.dll']))

            (redist / 'msvcp140.dll').write_bytes(_make_minimal_pe64(['VCRUNTIME140.dll', 'VCRUNTIME140_1.dll']))
            (redist / 'vcruntime140.dll').write_bytes(_make_minimal_pe64(['KERNEL32.dll']))
            (redist / 'vcruntime140_1.dll').write_bytes(_make_minimal_pe64(['VCRUNTIME140.dll']))
            (redist / 'concrt140.dll').write_bytes(_make_minimal_pe64(['MSVCP140.dll']))
            (redist / 'vccorlib140.dll').write_bytes(_make_minimal_pe64(['MSVCP140.dll']))

            self.assertEqual(pe_imports(rel / 'dont_forget.exe'), {'kernel32.dll', 'msvcp140.dll'})
            summary = prune_and_stage_crt(rel, redist)

            self.assertEqual(summary['copied_crt'], ['msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'])
            self.assertEqual(summary['skipped_crt'], ['concrt140.dll', 'vccorlib140.dll'])
            self.assertEqual(summary['removed_unused_shims'], ['dartjni.dll'])
            self.assertFalse((rel / 'dartjni.dll').exists())
            self.assertFalse((rel / 'concrt140.dll').exists())
            self.assertFalse((rel / 'vccorlib140.dll').exists())
            for dll in ('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'sqlite3.dll'):
                self.assertTrue((rel / dll).is_file(), f'Missing expected {dll}')

    def test_missing_required_crt_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rel = root / 'Release'
            redist = root / 'CRT'
            rel.mkdir()
            redist.mkdir()
            (rel / 'dont_forget.exe').write_bytes(_make_minimal_pe64(['MSVCP140.dll']))
            (rel / 'flutter_windows.dll').write_bytes(_make_minimal_pe64(['KERNEL32.dll']))
            (redist / 'vcruntime140.dll').write_bytes(_make_minimal_pe64(['KERNEL32.dll']))
            with self.assertRaises(FileNotFoundError):
                prune_and_stage_crt(rel, redist)

    def test_repo_size_optimization_contracts(self):
        pubspec = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
        self.assertNotIn('cupertino_icons:', pubspec)
        self.assertNotIn('sqlite3_flutter_libs:', pubspec)

        notif = (ROOT / 'lib' / 'services' / 'notification_service.dart').read_text(encoding='utf-8')
        self.assertNotIn('timezone/data/latest', notif)
        self.assertIn('tz.setLocalLocation(tz.UTC)', notif)

        gradle = (ROOT / 'android' / 'app' / 'build.gradle.kts').read_text(encoding='utf-8')
        self.assertIn('useLegacyPackaging = true', gradle)
        self.assertIn('**/libsqlite3.so', gradle)
        self.assertNotIn('multiDexEnabled = true', gradle)

        win_pkg = (ROOT / 'scripts' / 'package_windows.ps1').read_text(encoding='utf-8')
        self.assertIn('--split-debug-info=', win_pkg)
        self.assertIn('-dTreeShakeIcons=true', win_pkg)
        self.assertIn('prune_windows_bundle.py', win_pkg)

        linux_sh = (ROOT / 'scripts' / 'build_linux.sh').read_text(encoding='utf-8')
        self.assertIn('--split-debug-info=build/symbols/linux', linux_sh)
        self.assertIn('-dTreeShakeIcons=true', linux_sh)

        for rel in ('scripts/build_macos.sh', 'scripts/build_ios.sh', 'scripts/build_android_variants.py'):
            self.assertIn('--split-debug-info', (ROOT / rel).read_text(encoding='utf-8'))

        iss = (ROOT / 'windows_installer' / 'installer.iss').read_text(encoding='utf-8')
        self.assertIn('Compression=lzma2/ultra64', iss)
        self.assertIn(r'Type: files; Name: "{app}\dartjni.dll"', iss)
        self.assertIn(r'Type: filesandordirs; Name: "{app}\data\flutter_assets\packages\cupertino_icons"', iss)


if __name__ == '__main__':
    unittest.main()
