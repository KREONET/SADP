#!/usr/bin/env python3
"""배포용 앱 archive의 checksum과 참조를 기록하고 import 전에 검증한다."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import runpy
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
ARCHIVE = 'images.tar'
REF = re.compile(r'[a-z0-9][a-z0-9./:_-]*:[0-9a-f]{40}')


def checksum(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate(directory):
    metadata = json.loads((directory / 'bundle.json').read_text())
    if metadata.get('schemaVersion') != 1 or metadata.get('archive') != ARCHIVE:
        raise ValueError('지원하지 않는 bundle 형식')
    refs = [metadata['images'][name] for name in ('testApp', 'portal')]
    if any(not isinstance(ref, str) or not REF.fullmatch(ref) for ref in refs) or len(set(refs)) != 2:
        raise ValueError('image 참조는 서로 다른 저장소와 40자리 SHA tag가 필요함')
    if not re.fullmatch(r'[0-9a-f]{40}', metadata['sourceRevision']):
        raise ValueError('sourceRevision 형식 오류')
    if metadata.get('platform') != 'linux/amd64':
        raise ValueError('현재 배포 bundle은 linux/amd64만 지원함')
    archive = directory / ARCHIVE
    if archive.is_symlink() or not archive.is_file() or checksum(archive) != metadata['sha256']:
        raise ValueError('archive checksum 불일치 또는 비정상 파일')
    runpy.run_path(str(ROOT / 'scripts/cluster/verify-image-archive.py'))['verify_archive'](archive, refs)
    if any(ref.rsplit(':', 1)[1] != metadata['sourceRevision'] for ref in refs):
        raise ValueError('이미지 tag와 sourceRevision이 다름')
    with tarfile.open(archive) as tar:
        index = json.load(tar.extractfile('index.json'))
        indexed = {entry.get('annotations', {}).get('io.containerd.image.name') for entry in index['manifests']}
        if not set(refs).issubset(indexed):
            raise ValueError('OCI index의 배포 참조 누락')
        for entry in json.load(tar.extractfile('manifest.json')):
            config = json.load(tar.extractfile(entry['Config']))
            if config.get('architecture') != 'amd64' or config.get('os') != 'linux':
                raise ValueError('archive 내부 platform이 linux/amd64가 아님')
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['create', 'verify', 'fields'])
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--test-app-ref')
    parser.add_argument('--portal-ref')
    parser.add_argument('--revision')
    args = parser.parse_args()
    if args.command == 'create':
        target = args.directory / 'bundle.json'
        if target.exists():
            raise ValueError('기존 bundle.json을 덮어쓰지 않음')
        data = dict(schemaVersion=1, archive=ARCHIVE, sha256=checksum(args.directory / ARCHIVE),
                    sourceRevision=args.revision, platform='linux/amd64',
                    images=dict(testApp=args.test_app_ref, portal=args.portal_ref))
        target.write_text(json.dumps(data, indent=2) + '\n')
        try:
            validate(args.directory)
        except Exception:
            target.unlink()
            raise
    data = validate(args.directory)
    if args.command == 'fields':
        for value in (str(args.directory.resolve() / ARCHIVE), data['images']['testApp'], data['images']['portal']):
            print(value)
    else:
        print('[OK] image bundle checksum / OCI blob / 참조 검증 완료')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f'[FAIL] {error}', file=sys.stderr)
        sys.exit(1)
