#!/usr/bin/env python3
"""RKE2 local containerd proxy와 Secret 없는 node bundle 회귀."""

from __future__ import annotations

import hashlib
import importlib.util
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "scripts/node/install-rke2-containerd-proxy.sh"
BUNDLER = ROOT / "scripts/ops/build-node-bundle.py"
passed = 0
failed = 0


def check(condition: bool, message: str) -> None:
    global passed, failed
    if condition:
        passed += 1
        print(f"[OK]   {message}")
    else:
        failed += 1
        print(f"[FAIL] {message}")


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(INSTALLER), *args],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def process(root: pathlib.Path, pid: int, argv: list[str], environ: list[str]) -> None:
    directory = root / "proc" / str(pid)
    directory.mkdir(parents=True)
    (directory / "exe").symlink_to(argv[0])
    (directory / "cmdline").write_bytes(b"\0".join(item.encode() for item in argv) + b"\0")
    (directory / "environ").write_bytes(
        b"\0".join(item.encode() for item in environ) + b"\0"
    )


with tempfile.TemporaryDirectory(prefix="sadp-containerd-proxy-test-") as temporary:
    work = pathlib.Path(temporary)
    root = work / "host"
    for relative in ("etc/default", "etc/systemd/system", "proc"):
        (root / relative).mkdir(parents=True, exist_ok=True)
    (root / "etc/systemd/system/rke2-server.service").write_text("fixture\n")
    proxy = work / "proxy.env"
    proxy.write_text(
        "# Generated fixture; no credentials.\n"
        "export HTTP_PROXY=http://192.0.2.10:3128\n"
        "export HTTPS_PROXY=http://192.0.2.10:3128\n"
        "export NO_PROXY=localhost,127.0.0.1,.svc\n",
        encoding="utf-8",
    )
    common = ("--root-prefix", str(root), "--proxy-env", str(proxy))
    result = run(*common)
    check(
        result.returncode == 0
        and "role=server" in result.stdout
        and "192.0.2.10" not in result.stdout + result.stderr,
        "local plan은 server를 자동 판별하고 proxy 값을 출력하지 않음",
    )

    result = run(*common, "--apply")
    target = root / "etc/default/rke2-server"
    expected_values = [
        "CONTAINERD_HTTP_PROXY=http://192.0.2.10:3128",
        "CONTAINERD_HTTPS_PROXY=http://192.0.2.10:3128",
        "CONTAINERD_NO_PROXY=localhost,127.0.0.1,.svc",
    ]
    target_text = target.read_text(encoding="utf-8")
    check(
        result.returncode == 0
        and all(value in target_text for value in expected_values)
        and (target.stat().st_mode & 0o777) == 0o600
        and "restart rke2-server" in result.stdout,
        "local apply는 RKE2 CONTAINERD_* 환경을 0600 관리 블록에 쓰고 수동 재시작만 안내",
    )
    second_apply = run(*common, "--apply")
    check(
        second_apply.returncode == 0
        and target.read_text(encoding="utf-8").count("# BEGIN SADP MANAGED CONTAINERD PROXY") == 1,
        "local apply는 관리 블록을 중복하지 않고 멱등 갱신",
    )

    rke2_environment = [
        "",
        "BROKEN",
        "CONTAINERD_HTTP_PROXY=http://192.0.2.10:3128",
        "CONTAINERD_HTTPS_PROXY=http://192.0.2.10:3128",
        "CONTAINERD_NO_PROXY=localhost,127.0.0.1,.svc",
    ]
    containerd_environment = [
        "=ignored",
        "HTTP_PROXY=http://192.0.2.10:3128",
        "HTTPS_PROXY=http://192.0.2.10:3128",
        "NO_PROXY=localhost,127.0.0.1,.svc",
    ]
    process(root, 101, ["/usr/local/bin/rke2", "server"], rke2_environment)
    process(
        root,
        102,
        ["/var/lib/rancher/rke2/data/fixture/bin/containerd", "-c", "/fixture"],
        containerd_environment,
    )
    process(root, 103, ["/usr/bin/containerd-shim-runc-v2", "-namespace", "k8s.io"], [])
    result = run(*common, "--check")
    check(
        result.returncode == 0 and "값 비출력" in result.stdout,
        "NUL environ의 빈 항목과 '=' 없는 항목을 건너뛰고 shim을 오인하지 않음",
    )

    for cmdline in (b"containerd\0-c\0/fixture\0", b"containerd -c /fixture\0"):
        (root / "proc/102/cmdline").write_bytes(cmdline)
        result = run(*common, "--check")
        check(result.returncode == 0, "짧은 argv/process title이어도 실제 RKE2 실행 파일로 판별")

    process(root, 104, ["/usr/bin/containerd"], [])
    process(root, 105, ["/var/lib/rancher/rke2/data/fixture/bin/containerd"], [])
    (root / "proc/105/exe").unlink()
    (root / "proc/105/exe").symlink_to("/usr/bin/containerd")
    result = run(*common, "--check")
    check(result.returncode == 0, "Docker containerd와 RKE2 경로를 흉내 낸 argv를 실제 실행 파일로 제외")

    process(root, 106, ["/var/lib/rancher/rke2/bin/containerd"], containerd_environment)
    result = run(*common, "--check")
    check(result.returncode != 0 and "count=2" in result.stderr
          and "102 106" in result.stderr, "실제 embedded containerd 중복은 PID/개수를 알리고 중단")
    shutil.rmtree(root / "proc/106")

    (root / "proc/102/exe").unlink()
    result = run(*common, "--check")
    check(result.returncode != 0 and "count=0" in result.stderr
          and "192.0.2.10" not in result.stdout + result.stderr,
          "실행 파일을 확인할 수 없으면 Docker로 대체하지 않고 값 비출력으로 실패")
    (root / "proc/102/exe").symlink_to("/var/lib/rancher/rke2/data/fixture/bin/containerd (deleted)")
    result = run(*common, "--check")
    check(result.returncode == 0, "교체된 실행 파일의 deleted 표식은 기존 프로세스 환경 검사를 방해하지 않음")
    (root / "proc/102/exe").unlink()
    (root / "proc/102/exe").symlink_to("/var/lib/rancher/rke2/data/fixture/bin/containerd")

    (root / "proc/101/cmdline").write_bytes(b"/usr/local/bin/rke2 server\0")
    result = run(*common, "--check")
    check(result.returncode == 0, "argv 하나인 '/usr/local/bin/rke2 server' 형태 인식")

    (root / "etc/systemd/system/rke2-server.service").unlink()
    (root / "etc/systemd/system/rke2-agent.service").write_text("fixture\n")
    (root / "proc/101/cmdline").write_bytes(b"/usr/local/bin/rke2\0agent\0")
    result = run(*common)
    check(result.returncode == 0 and "role=agent" in result.stdout, "agent argv/서비스 자동 판별")
    (root / "etc/systemd/system/rke2-server.service").write_text("fixture\n")
    (root / "etc/systemd/system/rke2-agent.service").write_text("fixture\n")
    result = run(*common)
    check(result.returncode != 0 and "모호" in result.stderr, "server/agent ambiguity는 fail-close")
    (root / "etc/systemd/system/rke2-agent.service").unlink()
    (root / "proc/101/cmdline").write_bytes(b"/usr/local/bin/rke2\0server\0")

    target.write_text("# BEGIN SADP MANAGED CONTAINERD PROXY\n", encoding="utf-8")
    result = run(*common, "--apply")
    check(result.returncode != 0 and "표식" in result.stderr, "깨진 관리 표식을 덮어쓰지 않음")
    target.unlink()
    target.symlink_to(work / "outside")
    result = run(*common, "--apply")
    check(result.returncode != 0 and "symlink" in result.stderr, "관리 파일 symlink 거부")

    bad_proxy = work / "bad-proxy.env"
    bad_proxy.write_text(
        "export HTTP_PROXY=http://operator:do-not-print@192.0.2.10:3128\n"
        "export HTTPS_PROXY=http://192.0.2.10:3128\n"
        "export NO_PROXY=localhost\n",
        encoding="utf-8",
    )
    result = run("--role", "server", "--proxy-env", str(bad_proxy))
    check(
        result.returncode != 0 and "do-not-print" not in result.stdout + result.stderr,
        "credential proxy를 값 비출력으로 거부",
    )
    empty_root = work / "empty-host"
    (empty_root / "etc").mkdir(parents=True)
    (empty_root / "proc").mkdir()
    result = run("--root-prefix", str(empty_root), "--proxy-env", str(proxy))
    check(result.returncode != 0 and "모호" in result.stderr, "role 단서가 없을 때도 fail-close")

with tempfile.TemporaryDirectory(prefix="sadp-node-bundle-output-") as temporary:
    output = pathlib.Path(temporary)
    result = subprocess.run(
        ["python3", str(BUNDLER), "--output-dir", str(output)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    archive = output / "sadp-node-bundle.tar.gz"
    outer = output / "sadp-node-bundle.tar.gz.sha256"
    check(
        result.returncode == 0
        and (archive.stat().st_mode & 0o777) == 0o600
        and (outer.stat().st_mode & 0o777) == 0o600,
        "node bundle archive와 outer checksum mode 0600",
    )
    checksum, filename = outer.read_text(encoding="utf-8").split()
    check(
        filename == archive.name
        and "/" not in filename
        and hashlib.sha256(archive.read_bytes()).hexdigest() == checksum,
        "outer checksum은 archive basename만 기록해 portable",
    )
    with tarfile.open(archive, "r:gz") as bundle:
        names = set(bundle.getnames())
        expected = {
            "sadp-node-bundle",
            "sadp-node-bundle/MANIFEST.sha256",
            *(f"sadp-node-bundle/{item}" for item in (
                "sadp",
                "scripts/node/install-rke2-containerd-proxy.sh",
                "platform/network/proxy.env",
                "rke/control-node/config.yaml",
                "rke/worker-node/config.yaml",
            )),
        }
        check(names == expected, "bundle은 코드의 정확한 file allowlist만 포함")
        manifest = bundle.extractfile("sadp-node-bundle/MANIFEST.sha256").read().decode()
        check(
            all(item in manifest for item in (
                "platform/network/proxy.env",
                "rke/control-node/config.yaml",
                "rke/worker-node/config.yaml",
            )),
            "archive 내부 MANIFEST.sha256 포함",
        )
        check(
            not any(
                marker in name
                for name in names
                for marker in ("site.env", "/.env", ".pem", ".key", "credentials", "backups")
            ),
            "site.env/.env/PEM/key/credential/state/backup 제외",
        )

spec = importlib.util.spec_from_file_location("node_bundle", BUNDLER)
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix="sadp-node-bundle-safety-") as temporary:
    fixture = pathlib.Path(temporary)
    (fixture / "rke/control-node").mkdir(parents=True)
    (fixture / "rke/worker-node").mkdir(parents=True)
    (fixture / "rke/control-node/config.yaml").write_text("token: non-empty\n")
    (fixture / "rke/worker-node/config.yaml").write_text("token: ''\n")
    original_root = module.ROOT
    module.ROOT = fixture
    try:
        try:
            module.validate_join_tokens()
            token_rejected = False
        except ValueError:
            token_rejected = True
        check(token_rejected, "bundle 생성 전 server/agent join token 빈 값 강제")
        secret = fixture / "secret.txt"
        secret.write_text("-----BEGIN PRIVATE KEY-----\nfixture\n")
        try:
            module.validate_source("secret.txt")
            secret_rejected = False
        except ValueError:
            secret_rejected = True
        check(secret_rejected, "bundle allowlist 파일의 private key/token 패턴 거부")
        plain = fixture / "plain.txt"
        plain.write_text("safe\n")
        link = fixture / "link.txt"
        link.symlink_to(plain)
        try:
            module.validate_source("link.txt")
            symlink_rejected = False
        except ValueError:
            symlink_rejected = True
        check(symlink_rejected, "bundle allowlist symlink 거부")
    finally:
        module.ROOT = original_root

print(f"통과 {passed} / 실패 {failed}")
raise SystemExit(1 if failed else 0)
