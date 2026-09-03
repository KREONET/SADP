#!/usr/bin/env bash
# OpenBao/ESO 상태를 Secret 값 조회 없이 확인하는 source 전용 함수 모음.
set -euo pipefail

OPENBAO_NAMESPACE=${OPENBAO_NAMESPACE:-openbao}
OPENBAO_POD=${OPENBAO_POD:-openbao-0}
OPENBAO_ADDR=${OPENBAO_ADDR:-https://openbao.openbao.svc.cluster.local:8200}
OPENBAO_CACERT=${OPENBAO_CACERT:-/openbao/tls/ca.crt}
OPENBAO_ACTIVE_SERVICE=${OPENBAO_ACTIVE_SERVICE:-openbao-active}
OPENBAO_ACTIVE_WAIT_ATTEMPTS=${OPENBAO_ACTIVE_WAIT_ATTEMPTS:-60}

openbao_print_unseal_commands() {
  cat >&2 <<'EOF'
[INFO] OpenBao 복구 명령(control-plane 전용):
  sudo bash ./sadp --unseal-openbao
  sudo bash ./sadp --unseal-openbao --apply
EOF
}

# Ready probe는 sealed 상태에서도 실패하므로 먼저 phase=Running과 bao status 자체를 읽는다.
# status JSON에는 복구 재료가 없지만 전체 문서는 출력하지 않고 필요한 boolean만 보관한다.
openbao_inspect_status() {
  local phase status_json
  phase=$(kctl get pod -n "${OPENBAO_NAMESPACE}" "${OPENBAO_POD}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ ${phase} == Running ]] || die \
    "OpenBao Pod가 Running이 아님: ${OPENBAO_NAMESPACE}/${OPENBAO_POD} (phase=${phase:-NotFound})"

  status_json=$(kctl exec -n "${OPENBAO_NAMESPACE}" "${OPENBAO_POD}" -- sh -ceu '
    export BAO_ADDR="$1" BAO_CACERT="$2"
    exec bao status -format=json
  ' sh "${OPENBAO_ADDR}" "${OPENBAO_CACERT}" 2>/dev/null || true)
  status_json=$(sed '/^command terminated with exit code /d' <<<"${status_json}")
  jq -e '
    (.initialized | type == "boolean") and
    (.sealed | type == "boolean")
  ' <<<"${status_json}" >/dev/null 2>&1 || die \
    "OpenBao initialized/sealed 상태를 확인할 수 없음: ${OPENBAO_NAMESPACE}/${OPENBAO_POD}"

  OPENBAO_INITIALIZED=$(jq -r '.initialized' <<<"${status_json}")
  OPENBAO_SEALED=$(jq -r '.sealed' <<<"${status_json}")
  OPENBAO_STANDBY=$(jq -r '.standby // false' <<<"${status_json}")
}

openbao_active_endpoint_exists() {
  local endpoints
  endpoints=$(kctl get endpointslice -n "${OPENBAO_NAMESPACE}" \
    -l "kubernetes.io/service-name=${OPENBAO_ACTIVE_SERVICE}" -o json 2>/dev/null || true)
  [[ -n ${endpoints} ]] || endpoints='{}'
  jq -e '
    any(.items[]?.endpoints[]?;
      (.conditions.ready != false) and ((.addresses // []) | length > 0))
  ' <<<"${endpoints}" >/dev/null 2>&1
}

# unseal 직후 service registration과 Ready probe가 수렴한 뒤에만 ESO/provider 작업을 허용한다.
openbao_wait_active_ready() {
  local timeout=${1:-2m} attempt
  [[ ${OPENBAO_STANDBY:-true} == false ]] || die \
    "${OPENBAO_NAMESPACE}/${OPENBAO_POD}가 active OpenBao endpoint가 아님(standby=true)"
  for ((attempt = 1; attempt <= OPENBAO_ACTIVE_WAIT_ATTEMPTS; attempt++)); do
    openbao_active_endpoint_exists && break
    sleep 2
  done
  openbao_active_endpoint_exists || die \
    "OpenBao active endpoint가 없음: ${OPENBAO_NAMESPACE}/${OPENBAO_ACTIVE_SERVICE}"
  kctl wait -n "${OPENBAO_NAMESPACE}" "pod/${OPENBAO_POD}" \
    --for=condition=Ready --timeout="${timeout}" >/dev/null 2>&1 || die \
    "OpenBao active endpoint는 있으나 Pod Ready가 아님: ${OPENBAO_NAMESPACE}/${OPENBAO_POD}"
}

openbao_require_unsealed() {
  local timeout=${1:-2m}
  openbao_inspect_status
  [[ ${OPENBAO_INITIALIZED} == true ]] || die \
    "OpenBao가 initialized 상태가 아님: 먼저 bootstrap 초기화 단계를 실행하라"
  if [[ ${OPENBAO_SEALED} == true ]]; then
    printf '[FAIL] OpenBao가 sealed 상태임: %s/%s\n' \
      "${OPENBAO_NAMESPACE}" "${OPENBAO_POD}" >&2
    openbao_print_unseal_commands
    return 1
  fi
  openbao_wait_active_ready "${timeout}"
  ok "OpenBao 상태 확인(initialized=True, sealed=False, active endpoint/Pod Ready; 값 미출력)"
}

external_secret_condition_fields() {
  local json=$1
  [[ -n ${json} ]] || json='{}'
  jq -r '
    ([.status.conditions[]? | select(.type == "Ready")][0] // {}) as $condition |
    ($condition.status // "<none>"),
    ($condition.reason // "<none>"),
    (($condition.message // "<none>") | gsub("[\\r\\n\\t]+"; " "))
  ' <<<"${json}"
}

external_secret_read_reference() {
  local namespace=$1 name=$2 json=$3
  EXTERNAL_SECRET_STORE_KIND=$(jq -r '.spec.secretStoreRef.kind // "SecretStore"' <<<"${json}")
  EXTERNAL_SECRET_STORE_NAME=$(jq -r '.spec.secretStoreRef.name // empty' <<<"${json}")
  EXTERNAL_SECRET_TARGET_NAME=$(jq -r --arg fallback "${name}" \
    '(.spec.target.name // "") as $target |
     if ($target | length) > 0 then $target else $fallback end' <<<"${json}")
  case "${EXTERNAL_SECRET_STORE_KIND}" in
    SecretStore) EXTERNAL_SECRET_STORE_RESOURCE=secretstore ;;
    ClusterSecretStore) EXTERNAL_SECRET_STORE_RESOURCE=clustersecretstore ;;
    *) die "지원하지 않는 spec.secretStoreRef.kind: ${EXTERNAL_SECRET_STORE_KIND}" ;;
  esac
  [[ -n ${EXTERNAL_SECRET_STORE_NAME} ]] || die \
    "ExternalSecret의 spec.secretStoreRef.name이 비어 있음: ${namespace}/${name}"
}

external_secret_store_json() {
  local namespace=$1
  if [[ ${EXTERNAL_SECRET_STORE_KIND} == SecretStore ]]; then
    kctl get secretstore -n "${namespace}" "${EXTERNAL_SECRET_STORE_NAME}" -o json 2>/dev/null || true
  else
    kctl get clustersecretstore "${EXTERNAL_SECRET_STORE_NAME}" -o json 2>/dev/null || true
  fi
}

external_secret_print_recovery() {
  local namespace=$1 name=$2
  cat >&2 <<EOF

[INFO] 값 비노출 복구 순서(control-plane 전용):
  sudo bash ./sadp --unseal-openbao

  # sealed일 때만 실행
  sudo bash ./sadp --unseal-openbao --apply

  kubectl annotate externalsecret \\
    -n ${namespace} ${name} \\
    force-sync="\$(date +%s)" --overwrite

  kubectl wait \\
    externalsecret/${name} \\
    -n ${namespace} \\
    --for=condition=Ready --timeout=2m

[INFO] 이미 unsealed이면 --apply 명령은 생략한다.
[INFO] force-sync 뒤에도 실패하면 ExternalSecret과 Store의 status.conditions만 확인한다.
[INFO] Secret data는 읽거나 출력하지 않는다.
EOF
}

# 실패 조건과 Store 연결 상태만 보여 주며 대상 Secret은 존재 여부만 API로 확인한다.
external_secret_diagnose() {
  local namespace=$1 name=$2 external_json=$3 store_json target_exists=no
  local -a external_condition store_condition
  external_secret_read_reference "${namespace}" "${name}" "${external_json}"
  store_json=$(external_secret_store_json "${namespace}")
  mapfile -t external_condition < <(external_secret_condition_fields "${external_json}")
  mapfile -t store_condition < <(external_secret_condition_fields "${store_json}")
  if kctl get secret -n "${namespace}" "${EXTERNAL_SECRET_TARGET_NAME}" >/dev/null 2>&1; then
    target_exists=yes
  fi

  printf '[FAIL] ExternalSecret Ready 확인 실패\n' >&2
  printf '  ExternalSecret: %s/%s\n' "${namespace}" "${name}" >&2
  printf '  Ready: status=%s reason=%s message=%s\n' \
    "${external_condition[0]}" "${external_condition[1]}" "${external_condition[2]}" >&2
  printf '  Store: kind=%s name=%s\n' \
    "${EXTERNAL_SECRET_STORE_KIND}" "${EXTERNAL_SECRET_STORE_NAME}" >&2
  printf '  Store Ready: status=%s reason=%s message=%s\n' \
    "${store_condition[0]}" "${store_condition[1]}" "${store_condition[2]}" >&2
  printf '  Target Secret: %s/%s exists=%s\n' \
    "${namespace}" "${EXTERNAL_SECRET_TARGET_NAME}" "${target_exists}" >&2
  printf '  Secret data는 읽거나 출력하지 않았음\n' >&2
  external_secret_print_recovery "${namespace}" "${name}"
}

external_secret_wait_store_ready() {
  local namespace=$1 timeout=$2
  local -a args
  if [[ ${EXTERNAL_SECRET_STORE_KIND} == SecretStore ]]; then
    args=(-n "${namespace}" "secretstore/${EXTERNAL_SECRET_STORE_NAME}")
  else
    args=("clustersecretstore/${EXTERNAL_SECRET_STORE_NAME}")
  fi
  kctl wait "${args[@]}" --for=condition=Ready --timeout="${timeout}" >/dev/null 2>&1
}

# Store가 준비된 뒤 force-sync하고 Ready를 기다린다. raw kubectl wait 오류는 원인을
# 가리므로 버리고, 실패 시 위의 제한된 condition 진단으로 교체한다.
wait_external_secret_ready() {
  local namespace=$1 name=$2 timeout=${3:-2m} external_json latest_json
  openbao_require_unsealed "${timeout}" || return 1
  external_json=$(kctl get externalsecret -n "${namespace}" "${name}" -o json 2>/dev/null || true)
  jq -e '.kind == "ExternalSecret"' <<<"${external_json}" >/dev/null 2>&1 || die \
    "ExternalSecret 없음: ${namespace}/${name}"
  external_secret_read_reference "${namespace}" "${name}" "${external_json}"

  if ! external_secret_wait_store_ready "${namespace}" "${timeout}"; then
    latest_json=$(kctl get externalsecret -n "${namespace}" "${name}" -o json 2>/dev/null || true)
    if jq -e '.kind == "ExternalSecret"' <<<"${latest_json}" >/dev/null 2>&1; then
      external_json=${latest_json}
    fi
    external_secret_diagnose "${namespace}" "${name}" "${external_json}"
    return 1
  fi
  kctl annotate externalsecret -n "${namespace}" "${name}" \
    force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || die \
    "ExternalSecret force-sync annotation 실패: ${namespace}/${name}"
  if ! kctl wait "externalsecret/${name}" -n "${namespace}" \
    --for=condition=Ready --timeout="${timeout}" >/dev/null 2>&1; then
    latest_json=$(kctl get externalsecret -n "${namespace}" "${name}" -o json 2>/dev/null || true)
    if jq -e '.kind == "ExternalSecret"' <<<"${latest_json}" >/dev/null 2>&1; then
      external_json=${latest_json}
    fi
    external_secret_diagnose "${namespace}" "${name}" "${external_json}"
    return 1
  fi
  if ! kctl get secret -n "${namespace}" "${EXTERNAL_SECRET_TARGET_NAME}" >/dev/null 2>&1; then
    latest_json=$(kctl get externalsecret -n "${namespace}" "${name}" -o json 2>/dev/null || true)
    if jq -e '.kind == "ExternalSecret"' <<<"${latest_json}" >/dev/null 2>&1; then
      external_json=${latest_json}
    fi
    external_secret_diagnose "${namespace}" "${name}" "${external_json}"
    return 1
  fi
  ok "ExternalSecret Ready=True, Store Ready=True, 대상 Secret 존재: ${namespace}/${name} (값 미조회)"
}
