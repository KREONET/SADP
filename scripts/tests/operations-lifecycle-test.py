#!/usr/bin/env python3
"""SADP/RKE2 업데이트와 안전 기동·종료의 읽기 전용 경계 회귀."""

from __future__ import annotations

import os
import pathlib
import re
import shutil
import subprocess
import tempfile

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
PASSED = 0
FAILED = 0


def check(
    label: str,
    command: list[str],
    expected: int,
    contains: tuple[str, ...],
    *,
    env: dict[str, str] | None = None,
    cwd: pathlib.Path = ROOT,
) -> None:
    global PASSED, FAILED
    result = subprocess.run(
        command,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, **(env or {})},
    )
    output = result.stdout + result.stderr
    if result.returncode == expected and all(item in output for item in contains):
        PASSED += 1
        print(f"[OK]   {label}")
        return
    FAILED += 1
    print(f"[FAIL] {label}: exit={result.returncode}, expected={expected}")
    for line in output.splitlines()[-20:]:
        print(f"       {line}")


check(
    "OP-01 power off plan never stops agent without apply",
    [
        "bash",
        "./sadp",
        "--power",
        "off",
        "--role",
        "agent",
        "--drained-node",
        "wrong-node",
    ],
    0,
    ("drain 확인 후", "계획만 확인함"),
)

check(
    "OP-02 server cannot use agent-only off confirmation",
    ["bash", "./sadp", "--power", "prepare-off", "--role", "agent"],
    1,
    ("지원하지 않음",),
)

with tempfile.TemporaryDirectory() as tmp:
    tmp_path = pathlib.Path(tmp)
    fake_rke2 = tmp_path / "rke2"
    locked_rke2 = str(
        yaml.safe_load((ROOT / "versions.lock.yaml").read_text(encoding="utf-8"))["platform"][
            "rke2"
        ]
    )
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)\+rke2r(\d+)", locked_rke2)
    assert match
    major, minor, patch, release = map(int, match.groups())
    if release > 1:
        old_rke2 = f"v{major}.{minor}.{patch}+rke2r{release - 1}"
    else:
        assert patch > 0
        old_rke2 = f"v{major}.{minor}.{patch - 1}+rke2r1"
    fake_rke2.write_text(
        f"#!/usr/bin/env bash\nprintf 'rke2 version {old_rke2} (test)\\n'\n",
        encoding="utf-8",
    )
    fake_rke2.chmod(0o755)
    check(
        "OP-03 RKE2 plan consumes locked version and does not restart",
        [
            "bash",
            "./sadp",
            "--upgrade-rke2",
            "--role",
            "agent",
            "--drained-node",
            os.uname().nodename.split(".")[0],
        ],
        0,
        (f"current={old_rke2} target={locked_rke2}", "자동 재시작하지 않음"),
        env={"SADP_RKE2_BIN": str(fake_rke2)},
    )

with tempfile.TemporaryDirectory() as tmp:
    upstream = pathlib.Path(tmp) / "upstream"
    upstream.mkdir()
    local_sadp = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    sadp_match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", local_sadp)
    assert sadp_match
    sadp_major, sadp_minor, sadp_patch = map(int, sadp_match.groups())
    remote_sadp = f"{sadp_major}.{sadp_minor}.{sadp_patch + 1}"
    (upstream / "VERSION").write_text(f"{remote_sadp}\n", encoding="utf-8")
    (upstream / "versions.lock.yaml").write_text(
        "platform:\n  rke2: v1.35.8+rke2r1\n",
        encoding="utf-8",
    )
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=upstream, check=True)
    subprocess.run(["git", "add", "."], cwd=upstream, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=SADP Test",
            "-c",
            "user.email=sadp-test@example.invalid",
            "commit",
            "-qm",
            "test update",
        ],
        cwd=upstream,
        check=True,
    )
    check(
        "OP-04 GitHub updater compares VERSION and package lock without apply",
        ["bash", "./sadp", "--update-sadp", "--repository", str(upstream)],
        0,
        (f"local={local_sadp} remote={remote_sadp}", "platform.rke2:", "계획만 확인함"),
    )

with tempfile.TemporaryDirectory() as tmp:
    tmp_path = pathlib.Path(tmp)
    installed = tmp_path / "installed"
    upstream = tmp_path / "upstream"
    (installed / "scripts" / "ops").mkdir(parents=True)
    shutil.copy2(ROOT / "scripts" / "ops" / "update-sadp.sh", installed / "scripts" / "ops")
    (installed / "VERSION").write_text("1.0.0\n", encoding="utf-8")
    (installed / "versions.lock.yaml").write_text(
        "platform:\n  rke2: v1.35.7+rke2r1\n", encoding="utf-8"
    )
    (installed / "sadp").write_text(
        "#!/usr/bin/env bash\n[[ ${1:-} == --test ]]\n", encoding="utf-8"
    )
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=installed, check=True)
    subprocess.run(["git", "add", "."], cwd=installed, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=SADP Test",
            "-c",
            "user.email=sadp-test@example.invalid",
            "commit",
            "-qm",
            "installed",
        ],
        cwd=installed,
        check=True,
    )
    subprocess.run(["git", "clone", "-q", str(installed), str(upstream)], check=True)
    (upstream / "VERSION").write_text("1.0.1\n", encoding="utf-8")
    (upstream / "versions.lock.yaml").write_text(
        "platform:\n  rke2: v1.35.8+rke2r1\n", encoding="utf-8"
    )
    subprocess.run(["git", "add", "."], cwd=upstream, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=SADP Test",
            "-c",
            "user.email=sadp-test@example.invalid",
            "commit",
            "-qm",
            "upgrade",
        ],
        cwd=upstream,
        check=True,
    )
    check(
        "OP-05 updater applies only verified fast-forward",
        [
            "bash",
            "scripts/ops/update-sadp.sh",
            "--repository",
            str(upstream),
            "--apply",
        ],
        0,
        ("SADP 1.0.0 -> 1.0.1 fast-forward 완료",),
        cwd=installed,
    )
    if (installed / "VERSION").read_text(encoding="utf-8").strip() != "1.0.1":
        FAILED += 1
        print("[FAIL] OP-05 updater did not change VERSION")

print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(1 if FAILED else 0)
