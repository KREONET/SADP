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


def run_case(contract: pathlib.Path, secret: pathlib.Path, log: pathlib.Path, scenario: str):
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
kctl() {
  case "$*" in
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
    exec\ -n\ openbao\ openbao-0\ --*)
      case "${OIDC_TEST_SCENARIO}" in
        timeout)
          printf '%s\n' '__SADP_HTTP_STATUS__:000' '__SADP_CURL_EXIT__:28'
          ;;
        issuer-mismatch)
          printf '%s\n' '{"issuer":"https://wrong.example.invalid/application/o/sadp"}' \
            '__SADP_HTTP_STATUS__:200' '__SADP_CURL_EXIT__:0'
          ;;
        *)
          printf '%s\n' '{"issuer":"https://idp.example.invalid/application/o/sadp"}' \
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
      jq -nc --arg client "${OIDC_OPENBAO_CLIENT_ID}" '{data:{oidc_discovery_url:"https://idp.example.invalid/application/o/sadp",oidc_client_id:$client,default_role:"user"}}'
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
                        "issuer": "https://idp.example.invalid/application/o/sadp",
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
        and applied.get("oidc_discovery_url")
        == "https://idp.example.invalid/application/o/sadp"
        and output.count("기존 OpenBao OIDC 공개 설정 일치") == 2,
        "정상 기존 설정은 Secret을 출력하지 않고 반복 실행해 같은 최종 상태로 수렴한다",
        output,
    )
    check(
        "<PLACEHOLDER>\n" not in output and "oidc_client_secret" not in output,
        "OIDC client Secret과 config 본문을 로그에 출력하지 않는다",
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
