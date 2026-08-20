#!/usr/bin/env bash
# Install the contract-rendered explicit Squid proxy on the selected egress host.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SKIP_PACKAGE_INSTALL=false
CHECK_ONLY=false

usage() {
  echo "usage: sudo $0 [--skip-package-install] [--check]" >&2
}

while (($#)); do
  case "$1" in
    --skip-package-install) SKIP_PACKAGE_INSTALL=true ;;
    --check) CHECK_ONLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

[[ ${EUID} -eq 0 ]] || { echo "[FAIL] root 권한이 필요함" >&2; exit 1; }
command -v python3 >/dev/null || { echo "[FAIL] python3가 필요함" >&2; exit 1; }
command -v curl >/dev/null || { echo "[FAIL] curl이 필요함" >&2; exit 1; }

cd "${ROOT}"
python3 scripts/site/render-network.py --check
bootstrap_http_proxy=${HTTP_PROXY:-${http_proxy:-}}
bootstrap_https_proxy=${HTTPS_PROXY:-${https_proxy:-}}
bootstrap_no_proxy=${NO_PROXY:-${no_proxy:-}}
source platform/network/proxy.env
rendered_http_proxy=${HTTP_PROXY}
rendered_https_proxy=${HTTPS_PROXY}
rendered_no_proxy=${NO_PROXY}
proxy_address=${HTTP_PROXY#http://}
proxy_ip=${proxy_address%:*}
proxy_port=${proxy_address##*:}

# pipefail 이 켜져 있으므로 `cmd | grep -q` 는 쓰지 않는다. grep -q 가 첫 매치에서
# 바로 끝나면 왼쪽 명령이 SIGPIPE(141)로 죽고, 매치에 성공했는데도 파이프라인이
# 실패로 판정된다. 출력을 먼저 변수에 담아 검사한다.
listener_has() { grep -Fq "$1" <<<"$2"; }

check_installed_config() {
  [[ -f /etc/squid/squid.conf ]] || {
    echo "[FAIL] /etc/squid/squid.conf 없음" >&2
    return 1
  }
  cmp -s platform/network/squid/squid.conf /etc/squid/squid.conf || {
    echo "[FAIL] 설치된 Squid 설정이 계약 생성물과 다름. --check 없이 다시 적용 필요" >&2
    return 1
  }
  # 저장소 파일만 parse 하면 daemon 이 오래된 설정으로 떠 있어도 [OK]가 된다.
  squid -k parse -f /etc/squid/squid.conf
  systemctl is-active --quiet squid || {
    echo "[FAIL] squid service가 active가 아님" >&2
    return 1
  }
}

check_acme_egress() {
  local target
  for target in \
    https://acme-staging-v02.api.letsencrypt.org/directory \
    https://acme-v02.api.letsencrypt.org/directory; do
    # HEAD 지원 여부에 기대지 않고 cert-manager와 같은 directory GET을 보낸다.
    curl --silent --show-error --fail --max-time 20 \
      --proxy "${HTTPS_PROXY}" --output /dev/null "${target}"
  done
  echo "[OK] ACME staging/production directory egress 확인"
}

host_addrs=$(ip -4 addr show)
listener_has " ${proxy_ip}/" "${host_addrs}" || {
  echo "[FAIL] 이 호스트에 Squid 내부 IP ${proxy_ip}가 없음" >&2
  exit 1
}

if [[ ${CHECK_ONLY} == true ]]; then
  command -v squid >/dev/null || { echo "[FAIL] squid 미설치" >&2; exit 1; }
  check_installed_config
  listeners=$(ss -ltn)
  listener_has "${proxy_ip}:${proxy_port}" "${listeners}" || {
    echo "[FAIL] ${proxy_ip}:${proxy_port} listener 없음" >&2
    exit 1
  }
  check_acme_egress
  echo "[OK] Squid 설치 설정, service, listener 확인"
  exit 0
fi

if ! command -v squid >/dev/null; then
  [[ ${SKIP_PACKAGE_INSTALL} == false ]] || {
    echo "[FAIL] --skip-package-install을 썼지만 squid가 설치되어 있지 않음" >&2
    exit 1
  }
  # 최초 egress gateway에 Squid 자체가 없을 때만 실행한다. 기존 upstream proxy 환경변수는 apt가 사용한다.
  if [[ -n ${bootstrap_http_proxy} && ${bootstrap_http_proxy} != "${rendered_http_proxy}" ]]; then
    export HTTP_PROXY=${bootstrap_http_proxy} http_proxy=${bootstrap_http_proxy}
    export HTTPS_PROXY=${bootstrap_https_proxy:-${bootstrap_http_proxy}}
    export https_proxy=${HTTPS_PROXY}
    export NO_PROXY=${bootstrap_no_proxy} no_proxy=${bootstrap_no_proxy}
  else
    # 전용 egress 호스트에 승인된 apt mirror direct bootstrap이 허용된 경우.
    unset HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y squid
  export HTTP_PROXY=${rendered_http_proxy} http_proxy=${rendered_http_proxy}
  export HTTPS_PROXY=${rendered_https_proxy} https_proxy=${rendered_https_proxy}
  export NO_PROXY=${rendered_no_proxy} no_proxy=${rendered_no_proxy}
fi

was_active=false
systemctl is-active --quiet squid 2>/dev/null && was_active=true
backup_dir=/var/backups/sadp-squid
install -d -m 0700 "${backup_dir}"
if [[ -f /etc/squid/squid.conf ]]; then
  cp -a /etc/squid/squid.conf "${backup_dir}/squid.conf.$(date -u +%Y%m%dT%H%M%SZ)"
fi
install -D -m 0644 platform/network/squid/squid.conf /etc/squid/squid.conf
install -D -m 0644 \
  platform/network/squid/dns-provider-domains.txt \
  /etc/squid/sadp-dns-provider-domains.txt

squid -k parse
if [[ ${was_active} == true ]]; then
  systemctl reload squid
else
  systemctl enable --now squid
fi
systemctl is-active --quiet squid
listener_ready=false
for _ in {1..20}; do
  listeners=$(ss -ltn)
  if listener_has "${proxy_ip}:${proxy_port}" "${listeners}"; then
    listener_ready=true
    break
  fi
  sleep 0.25
done
[[ ${listener_ready} == true ]] || {
  echo "[FAIL] Squid가 ${proxy_ip}:${proxy_port}에 bind하지 않음" >&2
  exit 1
}
check_installed_config
check_acme_egress

curl --silent --show-error --fail --head --max-time 20 \
  --proxy "${HTTP_PROXY}" https://registry.npmjs.org/next >/dev/null
if curl --silent --show-error --fail --head --max-time 10 \
  --proxy "${HTTP_PROXY}" https://example.com/ >/dev/null 2>&1; then
  echo "[FAIL] allowlist 밖 example.com이 Squid를 통과함" >&2
  exit 1
fi
echo "[OK] Squid 설치, 허용 npm CONNECT, 비허용 목적지 차단 확인"
