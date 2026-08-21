#!/usr/bin/env bash
# control-plane에서 외부 Keycloak VM의 realm/IdP/client 정책을 원격 수렴시킨다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

APPLY=false
SSH_USER=${KEYCLOAK_SSH_USER:-root}
SSH_PORT=${KEYCLOAK_SSH_PORT:-22}
SSH_IDENTITY_FILE=${KEYCLOAK_SSH_IDENTITY_FILE:-}
REMOTE_ENV_FILE=${KEYCLOAK_REMOTE_ENV_FILE:-/etc/keycloak/keycloak.env}
REMOTE_KCADM=${KEYCLOAK_REMOTE_KCADM:-/opt/keycloak/bin/kcadm.sh}
REMOTE_SCRIPT=${KEYCLOAK_REMOTE_SCRIPT:-/root/sadp-configure-keycloak-trusted-saml.sh}
REMOTE_TEST_USER_SCRIPT=${KEYCLOAK_REMOTE_TEST_USER_SCRIPT:-/root/sadp-configure-keycloak-test-user.sh}
REMOTE_TIME_SCRIPT=${KEYCLOAK_REMOTE_TIME_SCRIPT:-/root/sadp-configure-identity-time-sync.sh}

usage() {
  cat <<'USAGE'
사용법: configure-external-keycloak.sh [--apply]

기본은 계획만 출력한다. --apply를 주면 계약의 external address로 BatchMode SSH 접속해
최신 수렴 스크립트를 설치·실행한다. 비밀번호는 원격 EnvironmentFile에서만 읽는다.

선택 환경변수:
  KEYCLOAK_SSH_USER, KEYCLOAK_SSH_PORT, KEYCLOAK_SSH_IDENTITY_FILE
  KEYCLOAK_REMOTE_ENV_FILE, KEYCLOAK_REMOTE_KCADM, KEYCLOAK_REMOTE_SCRIPT
  KEYCLOAK_REMOTE_TEST_USER_SCRIPT, KEYCLOAK_REMOTE_TIME_SCRIPT
USAGE
}

while (($#)); do
  case $1 in
    --apply) APPLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "알 수 없는 인자: $1" ;;
  esac
  shift
done

require_root
for command in base64 python3 ssh; do require_command "${command}"; done
ensure_state_dirs
cd "${TESTBED_ROOT}"
local_script=platform/keycloak/external/configure-default-developer.sh
local_test_user_script=platform/keycloak/external/configure-test-user.sh
local_time_script=platform/keycloak/external/configure-time-sync.sh
[[ -s ${local_script} ]] || die "외부 Keycloak 수렴 스크립트 없음: ${local_script}"
[[ -s ${local_test_user_script} ]] \
  || die "외부 Keycloak 테스트 사용자 수렴 스크립트 없음: ${local_test_user_script}"
[[ -s ${local_time_script} ]] \
  || die "외부 Keycloak 시간 동기화 스크립트 없음: ${local_time_script}"
[[ ${SSH_USER} == root ]] || die "외부 Keycloak EnvironmentFile 접근에는 KEYCLOAK_SSH_USER=root가 필요"
[[ ${SSH_PORT} =~ ^[0-9]+$ ]] && ((SSH_PORT >= 1 && SSH_PORT <= 65535)) \
  || die "KEYCLOAK_SSH_PORT는 1..65535여야 함"
for remote_path in "${REMOTE_ENV_FILE}" "${REMOTE_KCADM}" "${REMOTE_SCRIPT}" \
  "${REMOTE_TEST_USER_SCRIPT}" "${REMOTE_TIME_SCRIPT}"; do
  # ssh는 원격 명령을 shell 문자열로 전달하므로 공백만 막아서는 세미콜론 같은 문자가
  # 명령으로 해석될 수 있다. 설치 경로에 필요한 문자만 허용해 관리자 접속 경계를 지킨다.
  [[ ${remote_path} =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || die "원격 경로는 안전한 절대경로여야 함: ${remote_path}"
done

mapfile -t contract_values < <(python3 - <<'PY'
import yaml

spec = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))["spec"]
keycloak = spec.get("keycloak") or {}
if keycloak.get("deployment") != "external":
    raise SystemExit("[FAIL] configure-external-keycloak은 deployment=external 전용")
external = keycloak.get("external") or {}
idp = keycloak.get("identityProvider") or {}
portal = yaml.safe_load(open("apps/portal-lite/values-beta.yaml", encoding="utf-8"))
values = (
    external.get("address"),
    keycloak.get("realm"),
    idp.get("alias"),
    keycloak.get("portalClientID"),
    (portal.get("exposure") or {}).get("host"),
    external.get("port"),
    spec.get("baseDomain"),
    keycloak.get("samlSpEntityId") or keycloak.get("issuer"),
    idp.get("metadataDescriptorUrl"),
    idp.get("singleSignOnServiceUrl"),
)
if any(not str(item or "").strip() for item in values):
    raise SystemExit("[FAIL] external address/realm/IdP alias/Portal client/host 계약값 필요")
print("\n".join(str(item).strip() for item in values))
PY
)
external_address=${contract_values[0]}
keycloak_realm=${contract_values[1]}
idp_alias=${contract_values[2]}
portal_client_id=${contract_values[3]}
portal_host=${contract_values[4]}
external_port=${contract_values[5]}
base_domain=${contract_values[6]}
saml_sp_entity_id=${contract_values[7]}
idp_metadata_url=${contract_values[8]}
idp_sso_url=${contract_values[9]}
[[ ${external_address} =~ ^[A-Za-z0-9.-]+$ ]] \
  || die "외부 Keycloak address 형식이 SSH 대상에 안전하지 않음"
for contract_name in "${keycloak_realm}" "${idp_alias}" "${portal_client_id}"; do
  [[ ${contract_name} =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "Keycloak realm/IdP/client 이름 형식이 안전하지 않음"
done
[[ ${portal_host} =~ ^[A-Za-z0-9.-]+$ ]] \
  || die "Portal host 형식이 안전하지 않음"
[[ ${base_domain} =~ ^[A-Za-z0-9.-]+$ ]] \
  || die "base domain 형식이 안전하지 않음"
[[ ${external_port} =~ ^[0-9]+$ ]] \
  && ((external_port >= 1 && external_port <= 65535)) \
  || die "외부 Keycloak port는 1..65535여야 함"
target=${SSH_USER}@${external_address}

ssh_args=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=yes
  -p "${SSH_PORT}"
)
if [[ -n ${SSH_IDENTITY_FILE} ]]; then
  [[ -s ${SSH_IDENTITY_FILE} ]] || die "SSH identity 파일 없음: ${SSH_IDENTITY_FILE}"
  ssh_args+=(-i "${SSH_IDENTITY_FILE}")
fi

note "외부 Keycloak 원격 수렴 계획: ${target}:${SSH_PORT}"
note "realm/IdP/Portal client 값은 계약과 generated Portal values에서 읽음"
note "SAML SP EntityID/metadata/SSO URL도 계약값으로 반복 수렴함"
note "원격 관리자 값은 ${REMOTE_ENV_FILE}에서만 읽고 Keycloak은 재시작하지 않음"
note "같은 EnvironmentFile의 SADP_NTP_SERVERS로 NTP를 먼저 수렴하고 sync 실패 시 중단"
note "acceptance 테스트 자격증명은 SSH stdin으로만 전달하고 원격 파일에 저장하지 않음"
if [[ ${APPLY} != true ]]; then
  note "변경 없음. 적용하려면 --apply"
  exit 0
fi

test_user_file=${CREDENTIAL_DIR}/keycloak-test-user
test_password_file=${CREDENTIAL_DIR}/keycloak-test-password
[[ -s ${test_user_file} && -s ${test_password_file} ]] \
  || die "Keycloak acceptance 테스트 자격증명 파일이 없음"

# known_hosts와 공개키 인증을 설치 전에 명시적으로 준비한다. StrictHostKeyChecking을
# 자동 완화하면 최초 연결에서 다른 호스트에 관리자 스크립트를 보낼 수 있다.
ssh "${ssh_args[@]}" "${target}" bash -s -- "${REMOTE_ENV_FILE}" "${REMOTE_KCADM}" <<'REMOTE'
set -euo pipefail
[[ -r $1 ]] || { echo "[FAIL] Keycloak EnvironmentFile을 읽을 수 없음" >&2; exit 1; }
[[ -x $2 ]] || { echo "[FAIL] kcadm 실행 파일 없음" >&2; exit 1; }
# client secret을 회수한 뒤 뒤늦게 보조 명령 누락으로 실패하면 이미 realm 정책은
# 바뀐 상태가 된다. 변경 전에 원격 응답 생성에 필요한 도구까지 함께 확인한다.
for command in awk base64 grep jq sed; do
  command -v "${command}" >/dev/null \
    || { echo "[FAIL] 외부 Keycloak VM 필수 명령 없음: ${command}" >&2; exit 1; }
done
REMOTE

# 스크립트 본문만 stdin으로 보내며 Secret 파일은 복사하지 않는다.
ssh "${ssh_args[@]}" "${target}" install -m 0700 /dev/stdin "${REMOTE_SCRIPT}" \
  <"${local_script}"
ssh "${ssh_args[@]}" "${target}" install -m 0700 /dev/stdin "${REMOTE_TEST_USER_SCRIPT}" \
  <"${local_test_user_script}"
ssh "${ssh_args[@]}" "${target}" install -m 0700 /dev/stdin "${REMOTE_TIME_SCRIPT}" \
  <"${local_time_script}"

# Assertion의 시간 검증을 완화하지 않는다. Keycloak 정책보다 먼저 VM의 UTC 기준을
# 정상화하고, DNS/UDP 123 또는 NTPSynchronized가 실패하면 realm 변경 전에 중단한다.
printf -v quoted_time_env '%q' "${REMOTE_ENV_FILE}"
printf -v quoted_time_script '%q' "${REMOTE_TIME_SCRIPT}"
ssh "${ssh_args[@]}" "${target}" \
  "${quoted_time_script} --env-file ${quoted_time_env} --runtime auto --apply"

remote_config_args=(
  "${REMOTE_ENV_FILE}" "${REMOTE_KCADM}" "${REMOTE_SCRIPT}"
  "${keycloak_realm}" "${idp_alias}" "${portal_client_id}" \
  "https://${portal_host}/portal" "${external_address}" "${external_port}" \
  "${saml_sp_entity_id}" "${idp_metadata_url}" "${idp_sso_url}"
)
# ssh는 여러 argv를 원격 shell 문자열로 다시 합친다. metadata URL의 `?`를 그대로 넘기면
# zsh nomatch에 걸리므로, 검증된 각 값을 shell word 하나로 quote한 명령을 만든다.
remote_config_command='bash -s --'
for value in "${remote_config_args[@]}"; do
  printf -v quoted_value '%q' "${value}"
  remote_config_command+=" ${quoted_value}"
done
ssh "${ssh_args[@]}" "${target}" "${remote_config_command}" <<'REMOTE'
set -euo pipefail
# 이 VM은 /run을 noexec로 마운트할 수 있다. kcadm wrapper는 root만 접근 가능한
# 실행 가능 디렉터리에 두고, config와 함께 EXIT trap에서 제거한다.
kcadm_home=$(mktemp -d /root/.sadp-keycloak-kcadm.XXXXXX)
kcadm_config=${kcadm_home}/kcadm.config
kcadm_wrapper=${kcadm_home}/kcadm
cleanup() {
  rm -f "${kcadm_config}" "${kcadm_wrapper}"
  rmdir "${kcadm_home}/.keycloak" 2>/dev/null || true
  rmdir "${kcadm_home}" 2>/dev/null || true
}
trap cleanup EXIT
install -m 0700 /dev/stdin "${kcadm_wrapper}" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
exec "${SADP_REAL_KCADM:?}" "$@" --config "${SADP_KCADM_CONFIG:?}"
WRAPPER
env \
  HOME="${kcadm_home}" \
  SADP_REAL_KCADM="$2" \
  SADP_KCADM_CONFIG="${kcadm_config}" \
  KEYCLOAK_ENV_FILE="$1" \
  KEYCLOAK_SERVER="http://$8:$9" \
  KCADM="${kcadm_wrapper}" \
  KEYCLOAK_REALM="$4" \
  KEYCLOAK_IDP_ALIAS="$5" \
  PORTAL_CLIENT_ID="$6" \
  PORTAL_POST_LOGOUT_REDIRECT_URI="$7" \
  KEYCLOAK_SAML_SP_ENTITY_ID="${10}" \
  KEYCLOAK_IDP_METADATA_URL="${11}" \
  KEYCLOAK_IDP_SSO_URL="${12}" \
  "$3"
REMOTE

# acceptance 계정은 실제 로그인 검증 전용이다. 두 값은 암호화된 SSH stdin으로만 보내고
# remote command, 환경변수, 임시 파일에는 넣지 않는다.
{
  base64 -w0 <"${test_user_file}"
  printf '\n'
  base64 -w0 <"${test_password_file}"
  printf '\n'
} | ssh "${ssh_args[@]}" "${target}" "${REMOTE_TEST_USER_SCRIPT}" \
  "${REMOTE_ENV_FILE}" "${REMOTE_KCADM}" \
  "http://${external_address}:${external_port}" \
  "${keycloak_realm}" "${portal_client_id}" "${base_domain}"

# OpenBao에는 임의로 만든 값이나 과거 파일이 아니라 Keycloak이 현재 보유한 client secret만
# 시드해야 한다. 관리자 자격증명은 계속 VM의 EnvironmentFile에서 읽고, 세 client secret만
# 암호화된 SSH stdout으로 base64 전송해 root-only 응답 파일에서 원자적으로 교체한다.
client_secret_response=$(mktemp "${CREDENTIAL_DIR}/.keycloak-client-secrets.XXXXXX")
chmod 0600 "${client_secret_response}"
cleanup_client_secret_response() { rm -f "${client_secret_response}"; }
trap cleanup_client_secret_response EXIT

secret_command='bash -s --'
for value in "${REMOTE_ENV_FILE}" "${REMOTE_KCADM}" \
  "http://${external_address}:${external_port}" "${keycloak_realm}" \
  secure-demo-prod "${portal_client_id}" openbao; do
  printf -v quoted_value '%q' "${value}"
  secret_command+=" ${quoted_value}"
done
ssh "${ssh_args[@]}" "${target}" "${secret_command}" >"${client_secret_response}" <<'REMOTE'
set -euo pipefail
env_file_value() {
  local file=$1 key=$2 rows
  rows=$(sed -n "s/^${key}=//p" "${file}")
  [[ $(grep -c '^' <<<"${rows}") == 1 && -n ${rows} ]] || exit 1
  if [[ ${rows} == \"*\" && ${rows} == *\" ]]; then
    rows=${rows:1:${#rows}-2}
  elif [[ ${rows} == \'*\' && ${rows} == *\' ]]; then
    rows=${rows:1:${#rows}-2}
  fi
  printf '%s' "${rows}"
}
kcadm_home=$(mktemp -d /root/.sadp-keycloak-secret-read.XXXXXX)
kcadm_config=${kcadm_home}/kcadm.config
cleanup() {
  rm -f "${kcadm_config}"
  rmdir "${kcadm_home}/.keycloak" 2>/dev/null || true
  rmdir "${kcadm_home}" 2>/dev/null || true
}
trap cleanup EXIT
admin_user=$(env_file_value "$1" KC_BOOTSTRAP_ADMIN_USERNAME)
admin_password=$(env_file_value "$1" KC_BOOTSTRAP_ADMIN_PASSWORD)
export KC_CLI_PASSWORD=${admin_password}
"$2" config credentials --server "$3" --realm master --user "${admin_user}" \
  --config "${kcadm_config}" >/dev/null
unset KC_CLI_PASSWORD admin_password admin_user

for client_spec in \
  "keycloak-secure-demo-client-secret:$5" \
  "keycloak-portal-client-secret:$6" \
  "keycloak-openbao-client-secret:$7"; do
  filename=${client_spec%%:*}
  client_id=${client_spec#*:}
  clients=$("$2" get clients -r "$4" -q clientId="${client_id}" \
    --fields id,clientId --format csv --noquotes --config "${kcadm_config}")
  uuid=$(awk -F, -v wanted="${client_id}" '$2 == wanted {count++; id=$1} END {if (count == 1) print id}' \
    <<<"${clients}")
  [[ -n ${uuid} ]] || exit 1
  secret=$("$2" get "clients/${uuid}/client-secret" -r "$4" \
    --config "${kcadm_config}" | jq -er '.value | strings | select(length > 0)')
  printf '%s\t' "${filename}"
  printf '%s' "${secret}" | base64 -w0
  printf '\n'
  unset secret
done
REMOTE

python3 - "${client_secret_response}" "${CREDENTIAL_DIR}" <<'PY'
import base64
import binascii
import os
from pathlib import Path
import sys
import tempfile

response = Path(sys.argv[1])
credential_dir = Path(sys.argv[2])
expected = {
    "keycloak-secure-demo-client-secret",
    "keycloak-portal-client-secret",
    "keycloak-openbao-client-secret",
}
decoded = {}
for line in response.read_text(encoding="ascii").splitlines():
    name, separator, payload = line.partition("\t")
    if not separator or name not in expected or name in decoded:
        raise SystemExit("[FAIL] 외부 Keycloak client secret 응답 형식 오류")
    try:
        value = base64.b64decode(payload, validate=True)
    except (binascii.Error, ValueError):
        raise SystemExit("[FAIL] 외부 Keycloak client secret 응답 인코딩 오류")
    if not value or b"\x00" in value or b"\r" in value or b"\n" in value:
        raise SystemExit("[FAIL] 외부 Keycloak client secret 응답 값 오류")
    decoded[name] = value
if set(decoded) != expected:
    raise SystemExit("[FAIL] 외부 Keycloak client secret 응답 항목 누락")
for name in sorted(expected):
    target = credential_dir / name
    descriptor, temporary_name = tempfile.mkstemp(prefix="." + name + ".", dir=credential_dir)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        os.write(descriptor, decoded[name])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, target)
    os.chmod(target, 0o600)
PY
cleanup_client_secret_response
trap - EXIT

ok "외부 Keycloak realm 정책·acceptance 계정 수렴 및 현재 client secret 안전 회수 완료"
