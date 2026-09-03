#!/usr/bin/env python3
"""control-plane 운영 bundle allowlist와 checksum 회귀."""

from __future__ import annotations

import hashlib
import pathlib
import subprocess
import tarfile
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
BUNDLER = ROOT / "scripts/ops/build-ops-bundle.py"

with tempfile.TemporaryDirectory(prefix="sadp-ops-bundle-test-") as temporary:
    output = pathlib.Path(temporary)
    result = subprocess.run(
        ["python3", str(BUNDLER), "--output-dir", str(output)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    archive = output / "sadp-ops-bundle.tar.gz"
    checksum = output / "sadp-ops-bundle.tar.gz.sha256"
    assert result.returncode == 0, result.stdout + result.stderr
    assert (archive.stat().st_mode & 0o777) == 0o600
    assert (checksum.stat().st_mode & 0o777) == 0o600
    expected = checksum.read_text(encoding="utf-8").split()[0]
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    assert expected == actual
    with tarfile.open(archive, "r:gz") as handle:
        members = {member.name for member in handle.getmembers()}
    required = {
        "sadp",
        "scripts/lib/openbao-eso.sh",
        "scripts/lib/openbao-oidc.sh",
        "scripts/ops/configure-openbao-oidc.sh",
        "scripts/ops/unseal-openbao.sh",
        "scripts/ops/build-ops-bundle.py",
        "MANIFEST.sha256",
    }
    assert required <= members
    forbidden_fragments = ("site.env", ".env", "openbao-init", "/credentials/", "/state/", "/backups/", ".pem", ".key", ".crt")
    assert not any(
        fragment in member.lower()
        for member in members
        for fragment in forbidden_fragments
    ), sorted(members)

print("[OK]   control-plane ops bundle은 고정 allowlist, mode 0600, portable checksum 사용")
print("[OK]   site.env/.env/OpenBao 초기화/credential/state/backup/certificate/private key 제외")
