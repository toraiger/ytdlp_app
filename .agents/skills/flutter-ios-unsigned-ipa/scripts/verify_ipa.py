#!/usr/bin/env python3
"""Inspect an unsigned device IPA without extracting or executing its contents."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import sys
import zipfile
import zlib
from xml.parsers.expat import ExpatError


class VerificationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def arm64_slices(binary):
    fat_formats = {
        b'\xca\xfe\xba\xbe': ('>', False),
        b'\xbe\xba\xfe\xca': ('<', False),
        b'\xca\xfe\xba\xbf': ('>', True),
        b'\xbf\xba\xfe\xca': ('<', True),
    }
    format_info = fat_formats.get(binary[:4])
    if format_info is None:
        return [binary]
    endian, is_64_bit = format_info
    require(len(binary) >= 8, 'Truncated universal Mach-O header')
    count = struct.unpack_from(endian + 'I', binary, 4)[0]
    entry_size = 32 if is_64_bit else 20
    table_end = 8 + count * entry_size
    require(count > 0 and table_end <= len(binary), 'Invalid universal Mach-O table')
    slices = []
    for i in range(count):
        offset = 8 + i * entry_size
        entry_format = 'IIQQII' if is_64_bit else 'IIIII'
        cpu, _, start, size, *_ = struct.unpack_from(endian + entry_format, binary, offset)
        require(start >= table_end and size >= 32 and start + size <= len(binary),
                'Invalid universal Mach-O slice bounds')
        if cpu == 0x0100000C:
            slices.append(binary[start:start + size])
    require(slices, 'No arm64 slice in main executable')
    return slices


def verify_arm64(binary):
    endian = {b'\xcf\xfa\xed\xfe': '<', b'\xfe\xed\xfa\xcf': '>'}.get(binary[:4])
    require(endian is not None and len(binary) >= 32, 'Expected a 64-bit arm64 Mach-O')
    _, cpu, _, file_type, command_count, command_bytes, _, _ = struct.unpack_from(
        endian + '8I', binary)
    require(cpu == 0x0100000C, 'Main executable is not arm64')
    require(file_type == 2, 'Expected a Mach-O executable')
    command_end = 32 + command_bytes
    require(command_end <= len(binary), 'Truncated Mach-O load commands')
    require(command_count > 0 and command_count <= command_bytes // 8,
            'Invalid Mach-O load command count')
    position = 32
    platforms = []
    for _ in range(command_count):
        require(position + 8 <= command_end, 'Truncated Mach-O load command')
        command, size = struct.unpack_from(endian + '2I', binary, position)
        require(size >= 8 and position + size <= command_end,
                'Invalid Mach-O load command size')
        require(command != 0x1D, 'Main executable has a code signature; expected unsigned')
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, 'Truncated LC_BUILD_VERSION')
            platforms.append(struct.unpack_from(endian + 'I', binary, position + 8)[0])
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS, used by older toolchains
            require(size >= 16, 'Truncated LC_VERSION_MIN_IPHONEOS')
            platforms.append(2)
        position += size
    require(position == command_end, 'Mach-O load command size mismatch')
    require(platforms and all(platform == 2 for platform in platforms),
            'Main executable is not an iPhoneOS device build')


def required_text(info, key):
    value = info.get(key)
    require(isinstance(value, str) and value.strip(), 'Missing or invalid ' + key)
    return value


def verify_ipa(ipa, *, expected_bundle_id, expected_version, expected_build_number,
               sha256_file=None, require_checksum=False):
    ipa = Path(ipa)
    hasher = hashlib.sha256()
    with ipa.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    checksum_path = Path(sha256_file) if sha256_file is not None else Path(str(ipa) + '.sha256')
    checksum_verified = False
    if sha256_file is not None or checksum_path.exists():
        records = [line.strip() for line in checksum_path.read_text(encoding='utf-8-sig').splitlines()
                   if line.strip()]
        require(len(records) == 1, 'Expected one SHA-256 checksum record')
        checksum = records[0].split()[0]
        require(re.fullmatch(r'[0-9a-fA-F]{64}', checksum), 'Invalid SHA-256 checksum record')
        require(digest == checksum.lower(), 'IPA SHA-256 checksum mismatch')
        checksum_verified = True
    require(not require_checksum or checksum_verified, 'SHA-256 checksum file is required')

    with zipfile.ZipFile(ipa) as bundle:
        names = bundle.namelist()
        require(len(names) == len(set(names)), 'Duplicate paths in IPA ZIP')
        require(bundle.testzip() is None, 'IPA ZIP integrity check failed')
        info_paths = [name for name in names
                      if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', name)]
        require(len(info_paths) == 1, 'Expected exactly one main app in Payload')
        app_path = info_paths[0].rsplit('/', 1)[0]
        info = plistlib.loads(bundle.read(info_paths[0]))
        require(isinstance(info, dict), 'Main Info.plist must be a dictionary')
        bundle_id = required_text(info, 'CFBundleIdentifier')
        version = required_text(info, 'CFBundleShortVersionString')
        build_number = required_text(info, 'CFBundleVersion')
        executable = required_text(info, 'CFBundleExecutable')
        require(executable not in ('.', '..') and '/' not in executable and '\\' not in executable,
                'Invalid CFBundleExecutable name')
        require(bundle_id == expected_bundle_id, 'Bundle ID does not match the expected project')
        require(version == expected_version, 'Version does not match the expected build')
        require(build_number == str(expected_build_number), 'Build number does not match the expected build')
        require(app_path + '/embedded.mobileprovision' not in names,
                'Main app has a provisioning profile; expected unsigned')
        for binary in arm64_slices(bundle.read(app_path + '/' + executable)):
            verify_arm64(binary)

    return {
        'file': str(ipa),
        'size_bytes': ipa.stat().st_size,
        'sha256': digest,
        'checksum_verified': checksum_verified,
        'bundle_id': bundle_id,
        'version': version,
        'build_number': build_number,
        'minimum_ios': info.get('MinimumOSVersion'),
        'app_path': app_path,
        'platform': 'iPhoneOS',
        'architecture': 'arm64',
        'main_executable_unsigned': True,
        'zip_integrity': 'valid',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--expected-bundle-id', required=True)
    parser.add_argument('--expected-version', required=True)
    parser.add_argument('--expected-build-number', required=True)
    parser.add_argument('--sha256-file', type=Path)
    parser.add_argument('--require-checksum', action='store_true')
    args = parser.parse_args()
    try:
        result = verify_ipa(
            args.ipa, expected_bundle_id=args.expected_bundle_id,
            expected_version=args.expected_version,
            expected_build_number=args.expected_build_number,
            sha256_file=args.sha256_file, require_checksum=args.require_checksum)
    except (OSError, ValueError, KeyError, RuntimeError, struct.error,
            zipfile.BadZipFile, zlib.error, ExpatError) as error:
        print('IPA verification failed: ' + str(error), file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    sys.exit(main())
