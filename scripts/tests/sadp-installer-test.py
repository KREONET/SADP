#!/usr/bin/env python3
"""SADP 통합 설치기의 읽기 전용 계획과 예제값 apply 차단 회귀."""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import sadp_test_fixture  # noqa: E402

# 사이트 checkout의 계약·생성물에 기대는 시험이다. 직접 실행해도 예제 site.env로
# 렌더한 fixture 사본에서 돌게 해 사이트 값 때문에 생기는 거짓 실패를 막는다.
sadp_test_fixture.reexec_in_fixture(__file__)

ROOT = pathlib.Path(__file__).resolve().parents[2]
ENV_FILE = ROOT / "environments" / "site.env.example"
PASSED = 0
FAILED = 0

# render/all 앞에서 외부 IdP discovery를 대조하므로 네트워크 대신 PATH mock curl이 예제
# site.env와 같은 discovery 문서를 돌려준다. MOCK_DISCOVERY_OVERRIDE로 한 필드만 틀리게 만든다.
MOCK_DIR = pathlib.Path(tempfile.mkdtemp(prefix="sadp-installer-test-"))
(MOCK_DIR / "curl").write_text(
    r"""#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    --output) out=$2; shift ;;
    --write-out|--connect-timeout|--max-time|--proto|--proxy) shift ;;
  esac
  shift
done
python3 - "${out}" <<'PY'
import json, os, sys
values = dict(
    line.split("=", 1) for line in open(os.environ["MOCK_ENV_FILE"], encoding="utf-8").read().splitlines()
    if line and not line.startswith("#") and "=" in line
)
document = {
    "issuer": values["OIDC_ISSUER"],
    "authorization_endpoint": values["OIDC_AUTHORIZATION_ENDPOINT"],
    "token_endpoint": values["OIDC_TOKEN_ENDPOINT"],
    "jwks_uri": values["OIDC_JWKS_URI"],
}
document.update(json.loads(os.environ.get("MOCK_DISCOVERY_OVERRIDE") or "{}"))
json.dump(document, open(sys.argv[1], "w", encoding="utf-8"))
PY
printf '200'
""",
    encoding="utf-8",
)
(MOCK_DIR / "curl").chmod(0o755)


def environment(**extra: str) -> dict[str, str]:
    return dict(
        os.environ,
        PATH=f"{MOCK_DIR}:{os.environ['PATH']}",
        MOCK_ENV_FILE=str(ENV_FILE),
        **extra,
    )


def check(
    label: str,
    command: list[str],
    expected: int,
    contains: tuple[str, ...],
    *,
    absent: tuple[str, ...] = (),
    env: dict[str, str] | None = None,
) -> None:
    global PASSED, FAILED
    result = subprocess.run(
        command, cwd=ROOT, env=env or environment(), capture_output=True, text=True, check=False
    )
    output = result.stdout + result.stderr
    if (
        result.returncode == expected
        and all(item in output for item in contains)
        and not any(item in output for item in absent)
    ):
        PASSED += 1
        print(f"[OK]   {label}")
        return
    FAILED += 1
    print(f"[FAIL] {label}: exit={result.returncode}, expected={expected}")
    for line in output.splitlines()[-20:]:
        print(f"       {line}")


def check_order(label: str, command: list[str], before: str, after: str) -> None:
    global PASSED, FAILED
    result = subprocess.run(
        command, cwd=ROOT, env=environment(), capture_output=True, text=True, check=False
    )
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
    ("site=sadp", "외부 OIDC issuer 연결:", "IdP 설정은 설치기 관리 대상 아님", "검사만 완료",
     "IdP discovery와 site.env"),
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

check(
    "SI-10 render 전 IdP discovery 불일치면 렌더·계획 전에 중단",
    ["bash", "./sadp", "--install", "--env-file", str(ENV_FILE), "--phase", "render"],
    1,
    ("불일치 필드: token_endpoint", "외부 IdP discovery 대조 실패로 설치를 중단함"),
    absent=("검사만 완료", "idp.example.invalid"),
    env=environment(MOCK_DISCOVERY_OVERRIDE=json.dumps({"token_endpoint": "https://x.invalid/t/"})),
)
check(
    "SI-11 all phase도 계획 출력 전에 IdP discovery를 대조",
    ["bash", "./sadp", "--install", "--env-file", str(ENV_FILE), "--phase", "all"],
    1,
    ("불일치 필드: issuer",),
    absent=("[PLAN]",),
    env=environment(MOCK_DISCOVERY_OVERRIDE=json.dumps({"issuer": "https://idp.example.invalid/x"})),
)
check(
    "SI-12 --skip-idp-verify는 외부 요청 없이 [WARN]을 남기고 진행",
    ["bash", "./sadp", "--install", "--env-file", str(ENV_FILE), "--phase", "render",
     "--skip-idp-verify"],
    0,
    ("[WARN] --skip-idp-verify", "검사만 완료"),
    env=environment(MOCK_DISCOVERY_OVERRIDE=json.dumps({"issuer": "https://wrong.invalid/"})),
)
check(
    "SI-13 node phase는 IdP를 다시 조회하지 않음(worker는 외부망이 없을 수 있음)",
    ["bash", "./sadp", "--install", "--env-file", str(ENV_FILE), "--phase", "node",
     "--node-name", "sadp-worker-1"],
    0,
    ("role=agent",),
    absent=("IdP discovery",),
    env=environment(MOCK_DISCOVERY_OVERRIDE=json.dumps({"issuer": "https://wrong.invalid/"})),
)

shutil.rmtree(MOCK_DIR, ignore_errors=True)
print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(1 if FAILED else 0)
