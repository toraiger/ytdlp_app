import hashlib
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

from verify_ipa import VerificationError, verify_ipa


def macho(*, platform=2, cpu=0x0100000C, signed=False, legacy=False):
    command = (struct.pack('<4I', 0x25, 16, 0, 0) if legacy else
               struct.pack('<6I', 0x32, 24, platform, 0, 0, 0))
    if signed:
        command += struct.pack('<4I', 0x1D, 16, 0, 0)
    return struct.pack('<8I', 0xFEEDFACF, cpu, 0, 2, 2 if signed else 1,
                       len(command), 0, 0) + command


def universal(binary, *, wide=False):
    header_size = 40 if wide else 28
    header = struct.pack('>2I', 0xCAFEBABF if wide else 0xCAFEBABE, 1)
    header += struct.pack('>IIQQII' if wide else '>5I',
                          *([0x0100000C, 0, header_size, len(binary), 0, 0]
                            if wide else [0x0100000C, 0, header_size, len(binary), 0]))
    return header + binary


class VerifyIpaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def make_ipa(self, *, bundle_id='com.example.player', binary=None,
                 app_name='Different Player', executable='CustomLauncher',
                 profile=False, info_bytes=None):
        ipa = self.root / 'fixture.ipa'
        info = {
            'CFBundleIdentifier': bundle_id,
            'CFBundleShortVersionString': '1.2.3',
            'CFBundleVersion': '42',
            'CFBundleExecutable': executable,
            'MinimumOSVersion': '13.0',
        }
        prefix = 'Payload/' + app_name + '.app/'
        with zipfile.ZipFile(ipa, 'w', compression=zipfile.ZIP_STORED) as archive:
            archive.writestr(prefix + 'Info.plist',
                             info_bytes if info_bytes is not None else plistlib.dumps(info))
            archive.writestr(prefix + executable, macho() if binary is None else binary)
            archive.writestr(prefix + 'asset.txt', b'fixture integrity marker')
            if profile:
                archive.writestr(prefix + 'embedded.mobileprovision', b'fixture profile')
        return ipa

    def verify(self, ipa, **kwargs):
        expected = {
            'expected_bundle_id': 'com.example.player',
            'expected_version': '1.2.3',
            'expected_build_number': '42',
        }
        expected.update(kwargs)
        return verify_ipa(ipa, **expected)

    def write_checksum(self, ipa, content=None):
        checksum = Path(str(ipa) + '.sha256')
        checksum.write_text(content if content is not None else
                            hashlib.sha256(ipa.read_bytes()).hexdigest() + '  ' + ipa.name + '\n')
        return checksum

    def test_other_projects_and_non_runner_names(self):
        for bundle_id, app_name, executable in [
            ('com.example.player', 'Different Player', 'CustomLauncher'),
            ('org.example.anotherFlutterApp', '別のアプリ', '起動'),
        ]:
            with self.subTest(bundle_id=bundle_id):
                ipa = self.make_ipa(bundle_id=bundle_id, app_name=app_name, executable=executable)
                result = self.verify(ipa, expected_bundle_id=bundle_id)
                self.assertEqual(result['bundle_id'], bundle_id)
                self.assertEqual(result['app_path'], 'Payload/' + app_name + '.app')
                self.assertTrue(result['main_executable_unsigned'])
                self.assertFalse(result['checksum_verified'])

    def test_valid_checksum(self):
        ipa = self.make_ipa()
        self.write_checksum(ipa)
        result = self.verify(ipa, require_checksum=True)
        self.assertTrue(result['checksum_verified'])
        self.assertEqual(result['sha256'], hashlib.sha256(ipa.read_bytes()).hexdigest())
        Path(str(ipa) + '.sha256').write_text(result['sha256'] + '\n', encoding='utf-8-sig')
        self.assertTrue(self.verify(ipa)['checksum_verified'])

    def test_missing_required_checksum(self):
        with self.assertRaisesRegex(VerificationError, 'checksum file is required'):
            self.verify(self.make_ipa(), require_checksum=True)

    def test_bad_checksum_records(self):
        ipa = self.make_ipa()
        for record in ['0' * 64 + '  fixture.ipa\n', 'not-a-hash\n', '',
                       '0' * 64 + '\n' + '1' * 64 + '\n']:
            with self.subTest(record=record):
                self.write_checksum(ipa, record)
                with self.assertRaises(VerificationError):
                    self.verify(ipa)

    def test_explicit_checksum_path(self):
        ipa = self.make_ipa()
        checksum = self.root / 'download.sha256'
        checksum.write_text(hashlib.sha256(ipa.read_bytes()).hexdigest().upper() + '\n')
        self.assertTrue(self.verify(ipa, sha256_file=checksum)['checksum_verified'])
        with self.assertRaises(OSError):
            self.verify(ipa, sha256_file=self.root / 'missing.sha256')

    def test_wrong_expected_identity_and_versions(self):
        ipa = self.make_ipa()
        for key, value in [('expected_bundle_id', 'org.example.wrongApp'),
                           ('expected_version', '9.9.9'), ('expected_build_number', '1')]:
            with self.subTest(key=key):
                with self.assertRaises(VerificationError):
                    self.verify(ipa, **{key: value})

    def test_simulator_and_non_arm64_rejected(self):
        for binary in [macho(platform=7), macho(cpu=0x01000007)]:
            with self.subTest(binary=binary[:16]):
                with self.assertRaises(VerificationError):
                    self.verify(self.make_ipa(binary=binary))

    def test_signed_main_and_provisioning_profile_rejected(self):
        for options in [{'binary': macho(signed=True)}, {'profile': True}]:
            with self.subTest(options=options):
                with self.assertRaises(VerificationError):
                    self.verify(self.make_ipa(**options))

    def test_universal_executables_and_legacy_platform_command(self):
        for binary in [universal(macho()), universal(macho(), wide=True), macho(legacy=True)]:
            with self.subTest(magic=binary[:4]):
                self.assertEqual(self.verify(self.make_ipa(binary=binary))['platform'], 'iPhoneOS')

    def test_malformed_load_commands(self):
        binary = bytearray(macho())
        struct.pack_into('<I', binary, 36, 4096)
        for candidate in [b'bad executable', bytes(binary), universal(macho())[:30]]:
            with self.subTest(size=len(candidate)):
                with self.assertRaises(VerificationError):
                    self.verify(self.make_ipa(binary=candidate))

    def test_zip_crc_failure(self):
        ipa = self.make_ipa()
        damaged = ipa.read_bytes().replace(b'fixture integrity marker', b'broken! integrity marker', 1)
        ipa.write_bytes(damaged)
        with self.assertRaisesRegex(VerificationError, 'ZIP integrity'):
            self.verify(ipa)

    def test_missing_and_ambiguous_main_apps(self):
        ipa = self.make_ipa()
        with zipfile.ZipFile(ipa, 'a') as archive:
            archive.writestr('Payload/Second.app/Info.plist', plistlib.dumps({}))
        with self.assertRaisesRegex(VerificationError, 'exactly one main app'):
            self.verify(ipa)
        with zipfile.ZipFile(ipa, 'w') as archive:
            archive.writestr('source/README.md', b'not an IPA')
        with self.assertRaisesRegex(VerificationError, 'exactly one main app'):
            self.verify(ipa)

    def test_invalid_executable_path(self):
        with self.assertRaisesRegex(VerificationError, 'CFBundleExecutable'):
            self.verify(self.make_ipa(executable='../outside'))

    def test_cli_success_and_failure_exit_codes(self):
        ipa = self.make_ipa()
        command = [sys.executable, str(Path(__file__).with_name('verify_ipa.py')), str(ipa),
                   '--expected-bundle-id', 'com.example.player', '--expected-version', '1.2.3',
                   '--expected-build-number', '42']
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['build_number'], '42')
        result = subprocess.run(command + ['--require-checksum'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('checksum file is required', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_cli_invalid_plist_has_no_traceback(self):
        ipa = self.make_ipa(info_bytes=b'<?xml version="1.0"?><plist><dict>')
        result = subprocess.run(
            [sys.executable, str(Path(__file__).with_name('verify_ipa.py')), str(ipa),
             '--expected-bundle-id', 'com.example.player', '--expected-version', '1.2.3',
             '--expected-build-number', '42'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('Traceback', result.stderr)


if __name__ == '__main__':
    unittest.main()
