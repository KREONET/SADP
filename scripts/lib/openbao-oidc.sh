#!/usr/bin/env bash
# OpenBao OIDC 설정 전에 외부 HTTPS 경로의 완료 증거를 값 비노출 방식으로 검증한다.
# 이 파일은 source 전용이며 호출자는 testbed-common.sh와 bao/bao_input 함수를 준비한다.
set -euo pipefail

oidc_print_gateway_checks() {
  cat >&2 <<EOF
[ACTION] 값 비노출 확인 명령:
  kubectl -n ${OIDC_GATEWAY_NAMESPACE} get certificate ${OIDC_CERTIFICATE_NAME} -o jsonpath='{.status.conditions}{"\n"}'
  kubectl -n ${OIDC_GATEWAY_NAMESPACE} get secret ${OIDC_TLS_SECRET} -o name
  kubectl -n ${OIDC_GATEWAY_NAMESPACE} get gateway ${OIDC_GATEWAY_NAME} -o jsonpath='{.status.listeners}{"\n"}'
  kubectl -n ${OIDC_GATEWAY_NAMESPACE} get svc -l gateway.envoyproxy.io/owning-gateway-name=${OIDC_GATEWAY_NAME} -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.ports[*].port}{"\n"}{end}'
EOF
}

oidc_print_discovery_checks() {
  cat >&2 <<EOF
[ACTION] 값 비노출 확인 명령:
  kubectl -n ${OIDC_OPENBAO_NAMESPACE} exec ${OIDC_OPENBAO_POD} -- sh -c 'nslookup "\$1" >/dev/null' sh ${OIDC_ISSUER_HOST}
  kubectl -n ${OIDC_OPENBAO_NAMESPACE} exec ${OIDC_OPENBAO_POD} -- sh -c 'wget -T 15 -S -O /dev/null "\$1"' sh '${OIDC_DISCOVERY_URL}'
  kubectl -n ${OIDC_GATEWAY_NAMESPACE} get gateway ${OIDC_GATEWAY_NAME} -o jsonpath='{.status.listeners}{"\n"}'
EOF
}

oidc_preflight_failure() {
  local cause=$1 action=$2 checks=${3:-gateway}
  printf '[FAIL] OpenBao OIDC preflight: %s\n' "${cause}" >&2
  printf '[ACTION] %s\n' "${action}" >&2
  if [[ ${checks} == discovery ]]; then
    oidc_print_discovery_checks
  else
    oidc_print_gateway_checks
  fi
  return 1
}

oidc_load_contract() {
  local contract_path=${SADP_OIDC_CONTRACT_PATH:-${TESTBED_ROOT}/contracts/platform-production.yaml}
  local contract_output
  local -a values
  contract_output=$(python3 - "${contract_path}" <<'PY'
import sys
from urllib.parse import urlsplit

import yaml

document = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
spec = document.get("spec") or {}
status = document.get("status") or {}
gateway = spec.get("gateway") or {}
tls = spec.get("tls") or {}
identity = spec.get("identityProvider") or {}
openbao = spec.get("openbao") or {}

issuer = str(identity.get("issuer") or "").rstrip("/")
parsed = urlsplit(issuer)
if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
    raise SystemExit("[FAIL] spec.identityProvider.issuer는 credential 없는 HTTPS URL이어야 한다")
if parsed.query or parsed.fragment:
    raise SystemExit("[FAIL] spec.identityProvider.issuer에는 query/fragment를 둘 수 없다")

source = str(tls.get("source") or "")
mode = str(tls.get("issuerMode") or "")
secret = str(gateway.get("wildcardTlsSecret") or "")
certificate = secret
if source == "acme" and mode != "production":
    certificate += "-staging"

resolved = (
    ("wildcard-status", str(status.get("wildcardTls") or "")),
    ("tls-source", source),
    ("issuer-mode", mode),
    ("gateway-namespace", str(gateway.get("namespace") or "")),
    ("gateway-name", str(gateway.get("name") or "")),
    ("https-listener", str(gateway.get("httpsListener") or "")),
    ("route-listener", str(gateway.get("routeListener") or "")),
    ("tls-secret", secret),
    ("certificate", certificate),
    ("issuer", issuer),
    ("issuer-host", parsed.hostname),
    ("openbao-namespace", str(openbao.get("namespace") or "openbao")),
)
for label, value in resolved:
    if not value:
        raise SystemExit(f"[FAIL] OIDC preflight 계약값 누락: {label}")
    print(value)
PY
  ) || return 1
  mapfile -t values <<<"${contract_output}"

  OIDC_WILDCARD_STATUS=${values[0]}
  OIDC_TLS_SOURCE=${values[1]}
  OIDC_ISSUER_MODE=${values[2]}
  OIDC_GATEWAY_NAMESPACE=${values[3]}
  OIDC_GATEWAY_NAME=${values[4]}
  OIDC_HTTPS_LISTENER=${values[5]}
  OIDC_ROUTE_LISTENER=${values[6]}
  OIDC_TLS_SECRET=${values[7]}
  OIDC_CERTIFICATE_NAME=${values[8]}
  OIDC_EXPECTED_ISSUER=${values[9]}
  OIDC_ISSUER_HOST=${values[10]}
  OIDC_OPENBAO_NAMESPACE=${values[11]}
  OIDC_OPENBAO_POD=${SADP_OPENBAO_POD:-openbao-0}
  OIDC_DISCOVERY_URL="${OIDC_EXPECTED_ISSUER}/.well-known/openid-configuration"
}

oidc_gateway_tls_preflight() {
  local certificate gateway services

  [[ ${OIDC_WILDCARD_STATUS} == ready ]] || oidc_preflight_failure \
    "site.env에서 파생된 wildcard TLS 완료 상태가 ready가 아님" \
    "Certificate Ready를 실제 확인한 뒤 EXISTING_GATEWAY_TLS_READY=true로 갱신하고 render→commit/push→cluster를 순서대로 다시 실행하라." || return 1
  [[ ${OIDC_ROUTE_LISTENER} == "${OIDC_HTTPS_LISTENER}" ]] || oidc_preflight_failure \
    "계약의 routeListener가 HTTPS listener를 가리키지 않음" \
    "TLS 완료 상태와 route renderer 동기화를 복구한 뒤 OIDC 단계부터 재실행하라." || return 1
  if [[ ${OIDC_TLS_SOURCE} == acme && ${OIDC_ISSUER_MODE} != production ]]; then
    oidc_preflight_failure "ACME issuer가 production 단계가 아님" \
      "staging Certificate 검증을 끝내고 production Certificate Ready 증거까지 확보한 뒤 OIDC를 적용하라." || return 1
  fi

  if [[ ${OIDC_TLS_SOURCE} == acme ]]; then
    certificate=$(kctl get certificate -n "${OIDC_GATEWAY_NAMESPACE}" \
      "${OIDC_CERTIFICATE_NAME}" -o json 2>/dev/null) || oidc_preflight_failure \
        "wildcard Certificate가 없음" \
        "cert-manager Application과 platform/cert-manager/resources.yaml 동기화를 확인하라." || return 1
    jq -e --arg secret "${OIDC_TLS_SECRET}" '
      .spec.secretName == $secret
      and any(.status.conditions[]?; .type == "Ready" and .status == "True")
    ' <<<"${certificate}" >/dev/null || oidc_preflight_failure \
      "wildcard Certificate가 Ready가 아니거나 대상 TLS Secret 이름이 계약과 다름" \
      "Order/Challenge condition과 authoritative DNS-01 경로를 먼저 복구하라." || return 1
  else
    note "provided TLS: cert-manager Certificate 대신 검증된 대상 TLS Secret을 완료 증거로 사용"
  fi

  kctl get secret -n "${OIDC_GATEWAY_NAMESPACE}" "${OIDC_TLS_SECRET}" -o json 2>/dev/null \
    | jq -e '
        .type == "kubernetes.io/tls"
        and ((.data["tls.crt"] // "") | length > 0)
        and ((.data["tls.key"] // "") | length > 0)
      ' >/dev/null || oidc_preflight_failure \
        "인증서 Secret이 없거나 TLS keypair가 완전하지 않음" \
        "Secret 본문을 출력하지 말고 객체 존재와 Certificate의 spec.secretName만 확인하라." || return 1

  gateway=$(kctl get gateway -n "${OIDC_GATEWAY_NAMESPACE}" \
    "${OIDC_GATEWAY_NAME}" -o json 2>/dev/null) || oidc_preflight_failure \
      "Gateway가 없음" "노출 renderer 결과와 Gateway Application 동기화를 확인하라." || return 1
  if jq -e --arg listener "${OIDC_HTTPS_LISTENER}" '
      any(.status.listeners[]?;
        .name == $listener
        and any(.conditions[]?; .reason == "InvalidCertificateRef"))
    ' <<<"${gateway}" >/dev/null; then
    oidc_preflight_failure "Gateway HTTPS listener에 InvalidCertificateRef가 있음" \
      "listener certificateRefs와 같은 Namespace의 대상 TLS Secret을 복구하라." || return 1
  fi
  jq -e --arg listener "${OIDC_HTTPS_LISTENER}" --arg secret "${OIDC_TLS_SECRET}" '
    any(.spec.listeners[]?;
      .name == $listener and .protocol == "HTTPS" and .port == 443
      and any(.tls.certificateRefs[]?;
        (.group // "") == "" and (.kind // "Secret") == "Secret" and .name == $secret))
    and any(.status.listeners[]?;
      .name == $listener
      and any(.conditions[]?; .type == "Accepted" and .status == "True")
      and any(.conditions[]?; .type == "Programmed" and .status == "True"))
  ' <<<"${gateway}" >/dev/null || oidc_preflight_failure \
    "Gateway HTTPS listener가 Accepted/Programmed가 아니거나 인증서 참조가 계약과 다름" \
    "Gateway listener condition을 확인하고 InvalidCertificateRef/route renderer drift를 먼저 복구하라." || return 1

  services=$(kctl get service -n "${OIDC_GATEWAY_NAMESPACE}" \
    -l "gateway.envoyproxy.io/owning-gateway-name=${OIDC_GATEWAY_NAME}" -o json 2>/dev/null) \
    || oidc_preflight_failure "Gateway Service를 조회할 수 없음" \
      "Envoy Gateway controller와 owning-gateway label을 확인하라." || return 1
  jq -e 'any(.items[]?; any(.spec.ports[]?; .port == 443))' <<<"${services}" >/dev/null \
    || oidc_preflight_failure "Gateway Service에 443 포트가 없음" \
      "HTTPS listener가 실제 Envoy Service 443으로 반영될 때까지 OIDC 설정을 시작하지 마라." || return 1

  ok "wildcard Certificate/TLS Secret/Gateway HTTPS listener/Service 443 완료 증거 확인"
}

oidc_discovery_preflight() {
  local run_dir response errors status curl_exit actual_issuer action cause
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/sadp-oidc-discovery.XXXXXX")
  chmod 0700 "${run_dir}"
  response=${run_dir}/response
  errors=${run_dir}/errors
  : >"${response}"
  : >"${errors}"
  chmod 0600 "${response}" "${errors}"

  if ! kctl exec -n "${OIDC_OPENBAO_NAMESPACE}" "${OIDC_OPENBAO_POD}" -- \
      sh -ceu '
        if command -v curl >/dev/null 2>&1; then
          set +e
          curl --silent --show-error --proto "=https" --tlsv1.2 \
            --connect-timeout 5 --max-time 15 --output - \
            --write-out "\n__SADP_HTTP_STATUS__:%{http_code}\n" "$1"
          result=$?
          printf "__SADP_CURL_EXIT__:%s\n" "${result}"
          exit 0
        fi
        if command -v wget >/dev/null 2>&1; then
          diagnostic=$(mktemp)
          trap '\''rm -f "${diagnostic}"'\'' EXIT
          set +e
          wget -T 15 -S -O - "$1" 2>"${diagnostic}"
          result=$?
          set -e
          status=$(sed -n '\''s/.*HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p'\'' "${diagnostic}" | tail -n1)
          if grep -qiE '\''bad address|name or service not known|temporary failure in name resolution'\'' "${diagnostic}"; then
            result=6
          elif grep -qiE '\''connection refused|refused'\'' "${diagnostic}"; then
            result=7
          elif grep -qiE '\''timed? out|timeout'\'' "${diagnostic}"; then
            result=28
          elif grep -qiE '\''certificate|tls|ssl|not trusted'\'' "${diagnostic}"; then
            result=60
          elif [[ -n ${status} ]]; then
            # HTTP 오류도 transport 자체는 성공이다. host가 본문을 버리고 status만 분류한다.
            result=0
          fi
          printf "\n__SADP_HTTP_STATUS__:%s\n" "${status:-000}"
          printf "__SADP_CURL_EXIT__:%s\n" "${result}"
          exit 0
        fi
        printf "__SADP_CURL_EXIT__:90\n"
      ' sh "${OIDC_DISCOVERY_URL}" >"${response}" 2>"${errors}"; then
    rm -rf "${run_dir}"
    oidc_preflight_failure "OpenBao Pod exec 실패" \
      "OpenBao Pod Running/Ready와 kubectl exec 권한을 확인하라." discovery
    return 1
  fi

  status=$(sed -n 's/^__SADP_HTTP_STATUS__://p' "${response}" | tail -n1)
  curl_exit=$(sed -n 's/^__SADP_CURL_EXIT__://p' "${response}" | tail -n1)
  sed '/^__SADP_HTTP_STATUS__:/,$d' "${response}" >"${run_dir}/body"
  chmod 0600 "${run_dir}/body"

  case "${curl_exit:-unknown}" in
    0) ;;
    5|6)
      rm -rf "${run_dir}"
      oidc_preflight_failure "DNS 해석 실패" \
        "OpenBao Pod의 CoreDNS 응답과 OIDC issuer split-horizon 레코드를 복구하라." discovery
      return 1
      ;;
    7)
      rm -rf "${run_dir}"
      oidc_preflight_failure "OIDC HTTPS endpoint 연결 거부" \
        "외부 OIDC endpoint와 Gateway listener/Service 443의 실제 backend 준비 상태를 확인하라." discovery
      return 1
      ;;
    28)
      rm -rf "${run_dir}"
      oidc_preflight_failure "OIDC discovery timeout" \
        "OpenBao Pod→Gateway 443 경로, NetworkPolicy, endpoint 준비 상태를 확인하라." discovery
      return 1
      ;;
    35|51|53|58|59|60|66|77|80|82|83|90|91)
      if [[ ${curl_exit} == 90 ]]; then
        action="OpenBao image에 curl 또는 HTTPS wget이 필요하다. image/버전을 저장소 계약으로 보강한 뒤 재배포하라."
      else
        action="wildcard 인증서 SAN/신뢰 체인/만료와 OpenBao Pod의 CA trust를 복구하라."
      fi
      rm -rf "${run_dir}"
      oidc_preflight_failure "TLS 인증서/CA 검증 실패" "${action}" discovery
      return 1
      ;;
    *)
      # curl/kubectl 원문은 URL이나 응답 내용을 포함할 수 있어 분류 밖 오류도 그대로 출력하지 않는다.
      if grep -qi 'no route to host' "${errors}"; then
        cause="OIDC HTTPS endpoint로 가는 route 없음"
      elif grep -qiE 'timed? out|timeout' "${errors}"; then
        cause="OIDC discovery timeout"
      elif grep -qiE 'connection refused|refused' "${errors}"; then
        cause="OIDC HTTPS endpoint 연결 거부"
      else
        cause="OIDC HTTPS client 실행 실패"
      fi
      rm -rf "${run_dir}"
      oidc_preflight_failure "${cause}" \
        "OpenBao Pod의 DNS, CA trust, NetworkPolicy와 Gateway 443 상태를 순서대로 확인하라." discovery
      return 1
      ;;
  esac

  if [[ ${status:-000} != 200 ]]; then
    rm -rf "${run_dir}"
    oidc_preflight_failure "OIDC discovery HTTP 오류(status=${status:-000})" \
      "응답 본문을 출력하지 말고 외부 OIDC issuer route와 readiness를 확인하라." discovery
    return 1
  fi
  if ! jq -e 'type == "object"' "${run_dir}/body" >/dev/null 2>&1; then
    rm -rf "${run_dir}"
    oidc_preflight_failure "OIDC discovery 응답이 JSON 문서가 아님" \
      "Gateway가 계약의 OIDC issuer 대신 다른 backend를 가리키는지 확인하라." discovery
    return 1
  fi
  actual_issuer=$(jq -r '.issuer // empty' "${run_dir}/body")
  rm -rf "${run_dir}"
  [[ ${actual_issuer} == "${OIDC_EXPECTED_ISSUER}" ]] || oidc_preflight_failure \
    "OIDC issuer 불일치(HTTP 200 응답도 거부)" \
    "외부 IdP의 discovery issuer와 계약의 issuer를 정확히 같은 HTTPS URL로 수렴시켜라." discovery || return 1

  ok "OpenBao Pod 내부 OIDC discovery HTTPS 200/JSON/issuer 정확 일치"
}

oidc_public_config_matches() {
  bao read auth/oidc/config -format=json 2>/dev/null | jq -e \
    --arg issuer "${OIDC_EXPECTED_ISSUER}" '
      .data.oidc_discovery_url == $issuer
      and .data.oidc_client_id == "openbao"
      and .data.default_role == "user"
    ' >/dev/null
}

oidc_apply_config() {
  local secret_file=$1
  [[ -s ${secret_file} ]] || die "OIDC client Secret 파일 없음: ${secret_file}"

  if bao auth list -format=json | jq -e 'has("oidc/")' >/dev/null; then
    if oidc_public_config_matches; then
      note "기존 OpenBao OIDC 공개 설정 일치(숨겨진 client Secret 값은 읽거나 출력하지 않음)"
    else
      note "기존 OpenBao OIDC 공개 설정 불일치 또는 미설정; 검증된 계약으로 수렴"
    fi
  else
    bao auth enable oidc >/dev/null
    note "OpenBao OIDC auth mount 활성화"
  fi

  # client secret은 host/Pod argv에 두지 않고 root-only 파일→stdin JSON으로만 전달한다.
  jq -nc --arg discovery "${OIDC_EXPECTED_ISSUER}" --rawfile secret "${secret_file}" '{
    oidc_discovery_url:$discovery, oidc_client_id:"openbao",
    oidc_client_secret:($secret | sub("[\\r\\n]+$"; "")), default_role:"user"
  }' | bao_input write auth/oidc/config - >/dev/null

  oidc_public_config_matches \
    || die "OIDC 적용 후 공개 설정 검증 실패(Secret 값은 확인/출력하지 않음)"
  bao read auth/oidc/role/user -format=json 2>/dev/null | jq -e '
    .data.role_type == "oidc"
    and .data.user_claim == "preferred_username"
    and .data.default_role == null
  ' >/dev/null 2>&1 || {
    # OpenBao 버전에 따라 없는 field는 반환하지 않으므로 실제 필수 field만 다시 확인한다.
    bao read auth/oidc/role/user -format=json 2>/dev/null | jq -e '
      .data.role_type == "oidc" and .data.user_claim == "preferred_username"
    ' >/dev/null || die "OIDC user role 안전 검증 실패"
  }
  ok "OpenBao auth/oidc/config 멱등 수렴 및 공개 설정/user role 안전 검증"
}
