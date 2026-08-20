#!/usr/bin/env bash
# 현재 테스트베드 자격증명을 Git 밖의 root-only 인수인계 파일로 모은다.
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

required_files=(
  keycloak-test-user
  keycloak-test-password
  keycloak-admin-user
  keycloak-admin-password
  keycloak-db-name
  keycloak-db-user
  keycloak-db-password
  keycloak-secure-demo-client-secret
  keycloak-openbao-client-secret
  keycloak-portal-client-secret
  portal-auth-secret
  app-db-password
  app-api-token
)
for name in "${required_files[@]}"; do
  [[ -s ${CREDENTIAL_DIR}/${name} ]] || die "자격증명 파일 없음: ${CREDENTIAL_DIR}/${name}"
done
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
print(spec["baseDomain"])
print(hosts["sso"])
print(hosts["rancher"])
print(hosts["openbao"])
print(spec["keycloak"]["realm"])
print(spec["keycloak"]["portalClientID"])
print(spec["environment"])
PY
)
BASE_DOMAIN=${site_values[0]}
SSO_HOST=${site_values[1]}
RANCHER_HOST=${site_values[2]}
OPENBAO_HOST=${site_values[3]}
KEYCLOAK_REALM=${site_values[4]}
PORTAL_CLIENT_ID=${site_values[5]}
APP_ENVIRONMENT=${site_values[6]}

temporary=$(mktemp "${TESTBED_STATE_DIR}/.test-credentials.XXXXXX")
cleanup() { rm -f "${temporary}"; }
trap cleanup EXIT

{
  printf '# SADP TEST ONLY - 절대 Git/메신저/티켓에 첨부하지 말 것\n'
  printf '# 생성: %s\n\n' "$(date --iso-8601=seconds)"

  printf '[일반 사용자 - Keycloak %s realm / secure-demo / OpenBao OIDC]\n' "${KEYCLOAK_REALM}"
  printf 'URL=https://secure-demo.%s\n' "${BASE_DOMAIN}"
  printf 'KEYCLOAK_URL=https://%s\n' "${SSO_HOST}"
  printf 'OPENBAO_URL=https://%s\n' "${OPENBAO_HOST}"
  printf 'USERNAME=%s\n' "$(read_secret_file "${CREDENTIAL_DIR}/keycloak-test-user")"
  printf 'PASSWORD=%s\n\n' "$(read_secret_file "${CREDENTIAL_DIR}/keycloak-test-password")"

  printf '[Keycloak 관리자 - break-glass]\n'
  printf 'URL=https://%s/admin/master/console/\n' "${SSO_HOST}"
  printf 'USERNAME=%s\n' "$(read_secret_file "${CREDENTIAL_DIR}/keycloak-admin-user")"
  printf 'PASSWORD=%s\n\n' "$(read_secret_file "${CREDENTIAL_DIR}/keycloak-admin-password")"

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
  printf 'SECURE_DEMO_CLIENT_ID=secure-demo-%s\n' "${APP_ENVIRONMENT}"
  printf 'SECURE_DEMO_CLIENT_SECRET=%s\n' \
    "$(read_secret_file "${CREDENTIAL_DIR}/keycloak-secure-demo-client-secret")"
  printf 'OPENBAO_CLIENT_ID=openbao\n'
  printf 'OPENBAO_CLIENT_SECRET=%s\n\n' \
    "$(read_secret_file "${CREDENTIAL_DIR}/keycloak-openbao-client-secret")"
  printf 'PORTAL_CLIENT_ID=%s\n' "${PORTAL_CLIENT_ID}"
  printf 'PORTAL_CLIENT_SECRET=%s\n' \
    "$(read_secret_file "${CREDENTIAL_DIR}/keycloak-portal-client-secret")"
  printf 'PORTAL_AUTH_SECRET_FILE=%s/portal-auth-secret\n\n' "${CREDENTIAL_DIR}"

  printf '[secure-demo runtime test secrets - 로그인 자격증명 아님]\n'
  printf 'DB_PASSWORD=%s\n' "$(read_secret_file "${CREDENTIAL_DIR}/app-db-password")"
  printf 'API_TOKEN=%s\n\n' "$(read_secret_file "${CREDENTIAL_DIR}/app-api-token")"

  printf '[Keycloak PostgreSQL - 클러스터 내부 전용]\n'
  printf 'DATABASE=%s\n' "$(read_secret_file "${CREDENTIAL_DIR}/keycloak-db-name")"
  printf 'USERNAME=%s\n' "$(read_secret_file "${CREDENTIAL_DIR}/keycloak-db-user")"
  printf 'PASSWORD=%s\n\n' "$(read_secret_file "${CREDENTIAL_DIR}/keycloak-db-password")"

  printf '[RKE2 join token - 사이트 로그인용 아님]\n'
  printf 'TOKEN=%s\n\n' "$(tr -d '\r\n' </var/lib/rancher/rke2/server/token)"

  printf '[현재 없는 자격증명]\n'
  printf 'FORGEJO=서버 endpoint만 확인됨, Actions/Registry/GitOps 계정은 아직 연결하지 않음\n'
  printf 'PUBLIC=hello는 로그인 없음; portal-lite의 /account는 Keycloak 로그인이 필요함\n'
} >"${temporary}"

install -m 0600 "${temporary}" "${output}"
ok "root 전용 테스트 자격증명표 생성: ${output}"
