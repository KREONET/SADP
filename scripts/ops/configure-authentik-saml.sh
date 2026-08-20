#!/usr/bin/env bash
# Authentik SAML Assertion의 발급 유효시간을 공식 기본 계약으로 수렴한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

APPLY=false
ENV_FILE=${AUTHENTIK_SAML_ENV_FILE:-/etc/sadp/authentik-saml.env}
# Authentik 현행 SAMLProvider 모델의 기본값이다. Keycloak clock skew나 로그인 timeout이 아니다.
EXPECTED_NOT_BEFORE='minutes=-5'
EXPECTED_NOT_ON_OR_AFTER='minutes=5'

usage() {
  cat <<'USAGE'
사용법: configure-authentik-saml.sh [--env-file <path>] [--apply]

필수 Private 입력:
  AUTHENTIK_API_URL
  AUTHENTIK_API_TOKEN_FILE       root만 읽는 API token 파일
  AUTHENTIK_SAML_PROVIDER_ID
  AUTHENTIK_API_CA_FILE          선택, 내부 CA 파일

기본은 현재 값을 읽고 계획만 출력한다. --apply는 해당 SAML Provider의
assertion_valid_not_before=-5분, assertion_valid_not_on_or_after=+5분만 PATCH한다.
USAGE
}

while (($#)); do
  case $1 in
    --env-file)
      (($# >= 2)) || die "--env-file 값이 필요함"
      ENV_FILE=$2
      shift
      ;;
    --apply) APPLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "알 수 없는 인자: $1" ;;
  esac
  shift
done

require_root
for command in curl jq python3 shred stat; do require_command "${command}"; done
[[ -r ${ENV_FILE} ]] || die "Authentik SAML Private 입력 파일을 읽을 수 없음"

env_file_value() {
  local key=$1 line value
  line=$(grep -m1 -E "^[[:space:]]*${key}=" "${ENV_FILE}") || return 1
  value=${line#*=}
  if [[ ${value} == \"*\" && ${value} == *\" ]]; then
    value=${value:1:${#value}-2}
  elif [[ ${value} == \'*\' && ${value} == *\' ]]; then
    value=${value:1:${#value}-2}
  fi
  [[ -n ${value} ]] || return 1
  printf '%s' "${value}"
}

api_url=$(env_file_value AUTHENTIK_API_URL) || die "AUTHENTIK_API_URL이 없음"
token_file=$(env_file_value AUTHENTIK_API_TOKEN_FILE) \
  || die "AUTHENTIK_API_TOKEN_FILE이 없음"
provider_id=$(env_file_value AUTHENTIK_SAML_PROVIDER_ID) \
  || die "AUTHENTIK_SAML_PROVIDER_ID가 없음"
ca_file=$(env_file_value AUTHENTIK_API_CA_FILE 2>/dev/null || true)
[[ ${token_file} =~ ^/[A-Za-z0-9._/-]+$ && -r ${token_file} ]] \
  || die "API token 파일은 읽을 수 있는 안전한 절대경로여야 함"
[[ $(stat -c '%a' "${token_file}") =~ ^[46]00$ ]] \
  || die "API token 파일 권한은 0400 또는 0600이어야 함"
[[ ${provider_id} =~ ^[1-9][0-9]*$ ]] || die "SAML Provider ID는 양의 정수여야 함"
if [[ -n ${ca_file} ]]; then
  [[ ${ca_file} =~ ^/[A-Za-z0-9._/-]+$ && -r ${ca_file} ]] \
    || die "AUTHENTIK_API_CA_FILE은 읽을 수 있는 안전한 절대경로여야 함"
fi
python3 - "${api_url}" <<'PY'
import sys
from urllib.parse import urlsplit

parsed = urlsplit(sys.argv[1])
if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password \
        or parsed.query or parsed.fragment:
    raise SystemExit("[FAIL] AUTHENTIK_API_URL은 자격증명·query 없는 HTTPS origin이어야 함")
PY

run_dir=$(mktemp -d /run/sadp-authentik-saml.XXXXXX)
chmod 0700 "${run_dir}"
auth_config=${run_dir}/auth.curl
current_json=${run_dir}/current.json
patch_json=${run_dir}/patch.json
result_json=${run_dir}/result.json
cleanup() {
  local file
  for file in "${run_dir}"/*; do
    [[ -f ${file} ]] && shred -u -- "${file}" 2>/dev/null || true
  done
  rmdir "${run_dir}" 2>/dev/null || true
}
trap cleanup EXIT

api_token=$(<"${token_file}")
[[ ${#api_token} -ge 20 && ${api_token} =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "API token 파일 형식이 유효하지 않음"
printf 'header = "Authorization: Bearer %s"\n' "${api_token}" >"${auth_config}"
chmod 0600 "${auth_config}"
unset api_token

endpoint=${api_url%/}/api/v3/providers/saml/${provider_id}/
curl_args=(--silent --show-error --fail --proto '=https' --tlsv1.2 --config "${auth_config}")
[[ -z ${ca_file} ]] || curl_args+=(--cacert "${ca_file}")
curl "${curl_args[@]}" -H 'Accept: application/json' \
  --output "${current_json}" "${endpoint}"

current_not_before=$(jq -er '.assertion_valid_not_before | select(type == "string")' \
  "${current_json}") || die "Authentik 응답에 assertion_valid_not_before가 없음"
current_not_after=$(jq -er '.assertion_valid_not_on_or_after | select(type == "string")' \
  "${current_json}") || die "Authentik 응답에 assertion_valid_not_on_or_after가 없음"
printf '[PLAN] Assertion NotBefore: %s -> %s\n' \
  "${current_not_before}" "${EXPECTED_NOT_BEFORE}"
printf '[PLAN] Assertion NotOnOrAfter: %s -> %s\n' \
  "${current_not_after}" "${EXPECTED_NOT_ON_OR_AFTER}"
printf '[PLAN] Keycloak allowedClockSkew/Login timeout/서명 검증 변경 없음\n'

if [[ ${current_not_before} == "${EXPECTED_NOT_BEFORE}" \
   && ${current_not_after} == "${EXPECTED_NOT_ON_OR_AFTER}" ]]; then
  ok "Authentik SAML Assertion 유효시간이 공식 기본 계약과 일치"
  exit 0
fi
if [[ ${APPLY} != true ]]; then
  note "변경 없음. 적용하려면 --apply"
  exit 0
fi

jq -nc --arg not_before "${EXPECTED_NOT_BEFORE}" \
  --arg not_after "${EXPECTED_NOT_ON_OR_AFTER}" '{
    assertion_valid_not_before: $not_before,
    assertion_valid_not_on_or_after: $not_after
  }' >"${patch_json}"
curl "${curl_args[@]}" -X PATCH \
  -H 'Accept: application/json' -H 'Content-Type: application/json' \
  --data-binary "@${patch_json}" --output "${result_json}" "${endpoint}"
jq -e --arg not_before "${EXPECTED_NOT_BEFORE}" \
  --arg not_after "${EXPECTED_NOT_ON_OR_AFTER}" '
    .assertion_valid_not_before == $not_before
    and .assertion_valid_not_on_or_after == $not_after
  ' "${result_json}" >/dev/null \
  || die "Authentik SAML Assertion 유효시간 적용 후 검증 실패"
ok "Authentik SAML Assertion 유효시간 -5분/+5분 수렴"
