#!/usr/bin/env python3
"""Export the tracked skill files as a deterministic, installable ZIP."""

import argparse
import hashlib
from pathlib import Path
import zipfile


SKILL_NAME = 'flutter-ios-unsigned-ipa'
SKILL_FILES = (
    'SKILL.md',
    'README.md',
    'references/github-actions.md',
    'references/mix-player.md',
    'scripts/verify_ipa.py',
    'scripts/test_verify_ipa.py',
)


def main():
    project = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path,
                        default=project / 'packages' / (SKILL_NAME + '.zip'))
    args = parser.parse_args()
    source = project / '.agents' / 'skills' / SKILL_NAME
    contents = []
    for name in SKILL_FILES:
        path = source / name
        if not path.is_file() or path.is_symlink():
            raise SystemExit('Expected a regular skill file: ' + name)
        contents.append((SKILL_NAME + '/' + name, path.read_bytes()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in contents:
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    Path(str(args.output) + '.sha256').write_text(
        digest + '  ' + args.output.name + '\n', encoding='utf-8')
    print(str(args.output))
    print('SHA-256: ' + digest)


if __name__ == '__main__':
    main()
