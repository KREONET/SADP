#!/usr/bin/env bash
# Gateway/TLS/discovery 완료 증거를 확인한 뒤에만 OpenBao OIDC 설정을 멱등 수렴한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"
source "$(dirname "$0")/../lib/openbao-eso.sh"
source "$(dirname "$0")/../lib/openbao-oidc.sh"

APPLY=false
while (($#)); do
  case "$1" in
    --apply) APPLY=true ;;
    -h|--help)
      cat <<'EOF'
usage: sudo bash ./sadp --configure-openbao-oidc [--apply]

기본 실행은 OpenBao Pod 내부 discovery와 Gateway/TLS 완료 증거만 확인한다.
--apply를 지정하면 같은 preflight가 성공한 뒤 auth/oidc/config를 멱등 수렴하고
Secret을 제외한 공개 설정과 user role을 다시 읽어 검증한다.
EOF
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

require_root
for command in jq python3; do require_command "${command}"; done
[[ -x ${KUBECTL_BIN} ]] || die "kubectl 없음: ${KUBECTL_BIN}"
ensure_state_dirs
cd "${TESTBED_ROOT}"

# sealed 상태의 503을 discovery/Gateway 오류로 오진하지 않는다. 복구 재료 사용은 별도
# --unseal-openbao --apply 경계에 남겨 두고 여기서는 상태만 확인한다.
openbao_require_unsealed 2m
oidc_load_contract
oidc_gateway_tls_preflight
oidc_discovery_preflight

if [[ ${APPLY} != true ]]; then
  note "OIDC preflight 완료. 적용하려면 같은 checkout에서 --configure-openbao-oidc --apply"
  exit 0
fi

INIT_FILE=${TESTBED_STATE_DIR}/openbao-init.json
CLIENT_SECRET_FILE=${CREDENTIAL_DIR}/oidc-openbao-client-secret
[[ -s ${INIT_FILE} ]] || die "OpenBao 초기화 파일 없음: ${INIT_FILE}"
jq -e '.root_token | type == "string" and length > 0' "${INIT_FILE}" >/dev/null \
  || die "OpenBao root token을 읽지 못함"
[[ -s ${CLIENT_SECRET_FILE} ]] || die "OIDC client Secret 파일 없음: ${CLIENT_SECRET_FILE}"

BAO_ADDR=https://openbao.openbao.svc.cluster.local:8200
bao() {
  jq -er '.root_token' "${INIT_FILE}" |
    kctl exec -i -n openbao openbao-0 -- sh -ceu '
      IFS= read -r BAO_TOKEN
      export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
      shift
      exec bao "$@"
    ' sh "${BAO_ADDR}" "$@"
}
bao_input() {
  {
    jq -er '.root_token' "${INIT_FILE}"
    cat
  } | kctl exec -i -n openbao openbao-0 -- sh -ceu '
    IFS= read -r BAO_TOKEN
    export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
    shift
    exec bao "$@"
  ' sh "${BAO_ADDR}" "$@"
}

oidc_apply_config "${CLIENT_SECRET_FILE}"
