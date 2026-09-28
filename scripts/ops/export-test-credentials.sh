#!/usr/bin/env bash
# SADP가 보관하는 자격증명만 Git 밖의 root-only 인수인계 파일로 모은다.
# 외부 IdP 계정과 관리 자격증명은 SADP의 소유물이 아니므로 읽거나 내보내지 않는다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

require_root
for command in base64 jq realpath; do require_command "${command}"; done
ensure_state_dirs

output=${1:-${TESTBED_STATE_DIR}/TEST-CREDENTIALS.txt}
output=$(realpath -m "${output}")
case ${output} in
  "${TESTBED_STATE_DIR}"/*) ;;
  *) die "자격증명표는 ${TESTBED_STATE_DIR} 아래에만 생성할 수 있음" ;;
esac

[[ -s ${TESTBED_STATE_DIR}/openbao-init.json ]] || die "OpenBao 초기화 파일 없음"
[[ -s /var/lib/rancher/rke2/server/token ]] || die "RKE2 server token 없음"

rancher_password=$(kctl get secret -n cattle-system bootstrap-secret \
  -o jsonpath='{.data.bootstrapPassword}' | base64 -d)
openbao_root_token=$(jq -r '.root_token // empty' "${TESTBED_STATE_DIR}/openbao-init.json")
[[ -n ${rancher_password} ]] || die "Rancher bootstrap password 없음"
[[ -n ${openbao_root_token} ]] || die "OpenBao root token 없음"

mapfile -t site_values < <(python3 - "${TESTBED_ROOT}/contracts/platform-production.yaml" <<'PY'
import sys
import yaml

spec = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["spec"]
hosts = {item["name"]: item["host"] for item in spec.get("platformServices") or []}
identity = spec["identityProvider"]
print(spec["baseDomain"])
print(hosts["rancher"])
print(hosts["openbao"])
print(identity["issuer"])
print(identity["portalClientID"])
print(spec["environment"])
print(identity.get("sharedClientID") or "")
PY
)
BASE_DOMAIN=${site_values[0]}
RANCHER_HOST=${site_values[1]}
OPENBAO_HOST=${site_values[2]}
OIDC_ISSUER=${site_values[3]}
PORTAL_CLIENT_ID=${site_values[4]}
APP_ENVIRONMENT=${site_values[5]}

SHARED_CLIENT_ID=${site_values[6]}
SECURE_DEMO_CLIENT_ID=${SHARED_CLIENT_ID:-secure-demo-${APP_ENVIRONMENT}}
OPENBAO_CLIENT_ID=${SHARED_CLIENT_ID:-openbao}
SECURE_DEMO_SECRET=oidc-secure-demo-client-secret
OPENBAO_SECRET=oidc-openbao-client-secret
PORTAL_SECRET=oidc-portal-client-secret
if [[ -n ${SHARED_CLIENT_ID} ]]; then
  SECURE_DEMO_SECRET=oidc-shared-client-secret
  OPENBAO_SECRET=${SECURE_DEMO_SECRET}
  PORTAL_SECRET=${SECURE_DEMO_SECRET}
fi
required_files=(
  "${SECURE_DEMO_SECRET}"
  "${OPENBAO_SECRET}"
  "${PORTAL_SECRET}"
  portal-auth-secret
  app-db-password
  app-api-token
)
for name in "${required_files[@]}"; do
  [[ -s ${CREDENTIAL_DIR}/${name} ]] || die "자격증명 파일 없음: ${CREDENTIAL_DIR}/${name}"
done

temporary=$(mktemp "${TESTBED_STATE_DIR}/.test-credentials.XXXXXX")
cleanup() { rm -f "${temporary}"; }
trap cleanup EXIT

{
  printf '# SADP TEST ONLY - 절대 Git/메신저/티켓에 첨부하지 말 것\n'
  printf '# 외부 IdP 사용자/관리자 자격증명은 이 파일에 포함하지 않음\n'
  printf '# 생성: %s\n\n' "$(date --iso-8601=seconds)"

  printf '[외부 OIDC 연결]\n'
  printf 'OIDC_ISSUER=%s\n' "${OIDC_ISSUER}"
  printf 'SECURE_DEMO_URL=https://secure-demo.%s\n' "${BASE_DOMAIN}"
  printf 'OPENBAO_URL=https://%s\n\n' "${OPENBAO_HOST}"

  printf '[Rancher 관리자 - bootstrap 값, 최초 로그인 후 변경 여부 확인]\n'
  printf 'URL=https://%s\n' "${RANCHER_HOST}"
  printf 'USERNAME=admin\n'
  printf 'PASSWORD=%s\n\n' "${rancher_password}"

  printf '[OpenBao 관리자 - break-glass token]\n'
  printf 'URL=https://%s\n' "${OPENBAO_HOST}"
  printf 'OIDC_ROLE=platform-admin\n'
  printf 'ROOT_TOKEN=%s\n' "${openbao_root_token}"
  printf 'UNSEAL_MATERIAL=%s/openbao-init.json\n\n' "${TESTBED_STATE_DIR}"

  printf '[OIDC confidential client secrets - 일반 사용자에게 전달 금지]\n'
  printf 'SECURE_DEMO_CLIENT_ID=%s\n' "${SECURE_DEMO_CLIENT_ID}"
  printf 'SECURE_DEMO_CLIENT_SECRET=%s\n' \
    "$(read_secret_file "${CREDENTIAL_DIR}/${SECURE_DEMO_SECRET}")"
  printf 'OPENBAO_CLIENT_ID=%s\n' "${OPENBAO_CLIENT_ID}"
  printf 'OPENBAO_CLIENT_SECRET=%s\n\n' \
    "$(read_secret_file "${CREDENTIAL_DIR}/${OPENBAO_SECRET}")"
  printf 'PORTAL_CLIENT_ID=%s\n' "${PORTAL_CLIENT_ID}"
  printf 'PORTAL_CLIENT_SECRET=%s\n' \
    "$(read_secret_file "${CREDENTIAL_DIR}/${PORTAL_SECRET}")"
  printf 'PORTAL_AUTH_SECRET_FILE=%s/portal-auth-secret\n\n' "${CREDENTIAL_DIR}"

  printf '[secure-demo runtime test secrets - 로그인 자격증명 아님]\n'
  printf 'DB_PASSWORD=%s\n' "$(read_secret_file "${CREDENTIAL_DIR}/app-db-password")"
  printf 'API_TOKEN=%s\n\n' "$(read_secret_file "${CREDENTIAL_DIR}/app-api-token")"

  printf '[RKE2 join token - 사이트 로그인용 아님]\n'
  printf 'TOKEN=%s\n\n' "$(tr -d '\r\n' </var/lib/rancher/rke2/server/token)"

  printf '[현재 없는 자격증명]\n'
  printf 'IDP=사용자와 관리자 계정은 외부 IdP 운영자가 별도로 관리함\n'
  printf 'FORGEJO=서버 endpoint만 확인됨, Actions/Registry/GitOps 계정은 아직 연결하지 않음\n'
} >"${temporary}"

install -m 0600 "${temporary}" "${output}"
ok "root 전용 SADP 자격증명표 생성: ${output}"
