#!/usr/bin/env bash
# machine-auth API 키를 active/next 병행 구간을 거쳐 명시적으로 회전한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"
source "$(dirname "$0")/../lib/machine-auth.sh"

usage() {
  cat <<'EOF'
usage:
  sudo bash ./sadp --rotate-machine-api-key <client>
  sudo bash ./sadp --rotate-machine-api-key <client> --promote --confirm-connected
  sudo bash ./sadp --rotate-machine-api-key <client> --abort

첫 명령은 신규 키를 OpenBao/ESO/Gateway에 기존 키와 병행 반영하고 root-only 전달 파일만
갱신한다. Grafana/Wazuh에 그 파일의 신규 키를 적용하고 실제 연결 성공을 확인한 뒤에만
--promote --confirm-connected를 실행한다. --abort는 미승격 신규 키를 버린다.
EOF
}

CLIENT=""
ACTION=prepare
CONFIRM_CONNECTED=false
while (($#)); do
  case "$1" in
    --promote) ACTION=promote ;;
    --abort) ACTION=abort ;;
    --confirm-connected) CONFIRM_CONNECTED=true ;;
    -h|--help) usage; exit 0 ;;
    --*) die "알 수 없는 인자: $1" ;;
    *)
      [[ -z ${CLIENT} ]] || die "client는 하나만 지정할 수 있음"
      CLIENT=$1
      ;;
  esac
  shift
done
[[ -n ${CLIENT} ]] || { usage; exit 2; }
[[ ${ACTION} == promote && ${CONFIRM_CONNECTED} == true || ${CONFIRM_CONNECTED} == false ]] \
  || die "--confirm-connected는 --promote와 함께만 사용"
if [[ ${ACTION} == promote && ${CONFIRM_CONNECTED} != true ]]; then
  die "외부 시스템에 신규 키를 적용하고 연결 성공을 확인한 뒤 --confirm-connected 필요"
fi

require_root
for command in jq openssl python3; do require_command "${command}"; done
ensure_state_dirs
cd "${TESTBED_ROOT}"
machine_auth_load_contract
machine_auth_validate_api_key_contract
allowed=false
for candidate in "${MACHINE_AUTH_CLIENTS[@]}"; do
  [[ ${candidate} != "${CLIENT}" ]] || allowed=true
done
[[ ${allowed} == true ]] || die "계약의 MACHINE_AUTH_CLIENTS에 없는 client: ${CLIENT}"

openbao_pod=openbao-0
bao_addr=https://openbao.openbao.svc.cluster.local:8200
init_file=${TESTBED_STATE_DIR}/openbao-init.json
[[ -s ${init_file} ]] || die "OpenBao 초기화 파일 없음: ${init_file}"
openbao_require_unsealed 2m

bao() {
  jq -er '.root_token' "${init_file}" |
    kctl exec -i -n openbao "${openbao_pod}" -- sh -ceu '
      IFS= read -r BAO_TOKEN
      export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
      shift
      exec bao "$@"
    ' sh "${bao_addr}" "$@"
}

bao_input() {
  {
    jq -er '.root_token' "${init_file}"
    cat
  } | kctl exec -i -n openbao "${openbao_pod}" -- sh -ceu '
    IFS= read -r BAO_TOKEN
    export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
    shift
    exec bao "$@"
  ' sh "${bao_addr}" "$@"
}

remote_path=$(machine_auth_remote_path "${CLIENT}")
transfer_path=$(machine_auth_export_path "${CLIENT}")
active_file=$(mktemp "${CREDENTIAL_DIR}/.machine-auth-active.XXXXXX")
next_file=$(mktemp "${CREDENTIAL_DIR}/.machine-auth-next.XXXXXX")
cleanup() { rm -f "${active_file}" "${next_file}"; }
trap cleanup EXIT

read_openbao_field() {
  local field=$1 target=$2
  bao kv get -field="${field}" -mount=kv "${remote_path}" 2>/dev/null \
    | tr -d '\r\n' >"${target}"
}

read_openbao_field "${CLIENT}" "${active_file}" \
  || die "기존 active API 키가 없음. bootstrap-services를 먼저 실행"
[[ $(wc -c <"${active_file}") -ge 64 ]] || die "기존 active API 키가 256비트보다 짧음"

next_key_is_unique() {
  local current_file
  cmp -s "${active_file}" "${next_file}" && return 1
  for current_file in "${CREDENTIAL_DIR}"/machine-auth-*-api-key; do
    [[ -e ${current_file} ]] || continue
    [[ ${current_file} != "${transfer_path}" ]] || continue
    cmp -s "${next_file}" "${current_file}" && return 1
  done
  return 0
}

case "${ACTION}" in
  prepare)
    if read_openbao_field "${CLIENT}-next" "${next_file}"; then
      note "${CLIENT} 회전 준비가 이미 존재하므로 신규 키를 다시 만들지 않음"
      next_key_is_unique || die "기존 next API 키가 다른 client/active 키와 중복됨"
    else
      while :; do
        openssl rand -hex 32 | tr -d '\r\n' >"${next_file}"
        next_key_is_unique && break
      done
      bao_input kv patch -mount=kv "${remote_path}" "${CLIENT}-next=-" \
        <"${next_file}" >/dev/null
    fi
    [[ $(wc -c <"${next_file}") -ge 64 ]] || die "신규 API 키가 256비트보다 짧음"
    install -m 0600 "${next_file}" "${transfer_path}"
    machine_auth_wait_external_secret "${CLIENT}" true
    machine_auth_wait_policies
    ok "${CLIENT} 신규 API 키를 기존 키와 병행 반영"
    note "전달 파일: ${transfer_path}"
    note "Grafana/Wazuh에 신규 키를 적용하고 연결 성공을 확인한 뒤 다음 명령 실행"
    note "sudo bash ./sadp --rotate-machine-api-key ${CLIENT} --promote --confirm-connected"
    ;;
  promote)
    read_openbao_field "${CLIENT}-next" "${next_file}" \
      || die "승격할 next API 키가 없음. 먼저 회전 준비 명령을 실행"
    old_versions=$(bao kv metadata get -format=json -mount=kv "${remote_path}" \
      | jq -er '[.data.versions | to_entries[] | select(.value.destroyed != true) | .key | tonumber] | join(",")')
    # next는 이미 Gateway에서 검증 가능한 상태다. 외부 연결 성공 확인 뒤 문서를 새 active
    # 하나로 교체하고 ESO가 수렴한 다음에만 이전 OpenBao 버전을 파기한다.
    bao_input kv put -mount=kv "${remote_path}" "${CLIENT}=-" \
      <"${next_file}" >/dev/null
    machine_auth_wait_external_secret "${CLIENT}" false
    kctl -n "${MACHINE_AUTH_NAMESPACE}" get secret \
      "${MACHINE_AUTH_SECRET_PREFIX}${CLIENT}-api-keys" -o json |
      jq -e --arg active "${CLIENT}" --arg next "${CLIENT}-next" \
        '.data | has($active) and (has($next) | not)' >/dev/null \
      || die "Gateway Secret에서 이전/next 키 정리가 확인되지 않음"
    machine_auth_wait_policies
    install -m 0600 "${next_file}" "${transfer_path}"
    [[ -z ${old_versions} ]] \
      || bao kv destroy -mount=kv -versions="${old_versions}" "${remote_path}" >/dev/null
    ok "${CLIENT} 신규 API 키 승격 및 기존 키 폐기 완료"
    note "전달 파일: ${transfer_path}"
    ;;
  abort)
    if ! read_openbao_field "${CLIENT}-next" "${next_file}"; then
      note "${CLIENT}에 폐기할 next API 키가 없음"
      install -m 0600 "${active_file}" "${transfer_path}"
      exit 0
    fi
    aborted_version=$(bao kv metadata get -format=json -mount=kv "${remote_path}" \
      | jq -er '.data.current_version')
    bao_input kv put -mount=kv "${remote_path}" "${CLIENT}=-" \
      <"${active_file}" >/dev/null
    machine_auth_wait_external_secret "${CLIENT}" false
    machine_auth_wait_policies
    install -m 0600 "${active_file}" "${transfer_path}"
    bao kv destroy -mount=kv -versions="${aborted_version}" "${remote_path}" >/dev/null
    ok "${CLIENT} 미승격 신규 API 키 폐기 완료"
    note "전달 파일: ${transfer_path}"
    ;;
esac
