#!/usr/bin/env bash
# OpenBao seal 상태를 먼저 계획하고, 명시적 --apply에서만 root-only 복구 재료를 사용한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"
source "$(dirname "$0")/../lib/openbao-eso.sh"

APPLY=false
while (($#)); do
  case "$1" in
    --apply) APPLY=true ;;
    -h|--help)
      cat <<'EOF'
usage:
  sudo bash ./sadp --unseal-openbao
  sudo bash ./sadp --unseal-openbao --apply

기본 실행은 initialized/sealed/active endpoint 상태만 확인한다. --apply에서만
/var/lib/sadp/openbao-init.json의 root-only unseal 재료를 stdin으로 전달한다.
EOF
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

require_root
for command in jq stat; do require_command "${command}"; done
cd "${TESTBED_ROOT}"

openbao_inspect_status
[[ ${OPENBAO_INITIALIZED} == true ]] || die \
  "OpenBao가 initialized 상태가 아님: bootstrap 초기화 단계를 먼저 실행하라"
if [[ ${OPENBAO_SEALED} != true ]]; then
  openbao_wait_active_ready 2m
  ok "OpenBao는 이미 unsealed 상태임. --apply를 실행하지 않아도 됨(값 미출력)"
  exit 0
fi

printf '[INFO] OpenBao 상태: initialized=True, sealed=True (값 미출력)\n'
if [[ ${APPLY} != true ]]; then
  openbao_print_unseal_commands
  exit 1
fi

init_file=${TESTBED_STATE_DIR}/openbao-init.json
[[ -f ${init_file} && ! -L ${init_file} ]] || die \
  "OpenBao 초기화 파일이 root-only 일반 파일이 아님: ${init_file}"
[[ $(stat -c '%u' "${init_file}") == 0 ]] || die \
  "OpenBao 초기화 파일 소유자는 root여야 함: ${init_file}"
mode=$(stat -c '%a' "${init_file}")
[[ ${mode} == 400 || ${mode} == 600 ]] || die \
  "OpenBao 초기화 파일 mode는 0400 또는 0600이어야 함: ${init_file}"
threshold=$(jq -er '
  (.unseal_threshold // 0) as $threshold |
  select(($threshold | type) == "number" and $threshold > 0) |
  $threshold
' "${init_file}") || die "OpenBao unseal threshold를 읽지 못함"
key_count=$(jq -er '.unseal_keys_b64 | length' "${init_file}") || die \
  "OpenBao unseal 재료 목록을 읽지 못함"
((key_count >= threshold)) || die "OpenBao unseal 재료 수가 threshold보다 적음"

for ((index = 0; index < threshold; index++)); do
  # host argv와 Kubernetes API request에는 key를 넣지 않고 root-only 파일에서 Pod stdin으로만
  # 보낸다. bao 출력도 버려 복구 재료와 불필요한 상태 문서가 로그로 번지지 않게 한다.
  jq -er ".unseal_keys_b64[${index}]" "${init_file}" |
    kctl exec -i -n "${OPENBAO_NAMESPACE}" "${OPENBAO_POD}" -- sh -ceu '
      IFS= read -r unseal_key
      export BAO_ADDR="$1" BAO_CACERT="$2"
      bao operator unseal "$unseal_key" >/dev/null
    ' sh "${OPENBAO_ADDR}" "${OPENBAO_CACERT}"
  openbao_inspect_status
  [[ ${OPENBAO_SEALED} == true ]] || break
done

[[ ${OPENBAO_SEALED} == false ]] || die \
  "OpenBao가 threshold 적용 뒤에도 sealed 상태임(복구 재료 값은 출력하지 않음)"
openbao_wait_active_ready 2m
ok "OpenBao unseal 완료 및 active endpoint/Pod Ready 확인(복구 재료 값 미출력)"
