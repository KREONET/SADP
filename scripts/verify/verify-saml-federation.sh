#!/usr/bin/env bash
# 외부 SSO/Keycloak UTC 동기화와 신규 SAML 만료 오류를 민감정보 없이 검증한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

MODE=
ENV_FILE=${SAML_FEDERATION_ENV_FILE:-/etc/sadp/saml-federation.env}
sample_first=
sample_second=

usage() {
  cat <<'USAGE'
사용법:
  verify-saml-federation.sh --env-file <path> --measure
  verify-saml-federation.sh --env-file <path> --mark
  verify-saml-federation.sh --env-file <path> --check \
    --assertion-sample <root-only-base64-file> --assertion-sample <root-only-base64-file>

--measure는 변경 전후의 NTP 상태와 UTC 차이만 민감값 없이 측정한다.
--mark는 외부 SSO/Keycloak NTP와 UTC 차이를 확인하고 Keycloak 로그 기준점을 저장한다.
그 뒤 정상/대기/다중 탭/뒤로 가기/로그아웃/Keycloak 재시작 로그인을 수행한다.
--check는 두 새 SAMLResponse의 시간·ID 재사용과 기준점 이후 Keycloak 오류를 검사한다.
SAML 원문, Response/Assertion ID, 사용자 정보는 출력하지 않는다.
USAGE
}

while (($#)); do
  case $1 in
    --env-file)
      (($# >= 2)) || die "--env-file 값이 필요함"
      ENV_FILE=$2
      shift
      ;;
    --measure) [[ -z ${MODE} ]] || die "검증 mode는 하나만 선택"; MODE=measure ;;
    --mark) [[ -z ${MODE} ]] || die "검증 mode는 하나만 선택"; MODE=mark ;;
    --check) [[ -z ${MODE} ]] || die "검증 mode는 하나만 선택"; MODE=check ;;
    --assertion-sample)
      (($# >= 2)) || die "--assertion-sample 값이 필요함"
      if [[ -z ${sample_first} ]]; then sample_first=$2; else sample_second=$2; fi
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "알 수 없는 인자: $1" ;;
  esac
  shift
done

require_root
for command in jq python3 ssh; do require_command "${command}"; done
[[ ${MODE} =~ ^(measure|mark|check)$ ]] \
  || { usage >&2; die "--measure, --mark 또는 --check가 필요함"; }
[[ -r ${ENV_FILE} ]] || die "SAML federation Private 입력 파일을 읽을 수 없음"
ensure_state_dirs
cd "${TESTBED_ROOT}"
state_file=${TESTBED_STATE_DIR}/saml-federation-log-start

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

idp_host=$(env_file_value SAML_IDP_SSH_HOST) || die "SAML_IDP_SSH_HOST가 없음"
idp_user=$(env_file_value SAML_IDP_SSH_USER) || idp_user=root
idp_port=$(env_file_value SAML_IDP_SSH_PORT) || idp_port=22
idp_identity=$(env_file_value SAML_IDP_SSH_IDENTITY_FILE 2>/dev/null || true)
max_delta=$(env_file_value SAML_MAX_CLOCK_DELTA_SECONDS) || max_delta=5
log_runtime=$(env_file_value KEYCLOAK_LOG_RUNTIME) || log_runtime=auto
[[ ${idp_host} =~ ^[A-Za-z0-9.-]+$ && ${idp_user} =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "외부 SSO SSH 대상 형식이 안전하지 않음"
[[ ${idp_port} =~ ^[0-9]+$ ]] && ((idp_port >= 1 && idp_port <= 65535)) \
  || die "SAML_IDP_SSH_PORT는 1..65535여야 함"
[[ ${max_delta} =~ ^[0-9]+$ ]] && ((max_delta >= 0 && max_delta <= 30)) \
  || die "SAML_MAX_CLOCK_DELTA_SECONDS는 0..30이어야 함"
[[ ${log_runtime} =~ ^(auto|native|compose)$ ]] \
  || die "KEYCLOAK_LOG_RUNTIME은 auto|native|compose여야 함"
if [[ -n ${idp_identity} ]]; then
  [[ ${idp_identity} =~ ^/[A-Za-z0-9._/-]+$ && -r ${idp_identity} ]] \
    || die "외부 SSO SSH identity 파일이 유효하지 않음"
fi

mapfile -t keycloak_values < <(python3 - <<'PY'
import yaml

keycloak = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))["spec"]["keycloak"]
if keycloak.get("deployment") != "external":
    raise SystemExit("[FAIL] SAML federation 원격 검증은 external Keycloak 전용")
print((keycloak.get("external") or {}).get("address") or "")
PY
)
keycloak_host=${keycloak_values[0]:?계약에 external Keycloak address가 없음}
[[ ${keycloak_host} =~ ^[A-Za-z0-9.-]+$ ]] || die "Keycloak SSH 대상 형식이 안전하지 않음"

keycloak_ssh_port=${KEYCLOAK_SSH_PORT:-22}
keycloak_identity=${KEYCLOAK_SSH_IDENTITY_FILE:-}
[[ ${keycloak_ssh_port} =~ ^[0-9]+$ ]] \
  && ((keycloak_ssh_port >= 1 && keycloak_ssh_port <= 65535)) \
  || die "KEYCLOAK_SSH_PORT는 1..65535여야 함"
if [[ -n ${keycloak_identity} ]]; then
  [[ ${keycloak_identity} =~ ^/[A-Za-z0-9._/-]+$ && -r ${keycloak_identity} ]] \
    || die "Keycloak SSH identity 파일이 유효하지 않음"
fi
keycloak_ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
  -p "${keycloak_ssh_port}")
idp_ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
  -p "${idp_port}")
[[ -z ${keycloak_identity} ]] || keycloak_ssh_args+=(-i "${keycloak_identity}")
[[ -z ${idp_identity} ]] || idp_ssh_args+=(-i "${idp_identity}")

run_dir=$(mktemp -d "${TESTBED_STATE_DIR}/.saml-time.XXXXXX")
chmod 0700 "${run_dir}"
cleanup() {
  rm -f "${run_dir}"/* 2>/dev/null || true
  rmdir "${run_dir}" 2>/dev/null || true
}
trap cleanup EXIT
keycloak_time=${run_dir}/keycloak-time.json
idp_time=${run_dir}/idp-time.json

read_time_remote() {
  local destination=$1 output=$2
  shift 2
  if ! ssh "$@" "${destination}" bash -s >"${output}" 2>/dev/null <<'REMOTE'
set -euo pipefail
sync=$(timedatectl show -p NTPSynchronized --value)
if [[ ${sync} == yes ]]; then synchronized=true; else synchronized=false; fi
printf '{"synchronized":%s,"epoch":%s,"epoch_ns":%s}\n' \
  "${synchronized}" "$(date -u +%s)" "$(date -u +%s%N)"
REMOTE
  then
    return 1
  fi
}

read_time_remote "root@${keycloak_host}" "${keycloak_time}" "${keycloak_ssh_args[@]}" &
keycloak_time_pid=$!
read_time_remote "${idp_user}@${idp_host}" "${idp_time}" "${idp_ssh_args[@]}" &
idp_time_pid=$!
wait "${keycloak_time_pid}" || die "Keycloak VM NTP/UTC 상태 조회 실패"
wait "${idp_time_pid}" || die "외부 SSO NTP/UTC 상태 조회 실패"

clock_delta=$(jq -nr --slurpfile keycloak "${keycloak_time}" \
  --slurpfile idp "${idp_time}" '
    (($keycloak[0].epoch_ns - $idp[0].epoch_ns) / 1000000000) as $delta
    | ($delta | if . < 0 then -. else . end | floor)
  ')
((clock_delta <= max_delta)) \
  || delta_ok=false
delta_ok=${delta_ok:-true}
keycloak_synchronized=$(jq -r '.synchronized' "${keycloak_time}")
idp_synchronized=$(jq -r '.synchronized' "${idp_time}")
printf '[INFO] Keycloak NTPSynchronized=%s\n' "${keycloak_synchronized}"
printf '[INFO] 외부 SSO NTPSynchronized=%s\n' "${idp_synchronized}"
printf '[INFO] 외부 SSO와 Keycloak UTC 시각 차이 %s초\n' "${clock_delta}"
if [[ ${MODE} == measure ]]; then
  [[ ${keycloak_synchronized} == true && ${idp_synchronized} == true \
    && ${delta_ok} == true ]] \
    || die "NTP 동기화 또는 UTC 시각 차이 기준 미충족"
  ok "외부 SSO/Keycloak 시간 기준 충족"
  exit 0
fi
[[ ${keycloak_synchronized} == true && ${idp_synchronized} == true ]] \
  || die "외부 SSO 또는 Keycloak이 NTP 동기화되지 않음"
[[ ${delta_ok} == true ]] \
  || die "Keycloak과 외부 SSO UTC 시각 차이가 허용 범위를 초과함"
ok "외부 SSO와 Keycloak 시간 기준 충족"

# 원격에서는 boolean/건수만 반환한다. journal/docker 원문은 SSH stdout으로 보내지 않는다.
ordering_ok=$(ssh "${keycloak_ssh_args[@]}" "root@${keycloak_host}" bash -s 2>/dev/null <<'REMOTE'
set -euo pipefail
if [[ $(systemctl show keycloak.service -p LoadState --value 2>/dev/null) == loaded ]]; then
  unit=keycloak.service
elif [[ $(systemctl show docker.service -p LoadState --value 2>/dev/null) == loaded ]]; then
  unit=docker.service
else
  exit 1
fi
after=$(systemctl show "${unit}" -p After --value)
wants=$(systemctl show "${unit}" -p Wants --value)
if grep -qw systemd-time-wait-sync.service <<<"${after}" \
    && grep -qw systemd-time-wait-sync.service <<<"${wants}"; then
  printf true
else
  printf false
fi
REMOTE
) || die "Keycloak 시작 순서 원격 검증 실패"
[[ ${ordering_ok} == true ]] || die "Keycloak이 time sync 전에 시작될 수 있음"
ok "Keycloak 시작이 systemd-time-wait-sync 뒤로 고정됨"

if [[ ${MODE} == mark ]]; then
  jq -er '.epoch | select(type == "number")' "${keycloak_time}" >"${state_file}"
  chmod 0600 "${state_file}"
  ok "Keycloak SAML 오류 로그 기준점 저장"
  note "이제 문서의 외부 SSO 로그인 시나리오를 수행한 뒤 --check 실행"
  exit 0
fi

[[ -r ${state_file} ]] || die "--mark로 만든 로그 기준점이 없음"
[[ -n ${sample_first} && -n ${sample_second} ]] \
  || die "--check에는 서로 다른 로그인에서 얻은 --assertion-sample 두 개가 필요함"
SADP_SAML_TEST_MODE=0 python3 scripts/verify/saml-assertion-contract.py \
  "${sample_first}" "${sample_second}"

since_epoch=$(<"${state_file}")
[[ ${since_epoch} =~ ^[0-9]+$ ]] || die "로그 기준점 형식이 유효하지 않음"
log_counts=$(ssh "${keycloak_ssh_args[@]}" "root@${keycloak_host}" \
  bash -s -- "${since_epoch}" "${log_runtime}" 2>/dev/null <<'REMOTE'
set -euo pipefail
since=$1
runtime=$2
if [[ ${runtime} == auto ]]; then
  if [[ $(systemctl show keycloak.service -p LoadState --value 2>/dev/null) == loaded ]]; then
    runtime=native
  else
    runtime=compose
  fi
fi
if [[ ${runtime} == native ]]; then
  journalctl -u keycloak.service --since "@${since}" -o cat --no-pager 2>/dev/null
else
  container_id=$(docker ps --filter label=com.docker.compose.service=keycloak \
    --format '{{.ID}}' | head -1)
  [[ -n ${container_id} ]]
  docker logs --since "${since}" "${container_id}" 2>&1
fi | python3 -c '
import json, sys
expired = 0
invalid = 0
for line in sys.stdin:
    expired += "Assertion expired" in line
    invalid += "invalid_saml_response" in line
print(json.dumps({"expired": expired, "invalid": invalid}, separators=(",", ":")))
'
REMOTE
) || die "Keycloak SAML 오류 로그 집계 실패"
jq -e '.expired == 0 and .invalid == 0' <<<"${log_counts}" >/dev/null \
  || die "검증 시나리오 중 신규 Assertion expired/invalid_saml_response 발생"
ok "검증 기준점 이후 신규 Assertion expired/invalid_saml_response 없음"
