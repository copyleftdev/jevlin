#!/usr/bin/env python3
"""Rehearse a source release from clean HEAD; never tag or publish a release."""
import argparse
import gzip
import hashlib
import io
import json
import pathlib
import re
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('release-dist'))
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]

    def git(*arguments):
        return subprocess.run(['git', *arguments], cwd=root, capture_output=True, check=True).stdout

    if git('status', '--porcelain', '--untracked-files=normal').strip():
        raise SystemExit('Release rehearsal requires a clean, committed checkout.')
    commit = git('rev-parse', 'HEAD').decode().strip()
    manifest = git('show', f'{commit}:build.zig.zon').decode()
    version = re.search(r'\.version\s*=\s*"([^"]+)"', manifest).group(1)
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version):
        raise SystemExit('Unsupported package version')
    paths = re.search(r'\.paths\s*=\s*\.\{([^}]+)\}', manifest).group(1)
    paths = re.findall(r'"([^"]+)"', paths)
    if not paths or any(path.startswith('/') or '..' in pathlib.PurePosixPath(path).parts for path in paths):
        raise SystemExit('Unsafe or empty package paths')
    tracked = git('ls-tree', '-r', '--name-only', commit).decode().splitlines()
    license_present = 'LICENSE' in tracked
    if not license_present or 'LICENSE' not in paths:
        raise SystemExit('A tracked LICENSE must be included in build.zig.zon package paths')
    toolchain = subprocess.run([args.zig, 'version'], capture_output=True, text=True, check=True).stdout.strip()
    if toolchain != '0.16.0':
        raise SystemExit('Release rehearsal requires Zig 0.16.0')
    name = f'jevlin-{version}'

    def archive_bytes():
        # Git supplies committed bytes, stable metadata and file modes. Gzip
        # omits the local filename and wall clock timestamp.
        source = git('archive', '--format=tar', f'--prefix={name}/', commit, '--', *paths)
        output = io.BytesIO()
        with gzip.GzipFile(fileobj=output, mode='wb', filename='', mtime=0, compresslevel=9) as stream:
            stream.write(source)
        return output.getvalue()

    first, second = archive_bytes(), archive_bytes()
    if first != second:
        raise SystemExit('Archive reproducibility check failed')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'{name}.tar.gz'
    archive.write_bytes(first)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / 'SHA256SUMS').write_text(f'{digest}  {archive.name}\n')
    report = {'passed': False, 'commit': commit, 'version': version, 'zig': toolchain,
              'archive': archive.name, 'sha256': digest, 'reproducible': True,
              'license_present': license_present, 'published': False, 'consumers': {}}
    report_path = output / 'release-report.json'
    report_path.write_text(json.dumps(report, indent=2)+'\n')
    for mode in ('Debug', 'ReleaseSafe'):
        consumer_report = output / f'consumer-{mode}.json'
        subprocess.run([sys.executable, str(root/'scripts/consumer.py'), '--zig', args.zig,
                        '--archive', str(archive), '--optimize', mode, '--report', str(consumer_report)], check=True)
        report['consumers'][mode] = json.loads(consumer_report.read_text())
    hashes = {entry['package_hash'] for entry in report['consumers'].values()}
    if len(hashes) != 1 or not all(entry['passed'] for entry in report['consumers'].values()):
        raise SystemExit('Consumer results or package hashes disagree')
    report['passed'] = True
    report_path.write_text(json.dumps(report, indent=2)+'\n')
    print(f'Rehearsal passed: {archive}\nSHA256: {digest}\nLicense present: {license_present}')


if __name__ == '__main__':
    main()
