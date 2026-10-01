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
  kubectl -n ${OIDC_OPENBAO_NAMESPACE} get pod ${OIDC_OPENBAO_POD} -o jsonpath='{.metadata.labels.controller-revision-hash}{" "}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}'
  kubectl -n ${OIDC_OPENBAO_NAMESPACE} get statefulset ${OIDC_OPENBAO_STATEFULSET} -o jsonpath='{.spec.updateStrategy.type}{" "}{.status.updateRevision}{"\n"}'
  kubectl -n ${OIDC_OPENBAO_NAMESPACE} exec ${OIDC_OPENBAO_POD} -- sh -c 'nslookup "\$1" >/dev/null' sh ${OIDC_ISSUER_HOST}
  kubectl -n ${OIDC_OPENBAO_NAMESPACE} exec ${OIDC_OPENBAO_POD} -c oidc-preflight -- sh -c 'curl -q --connect-timeout 5 --max-time 15 --silent --show-error --output /dev/null "\$1"' sh '${OIDC_DISCOVERY_URL}'
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

# issuer는 정규화하지 않는다. OpenBao는 oidc_discovery_url과 discovery 응답의 issuer를 정확히
# 비교하므로 끝 '/'를 지우면 Authentik처럼 '/'로 끝나는 issuer에서 설정이 거부된다.
issuer = str(identity.get("issuer") or "")
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
    ("openbao-client-id", str(identity.get("sharedClientID") or "openbao")),
    ("openbao-secret-name", "oidc-shared-client-secret" if identity.get("sharedClientID") else "oidc-openbao-client-secret"),
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
  OIDC_OPENBAO_CLIENT_ID=${values[12]}
  OIDC_OPENBAO_SECRET_NAME=${values[13]}
  OIDC_OPENBAO_POD=${SADP_OPENBAO_POD:-openbao-0}
  # 사전 진단이 Pod ownerReference로 실제 이름을 다시 찾는다. 이 값은 확인 명령 안내용 기본값이다.
  OIDC_OPENBAO_STATEFULSET=${OIDC_OPENBAO_POD%-*}
  OIDC_DISCOVERY_URL="${OIDC_EXPECTED_ISSUER%/}/.well-known/openid-configuration"
}

# oidc-preflight 컨테이너가 실제로 exec 가능한 상태인지 exec 전에 진단한다.
#
# OpenBao StatefulSet은 updateStrategy=OnDelete다. unseal 재료가 필요한 Pod를 controller가 임의로
# 재시작하지 않게 하려는 선택이지만, 그 대가로 템플릿에 oidc-preflight가 추가돼도 기존 Pod는 옛
# revision으로 계속 돈다. 이때 exec는 "container not found"로 실패하고 원인이 드러나지 않았다.
# 이 함수는 메타데이터와 컨테이너 상태만 읽고 Secret/환경변수/로그는 읽지 않는다. Pod를 지우거나
# 재시작하지 않는다. 교체는 unseal을 동반하는 유지보수 작업이라 운영자가 결정한다.
oidc_preflight_container_diagnose() {
  local namespace=${OIDC_OPENBAO_NAMESPACE} pod=${OIDC_OPENBAO_POD}
  local pod_json sts_json strategy update_revision pod_revision image ready reason

  pod_json=$(kctl get pod -n "${namespace}" "${pod}" -o json 2>/dev/null) || {
    oidc_preflight_failure "OpenBao Pod를 조회할 수 없음" \
      "Pod 존재 여부와 kubectl 조회 권한을 확인하라." discovery
    return 1
  }
  OIDC_OPENBAO_STATEFULSET=$(jq -r '
    first(.metadata.ownerReferences[]? | select(.kind == "StatefulSet") | .name) // empty
  ' <<<"${pod_json}")
  [[ -n ${OIDC_OPENBAO_STATEFULSET} ]] || OIDC_OPENBAO_STATEFULSET=${pod%-*}
  sts_json=$(kctl get statefulset -n "${namespace}" "${OIDC_OPENBAO_STATEFULSET}" -o json 2>/dev/null) || {
    oidc_preflight_failure "OpenBao StatefulSet을 조회할 수 없음" \
      "Pod의 ownerReference와 openbao Namespace의 StatefulSet 이름을 확인하라." discovery
    return 1
  }

  # (a) 템플릿에 없으면 Pod를 교체해도 소용없다. 생성물이나 Argo 동기화부터 봐야 한다.
  if ! jq -e 'any(.spec.template.spec.containers[]?; .name == "oidc-preflight")' \
      <<<"${sts_json}" >/dev/null; then
    oidc_preflight_failure "OpenBao StatefulSet 템플릿에 oidc-preflight 컨테이너가 없음" \
      "platform/openbao/proxy-values.yaml 생성물에 extraContainers.oidc-preflight가 있는지 보고, Argo openbao Application(devtroncd)이 그 revision으로 Synced인지 확인하라." \
      discovery
    return 1
  fi

  # (b) 템플릿에는 있는데 Pod에 없거나 revision이 뒤처졌다 = 기존 Pod가 교체되지 않았다.
  strategy=$(jq -r '.spec.updateStrategy.type // "RollingUpdate"' <<<"${sts_json}")
  update_revision=$(jq -r '.status.updateRevision // empty' <<<"${sts_json}")
  pod_revision=$(jq -r '.metadata.labels["controller-revision-hash"] // empty' <<<"${pod_json}")
  if ! jq -e 'any(.spec.containers[]?; .name == "oidc-preflight")' <<<"${pod_json}" >/dev/null \
      || [[ -n ${update_revision} && ${pod_revision} != "${update_revision}" ]]; then
    if [[ ${strategy} == OnDelete ]]; then
      oidc_preflight_failure \
        "StatefulSet updateStrategy=OnDelete라 기존 Pod ${pod}가 새 템플릿(oidc-preflight)으로 교체되지 않음" \
        "유지보수 창에서 kubectl -n ${namespace} delete pod ${pod} 로 Pod만 지운다(PVC와 Raft 데이터는 유지). 새 Pod는 sealed로 뜨므로 sudo bash ./sadp --unseal-openbao --apply 로 unseal한 뒤 이 단계를 다시 실행하라. 이 스크립트는 Pod를 자동 삭제하지 않는다." \
        discovery
    else
      oidc_preflight_failure "OpenBao Pod ${pod}가 StatefulSet 최신 revision이 아님" \
        "kubectl -n ${namespace} rollout status statefulset/${OIDC_OPENBAO_STATEFULSET} 로 교체 진행 상태를 확인하라." \
        discovery
    fi
    return 1
  fi

  # (c) 컨테이너는 있으나 실행 전이다. 폐쇄망 노드에 curl 이미지가 없는 경우가 대부분이다.
  ready=$(jq -r '
    first(.status.containerStatuses[]? | select(.name == "oidc-preflight") | .ready) // false
  ' <<<"${pod_json}")
  if [[ ${ready} != true ]]; then
    # waiting.reason은 Kubernetes가 정한 CamelCase 식별자만 남긴다. message는 이미지 경로나
    # registry 오류 원문을 담을 수 있어 출력하지 않는다.
    reason=$(jq -r '
      first(.status.containerStatuses[]? | select(.name == "oidc-preflight") | .state.waiting.reason) // empty
    ' <<<"${pod_json}" | tr -cd 'A-Za-z0-9')
    image=$(jq -r '
      first(.spec.template.spec.containers[]? | select(.name == "oidc-preflight") | .image) // empty
    ' <<<"${sts_json}")
    oidc_preflight_failure \
      "oidc-preflight 컨테이너가 준비되지 않음(waiting.reason=${reason:-unknown})" \
      "이미지가 노드에 없으면 sudo bash ./sadp --sync-images --image ${image:-<oidc-preflight image>} 로 모든 노드에 넣은 뒤 이 단계를 다시 실행하라." \
      discovery
    return 1
  fi
  return 0
}

# kubectl exec 오류 원문에는 URL·노드 주소·API 응답이 섞일 수 있다. 원인만 분류해 알린다.
oidc_classify_exec_failure() {
  local errors=$1
  if grep -qiE 'container not found|is not valid for pod|container .* not found' "${errors}"; then
    printf '%s' "exec 대상 oidc-preflight 컨테이너가 Pod에 없음(OnDelete StatefulSet 미교체 가능)"
  elif grep -qi 'forbidden' "${errors}"; then
    printf '%s' "kubectl exec 권한 거부(pods/exec RBAC)"
  elif grep -qiE 'unable to upgrade connection|error dialing backend' "${errors}"; then
    printf '%s' "API server→kubelet exec 연결 실패(노드 kubelet 10250 경로와 interface guard 확인)"
  else
    printf '%s' "OpenBao Pod exec 실패(분류 불가, 원문은 출력하지 않음)"
  fi
}

# OnDelete StatefulSet은 템플릿이 바뀌어도 Pod를 스스로 교체하지 않는다. 설치·검수 끝에서
# revision이 뒤처진 Pod를 [WARN]으로 알려 다음 OIDC 단계가 exec 실패로 멈추기 전에 드러낸다.
# 이름과 revision만 출력하고 Pod를 건드리지 않는다. 항상 0을 반환한다(경고 전용).
openbao_report_ondelete_revision_lag() {
  local namespace=${1:-openbao} run_dir lagging watched
  # doctor가 경고를 "막힌 단계"로 판정할 수 있게 결과를 전역 변수로도 남긴다.
  OPENBAO_REVISION_LAGGING=false
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/sadp-ondelete.XXXXXX")
  chmod 0700 "${run_dir}"
  if ! kctl get statefulset -n "${namespace}" -o json >"${run_dir}/sts.json" 2>/dev/null \
      || ! kctl get pod -n "${namespace}" -o json >"${run_dir}/pods.json" 2>/dev/null; then
    rm -rf -- "${run_dir}"
    printf '[WARN] %s StatefulSet/Pod revision 조회 실패: OnDelete 미반영 여부를 확인하지 못함\n' \
      "${namespace}" >&2
    return 0
  fi
  # 대상이 하나도 없는데 "모두 최신"이라고 말하면 조회 실패와 구분되지 않는다.
  watched=$(jq -rn --slurpfile sts "${run_dir}/sts.json" '
    [$sts[0].items[]? | select((.spec.updateStrategy.type // "") == "OnDelete")] | length
  ' 2>/dev/null || echo 0)
  lagging=$(jq -rn --slurpfile sts "${run_dir}/sts.json" --slurpfile pods "${run_dir}/pods.json" '
    $sts[0].items[]?
    | select((.spec.updateStrategy.type // "") == "OnDelete" and (.status.updateRevision // "") != "")
    | . as $set
    | [$pods[0].items[]?
        | select(any(.metadata.ownerReferences[]?; .kind == "StatefulSet" and .name == $set.metadata.name))
        | select((.metadata.labels["controller-revision-hash"] // "") != $set.status.updateRevision)
        | .metadata.name]
    | select(length > 0)
    | "\($set.metadata.name) \(join(","))"
  ')
  rm -rf -- "${run_dir}"
  if [[ ${watched:-0} == 0 ]]; then
    printf '[INFO] %s에 revision을 확인할 OnDelete StatefulSet 없음\n' "${namespace}"
    return 0
  fi
  if [[ -z ${lagging} ]]; then
    ok "${namespace} OnDelete StatefulSet Pod가 모두 최신 revision"
    return 0
  fi
  OPENBAO_REVISION_LAGGING=true
  while read -r sts pods; do
    printf '[WARN] %s/%s: updateStrategy=OnDelete라 Pod %s가 옛 revision으로 남음\n' \
      "${namespace}" "${sts}" "${pods}" >&2
  done <<<"${lagging}"
  printf '[WARN] 유지보수 창에서 해당 Pod를 한 대씩 삭제(PVC 유지)하고 sudo bash ./sadp --unseal-openbao --apply 로 unseal하라. 자동 삭제는 하지 않는다\n' >&2
  return 0
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

  # exec 실패 뒤에 원인을 추측하지 않도록 컨테이너 반영 상태를 먼저 진단한다.
  if ! oidc_preflight_container_diagnose; then
    rm -rf "${run_dir}"
    return 1
  fi

  if ! kctl exec -n "${OIDC_OPENBAO_NAMESPACE}" "${OIDC_OPENBAO_POD}" -c oidc-preflight -- \
      sh -ceu '
        if command -v curl >/dev/null 2>&1; then
          set +e
          curl -q --silent --show-error --proto "=https" --tlsv1.2 \
            --connect-timeout 5 --max-time 15 --output - \
            --write-out "\n__SADP_HTTP_STATUS__:%{http_code}\n" "$1"
          result=$?
          printf "__SADP_CURL_EXIT__:%s\n" "${result}"
          exit 0
        fi
        printf "__SADP_CURL_EXIT__:90\n"
      ' sh "${OIDC_DISCOVERY_URL}" >"${response}" 2>"${errors}"; then
    cause=$(oidc_classify_exec_failure "${errors}")
    rm -rf "${run_dir}"
    oidc_preflight_failure "${cause}" \
      "아래 확인 명령으로 Pod 컨테이너·revision과 StatefulSet updateStrategy를 보고, exec 권한과 kubelet 경로를 확인하라." discovery
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
        action="OpenBao Pod의 oidc-preflight 컨테이너와 curl 이미지 반영 상태를 확인하라."
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
    --arg client "${OIDC_OPENBAO_CLIENT_ID:-openbao}" --arg issuer "${OIDC_EXPECTED_ISSUER}" '
      .data.oidc_discovery_url == $issuer
      and .data.oidc_client_id == $client
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
  jq -nc --arg client "${OIDC_OPENBAO_CLIENT_ID:-openbao}" --arg discovery "${OIDC_EXPECTED_ISSUER}" --rawfile secret "${secret_file}" '{
    oidc_discovery_url:$discovery, oidc_client_id:$client,
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
