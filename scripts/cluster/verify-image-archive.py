#!/usr/bin/env python3
"""노드로 보내기 전에 containerd OCI archive의 내용과 이름을 검증한다."""

from __future__ import annotations

import argparse
import hashlib
import json
import posixpath
import re
import sys
import tarfile
from pathlib import Path
from typing import Any


SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
OCI_IMAGE_NAME = "io.containerd.image.name"


class ArchiveError(ValueError):
    pass


def normalize_member_name(name: str) -> str:
    """동일 경로의 다른 철자가 duplicate 검사를 우회하지 못하게 정규화한다."""
    if not name or name.startswith("/"):
        raise ArchiveError(f"안전하지 않은 tar path: {name!r}")
    normalized = posixpath.normpath(name)
    if normalized in ("", ".") or normalized == ".." or normalized.startswith("../"):
        raise ArchiveError(f"안전하지 않은 tar path: {name!r}")
    return normalized


def normalize_image_ref(ref: str) -> str:
    """Docker Hub 축약 표기와 완전한 registry 표기를 같은 이름으로 비교한다."""
    ref = ref.strip()
    if not ref:
        raise ArchiveError("빈 image 이름")

    name, separator, digest = ref.partition("@")
    parts = name.split("/")
    if len(parts) == 1:
        name = f"docker.io/library/{name}"
    elif "." not in parts[0] and ":" not in parts[0] and parts[0] != "localhost":
        name = f"docker.io/{name}"
    elif parts[0] == "registry-1.docker.io":
        name = "docker.io/" + "/".join(parts[1:])

    if separator:
        return f"{name}@{digest}"
    return name


def load_json(tar: tarfile.TarFile, members: dict[str, tarfile.TarInfo], path: str) -> Any:
    member = members.get(path)
    if member is None or not member.isfile():
        raise ArchiveError(f"필수 JSON member 누락 또는 비정상: {path}")
    extracted = tar.extractfile(member)
    if extracted is None:
        raise ArchiveError(f"JSON member를 읽을 수 없음: {path}")
    try:
        return json.load(extracted)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ArchiveError(f"JSON member 형식 오류: {path}") from exc


def require_regular_member(members: dict[str, tarfile.TarInfo], path: str, *, source: str) -> None:
    normalized = normalize_member_name(path)
    member = members.get(normalized)
    if member is None or not member.isfile():
        raise ArchiveError(f"{source}가 참조한 member 누락: {normalized}")


def descriptor_blob_path(descriptor: Any, *, source: str) -> str:
    if not isinstance(descriptor, dict):
        raise ArchiveError(f"{source} descriptor 형식 오류")
    digest = descriptor.get("digest")
    if not isinstance(digest, str) or not digest.startswith("sha256:"):
        raise ArchiveError(f"{source} descriptor digest 형식 오류")
    hex_digest = digest.removeprefix("sha256:")
    if not SHA256_HEX.fullmatch(hex_digest):
        raise ArchiveError(f"{source} descriptor digest 형식 오류")
    return f"blobs/sha256/{hex_digest}"


def verify_archive(archive: Path, expected_refs: list[str], expected_platforms: list[str] | None = None) -> tuple[int, int, int]:
    platforms = set(expected_platforms or [])
    if any(not re.fullmatch(r"linux/[a-z0-9_]+", value) for value in platforms):
        raise ArchiveError("platform은 Linux node의 linux/<architecture> 형식이어야 함")
    try:
        tar = tarfile.open(archive, mode="r:*")
    except (OSError, tarfile.TarError) as exc:
        raise ArchiveError("tar archive를 열 수 없음") from exc

    with tar:
        members: dict[str, tarfile.TarInfo] = {}
        for member in tar.getmembers():
            normalized = normalize_member_name(member.name)
            if normalized in members:
                raise ArchiveError(f"중복 tar path: {normalized}")
            members[normalized] = member

        # OCI blob 경로 자체가 digest 계약이다. 참조 여부와 관계없이 archive 안의 모든 blob을
        # 다시 계산해야 우연히 참조되지 않은 손상 content도 다음 전송에 재사용되지 않는다.
        blob_count = 0
        for path, member in members.items():
            if path == "blobs/sha256":
                continue
            if not path.startswith("blobs/sha256/"):
                continue
            hex_digest = path.removeprefix("blobs/sha256/")
            if not SHA256_HEX.fullmatch(hex_digest) or not member.isfile():
                raise ArchiveError(f"비정상 digest path: {path}")
            extracted = tar.extractfile(member)
            if extracted is None:
                raise ArchiveError(f"blob을 읽을 수 없음: {path}")
            actual = hashlib.file_digest(extracted, "sha256").hexdigest()
            if actual != hex_digest:
                raise ArchiveError(f"blob digest 불일치: {path}")
            blob_count += 1

        docker_manifest = load_json(tar, members, "manifest.json")
        if not isinstance(docker_manifest, list) or not docker_manifest:
            raise ArchiveError("manifest.json이 비어 있거나 배열이 아님")

        discovered_names: set[str] = set()
        for position, entry in enumerate(docker_manifest):
            source = f"manifest.json[{position}]"
            if not isinstance(entry, dict):
                raise ArchiveError(f"{source} 형식 오류")
            config = entry.get("Config")
            layers = entry.get("Layers")
            if not isinstance(config, str) or not config:
                raise ArchiveError(f"{source} Config 누락")
            if not isinstance(layers, list):
                raise ArchiveError(f"{source} Layers 누락")
            require_regular_member(members, config, source=source)
            for layer in layers:
                if not isinstance(layer, str) or not layer:
                    raise ArchiveError(f"{source} layer path 형식 오류")
                require_regular_member(members, layer, source=source)
            repo_tags = entry.get("RepoTags") or []
            if not isinstance(repo_tags, list):
                raise ArchiveError(f"{source} RepoTags 형식 오류")
            for ref in repo_tags:
                if not isinstance(ref, str):
                    raise ArchiveError(f"{source} RepoTags 형식 오류")
                discovered_names.add(normalize_image_ref(ref))

        oci_index = load_json(tar, members, "index.json")
        descriptors = oci_index.get("manifests") if isinstance(oci_index, dict) else None
        if not isinstance(descriptors, list) or not descriptors:
            raise ArchiveError("index.json manifest가 비어 있음")

        # index descriptor와 하위 manifest의 config/layer descriptor도 실제 blob을 가리키는지
        # 확인한다. Docker manifest 검사만으로는 OCI 전용 annotation 경로를 놓칠 수 있다.
        # platform export는 원본 index digest를 보존하므로 다른 아키텍처 descriptor가 남는다.
        # 명시한 node platform만 따라가되 각 ref마다 필요한 platform 전체의 완전성을 증명한다.
        coverage_by_name: dict[str, set[str]] = {}
        visiting: set[str] = set()

        def walk(descriptor: Any, source: str, depth: int = 0) -> set[str]:
            if depth > 64:
                raise ArchiveError("OCI index 중첩 제한 초과")
            path = descriptor_blob_path(descriptor, source=source)
            declared = descriptor.get("platform")
            if declared is not None and not isinstance(declared, dict):
                raise ArchiveError(f"{source} platform 형식 오류")
            declared_platform = None
            if declared and declared.get("os") and declared.get("architecture"):
                declared_platform = f'{declared["os"]}/{declared["architecture"]}'
                if platforms and declared_platform not in platforms:
                    return set()
            require_regular_member(members, path, source=source)
            annotations = descriptor.get("annotations") or {}
            if not isinstance(annotations, dict):
                raise ArchiveError(f"{source} annotations 형식 오류")
            image_name = annotations.get(OCI_IMAGE_NAME)
            if image_name is not None:
                if not isinstance(image_name, str):
                    raise ArchiveError(f"{source} image name annotation 형식 오류")
                discovered_names.add(normalize_image_ref(image_name))

            media_type = str(descriptor.get("mediaType") or "")
            is_manifest = ".manifest." in media_type and media_type.endswith("+json")
            is_index = (
                ".index." in media_type or ".manifest.list." in media_type
            ) and media_type.endswith("+json")
            if not (is_manifest or is_index):
                raise ArchiveError(f"지원하지 않는 OCI manifest mediaType: {path}")
            if path in visiting:
                raise ArchiveError(f"OCI index 순환 참조: {path}")
            visiting.add(path)
            document = load_json(tar, members, path)
            if not isinstance(document, dict):
                raise ArchiveError(f"descriptor JSON 형식 오류: {path}")
            covered: set[str] = set()
            if is_index:
                children = document.get("manifests")
                if not isinstance(children, list) or not children:
                    raise ArchiveError(f"OCI index manifests 누락: {path}")
                for index, child in enumerate(children):
                    covered.update(walk(child, f"{path}.manifests[{index}]", depth + 1))
            else:
                config = document.get("config")
                layers = document.get("layers")
                if config is None or not isinstance(layers, list):
                    raise ArchiveError(f"OCI manifest config/layers 누락: {path}")
                require_regular_member(
                    members,
                    descriptor_blob_path(config, source=f"{path}.config"),
                    source=f"{path}.config",
                )
                if platforms:
                    config_document = load_json(tar, members, descriptor_blob_path(config, source=f"{path}.config"))
                    if not isinstance(config_document, dict):
                        raise ArchiveError(f"OCI config 형식 오류: {path}")
                    actual_platform = f'{config_document.get("os", "")}/{config_document.get("architecture", "")}'
                    if actual_platform not in platforms or (declared_platform and actual_platform != declared_platform):
                        raise ArchiveError(f"OCI config platform 불일치: {path}")
                    covered.add(actual_platform)
                for index, layer in enumerate(layers):
                    layer_source = f"{path}.layers[{index}]"
                    require_regular_member(
                        members,
                        descriptor_blob_path(layer, source=layer_source),
                        source=layer_source,
                    )
            visiting.remove(path)
            if image_name is not None:
                coverage_by_name.setdefault(normalize_image_ref(image_name), set()).update(covered)
            return covered

        for index, descriptor in enumerate(descriptors):
            walk(descriptor, f"index.json.manifests[{index}]")

        normalized_expected = {normalize_image_ref(ref) for ref in expected_refs}
        missing = sorted(normalized_expected - discovered_names)
        if missing:
            raise ArchiveError("예상 image 이름 누락: " + ", ".join(missing))
        for ref in sorted(normalized_expected):
            missing_platforms = platforms - coverage_by_name.get(ref, set())
            if missing_platforms:
                raise ArchiveError(f"예상 image platform 누락: {ref}: {', '.join(sorted(missing_platforms))}")

    return len(docker_manifest), blob_count, len(normalized_expected)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--expected-ref", action="append", default=[])
    parser.add_argument("--platform", action="append", default=[], help="검증할 Linux node platform; 생략하면 전체 descriptor 검사")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.expected_ref:
        print("[FAIL] --expected-ref가 하나 이상 필요함", file=sys.stderr)
        return 2
    try:
        manifests, blobs, names = verify_archive(args.archive, args.expected_ref, args.platform)
    except ArchiveError as exc:
        print(f"[FAIL] archive 검증 실패: {exc}", file=sys.stderr)
        return 1
    print(f"[OK]   archive 검증 완료: manifest={manifests}, blob={blobs}, image={names}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
