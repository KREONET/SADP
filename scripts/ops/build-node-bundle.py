#!/usr/bin/env python3
"""정확한 allowlist만 담은 Secret 없는 RKE2 node bundle을 만든다."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import pathlib
import re
import shutil
import tarfile
import tempfile
from urllib.parse import urlsplit

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
BUNDLE_NAME = "sadp-node-bundle.tar.gz"
BUNDLE_ROOT = "sadp-node-bundle"

# wildcard/glob을 쓰지 않는다. node proxy 설치와 join-token 무결성 확인에 필요한 파일만
# 코드 리뷰 가능한 목록으로 고정해 저장소 전체나 ignored Secret이 섞일 여지를 없앤다.
ALLOWLIST = (
    "sadp",
    "scripts/node/install-rke2-containerd-proxy.sh",
    "platform/network/proxy.env",
    "rke/control-node/config.yaml",
    "rke/worker-node/config.yaml",
)
SENSITIVE = re.compile(
    rb"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY|"
    rb"hvs\.[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|"
    rb"github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|"
    rb"AKIA[0-9A-Z]{16}"
)


def digest(path: pathlib.Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def validate_source(relative: str) -> pathlib.Path:
    path = ROOT / relative
    current = ROOT
    has_symlink = path.is_symlink()
    for part in pathlib.PurePosixPath(relative).parts[:-1]:
        current /= part
        has_symlink = has_symlink or current.is_symlink()
    if has_symlink:
        raise ValueError(f"allowlist 경로가 symlink를 포함함: {relative}")
    if not path.is_file():
        raise ValueError(f"allowlist 경로가 일반 파일이 아님: {relative}")
    content = path.read_bytes()
    if SENSITIVE.search(content):
        raise ValueError(f"private key/token 패턴 감지: {relative}")
    return path


def validate_join_tokens() -> None:
    for relative in ("rke/control-node/config.yaml", "rke/worker-node/config.yaml"):
        document = yaml.safe_load((ROOT / relative).read_text(encoding="utf-8")) or {}
        if document.get("token") not in (None, ""):
            raise ValueError(f"RKE2 join token이 비어 있지 않음: {relative}")


def validate_proxy() -> None:
    values: dict[str, str] = {}
    for line in (ROOT / "platform/network/proxy.env").read_text(encoding="utf-8").splitlines():
        if not line.startswith("export ") or "=" not in line:
            continue
        name, value = line.removeprefix("export ").split("=", 1)
        if name in {"HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"}:
            values[name] = value.strip("'\"")
    for name in ("HTTP_PROXY", "HTTPS_PROXY"):
        parsed = urlsplit(values.get(name, ""))
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username
            or parsed.password
        ):
            raise ValueError(f"{name}는 credential 없는 생성 URL이어야 함")
    if not values.get("NO_PROXY") or any(char.isspace() for char in values["NO_PROXY"]):
        raise ValueError("NO_PROXY는 공백 없는 생성 목록이어야 함")


def add_file(archive: tarfile.TarFile, path: pathlib.Path, arcname: str) -> None:
    info = archive.gettarinfo(str(path), arcname=arcname)
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0
    info.mode = 0o700 if path.name == "sadp" or path.suffix == ".sh" else 0o600
    with path.open("rb") as handle:
        archive.addfile(info, handle)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Secret 없는 SADP node bundle과 portable outer checksum 생성"
    )
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    output_dir = pathlib.Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(output_dir, 0o700)

    sources = {relative: validate_source(relative) for relative in ALLOWLIST}
    validate_join_tokens()
    validate_proxy()

    with tempfile.TemporaryDirectory(prefix="sadp-node-bundle-") as temporary:
        stage = pathlib.Path(temporary) / BUNDLE_ROOT
        stage.mkdir(mode=0o700)
        for relative, source in sources.items():
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target, follow_symlinks=False)
            os.chmod(target, 0o700 if target.name == "sadp" or target.suffix == ".sh" else 0o600)
        manifest = stage / "MANIFEST.sha256"
        manifest.write_text(
            "".join(
                f"{digest(stage / relative)}  {relative}\n" for relative in sorted(ALLOWLIST)
            ),
            encoding="utf-8",
        )
        os.chmod(manifest, 0o600)

        archive_path = output_dir / BUNDLE_NAME
        archive_temporary = output_dir / f".{BUNDLE_NAME}.tmp-{os.getpid()}"
        with archive_temporary.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    root_info = tarfile.TarInfo(BUNDLE_ROOT)
                    root_info.type = tarfile.DIRTYPE
                    root_info.mode = 0o700
                    root_info.uid = root_info.gid = root_info.mtime = 0
                    root_info.uname = root_info.gname = "root"
                    archive.addfile(root_info)
                    for relative in (*sorted(ALLOWLIST), "MANIFEST.sha256"):
                        add_file(archive, stage / relative, f"{BUNDLE_ROOT}/{relative}")
        os.chmod(archive_temporary, 0o600)
        os.replace(archive_temporary, archive_path)
        os.chmod(archive_path, 0o600)

    outer = output_dir / f"{BUNDLE_NAME}.sha256"
    outer_temporary = output_dir / f".{BUNDLE_NAME}.sha256.tmp-{os.getpid()}"
    outer_temporary.write_text(f"{digest(archive_path)}  {archive_path.name}\n", encoding="utf-8")
    os.chmod(outer_temporary, 0o600)
    os.replace(outer_temporary, outer)
    os.chmod(outer, 0o600)
    print(f"[OK]   node bundle 생성(Secret 제외, mode 0600): {archive_path}")
    print(f"[OK]   portable outer checksum(basename만 기록): {outer}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
