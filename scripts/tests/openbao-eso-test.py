#!/usr/bin/env python3
"""OpenBao seal 사전검사와 ExternalSecret 값 비노출 진단 회귀."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
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


def run_helper(
    fake_bin: pathlib.Path,
    log: pathlib.Path,
    command: str,
    **extra: str,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": f"{fake_bin}:{environment['PATH']}",
            "KUBECTL_BIN": str(fake_bin / "kubectl"),
            "KUBECONFIG_PATH": "/tmp/<PLACEHOLDER>-kubeconfig",
            "MOCK_LOG": str(log),
            "OPENBAO_ACTIVE_WAIT_ATTEMPTS": "1",
            **extra,
        }
    )
    return subprocess.run(
        ["bash", "-c", command],
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


with tempfile.TemporaryDirectory(prefix="sadp-openbao-eso-test-") as temporary:
    work = pathlib.Path(temporary)
    fake_bin = work / "bin"
    fake_bin.mkdir()
    log = work / "kubectl.log"
    state = work / "sealed-state"
    state.write_text("true\n", encoding="utf-8")
    external = work / "external.json"
    store = work / "store.json"

    (fake_bin / "kubectl").write_text(
        r'''#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --kubeconfig ]]; then shift 2; fi
printf '%s\n' "$*" >>"${MOCK_LOG}"
case "$*" in
  "get pod -n openbao openbao-0 -o jsonpath={.status.phase}")
    printf Running
    ;;
  *"bao status -format=json"*)
    sealed=${MOCK_SEALED:-}
    [[ -n ${sealed} ]] || sealed=$(tr -d '\r\n' <"${MOCK_STATE_FILE}")
    printf '{"initialized":true,"sealed":%s,"standby":false}\n' "${sealed}"
    [[ ${sealed} != true ]] || exit 2
    ;;
  *"bao operator unseal"*)
    IFS= read -r _recovery_material
    printf 'false\n' >"${MOCK_STATE_FILE}"
    ;;
  "get endpointslice -n openbao -l kubernetes.io/service-name=openbao-active -o json")
    printf '%s\n' '{"items":[{"endpoints":[{"conditions":{"ready":true},"addresses":["192.0.2.1"]}]}]}'
    ;;
  get\ externalsecret\ -n\ *)
    cat "${MOCK_EXTERNAL_JSON}"
    ;;
  get\ secretstore\ -n\ *)
    cat "${MOCK_STORE_JSON}"
    ;;
  get\ clustersecretstore\ *)
    cat "${MOCK_STORE_JSON}"
    ;;
  wait\ externalsecret/*)
    [[ ${MOCK_EXTERNAL_WAIT_FAIL:-false} != true ]]
    ;;
  wait\ *)
    exit 0
    ;;
  annotate\ externalsecret\ *)
    exit 0
    ;;
  get\ secret\ -n\ *)
    [[ ${MOCK_TARGET_EXISTS:-false} == true ]]
    ;;
  *)
    printf 'unexpected kubectl call: %s\n' "$*" >&2
    exit 97
    ;;
esac
''',
        encoding="utf-8",
    )
    (fake_bin / "kubectl").chmod(0o700)
    (fake_bin / "id").write_text(
        "#!/usr/bin/env bash\n[[ ${1:-} == -u ]] && { echo 0; exit 0; }\nexec /usr/bin/id \"$@\"\n",
        encoding="utf-8",
    )
    (fake_bin / "id").chmod(0o700)
    (fake_bin / "stat").write_text(
        "#!/usr/bin/env bash\n"
        "[[ ${1:-} == -c && ${2:-} == %u ]] && { echo 0; exit 0; }\n"
        "[[ ${1:-} == -c && ${2:-} == %a ]] && { echo 600; exit 0; }\n"
        "exec /usr/bin/stat \"$@\"\n",
        encoding="utf-8",
    )
    (fake_bin / "stat").chmod(0o700)

    source = (
        "source scripts/lib/testbed-common.sh; "
        "source scripts/lib/openbao-eso.sh; "
    )
    result = run_helper(
        fake_bin,
        log,
        source + "openbao_require_unsealed 1s",
        MOCK_SEALED="true",
    )
    output = result.stdout + result.stderr
    calls = log.read_text(encoding="utf-8")
    check(
        result.returncode != 0
        and "sealed 상태" in output
        and "sudo bash ./sadp --unseal-openbao" in output
        and "sudo bash ./sadp --unseal-openbao --apply" in output
        and "externalsecret" not in calls,
        "Running이지만 sealed인 OpenBao는 ExternalSecret 전에 plan/apply 명령과 함께 fail-fast",
    )

    log.write_text("", encoding="utf-8")
    result = run_helper(
        fake_bin,
        log,
        source + "openbao_require_unsealed 1s",
        MOCK_SEALED="false",
    )
    check(
        result.returncode == 0 and "sealed=False" in result.stdout,
        "unsealed OpenBao는 active endpoint와 Pod Ready 뒤 정상 진행",
    )

    for kind in ("SecretStore", "ClusterSecretStore"):
        external.write_text(
            json.dumps(
                {
                    "apiVersion": "external-secrets.io/v1",
                    "kind": "ExternalSecret",
                    "metadata": {"name": "runtime", "namespace": "apps"},
                    "spec": {
                        "secretStoreRef": {"kind": kind, "name": "openbao-runtime"},
                        "target": {"name": "runtime-secret"},
                        "data": [{"remoteRef": {"key": "<PLACEHOLDER>"}}],
                    },
                    "status": {
                        "conditions": [
                            {
                                "type": "Ready",
                                "status": "False",
                                "reason": "SecretSyncedError",
                                "message": "provider returned HTTP 503: Vault is sealed",
                            }
                        ]
                    },
                }
            ),
            encoding="utf-8",
        )
        store.write_text(
            json.dumps(
                {
                    "status": {
                        "conditions": [
                            {
                                "type": "Ready",
                                "status": "True",
                                "reason": "Valid",
                                "message": "store validated",
                            }
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        log.write_text("", encoding="utf-8")
        result = run_helper(
            fake_bin,
            log,
            source + 'wait_external_secret_ready apps runtime 1s',
            MOCK_SEALED="false",
            MOCK_EXTERNAL_JSON=str(external),
            MOCK_STORE_JSON=str(store),
            MOCK_EXTERNAL_WAIT_FAIL="true",
            MOCK_TARGET_EXISTS="false",
        )
        output = result.stdout + result.stderr
        calls = log.read_text(encoding="utf-8")
        check(
            result.returncode != 0
            and f"Store: kind={kind} name=openbao-runtime" in output
            and "Ready: status=False reason=SecretSyncedError" in output
            and "Store Ready: status=True reason=Valid" in output
            and "Target Secret: apps/runtime-secret exists=no" in output,
            f"timeout 진단은 {kind} 참조와 양쪽 Ready condition 및 대상 존재 여부를 자동 판별",
        )
        check(
            "force-sync=" in calls
            and "kubectl annotate externalsecret" in output
            and "kubectl wait" in output
            and "--apply 명령은 생략" in output,
            f"{kind} timeout은 force-sync 뒤 실제 이름의 값 비노출 복구 순서를 출력",
        )
        secret_get_calls = [line for line in calls.splitlines() if line.startswith("get secret -n")]
        check(
            "<PLACEHOLDER>" not in output
            and secret_get_calls
            and all(" -o " not in line for line in secret_get_calls)
            and "Secret data는 읽거나 출력하지 않았음" in output,
            f"{kind} 진단은 Secret 본문 대신 객체 존재 여부만 확인",
        )

    state_dir = work / "state"
    state_dir.mkdir()
    init_file = state_dir / "openbao-init.json"
    init_file.write_text(
        json.dumps(
            {
                "unseal_threshold": 1,
                "unseal_keys_b64": ["<PLACEHOLDER>"],
                "root_token": "<PLACEHOLDER>",
            }
        ),
        encoding="utf-8",
    )
    init_file.chmod(0o600)
    state.write_text("true\n", encoding="utf-8")
    log.write_text("", encoding="utf-8")
    result = run_helper(
        fake_bin,
        log,
        "bash scripts/ops/unseal-openbao.sh --apply",
        SADP_STATE_DIR=str(state_dir),
        MOCK_STATE_FILE=str(state),
    )
    output = result.stdout + result.stderr
    check(
        result.returncode == 0
        and state.read_text(encoding="utf-8").strip() == "false"
        and "unseal 완료" in output
        and "<PLACEHOLDER>" not in output,
        "명시적 --apply만 root-only 재료를 stdin으로 전달하고 값 없이 active/Ready를 재확인",
    )

deploy_text = (ROOT / "scripts/cluster/deploy-testbed-apps.sh").read_text(encoding="utf-8")
portal_text = (ROOT / "scripts/cluster/install-portal-backend.sh").read_text(encoding="utf-8")
bootstrap_text = (ROOT / "scripts/cluster/bootstrap-testbed-services.sh").read_text(
    encoding="utf-8"
)
check(
    deploy_text.index("openbao_require_unsealed")
    < deploy_text.index("bao_root_input write")
    < deploy_text.index("wait_external_secret_ready")
    < deploy_text.index("render_apply_workload hello")
    < deploy_text.index('rollout restart -n "${WORKLOAD_NAMESPACE}" deployment/${deployment}'),
    "앱 bootstrap은 OpenBao 검사→KV→Store/force-sync/Ready/Secret→workload rollout 순서를 고정",
)
check(
    portal_text.index("openbao_require_unsealed")
    < portal_text.index("wait_external_secret_ready")
    < portal_text.index("apply_release true")
    < portal_text.rindex("\nwait_workload_ready\n"),
    "Portal 개별 설치도 OpenBao/ESO/대상 Secret 확인 뒤에만 Deployment를 apply하고 기다림",
)
check(
    bootstrap_text.index("openbao_require_unsealed") < bootstrap_text.index("bao audit list")
    and "for index in 0 1" not in bootstrap_text,
    "OpenBao policy/KV bootstrap은 sealed 사전검사 뒤에만 실행되고 자동 unseal 경로가 없음",
)

print(f"\n총 {passed + failed}건: {passed} 통과, {failed} 실패")
raise SystemExit(1 if failed else 0)
