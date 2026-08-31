#!/usr/bin/env bash
# 기계 API 키의 OpenBao 원본과 ESO/Gateway 수렴을 공통 처리한다.
# 이 파일은 bao/bao_input/kctl과 testbed-common.sh를 준비한 root 스크립트에서 source한다.

machine_auth_load_contract() {
  local -a values
  local index client_count service_count
  mapfile -t values < <(python3 - "${TESTBED_ROOT}/contracts/platform-production.yaml" <<'PY'
import sys

import yaml

spec = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["spec"]
config = spec.get("machineAuth") or {}
api_key = config.get("apiKey") or {}
gateway = spec.get("gateway") or {}
print(str(config.get("mode") or ""))
print(str(gateway.get("redirectRouteNamespace") or ""))
for field in (
    "remotePathPrefix", "secretStoreName", "esoServiceAccount", "esoRole",
    "credentialSecretPrefix", "header",
):
    print(str(api_key.get(field) or ""))
clients = [str(item) for item in config.get("clients") or []]
print(len(clients))
print(*clients, sep="\n")
services = [
    (str(item.get("name") or ""), str(item.get("host") or ""))
    for item in spec.get("platformServices") or []
    if (item or {}).get("machineAuth")
]
print(len(services))
for name, host in services:
    print(name)
    print(host)
PY
  ) || die "기계 인증 계약을 읽지 못함"
  ((${#values[@]} >= 9)) || die "기계 인증 계약 필드가 부족함"
  MACHINE_AUTH_MODE=${values[0]}
  MACHINE_AUTH_NAMESPACE=${values[1]}
  MACHINE_AUTH_REMOTE_PATH_PREFIX=${values[2]}
  MACHINE_AUTH_SECRET_STORE=${values[3]}
  MACHINE_AUTH_ESO_SERVICE_ACCOUNT=${values[4]}
  MACHINE_AUTH_ESO_ROLE=${values[5]}
  MACHINE_AUTH_SECRET_PREFIX=${values[6]}
  MACHINE_AUTH_HEADER=${values[7]}
  client_count=${values[8]}
  [[ ${client_count} =~ ^[0-9]+$ ]] || die "기계 인증 client 수 계약 오류"
  MACHINE_AUTH_CLIENTS=()
  index=9
  while ((${#MACHINE_AUTH_CLIENTS[@]} < client_count)); do
    MACHINE_AUTH_CLIENTS+=("${values[index]:-}")
    index=$((index + 1))
  done
  service_count=${values[index]:-}
  [[ ${service_count} =~ ^[0-9]+$ ]] || die "기계 인증 service 수 계약 오류"
  index=$((index + 1))
  MACHINE_AUTH_SERVICES=()
  MACHINE_AUTH_HOSTS=()
  while ((${#MACHINE_AUTH_SERVICES[@]} < service_count)); do
    MACHINE_AUTH_SERVICES+=("${values[index]:-}")
    MACHINE_AUTH_HOSTS+=("${values[index + 1]:-}")
    index=$((index + 2))
  done
}

machine_auth_validate_api_key_contract() {
  [[ ${MACHINE_AUTH_MODE} == api-key ]] || die "MACHINE_AUTH_MODE=api-key에서만 API 키를 다룰 수 있음"
  [[ -n ${MACHINE_AUTH_NAMESPACE} ]] || die "machine-auth route Namespace가 비어 있음"
  [[ ${MACHINE_AUTH_REMOTE_PATH_PREFIX} == platform/machine-auth ]] \
    || die "machine-auth OpenBao 경로 계약 불일치"
  [[ ${MACHINE_AUTH_SECRET_STORE} == machine-auth-openbao ]] \
    || die "machine-auth SecretStore 계약 불일치"
  [[ ${MACHINE_AUTH_ESO_SERVICE_ACCOUNT} == eso-machine-auth ]] \
    || die "machine-auth ESO ServiceAccount 계약 불일치"
  [[ ${MACHINE_AUTH_ESO_ROLE} == machine-auth-eso ]] \
    || die "machine-auth ESO role 계약 불일치"
  [[ ${MACHINE_AUTH_SECRET_PREFIX} == machine-auth- ]] \
    || die "machine-auth Secret 접두사 계약 불일치"
  [[ ${MACHINE_AUTH_HEADER} == X-SADP-API-Key ]] \
    || die "machine-auth API key header 계약 불일치"
  ((${#MACHINE_AUTH_CLIENTS[@]})) || die "api-key 모드의 client 목록이 비어 있음"
}

machine_auth_export_path() {
  printf '%s/machine-auth-%s-api-key' "${CREDENTIAL_DIR}" "$1"
}

machine_auth_remote_path() {
  printf '%s/%s' "${MACHINE_AUTH_REMOTE_PATH_PREFIX}" "$1"
}

machine_auth_ensure_client_key() {
  local client=$1 remote_path transfer_path temporary current_file
  remote_path=$(machine_auth_remote_path "${client}")
  transfer_path=$(machine_auth_export_path "${client}")
  temporary=$(mktemp "${CREDENTIAL_DIR}/.machine-auth-${client}.XXXXXX")
  if bao kv get -field="${client}" -mount=kv "${remote_path}" 2>/dev/null \
      | tr -d '\r\n' >"${temporary}"; then
    : # OpenBao의 기존 키를 그대로 내보낸다. 일반 bootstrap은 절대 회전하지 않는다.
  else
    openssl rand -hex 32 | tr -d '\r\n' >"${temporary}"
    for current_file in "${CREDENTIAL_DIR}"/machine-auth-*-api-key; do
      [[ -e ${current_file} ]] || continue
      while cmp -s "${temporary}" "${current_file}"; do
        openssl rand -hex 32 | tr -d '\r\n' >"${temporary}"
      done
    done
    if bao kv get -mount=kv "${remote_path}" >/dev/null 2>&1; then
      bao_input kv patch -mount=kv "${remote_path}" "${client}=-" \
        <"${temporary}" >/dev/null
    else
      bao_input kv put -mount=kv "${remote_path}" "${client}=-" \
        <"${temporary}" >/dev/null
    fi
  fi
  [[ $(wc -c <"${temporary}") -ge 64 ]] || die "${client} API 키가 256비트보다 짧음"
  install -m 0600 "${temporary}" "${transfer_path}"
  rm -f "${temporary}"
  ok "${client} API 키 준비 완료"
  note "전달 파일: ${transfer_path}"
}

machine_auth_assert_distinct_keys() {
  local left right left_file right_file
  for ((left = 0; left < ${#MACHINE_AUTH_CLIENTS[@]}; left++)); do
    left_file=$(machine_auth_export_path "${MACHINE_AUTH_CLIENTS[left]}")
    for ((right = left + 1; right < ${#MACHINE_AUTH_CLIENTS[@]}; right++)); do
      right_file=$(machine_auth_export_path "${MACHINE_AUTH_CLIENTS[right]}")
      if cmp -s "${left_file}" "${right_file}"; then
        die "서로 다른 machine-auth client에 같은 API 키가 존재함"
      fi
    done
  done
  return 0
}

machine_auth_wait_external_secret() {
  local client=$1 expect_next=${2:-false} external_secret secret ready
  external_secret="${MACHINE_AUTH_SECRET_PREFIX}${client}"
  secret="${MACHINE_AUTH_SECRET_PREFIX}${client}-api-keys"
  kctl -n "${MACHINE_AUTH_NAMESPACE}" get externalsecret "${external_secret}" >/dev/null \
    || die "machine-auth ExternalSecret 없음: ${MACHINE_AUTH_NAMESPACE}/${external_secret}"
  kctl -n "${MACHINE_AUTH_NAMESPACE}" annotate externalsecret "${external_secret}" \
    force-sync="$(date +%s)" --overwrite >/dev/null
  ready=""
  for _ in $(seq 1 60); do
    ready=$(kctl -n "${MACHINE_AUTH_NAMESPACE}" get externalsecret "${external_secret}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ ${ready} == True ]] && break
    sleep 2
  done
  [[ ${ready} == True ]] || die "machine-auth ExternalSecret가 Ready가 아님: ${external_secret}"
  if [[ ${expect_next} == true ]]; then
    kctl -n "${MACHINE_AUTH_NAMESPACE}" get secret "${secret}" -o json |
      jq -e --arg active "${client}" --arg next "${client}-next" \
        '.data | has($active) and has($next)' >/dev/null \
      || die "Gateway Secret에 active/next API 키 이름이 함께 없음: ${secret}"
  else
    kctl -n "${MACHINE_AUTH_NAMESPACE}" get secret "${secret}" -o json |
      jq -e --arg active "${client}" \
        '.data | has($active)' >/dev/null \
      || die "Gateway Secret에 active API 키 이름이 없음: ${secret}"
  fi
}

machine_auth_wait_policies() {
  local service accepted
  for service in "${MACHINE_AUTH_SERVICES[@]}"; do
    accepted=""
    for _ in $(seq 1 60); do
      accepted=$(kctl -n "${MACHINE_AUTH_NAMESPACE}" get securitypolicy \
        "${service}-machine-auth" \
        -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' \
        2>/dev/null || true)
      [[ ${accepted} == True ]] && break
      sleep 2
    done
    [[ ${accepted} == True ]] \
      || die "machine-auth SecurityPolicy가 Accepted가 아님: ${service}-machine-auth"
  done
}

machine_auth_bootstrap() {
  local client
  machine_auth_load_contract
  if [[ ${MACHINE_AUTH_MODE} == keycloak ]]; then
    note "machine-auth mode=keycloak: API 키를 생성하거나 변경하지 않음"
    return 0
  fi
  machine_auth_validate_api_key_contract
  cat <<HCL | bao_input policy write machine-auth-reader - >/dev/null
path "kv/data/${MACHINE_AUTH_REMOTE_PATH_PREFIX}/*" { capabilities = ["read"] }
path "kv/metadata/${MACHINE_AUTH_REMOTE_PATH_PREFIX}/*" { capabilities = ["read"] }
HCL
  bao write "auth/kubernetes/role/${MACHINE_AUTH_ESO_ROLE}" \
    bound_service_account_names="${MACHINE_AUTH_ESO_SERVICE_ACCOUNT}" \
    bound_service_account_namespaces="${MACHINE_AUTH_NAMESPACE}" audience=vault \
    token_policies=machine-auth-reader token_ttl=1h token_max_ttl=4h >/dev/null
  for client in "${MACHINE_AUTH_CLIENTS[@]}"; do
    machine_auth_ensure_client_key "${client}"
  done
  machine_auth_assert_distinct_keys
  for client in "${MACHINE_AUTH_CLIENTS[@]}"; do
    machine_auth_wait_external_secret "${client}" false
  done
  machine_auth_wait_policies
  ok "machine-auth OpenBao/ESO/Gateway 수렴 완료"
}
