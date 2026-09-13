#!/usr/bin/env python3
"""Devtron 자동 bootstrap과 RKE2 preflight의 fail-close 회귀."""

from __future__ import annotations

import os
import pathlib
import shlex
import subprocess
import tempfile

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
PASSED = 0
FAILED = 0
VERSIONS = yaml.safe_load((ROOT / "versions.lock.yaml").read_text(encoding="utf-8"))["delivery"]
DEVTRON_APP_VERSION = str(VERSIONS["devtronOperator"])
DEVTRON_CHART_VERSION = str(VERSIONS["devtronOperatorChart"])
DEVTRON_INSTALLER_SOURCE = (ROOT / "scripts/cluster/install-devtron.sh").read_text(encoding="utf-8")


def write_executable(path: pathlib.Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def report(label: str, result: subprocess.CompletedProcess[str], expected: int, contains: tuple[str, ...]) -> None:
    global PASSED, FAILED
    output = result.stdout + result.stderr
    if result.returncode == expected and all(item in output for item in contains):
        PASSED += 1
        print(f"[OK]   {label}")
        return
    FAILED += 1
    print(f"[FAIL] {label}: exit={result.returncode}, expected={expected}")
    for line in output.splitlines()[-30:]:
        print(f"       {line}")


if "== Applied" in DEVTRON_INSTALLER_SOURCE and "== Downloaded" not in DEVTRON_INSTALLER_SOURCE:
    PASSED += 1
    print("[OK]   DB-Downloaded는 완료가 아니며 최종 Applied만 성공")
else:
    FAILED += 1
    print("[FAIL] DB-Installer 완료 조건이 Applied 단독이 아님")


with tempfile.TemporaryDirectory(prefix="sadp-delivery-test-") as raw_tmp:
    tmp = pathlib.Path(raw_tmp)
    kubectl = tmp / "kubectl"
    helm = tmp / "helm"
    fake_id = tmp / "id"
    log = tmp / "kubectl.log"
    helm_log = tmp / "helm.log"
    apply_log = tmp / "kubectl-apply.log"
    write_executable(
        fake_id,
        """#!/usr/bin/env bash
[[ ${1:-} == -u ]] && { printf '0\\n'; exit 0; }
exec /usr/bin/id "$@"
""",
    )
    write_executable(
        helm,
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"${MOCK_HELM_LOG}"
args=" $* "
case "${MOCK_SCENARIO:-missing}" in
  missing|partial|devtron-crd)
    [[ ${args} == *" status devtron "* ]] && exit 1
    ;;
  ready|stalled|wrong-config|failed|pending)
    if [[ ${args} == *" status devtron "* ]]; then
      status=deployed
      [[ ${MOCK_SCENARIO} != failed ]] || status=failed
      [[ ${MOCK_SCENARIO} != pending ]] || status=pending-upgrade
      printf '{"info":{"status":"%s"}}\\n' "${status}"
      exit 0
    fi
    if [[ ${args} == *" list "* ]]; then
      printf '[{"chart":"devtron-operator-%s","app_version":"%s"}]\\n' \
        "${EXPECTED_CHART_VERSION}" "${EXPECTED_APP_VERSION}"
      exit 0
    fi
    if [[ ${args} == *" get values "* ]]; then
      if [[ ${MOCK_SCENARIO} == wrong-config ]]; then
        printf '{"installer":{"modules":[]},"argo-cd":{"enabled":false},"components":{"devtron":{"service":{"type":"LoadBalancer"}}}}\\n'
      else
        python3 - <<'PY'
import json
import os

proxy = {
    "HTTP_PROXY": os.environ.get("HTTP_PROXY", ""),
    "HTTPS_PROXY": os.environ.get("HTTPS_PROXY", ""),
    "NO_PROXY": os.environ.get("NO_PROXY", ""),
}
print(json.dumps({
    "installer": {"modules": ["cicd"]},
    "argo-cd": {"enabled": True},
    "components": {"devtron": {"service": {"type": "ClusterIP"}}},
    "configs": proxy,
    "global": {"configs": proxy},
}))
PY
      fi
      exit 0
    fi
    ;;
  wrong-version)
    [[ ${args} == *" status devtron "* ]] \
      && { printf '{"info":{"status":"deployed"}}\\n'; exit 0; }
    [[ ${args} == *" list "* ]] \
      && { printf '[{"chart":"devtron-operator-other","app_version":"other"}]\\n'; exit 0; }
    ;;
esac
exit 0
""",
    )
    write_executable(
        kubectl,
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"${MOCK_LOG}"
args=" $* "
scenario=${MOCK_SCENARIO:-missing}
if [[ ${scenario} == ready || ${scenario} == wrong-config || ${scenario} == wrong-version \
  || ${scenario} == failed ]]; then
  [[ ${args} == *" get installer -n devtroncd installer-devtron "* ]] && printf 'Applied' && exit 0
  [[ ${args} == *" get crd applications.argoproj.io "* ]] && exit 0
  [[ ${args} == *" get deployment -n devtroncd argocd-repo-server "* ]] && exit 0
  [[ ${args} == *" get statefulset -n devtroncd argocd-application-controller "* ]] && exit 0
  [[ ${args} == *" get deployment -n devtroncd devtron "* ]] && exit 0
  [[ ${args} == *" rollout status "* ]] && exit 0
fi
if [[ ${scenario} == partial && ${args} == *" get crd applications.argoproj.io "* ]]; then
  exit 0
fi
if [[ ${scenario} == devtron-crd && ${args} == *" get crd installers.installer.devtron.ai "* ]]; then
  exit 0
fi
exit 1
""",
    )
    base_env = os.environ | {
        "KUBECTL_BIN": str(kubectl),
        "HELM_BIN": str(helm),
        "KUBECONFIG_PATH": str(tmp / "kubeconfig"),
        "MOCK_LOG": str(log),
        "MOCK_HELM_LOG": str(helm_log),
        "MOCK_APPLY_LOG": str(apply_log),
        "EXPECTED_APP_VERSION": DEVTRON_APP_VERSION,
        "EXPECTED_CHART_VERSION": DEVTRON_CHART_VERSION,
        "PATH": f"{tmp}:{os.environ['PATH']}",
    }

    for scenario, expected, contains in (
        (
            "missing",
            0,
            (
                f"Devtron {DEVTRON_APP_VERSION} / chart {DEVTRON_CHART_VERSION}",
                f"--version {DEVTRON_CHART_VERSION}",
                "--timeout 1800s",
                "components.devtron.service.type=ClusterIP",
                "configs.HTTP_PROXY",
                "global.configs.NO_PROXY",
            ),
        ),
        (
            "ready",
            0,
            (f"기존 Devtron {DEVTRON_APP_VERSION}/Argo CD Ready", "자동 변경 없음"),
        ),
        (
            "failed",
            0,
            ("동일 버전 failed release 복구", "--reuse-values", "--timeout 1800s"),
        ),
        ("pending", 1, ("상태가 pending-upgrade", "failed 상태만 자동 복구")),
        ("stalled", 1, ("Helm release가 있지만 Installer/Devtron/Argo CD가 Ready가 아님", "자동 재적용하지 않으므로")),
        ("wrong-config", 1, ("Devtron release 설정이 SADP 계약과 다름", "자동 덮어쓰기하지 않음")),
        ("wrong-version", 1, ("Devtron release가 계약과 다름", "자동 upgrade/downgrade하지 않음")),
        ("partial", 1, ("Helm release 없이 Devtron/Argo CD 일부 리소스",)),
        ("devtron-crd", 1, ("Helm release 없이 Devtron/Argo CD 일부 리소스",)),
    ):
        result = subprocess.run(
            ["bash", "scripts/cluster/install-devtron.sh"],
            cwd=ROOT,
            env=base_env | {"MOCK_SCENARIO": scenario},
            capture_output=True,
            text=True,
            check=False,
        )
        report(f"DB-{scenario}", result, expected, contains)

    helm_log.write_text("", encoding="utf-8")
    result = subprocess.run(
        ["bash", "scripts/cluster/install-devtron.sh", "--apply"],
        cwd=ROOT,
        env=base_env | {"MOCK_SCENARIO": "failed"},
        capture_output=True,
        text=True,
        check=False,
    )
    report(
        "DB-failed apply",
        result,
        0,
        (f"Devtron {DEVTRON_APP_VERSION}와 번들 Argo CD Ready",),
    )
    helm_calls = [shlex.split(line) for line in helm_log.read_text(encoding="utf-8").splitlines()]
    upgrade = next(
        (
            call
            for call in helm_calls
            if any(call[index : index + 2] == ["upgrade", "--install"] for index in range(len(call)))
        ),
        [],
    )
    managed = {
        "installer.modules={cicd}",
        "argo-cd.enabled=true",
        "components.devtron.service.type=ClusterIP",
    }
    if (
        "--reuse-values" in upgrade
        and "--timeout" in upgrade
        and "1800s" in upgrade
        and managed.issubset(set(upgrade))
        and any(value.startswith("configs.HTTP_PROXY=") for value in upgrade)
        and any(value.startswith("global.configs.NO_PROXY=") for value in upgrade)
    ):
        PASSED += 1
        print("[OK]   DB-failed apply preserves values and reapplies only managed boundary")
    else:
        FAILED += 1
        print(f"[FAIL] DB-failed apply Helm args mismatch: {upgrade}")

    write_executable(
        helm,
        """#!/usr/bin/env bash
set -euo pipefail
[[ " $* " == *" version "* ]] && printf 'v3.16.3+test\\n'
""",
    )
    write_executable(
        kubectl,
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"${MOCK_LOG}"
args=" $* "
if [[ ${args} == *" version --short "* ]]; then printf 'Client Version: test\\n'; exit 0; fi
if [[ ${args} == *" get nodes -o wide "* ]]; then printf 'NAME STATUS\\ncp Ready\\nw1 Ready\\nw2 Ready\\n'; exit 0; fi
if [[ ${args} == *" get nodes -o json "* ]]; then
  if [[ ${MOCK_SCENARIO:-preflight-ok} == preflight-two-nodes ]]; then
    printf '{"items":[{"metadata":{"name":"cp","labels":{"node-role.kubernetes.io/control-plane":"true"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"w1","labels":{}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}\\n'
  elif [[ ${MOCK_SCENARIO:-preflight-ok} == preflight-two-servers ]]; then
    printf '{"items":[{"metadata":{"name":"cp1","labels":{"node-role.kubernetes.io/control-plane":"true"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"cp2","labels":{"node-role.kubernetes.io/control-plane":"true"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"w1","labels":{}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}\\n'
  else
    printf '{"items":[{"metadata":{"name":"cp","labels":{"node-role.kubernetes.io/control-plane":"true"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"w1","labels":{}},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"w2","labels":{}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}\\n'
  fi
  exit 0
fi
if [[ ${args} == *" get storageclass -o json "* ]]; then
  printf '{"items":[{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}]}\\n'; exit 0
fi
if [[ ${args} == *" get storageclass "* ]]; then printf 'NAME\\nlocal-path (default)\\n'; exit 0; fi
if [[ ${args} == *" create namespace sadp-preflight-"* ]]; then exit 0; fi
if [[ ${args} == *" apply -f - "* ]]; then cat >>"${MOCK_APPLY_LOG}"; exit 0; fi
if [[ ${args} == *" wait --for=jsonpath="* ]]; then exit 0; fi
if [[ ${args} == *" delete namespace sadp-preflight-"* ]]; then exit 0; fi
if [[ ${args} == *" top nodes "* ]]; then exit 1; fi
if [[ ${args} == *" get crd applications.argoproj.io "* ]]; then exit 1; fi
exit 0
""",
    )
    log.write_text("", encoding="utf-8")
    apply_log.write_text("", encoding="utf-8")
    result = subprocess.run(
        ["bash", "scripts/cluster/preflight.sh"],
        cwd=ROOT,
        env=base_env | {"MOCK_SCENARIO": "preflight-ok"},
        capture_output=True,
        text=True,
        check=False,
    )
    commands = log.read_text(encoding="utf-8")
    applied = apply_log.read_text(encoding="utf-8")
    report(
        "PF-unique namespace and cleanup",
        result,
        0,
        ("RKE2 노드 3/3 Ready(server 1 + worker 2)", "dynamic provisioning 정상", "원툴 cluster apply"),
    )
    if "create namespace sadp-preflight-" in commands and "delete namespace sadp-preflight-" in commands \
            and " namespace preflight" not in commands:
        PASSED += 1
        print("[OK]   PF-created namespace only is deleted")
    else:
        FAILED += 1
        print("[FAIL] PF namespace lifecycle mismatch")
    if (
        "kind: PersistentVolumeClaim" in applied
        and "kind: Pod" in applied
        and "claimName: preflight-pvc" in applied
    ):
        PASSED += 1
        print("[OK]   PF-WaitForFirstConsumer creates a temporary consumer Pod")
    else:
        FAILED += 1
        print("[FAIL] PF-WaitForFirstConsumer consumer Pod missing")

    log.write_text("", encoding="utf-8")
    result = subprocess.run(
        ["bash", "scripts/cluster/preflight.sh"],
        cwd=ROOT,
        env=base_env | {"MOCK_SCENARIO": "preflight-two-nodes"},
        capture_output=True,
        text=True,
        check=False,
    )
    report("PF-two nodes rejected", result, 1, ("RKE2 노드 수가 계약과 다름: expected=3, actual=2",))

    log.write_text("", encoding="utf-8")
    result = subprocess.run(
        ["bash", "scripts/cluster/preflight.sh"],
        cwd=ROOT,
        env=base_env | {"MOCK_SCENARIO": "preflight-two-servers"},
        capture_output=True,
        text=True,
        check=False,
    )
    report(
        "PF-wrong server/worker topology rejected",
        result,
        1,
        ("RKE2 역할은 server 1대 + worker 2대여야 함: server=2, worker=1",),
    )

platform_installer = (ROOT / "scripts/cluster/install-testbed-platform.sh").read_text(encoding="utf-8")
if "delete namespace preflight" not in platform_installer:
    PASSED += 1
    print("[OK]   PF-platform installer does not delete a foreign preflight namespace")
else:
    FAILED += 1
    print("[FAIL] PF-platform installer still deletes namespace preflight")

print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(1 if FAILED else 0)
