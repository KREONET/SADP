#!/usr/bin/env bash
# Keycloak/상위 IdP 호스트의 시계를 검증된 NTP와 동기화하고 인증 서비스의 시작 순서를 고정한다.
set -euo pipefail

APPLY=false
ENV_FILE=${SADP_TIME_ENV_FILE:-/etc/keycloak/keycloak.env}
RUNTIME=${SADP_IDENTITY_RUNTIME:-auto}
SYNC_WAIT_SECONDS=${SADP_NTP_SYNC_WAIT_SECONDS:-120}
TIMESYNCD_CONFIG=/etc/systemd/timesyncd.conf.d/60-sadp-identity.conf

usage() {
  cat <<'USAGE'
사용법: configure-time-sync.sh [--env-file <path>] [--runtime auto|native|compose] [--apply]

EnvironmentFile의 SADP_NTP_SERVERS(공백 구분)를 읽어 각 서버에 실제 NTP 요청을 보낸다.
기본은 계획이며 --apply에서만 systemd-timesyncd와 서비스 시작 순서를 변경한다.

  native  keycloak.service를 time sync 뒤에 시작
  compose docker.service를 time sync 뒤에 시작
  auto    keycloak.service가 있으면 native, 아니면 docker.service를 선택

SADP_NTP_SYNC_WAIT_SECONDS는 NTP 수렴을 기다리는 상한이다. SAML/Login 유효시간은 바꾸지 않는다.
USAGE
}

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '[OK]   %s\n' "$*"
}

while (($#)); do
  case $1 in
    --env-file)
      (($# >= 2)) || die "--env-file 값이 필요함"
      ENV_FILE=$2
      shift
      ;;
    --runtime)
      (($# >= 2)) || die "--runtime 값이 필요함"
      RUNTIME=$2
      shift
      ;;
    --apply) APPLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "알 수 없는 인자: $1" ;;
  esac
  shift
done

((EUID == 0)) || die "root 권한이 필요함"
for command in install mktemp python3 systemctl timedatectl; do
  command -v "${command}" >/dev/null 2>&1 || die "필수 명령 없음: ${command}"
done
[[ -r ${ENV_FILE} ]] || die "시간 동기화 EnvironmentFile을 읽을 수 없음"
[[ ${RUNTIME} =~ ^(auto|native|compose)$ ]] || die "runtime은 auto|native|compose 중 하나여야 함"
[[ ${SYNC_WAIT_SECONDS} =~ ^[0-9]+$ ]] \
  && ((SYNC_WAIT_SECONDS >= 10 && SYNC_WAIT_SECONDS <= 600)) \
  || die "SADP_NTP_SYNC_WAIT_SECONDS는 10..600초여야 함"

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

ntp_value=$(env_file_value SADP_NTP_SERVERS) \
  || die "EnvironmentFile에 SADP_NTP_SERVERS가 없음"
read -r -a ntp_servers <<<"${ntp_value}"
(( ${#ntp_servers[@]} > 0 )) || die "SADP_NTP_SERVERS가 비어 있음"
for server in "${ntp_servers[@]}"; do
  [[ ${#server} -le 253 && ${server} =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] \
    || die "NTP 서버 값 형식이 안전하지 않음"
done

unit_exists() {
  local load_state
  load_state=$(systemctl show "$1" -p LoadState --value 2>/dev/null) || return 1
  [[ ${load_state} == loaded ]]
}

if [[ ${RUNTIME} == auto ]]; then
  if unit_exists keycloak.service; then
    RUNTIME=native
  elif unit_exists docker.service; then
    RUNTIME=compose
  else
    die "keycloak.service와 docker.service를 찾지 못해 시작 순서를 정할 수 없음"
  fi
fi
if [[ ${RUNTIME} == native ]]; then
  gated_unit=keycloak.service
else
  gated_unit=docker.service
fi
unit_exists "${gated_unit}" || die "시간 동기화 뒤에 시작할 서비스가 없음"
unit_exists systemd-timesyncd.service || die "systemd-timesyncd.service가 없음"
unit_exists systemd-time-wait-sync.service || die "systemd-time-wait-sync.service가 없음"

# DNS 이름만 해석되는지 보는 검사는 UDP 123 차단을 놓친다. 실제 최소 NTP 요청을 보내
# 응답 mode/stratum/transmit timestamp까지 확인하되 주소와 응답은 출력하지 않는다.
ntp_list_file=$(mktemp /run/sadp-ntp-servers.XXXXXX)
cleanup() {
  rm -f "${ntp_list_file}"
}
trap cleanup EXIT
chmod 0600 "${ntp_list_file}"
printf '%s\n' "${ntp_servers[@]}" >"${ntp_list_file}"
python3 - "${ntp_list_file}" <<'PY'
import pathlib
import socket
import sys

servers = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
request = b"\x1b" + (b"\0" * 47)
for index, server in enumerate(servers, start=1):
    try:
        addresses = socket.getaddrinfo(server, 123, type=socket.SOCK_DGRAM)
    except socket.gaierror:
        raise SystemExit(f"[FAIL] NTP[{index}] DNS 조회 실패") from None
    reachable = False
    for family, socktype, proto, _, address in addresses:
        sock = socket.socket(family, socktype, proto)
        sock.settimeout(3)
        try:
            sock.sendto(request, address)
            response, _ = sock.recvfrom(512)
            mode = response[0] & 0x07 if response else 0
            stratum = response[1] if len(response) > 1 else 0
            if len(response) >= 48 and mode in (4, 5) and 0 < stratum < 16 \
                    and any(response[40:48]):
                reachable = True
                break
        except OSError:
            pass
        finally:
            sock.close()
    if not reachable:
        raise SystemExit(f"[FAIL] NTP[{index}] UDP 123 응답 검증 실패")
print(f"[OK]   NTP endpoint {len(servers)}개 DNS/UDP 123 응답 확인")
PY

printf '[PLAN] systemd-timesyncd 서버 %d개 수렴\n' "${#ntp_servers[@]}"
printf '[PLAN] %s 시작을 systemd-time-wait-sync 뒤로 고정\n' "${gated_unit}"
if [[ ${APPLY} != true ]]; then
  printf '[PLAN] 변경 없음. 적용하려면 --apply\n'
  exit 0
fi

config_temp=$(mktemp /run/sadp-timesyncd.XXXXXX)
{
  printf '[Time]\nNTP='
  printf '%s ' "${ntp_servers[@]}"
  printf '\nFallbackNTP=\n'
} >"${config_temp}"
install -d -m 0755 "$(dirname "${TIMESYNCD_CONFIG}")"
install -m 0644 "${config_temp}" "${TIMESYNCD_CONFIG}"
rm -f "${config_temp}"

dropin_dir=/etc/systemd/system/${gated_unit}.d
install -d -m 0755 "${dropin_dir}"
install -m 0644 /dev/stdin "${dropin_dir}/20-sadp-time-sync.conf" <<'UNIT'
[Unit]
Wants=systemd-time-wait-sync.service
After=systemd-time-wait-sync.service time-sync.target
UNIT

systemctl daemon-reload
systemctl enable systemd-timesyncd.service >/dev/null
systemctl enable systemd-time-wait-sync.service >/dev/null 2>&1 \
  || systemctl add-wants time-sync.target systemd-time-wait-sync.service >/dev/null
timedatectl set-ntp true
systemctl restart systemd-timesyncd.service

deadline=$((SECONDS + SYNC_WAIT_SECONDS))
while [[ $(timedatectl show -p NTPSynchronized --value) != yes ]]; do
  ((SECONDS < deadline)) || die "NTP 동기화가 제한 시간 안에 완료되지 않음"
  sleep 1
done
systemctl is-active --quiet systemd-timesyncd.service \
  || die "systemd-timesyncd.service가 active가 아님"
after_units=$(systemctl show "${gated_unit}" -p After --value)
wanted_units=$(systemctl show "${gated_unit}" -p Wants --value)
grep -qw systemd-time-wait-sync.service <<<"${after_units}" \
  && grep -qw systemd-time-wait-sync.service <<<"${wanted_units}" \
  || die "인증 서비스의 time sync 시작 순서 적용 실패"

ok "NTPSynchronized=yes"
ok "재부팅 시 인증 서비스가 time sync 완료 뒤 시작하도록 적용"
printf '[NOTE] 실행 중인 Keycloak/Docker는 자동 재시작하지 않음\n'
