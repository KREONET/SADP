#!/usr/bin/env python3
"""control-plane 복구에 필요한 Secret 제외 운영 overlay bundle을 만든다."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import pathlib
import re
import tarfile
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
BUNDLE_NAME = "sadp-ops-bundle.tar.gz"

# glob으로 저장소를 훑지 않는다. 기존 checkout 위에 덮을 control-plane 운영 코드만 고정해
# ignored site.env나 상태/백업/인증서가 archive에 들어올 통로 자체를 없앤다.
ALLOWLIST = (
    "sadp",
    "scripts/cluster/bootstrap-testbed-services.sh",
    "scripts/cluster/deploy-testbed-apps.sh",
    "scripts/cluster/install-portal-backend.sh",
    "scripts/lib/machine-auth.sh",
    "scripts/lib/openbao-eso.sh",
    "scripts/lib/openbao-oidc.sh",
    "scripts/lib/testbed-common.sh",
    "scripts/ops/backup-testbed.sh",
    "scripts/ops/build-ops-bundle.py",
    "scripts/ops/configure-openbao-app-access.sh",
    "scripts/ops/configure-openbao-oidc.sh",
    "scripts/ops/rotate-forgejo-token.sh",
    "scripts/ops/rotate-machine-api-key.sh",
    "scripts/ops/unseal-openbao.sh",
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
    if has_symlink or not path.is_file():
        raise ValueError(f"allowlist 경로가 일반 파일이 아님: {relative}")
    if SENSITIVE.search(path.read_bytes()):
        raise ValueError(f"private key/token 패턴 감지: {relative}")
    return path


def add_file(archive: tarfile.TarFile, path: pathlib.Path, arcname: str) -> None:
    info = archive.gettarinfo(str(path), arcname=arcname)
    info.uid = info.gid = info.mtime = 0
    info.uname = info.gname = "root"
    info.mode = 0o700 if path.name == "sadp" or path.suffix in {".sh", ".py"} else 0o600
    with path.open("rb") as handle:
        archive.addfile(info, handle)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Secret 없는 SADP control-plane 운영 bundle/checksum 생성"
    )
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    output_dir = pathlib.Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(output_dir, 0o700)
    sources = {relative: validate_source(relative) for relative in ALLOWLIST}

    with tempfile.TemporaryDirectory(prefix="sadp-ops-bundle-") as temporary:
        manifest = pathlib.Path(temporary) / "MANIFEST.sha256"
        manifest.write_text(
            "".join(f"{digest(sources[path])}  {path}\n" for path in sorted(ALLOWLIST)),
            encoding="utf-8",
        )
        os.chmod(manifest, 0o600)
        archive_path = output_dir / BUNDLE_NAME
        pending = output_dir / f".{BUNDLE_NAME}.tmp-{os.getpid()}"
        with pending.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    for relative in sorted(ALLOWLIST):
                        add_file(archive, sources[relative], relative)
                    add_file(archive, manifest, "MANIFEST.sha256")
        os.chmod(pending, 0o600)
        os.replace(pending, archive_path)
        os.chmod(archive_path, 0o600)

    checksum = output_dir / f"{BUNDLE_NAME}.sha256"
    pending_checksum = output_dir / f".{BUNDLE_NAME}.sha256.tmp-{os.getpid()}"
    pending_checksum.write_text(
        f"{digest(archive_path)}  {archive_path.name}\n", encoding="utf-8"
    )
    os.chmod(pending_checksum, 0o600)
    os.replace(pending_checksum, checksum)
    os.chmod(checksum, 0o600)
    print(f"[OK]   control-plane ops bundle 생성(Secret 제외, mode 0600): {archive_path}")
    print(f"[OK]   portable outer checksum(basename만 기록): {checksum}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
