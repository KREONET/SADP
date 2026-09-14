#!/usr/bin/env python3
"""사전 빌드 bundle의 변조와 잘못된 배포 메타데이터를 거부하는지 검사한다."""
import copy
import hashlib
import io
import json
from pathlib import Path
import runpy
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
module = runpy.run_path(str(ROOT / 'scripts/release/image-bundle.py'))
fixture = runpy.run_path(str(ROOT / 'scripts/tests/image-archive-test.py'))
REVISION = 'a' * 40
REFS = ['registry.example.invalid/sadp/' + name + ':' + REVISION for name in ('test-app', 'portal-lite')]


class BundleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        original = self.path / 'original.tar'
        fixture['make_archive'](original, image_name=REFS[0], repo_tags=REFS)
        with tarfile.open(original) as src, tarfile.open(self.path / 'images.tar', 'w') as out:
            for item in src:
                data = src.extractfile(item).read()
                if item.name == 'index.json':
                    index = json.loads(data)
                    duplicate = copy.deepcopy(index['manifests'][0])
                    duplicate['annotations']['io.containerd.image.name'] = REFS[1]
                    index['manifests'].append(duplicate)
                    data = json.dumps(index).encode()
                item.size = len(data)
                out.addfile(item, io.BytesIO(data))
        self.metadata = dict(schemaVersion=1, archive='images.tar', sourceRevision=REVISION,
                             sha256=module['checksum'](self.path / 'images.tar'), platform='linux/amd64',
                             images=dict(zip(('testApp', 'portal'), REFS)))
        self.write()

    def write(self):
        (self.path / 'bundle.json').write_text(json.dumps(self.metadata))

    def test_valid(self):
        self.assertEqual(module['validate'](self.path)['sourceRevision'], REVISION)

    def test_corruption(self):
        with (self.path / 'images.tar').open('r+b') as stream:
            stream.write(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            module['validate'](self.path)

    def test_traversal(self):
        self.metadata['archive'] = '../images.tar'
        self.write()
        with self.assertRaises(ValueError):
            module['validate'](self.path)

    def test_revision_mismatch(self):
        self.metadata['sourceRevision'] = 'b' * 40
        self.write()
        with self.assertRaisesRegex(ValueError, 'sourceRevision'):
            module['validate'](self.path)

    def test_wrong_platform(self):
        self.metadata['platform'] = 'linux/arm64'
        self.write()
        with self.assertRaises(ValueError):
            module['validate'](self.path)


if __name__ == '__main__':
    unittest.main()
