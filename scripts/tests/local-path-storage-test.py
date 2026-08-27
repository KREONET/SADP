#!/usr/bin/env python3
"""StorageClass 부재 시에만 local-path를 설치하는 경계 회귀."""

from __future__ import annotations

import os
import pathlib
import stat
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
PASSED = 0
FAILED = 0


def executable(path: pathlib.Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run(scenario: str, *arguments: str) -> tuple[subprocess.CompletedProcess, str]:
    with tempfile.TemporaryDirectory(prefix="local-path-storage-test-") as raw:
        temp = pathlib.Path(raw)
        log = temp / "kubectl.log"
        kubectl = temp / "kubectl"
        fake_id = temp / "id"
        executable(
            fake_id,
            "#!/usr/bin/env bash\n[[ ${1:-} == -u ]] && { echo 0; exit 0; }\n/usr/bin/id \"$@\"\n",
        )
        executable(
            kubectl,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_LOG}"
args=" $* "
if [[ ${args} == *" get storageclass -o json "* ]]; then
  case "${MOCK_SCENARIO}" in
    none) printf '{"items":[]}\n' ;;
    other) printf '{"items":[{"metadata":{"name":"fast"},"provisioner":"example.io/fast"}]}\n' ;;
    local) printf '{"items":[{"metadata":{"name":"local-path"},"provisioner":"rancher.io/local-path"}]}\n' ;;
  esac
  exit 0
fi
if [[ ${args} == *" get deployment -n local-path-storage local-path-provisioner "* ]]; then
  [[ ${MOCK_SCENARIO} != local ]] || exit 1
fi
exit 0
""",
        )
        env = os.environ | {
            "KUBECTL_BIN": str(kubectl),
            "KUBECONFIG_PATH": str(temp / "kubeconfig"),
            "MOCK_LOG": str(log),
            "MOCK_SCENARIO": scenario,
            "PATH": f"{temp}:{os.environ.get('PATH', '')}",
        }
        result = subprocess.run(
            ["bash", "scripts/cluster/install-local-path-storage.sh", *arguments],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        return result, log.read_text(encoding="utf-8")


def report(label: str, condition: bool, detail: str = "") -> None:
    global PASSED, FAILED
    if condition:
        PASSED += 1
        print(f"[OK]   {label}")
    else:
        FAILED += 1
        print(f"[FAIL] {label}: {detail}")


plan, plan_log = run("none")
report(
    "LP-01 StorageClass 부재 계획은 read-only",
    plan.returncode == 0
    and "StorageClass 없음" in plan.stdout
    and " apply -f docs/examples/local-path-storage.yaml" not in plan_log,
    plan.stdout + plan.stderr + plan_log,
)

applied, apply_log = run("none", "--apply")
report(
    "LP-02 StorageClass 부재 apply는 manifest/rollout/default 지정을 수행",
    applied.returncode == 0
    and "apply -f docs/examples/local-path-storage.yaml" in apply_log
    and "rollout status deployment/local-path-provisioner" in apply_log
    and "annotate storageclass local-path" in apply_log,
    applied.stdout + applied.stderr + apply_log,
)

existing, existing_log = run("other", "--apply")
report(
    "LP-03 기존 StorageClass가 있으면 자동 설치하지 않음",
    existing.returncode == 0
    and "자동 설치 생략" in existing.stdout
    and " apply -f " not in existing_log,
    existing.stdout + existing.stderr + existing_log,
)

partial, _ = run("local", "--apply")
report(
    "LP-04 local-path 부분 설치는 자동 채택하지 않고 거부",
    partial.returncode == 1 and "부분 설치 상태" in partial.stderr,
    partial.stdout + partial.stderr,
)

listed = subprocess.run(
    ["bash", "./sadp", "--list"], cwd=ROOT, capture_output=True, text=True, check=False
)
report(
    "LP-05 단일 진입점에 local-path 설치 명령 노출",
    listed.returncode == 0 and "--install-local-path-storage" in listed.stdout,
    listed.stdout + listed.stderr,
)

print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(1 if FAILED else 0)
