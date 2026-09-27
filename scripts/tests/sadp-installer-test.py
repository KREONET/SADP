#!/usr/bin/env python3
"""SADP 통합 설치기의 읽기 전용 계획과 예제값 apply 차단 회귀."""

from __future__ import annotations

import pathlib
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[2]
ENV_FILE = ROOT / "environments" / "site.env.example"
PASSED = 0
FAILED = 0


def check(label: str, command: list[str], expected: int, contains: tuple[str, ...]) -> None:
    global PASSED, FAILED
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)
    output = result.stdout + result.stderr
    if result.returncode == expected and all(item in output for item in contains):
        PASSED += 1
        print(f"[OK]   {label}")
        return
    FAILED += 1
    print(f"[FAIL] {label}: exit={result.returncode}, expected={expected}")
    for line in output.splitlines()[-20:]:
        print(f"       {line}")


def check_order(label: str, command: list[str], before: str, after: str) -> None:
    global PASSED, FAILED
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)
    output = result.stdout + result.stderr
    before_index = output.find(before)
    after_index = output.find(after)
    if result.returncode == 0 and before_index >= 0 and after_index > before_index:
        PASSED += 1
        print(f"[OK]   {label}")
        return
    FAILED += 1
    print(
        f"[FAIL] {label}: exit={result.returncode}, "
        f"before={before_index}, after={after_index}"
    )
    for line in output.splitlines()[-20:]:
        print(f"       {line}")


check(
    "SI-01 example site.env render plan is read-only",
    ["bash", "./sadp", "--install", "--env-file", str(ENV_FILE), "--phase", "render"],
    0,
    ("site=sadp", "외부 OIDC issuer 연결:", "IdP 설정은 설치기 관리 대상 아님", "검사만 완료"),
)
check(
    "SI-02 worker role/IP and node steps are inferred from env",
    [
        "bash",
        "./sadp",
        "--install",
        "--env-file",
        str(ENV_FILE),
        "--phase",
        "node",
        "--node-name",
        "sadp-worker-1",
    ],
    0,
    (
        "role=agent internal-ip=10.20.30.21",
        "--server-url https://10.20.30.11:9345",
        "RKE2 embedded containerd proxy",
    ),
)
check(
    "SI-03 documentation endpoints cannot be applied",
    [
        "bash",
        "./sadp",
        "--install",
        "--env-file",
        str(ENV_FILE),
        "--phase",
        "render",
        "--apply",
    ],
    1,
    ("예제 BASE_DOMAIN을 실제 설치에 사용할 수 없음",),
)
check(
    "SI-04 all plan describes rendering, restart and TLS without applying",
    [
        "bash",
        "./sadp",
        "--install",
        "--env-file",
        str(ENV_FILE),
        "--phase",
        "all",
    ],
    0,
    ("Git commit/push", "RKE2 재시작", "Certificate 확인", "OpenBao 초기화·unseal"),
)
check(
    "SI-05 cluster phase plans automatic Devtron/Argo bootstrap",
    [
        "bash",
        "./sadp",
        "--install",
        "--env-file",
        str(ENV_FILE),
        "--phase",
        "cluster",
        "--node-name",
        "sadp-control-plane-1",
    ],
    0,
    (
        "외부 OIDC issuer 연결:",
        "기존 RKE2 클러스터 선행 조건 검사",
        "Devtron과 번들 Argo CD 자동 준비",
        "scripts/cluster/install-devtron.sh",
        "--skip-monitoring-image-sync",
        "monitoring image pull용 Docker daemon Squid 확인",
    ),
)

check_order(
    "SI-05b cluster prepares missing StorageClass before preflight",
    [
        "bash",
        "./sadp",
        "--install",
        "--env-file",
        str(ENV_FILE),
        "--phase",
        "cluster",
        "--node-name",
        "sadp-control-plane-1",
    ],
    "StorageClass 부재 시 local-path 준비",
    "기존 RKE2 클러스터 선행 조건 검사",
)

check_order(
    "SI-06 Squid node installs egress before containerd proxy configuration",
    [
        "bash",
        "./sadp",
        "--install",
        "--env-file",
        str(ENV_FILE),
        "--phase",
        "node",
        "--node-name",
        "sadp-control-plane-1",
    ],
    "계약 기반 Squid egress 선행 설치",
    "RKE2 embedded containerd proxy",
)

check_order(
    "SI-07 cluster preloads monitoring images through Squid before Devtron/Argo",
    [
        "bash",
        "./sadp",
        "--install",
        "--env-file",
        str(ENV_FILE),
        "--phase",
        "cluster",
        "--node-name",
        "sadp-control-plane-1",
    ],
    "패키지·차트 설치 전 Squid egress 확인",
    "Prometheus/Loki/Alloy 이미지 Squid 경유 선배포",
)

check_order(
    "SI-08 cluster preloads monitoring images before Devtron package/chart installation",
    [
        "bash",
        "./sadp",
        "--install",
        "--env-file",
        str(ENV_FILE),
        "--phase",
        "cluster",
        "--node-name",
        "sadp-control-plane-1",
    ],
    "Prometheus/Loki/Alloy 이미지 Squid 경유 선배포",
    "Devtron과 번들 Argo CD 자동 준비",
)

check_order(
    "SI-09 cluster checks Docker daemon proxy before monitoring image preload",
    [
        "bash",
        "./sadp",
        "--install",
        "--env-file",
        str(ENV_FILE),
        "--phase",
        "cluster",
        "--node-name",
        "sadp-control-plane-1",
    ],
    "monitoring image pull용 Docker daemon Squid 확인",
    "Prometheus/Loki/Alloy 이미지 Squid 경유 선배포",
)

print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(1 if FAILED else 0)
