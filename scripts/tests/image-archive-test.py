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
    architecture: str = "amd64",
) -> None:
    config = json_bytes({"architecture": architecture, "os": "linux"})
    layer = f"fixture-layer-content-{architecture}".encode()
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


def make_multi_archive(path: Path, *, available: tuple[str, ...] = ("amd64", "arm64"),
                       advertised: tuple[str, ...] = ("amd64", "arm64", "ppc64le"),
                       omit_layer: bool = False, wrong_platform: bool = False) -> None:
    # ctr export와 같이 원본 multi-platform index와 선택한 platform의 blob만 담는다.
    members = {}
    children = []
    docker_entries = []
    with tempfile.TemporaryDirectory() as temporary:
        for architecture in advertised:
            child_archive = Path(temporary) / f"{architecture}.tar"
            make_archive(child_archive, architecture=architecture)
            with tarfile.open(child_archive) as tar:
                payloads = {member.name: tar.extractfile(member).read() for member in tar.getmembers()}
            child = json.loads(payloads["index.json"])["manifests"][0]
            child.pop("annotations")
            child["platform"] = {"os": "linux", "architecture": "arm64" if wrong_platform and architecture == "amd64" else architecture}
            children.append(child)
            if architecture in available:
                members.update({name: data for name, data in payloads.items() if name.startswith("blobs/")})
                docker_entries.extend(json.loads(payloads["manifest.json"]))
    index_blob = json_bytes({"schemaVersion": 2, "manifests": children})
    index_digest, index_path = digest_path(index_blob)
    members[index_path] = index_blob
    members["oci-layout"] = json_bytes({"imageLayoutVersion": "1.0.0"})
    members["index.json"] = json_bytes({"schemaVersion": 2, "manifests": [{
        "mediaType": "application/vnd.oci.image.index.v1+json", "digest": "sha256:" + index_digest,
        "size": len(index_blob), "annotations": {"io.containerd.image.name": EXPECTED}}]})
    members["manifest.json"] = json_bytes(docker_entries[:1])
    if omit_layer:
        members.pop(docker_entries[-1]["Layers"][0])
    with tarfile.open(path, "w") as tar:
        for name, payload in members.items():
            add_bytes(tar, name, payload)


class ImageArchiveTest(unittest.TestCase):
    def run_verify(self, archive: Path, expected: str = EXPECTED, platforms: tuple[str, ...] = ()) -> subprocess.CompletedProcess[str]:
        platform_args = [value for platform in platforms for value in ("--platform", platform)]
        return subprocess.run(
            ["python3", str(VERIFIER), "--archive", str(archive), "--expected-ref", expected, *platform_args],
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

    def test_platform_export(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "image.tar"
            make_multi_archive(archive)
            result = self.run_verify(archive, platforms=("linux/amd64", "linux/arm64"))
            self.assertEqual(result.returncode, 0, result.stderr)
            strict = self.run_verify(archive)
            self.assertNotEqual(strict.returncode, 0)
            self.assertIn("member 누락", strict.stderr)

    def test_selected_manifest_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "image.tar"
            make_multi_archive(archive, available=("amd64",))
            self.assertEqual(self.run_verify(archive, platforms=("linux/amd64",)).returncode, 0)
            result = self.run_verify(archive, platforms=("linux/amd64", "linux/arm64"))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("member 누락", result.stderr)

    def test_selected_layer_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "image.tar"
            make_multi_archive(archive, omit_layer=True)
            result = self.run_verify(archive, platforms=("linux/amd64", "linux/arm64"))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("member 누락", result.stderr)

    def test_platform_coverage_is_per_image(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "image.tar"
            make_multi_archive(archive)
            with tarfile.open(archive) as tar:
                members = {member.name: tar.extractfile(member).read() for member in tar.getmembers()}
            root = json.loads(members["index.json"])
            index_path = "blobs/sha256/" + root["manifests"][0]["digest"].split(":")[1]
            other = json.loads(members[index_path])["manifests"][0]
            other_ref = "registry.example.invalid/acme/other:1.2.3"
            other["annotations"] = {"io.containerd.image.name": other_ref}
            root["manifests"].append(other)
            members["index.json"] = json_bytes(root)
            with tarfile.open(archive, "w") as tar:
                for name, payload in members.items():
                    add_bytes(tar, name, payload)
            result = self.run_verify(archive, expected=other_ref, platforms=("linux/amd64", "linux/arm64"))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("platform 누락", result.stderr)

    def test_platform_absent_from_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "image.tar"
            make_multi_archive(archive, advertised=("amd64",))
            result = self.run_verify(archive, platforms=("linux/amd64", "linux/arm64"))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("platform 누락", result.stderr)

    def test_descriptor_config_platform_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "image.tar"
            make_multi_archive(archive, wrong_platform=True)
            result = self.run_verify(archive, platforms=("linux/arm64",))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("platform 불일치", result.stderr)

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
