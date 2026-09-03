#!/usr/bin/env python3
"""외부 image archive가 node 전송 전에 완전성을 증명하는지 회귀 시험한다."""

from __future__ import annotations

import hashlib
import io
import json
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "scripts/cluster/verify-image-archive.py"
EXPECTED = "registry.example.invalid/acme/service:1.2.3"


def json_bytes(document: object) -> bytes:
    return json.dumps(document, separators=(",", ":"), sort_keys=True).encode()


def digest_path(content: bytes) -> tuple[str, str]:
    digest = hashlib.sha256(content).hexdigest()
    return digest, f"blobs/sha256/{digest}"


def add_bytes(tar: tarfile.TarFile, name: str, content: bytes) -> None:
    member = tarfile.TarInfo(name)
    member.size = len(content)
    member.mode = 0o600
    tar.addfile(member, io.BytesIO(content))


def make_archive(
    path: Path,
    *,
    image_name: str = EXPECTED,
    repo_tags: list[str] | None = None,
    omit: str | None = None,
    corrupt_blob: bool = False,
    duplicate: bool = False,
    malformed_digest: bool = False,
    empty_manifest: bool = False,
) -> None:
    config = json_bytes({"architecture": "amd64", "os": "linux"})
    layer = b"fixture-layer-content"
    config_digest, config_path = digest_path(config)
    layer_digest, layer_path = digest_path(layer)
    manifest_document = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": {
            "mediaType": "application/vnd.oci.image.config.v1+json",
            "digest": f"sha256:{config_digest}",
            "size": len(config),
        },
        "layers": [
            {
                "mediaType": "application/vnd.oci.image.layer.v1.tar",
                "digest": f"sha256:{layer_digest}",
                "size": len(layer),
            }
        ],
    }
    manifest_blob = json_bytes(manifest_document)
    manifest_digest, manifest_path = digest_path(manifest_blob)
    index_document = {
        "schemaVersion": 2,
        "manifests": [
            {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": f"sha256:{manifest_digest}",
                "size": len(manifest_blob),
                "annotations": {"io.containerd.image.name": image_name},
            }
        ],
    }
    docker_manifest = [] if empty_manifest else [
        {
            "Config": config_path,
            "RepoTags": [image_name] if repo_tags is None else repo_tags,
            "Layers": [layer_path],
        }
    ]

    with tarfile.open(path, "w") as tar:
        add_bytes(tar, "oci-layout", json_bytes({"imageLayoutVersion": "1.0.0"}))
        add_bytes(tar, "index.json", json_bytes(index_document))
        add_bytes(tar, "manifest.json", json_bytes(docker_manifest))
        if omit != "config":
            add_bytes(tar, config_path, config)
        if omit != "layer":
            add_bytes(tar, layer_path, b"damaged" if corrupt_blob else layer)
        add_bytes(tar, manifest_path, manifest_blob)
        if duplicate:
            add_bytes(tar, "./manifest.json", json_bytes(docker_manifest))
        if malformed_digest:
            add_bytes(tar, "blobs/sha256/not-a-digest", b"bad")


class ImageArchiveTest(unittest.TestCase):
    def run_verify(self, archive: Path, expected: str = EXPECTED) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(VERIFIER), "--archive", str(archive), "--expected-ref", expected],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def fixture(self, **kwargs: object) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        archive = Path(temporary.name) / "image.tar"
        make_archive(archive, **kwargs)
        return temporary, archive

    def test_valid_archive(self) -> None:
        temporary, archive = self.fixture()
        with temporary:
            result = self.run_verify(archive)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("blob=3", result.stdout)

    def test_missing_config_is_rejected(self) -> None:
        temporary, archive = self.fixture(omit="config")
        with temporary:
            result = self.run_verify(archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("member 누락", result.stderr)

    def test_missing_layer_is_rejected(self) -> None:
        temporary, archive = self.fixture(omit="layer")
        with temporary:
            result = self.run_verify(archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("member 누락", result.stderr)

    def test_corrupt_blob_is_rejected(self) -> None:
        temporary, archive = self.fixture(corrupt_blob=True)
        with temporary:
            result = self.run_verify(archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("blob digest 불일치", result.stderr)

    def test_missing_expected_image_name_is_rejected(self) -> None:
        temporary, archive = self.fixture()
        with temporary:
            result = self.run_verify(archive, "registry.example.invalid/acme/other:1.2.3")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("예상 image 이름 누락", result.stderr)

    def test_docker_hub_name_from_oci_annotation(self) -> None:
        temporary, archive = self.fixture(
            image_name="docker.io/library/busybox:1.36.1",
            repo_tags=[],
        )
        with temporary:
            result = self.run_verify(archive, "busybox:1.36.1")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_duplicate_tar_path_is_rejected(self) -> None:
        temporary, archive = self.fixture(duplicate=True)
        with temporary:
            result = self.run_verify(archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("중복 tar path", result.stderr)

    def test_malformed_digest_path_is_rejected(self) -> None:
        temporary, archive = self.fixture(malformed_digest=True)
        with temporary:
            result = self.run_verify(archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("비정상 digest path", result.stderr)

    def test_empty_manifest_is_rejected(self) -> None:
        temporary, archive = self.fixture(empty_manifest=True)
        with temporary:
            result = self.run_verify(archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest.json이 비어", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
