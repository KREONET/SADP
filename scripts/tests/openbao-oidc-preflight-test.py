#!/usr/bin/env python3
"""OpenBao OIDC Gateway/TLS/discovery fail-closed 및 멱등 수렴 회귀."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
passed = 0
failed = 0


def check(condition: bool, message: str, detail: str = "") -> None:
    global passed, failed
    if condition:
        passed += 1
        print(f"[OK]   {message}")
    else:
        failed += 1
        print(f"[FAIL] {message}{': ' + detail if detail else ''}")


ISSUER = "https://idp.example.invalid/application/o/sadp/"
DISCOVERY_URL = "https://idp.example.invalid/application/o/sadp/.well-known/openid-configuration"


def aux(log: pathlib.Path, suffix: str) -> pathlib.Path:
    return pathlib.Path(f"{log}.{suffix}")


def run_case(contract: pathlib.Path, secret: pathlib.Path, log: pathlib.Path, scenario: str):
    # 앞 사례의 config write 흔적이 뒤 사례의 "write 전에 중단" 판정을 가리지 않게 매번 지운다.
    for path in (log, aux(log, "last-body"), aux(log, "exec-url"), aux(log, "kctl")):
        path.unlink(missing_ok=True)
    environment = os.environ.copy()
    environment.update(
        {
            "SADP_OIDC_CONTRACT_PATH": str(contract),
            "OIDC_TEST_SECRET": str(secret),
            "OIDC_TEST_LOG": str(log),
            "OIDC_TEST_SCENARIO": scenario,
        }
    )
    command = r'''
source scripts/lib/testbed-common.sh
source scripts/lib/openbao-oidc.sh
oidc_mock_sts() {
  local containers='[{"name":"openbao","image":"openbao"},{"name":"oidc-preflight","image":"docker.io/curlimages/curl:8.21.0"}]'
  [[ ${OIDC_TEST_SCENARIO} != template-missing ]] || containers='[{"name":"openbao","image":"openbao"}]'
  jq -nc --argjson containers "${containers}" '{
    metadata:{name:"openbao"},
    spec:{updateStrategy:{type:"OnDelete"},template:{spec:{containers:$containers}}},
    status:{updateRevision:"openbao-new"}}'
}
oidc_mock_pod() {
  local revision=openbao-new
  local containers='[{"name":"openbao"},{"name":"oidc-preflight"}]'
  local statuses='[{"name":"openbao","ready":true},{"name":"oidc-preflight","ready":true,"state":{"running":{}}}]'
  case "${OIDC_TEST_SCENARIO}" in
    template-missing|pod-stale-revision)
      revision=openbao-old
      containers='[{"name":"openbao"}]'
      statuses='[{"name":"openbao","ready":true}]'
      ;;
    image-pull-backoff)
      statuses='[{"name":"openbao","ready":true},{"name":"oidc-preflight","ready":false,"state":{"waiting":{"reason":"ImagePullBackOff","message":"pull <PLACEHOLDER> from registry.example.invalid denied"}}}]'
      ;;
  esac
  jq -nc --arg revision "${revision}" --argjson containers "${containers}" \
    --argjson statuses "${statuses}" '{
      metadata:{name:"openbao-0",labels:{"controller-revision-hash":$revision},
        ownerReferences:[{kind:"StatefulSet",name:"openbao"}]},
      spec:{containers:$containers},
      status:{containerStatuses:$statuses}}'
}
kctl() {
  printf '%s\n' "$*" >>"${OIDC_TEST_LOG}.kctl"
  case "$*" in
    "get pod -n openbao openbao-0 -o json") oidc_mock_pod ;;
    "get statefulset -n openbao openbao -o json") oidc_mock_sts ;;
    "get certificate -n gateway-system wildcard-tls -o json")
      printf '%s\n' '{"spec":{"secretName":"wildcard-tls"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}'
      ;;
    "get secret -n gateway-system wildcard-tls -o json")
      printf '%s\n' '{"type":"kubernetes.io/tls","data":{"tls.crt":"PFBMQUNFSE9MREVS\n","tls.key":"PFBMQUNFSE9MREVS\n"}}'
      ;;
    "get gateway -n gateway-system gateway -o json")
      if [[ ${OIDC_TEST_SCENARIO} == gateway-unready ]]; then
        printf '%s\n' '{"spec":{"listeners":[{"name":"https","protocol":"HTTPS","port":443,"tls":{"certificateRefs":[{"name":"wildcard-tls"}]}}]},"status":{"listeners":[{"name":"https","conditions":[{"type":"Accepted","status":"False","reason":"InvalidCertificateRef"},{"type":"Programmed","status":"False","reason":"InvalidCertificateRef"}]}]}}'
      else
        printf '%s\n' '{"spec":{"listeners":[{"name":"https","protocol":"HTTPS","port":443,"tls":{"certificateRefs":[{"name":"wildcard-tls"}]}}]},"status":{"listeners":[{"name":"https","conditions":[{"type":"Accepted","status":"True","reason":"Accepted"},{"type":"Programmed","status":"True","reason":"Programmed"}]}]}}'
      fi
      ;;
    "get service -n gateway-system -l gateway.envoyproxy.io/owning-gateway-name=gateway -o json")
      printf '%s\n' '{"items":[{"spec":{"ports":[{"port":443}]}}]}'
      ;;
    exec\ -n\ openbao\ openbao-0\ -c\ oidc-preflight\ --*)
      printf '%s\n' "${@: -1}" >"${OIDC_TEST_LOG}.exec-url"
      case "${OIDC_TEST_SCENARIO}" in
        exec-container-not-found)
          printf '%s\n' 'error: unable to upgrade connection: container not found ("oidc-preflight") https://10.20.30.21:10250/exec/<PLACEHOLDER>' >&2
          return 1
          ;;
        timeout)
          printf '%s\n' '__SADP_HTTP_STATUS__:000' '__SADP_CURL_EXIT__:28'
          ;;
        issuer-mismatch)
          printf '%s\n' '{"issuer":"https://wrong.example.invalid/application/o/sadp/"}' \
            '__SADP_HTTP_STATUS__:200' '__SADP_CURL_EXIT__:0'
          ;;
        issuer-slash-stripped)
          # 끝 '/'만 다른 issuer도 불일치다. 정규화 비교로 되돌아가면 이 사례가 통과해 버린다.
          printf '%s\n' '{"issuer":"https://idp.example.invalid/application/o/sadp"}' \
            '__SADP_HTTP_STATUS__:200' '__SADP_CURL_EXIT__:0'
          ;;
        *)
          printf '%s\n' '{"issuer":"https://idp.example.invalid/application/o/sadp/"}' \
            '__SADP_HTTP_STATUS__:200' '__SADP_CURL_EXIT__:0'
          ;;
      esac
      ;;
    *)
      printf 'unexpected kctl call: %s\n' "$*" >&2
      return 97
      ;;
  esac
}
bao() {
  case "$*" in
    "auth list -format=json") printf '%s\n' '{"oidc/":{"type":"oidc"}}' ;;
    "read auth/oidc/config -format=json")
      jq -nc --arg client "${OIDC_OPENBAO_CLIENT_ID}" '{data:{oidc_discovery_url:"https://idp.example.invalid/application/o/sadp/",oidc_client_id:$client,default_role:"user"}}'
      ;;
    "read auth/oidc/role/user -format=json")
      printf '%s\n' '{"data":{"role_type":"oidc","user_claim":"preferred_username"}}'
      ;;
    *) printf 'unexpected bao call: %s\n' "$*" >&2; return 96 ;;
  esac
}
bao_input() {
  local body
  body=$(cat)
  printf '%s\n' "$*" >>"${OIDC_TEST_LOG}"
  printf '%s' "${body}" >"${OIDC_TEST_LOG}.last-body"
}
oidc_load_contract
oidc_gateway_tls_preflight
oidc_discovery_preflight
oidc_apply_config "${OIDC_TEST_SECRET}"
if [[ ${OIDC_TEST_SCENARIO} == success-twice ]]; then
  oidc_apply_config "${OIDC_TEST_SECRET}"
fi
'''
    return subprocess.run(
        ["bash", "-c", command],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


with tempfile.TemporaryDirectory(prefix="sadp-openbao-oidc-test-") as temporary:
    work = pathlib.Path(temporary)
    contract = work / "contract.yaml"
    secret = work / "client-secret"
    log = work / "bao-input.log"
    contract.write_text(
        yaml.safe_dump(
            {
                "apiVersion": "platform.example.io/v1alpha1",
                "kind": "PlatformContract",
                "spec": {
                    "gateway": {
                        "namespace": "gateway-system",
                        "name": "gateway",
                        "httpsListener": "https",
                        "routeListener": "https",
                        "wildcardTlsSecret": "wildcard-tls",
                    },
                    "tls": {"source": "acme", "issuerMode": "production"},
                    "identityProvider": {
                        "managed": "external",
                        "sourceProtocol": "openid",
                        "issuer": ISSUER,
                        "groupsClaim": "groups",
                    },
                    "openbao": {"namespace": "openbao"},
                },
                "status": {"wildcardTls": "ready"},
            },
            sort_keys=False,
        ),
        encoding="utf-8",
    )
    secret.write_text("<PLACEHOLDER>\n", encoding="utf-8")
    secret.chmod(0o600)

    result = run_case(contract, secret, log, "gateway-unready")
    output = result.stdout + result.stderr
    check(
        result.returncode != 0
        and "InvalidCertificateRef" in output
        and not log.exists(),
        "Gateway TLS 미준비면 auth/oidc/config API를 호출하지 않는다",
        output,
    )

    result = run_case(contract, secret, log, "timeout")
    output = result.stdout + result.stderr
    check(
        result.returncode != 0
        and "OIDC discovery timeout" in output
        and not log.exists(),
        "OpenBao Pod discovery timeout을 구분하고 config write 전에 중단한다",
        output,
    )

    result = run_case(contract, secret, log, "issuer-mismatch")
    output = result.stdout + result.stderr
    check(
        result.returncode != 0
        and "issuer 불일치" in output
        and "HTTP 200" in output
        and not log.exists(),
        "HTTP 200 JSON이어도 issuer가 다르면 config write 전에 실패한다",
        output,
    )

    result = run_case(contract, secret, log, "success-twice")
    output = result.stdout + result.stderr
    calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
    last_body = pathlib.Path(f"{log}.last-body")
    applied = json.loads(last_body.read_text(encoding="utf-8")) if last_body.exists() else {}
    check(
        result.returncode == 0
        and calls == ["write auth/oidc/config -", "write auth/oidc/config -"]
        and applied.get("oidc_discovery_url") == ISSUER
        and output.count("기존 OpenBao OIDC 공개 설정 일치") == 2,
        "정상 기존 설정은 Secret을 출력하지 않고 반복 실행해 같은 최종 상태로 수렴한다",
        output,
    )
    check(
        "<PLACEHOLDER>\n" not in output and "oidc_client_secret" not in output,
        "OIDC client Secret과 config 본문을 로그에 출력하지 않는다",
        output,
    )

    exec_url = aux(log, "exec-url")
    check(
        exec_url.exists() and exec_url.read_text(encoding="utf-8").strip() == DISCOVERY_URL,
        "issuer 끝 '/'는 보존하고 discovery URL만 `${issuer%/}`로 만든다(이중 '/' 없음)",
        exec_url.read_text(encoding="utf-8") if exec_url.exists() else "exec 미호출",
    )

    result = run_case(contract, secret, log, "issuer-slash-stripped")
    output = result.stdout + result.stderr
    check(
        result.returncode != 0 and "issuer 불일치" in output and not log.exists(),
        "끝 '/'만 다른 discovery issuer도 config write 전에 거부한다",
        output,
    )

    def diagnosed(scenario: str, expected: tuple[str, ...], *, exec_expected: bool) -> None:
        result = run_case(contract, secret, log, scenario)
        output = result.stdout + result.stderr
        kctl_calls = aux(log, "kctl").read_text(encoding="utf-8") if aux(log, "kctl").exists() else ""
        exec_called = any(line.startswith("exec ") for line in kctl_calls.splitlines())
        missing = [item for item in expected if item not in output]
        check(
            result.returncode != 0
            and not missing
            and not log.exists()
            and exec_called == exec_expected
            and "delete" not in kctl_calls
            and "<PLACEHOLDER>" not in output
            and "registry.example.invalid" not in output
            and "10.20.30.21" not in output,
            f"{scenario}: 원인·안내만 값 없이 출력하고 Pod 자동 삭제·config write 없이 중단",
            f"missing={missing} exec_called={exec_called}\n{output}",
        )

    diagnosed(
        "template-missing",
        ("템플릿에 oidc-preflight 컨테이너가 없음", "proxy-values.yaml", "Argo openbao Application"),
        exec_expected=False,
    )
    diagnosed(
        "pod-stale-revision",
        (
            "OnDelete라 기존 Pod openbao-0가 새 템플릿",
            "delete pod openbao-0",
            "PVC",
            "sudo bash ./sadp --unseal-openbao --apply",
            "자동 삭제하지 않는다",
            "controller-revision-hash",
            "updateStrategy.type",
        ),
        exec_expected=False,
    )
    diagnosed(
        "image-pull-backoff",
        (
            "waiting.reason=ImagePullBackOff",
            "sudo bash ./sadp --sync-images --image docker.io/curlimages/curl:8.21.0",
        ),
        exec_expected=False,
    )
    diagnosed(
        "exec-container-not-found",
        ("oidc-preflight 컨테이너가 Pod에 없음", "OnDelete"),
        exec_expected=True,
    )

    def lag_report(pod_revision: str) -> subprocess.CompletedProcess:
        command = r'''
source scripts/lib/testbed-common.sh
source scripts/lib/openbao-oidc.sh
kctl() {
  case "$*" in
    "get statefulset -n openbao -o json")
      printf '%s\n' '{"items":[{"metadata":{"name":"openbao"},"spec":{"updateStrategy":{"type":"OnDelete"}},"status":{"updateRevision":"openbao-new"}}]}'
      ;;
    "get pod -n openbao -o json")
      jq -nc --arg revision "${LAG_POD_REVISION}" '{items:[
        {metadata:{name:"openbao-0",labels:{"controller-revision-hash":$revision},ownerReferences:[{kind:"StatefulSet",name:"openbao"}]}},
        {metadata:{name:"openbao-1",labels:{"controller-revision-hash":"openbao-new"},ownerReferences:[{kind:"StatefulSet",name:"openbao"}]}}]}'
      ;;
    *) printf 'unexpected kctl call: %s\n' "$*" >&2; return 97 ;;
  esac
}
openbao_report_ondelete_revision_lag openbao
'''
        return subprocess.run(
            ["bash", "-c", command], cwd=ROOT, capture_output=True, text=True, check=False,
            env=dict(os.environ, LAG_POD_REVISION=pod_revision),
        )

    result = lag_report("openbao-old")
    output = result.stdout + result.stderr
    check(
        result.returncode == 0
        and "[WARN] openbao/openbao: updateStrategy=OnDelete라 Pod openbao-0가 옛 revision" in output
        and "openbao-1" not in output
        and "--unseal-openbao --apply" in output,
        "OnDelete StatefulSet의 뒤처진 Pod만 [WARN]으로 보고하고 실패로 만들지 않는다",
        output,
    )
    result = lag_report("openbao-new")
    output = result.stdout + result.stderr
    check(
        result.returncode == 0 and "[WARN]" not in output and "최신 revision" in output,
        "모든 OnDelete Pod가 최신 revision이면 경고하지 않는다",
        output,
    )

    shared_contract = yaml.safe_load(contract.read_text())
    shared_contract["spec"]["identityProvider"]["sharedClientID"] = "Authentik.Shared_123"
    contract.write_text(yaml.safe_dump(shared_contract))
    result = run_case(contract, secret, log, "success-twice")
    applied = json.loads(last_body.read_text())
    check(result.returncode == 0 and applied["oidc_client_id"] == "Authentik.Shared_123",
          "공통 Provider ID를 OpenBao 적용과 재검증에 동일하게 사용", result.stdout + result.stderr)

print(f"\nOpenBao OIDC preflight tests: {passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
