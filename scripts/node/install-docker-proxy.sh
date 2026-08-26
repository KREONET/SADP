#!/usr/bin/env bash
# control-plane Docker daemon의 외부 pull을 계약 Squid로 고정한다.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROXY_ENV=${ROOT}/platform/network/proxy.env
APPLY=false
CHECK_ONLY=false

usage() {
  cat <<'EOF'
usage: sudo scripts/node/install-docker-proxy.sh [--proxy-env <path>] [--apply|--check]

기본은 systemd drop-in 계획만 출력한다. --apply는 설정을 쓰고 daemon-reload까지만 수행하며
Docker를 자동 재시작하지 않는다. --check는 설정 파일과 실행 중 daemon 환경이 모두 계약과
같은지 확인한다.
EOF
}

while (($#)); do
  case "$1" in
    --proxy-env) PROXY_ENV=${2:?--proxy-env 값 필요}; shift ;;
    --apply) APPLY=true ;;
    --check) CHECK_ONLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[FAIL] 알 수 없는 인자: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ ${APPLY} == false || ${CHECK_ONLY} == false ]] || {
  printf '[FAIL] --apply와 --check는 함께 사용할 수 없음\n' >&2
  exit 2
}
[[ -r ${PROXY_ENV} ]] || {
  printf '[FAIL] proxy env를 읽을 수 없음: %s\n' "${PROXY_ENV}" >&2
  exit 1
}

# shellcheck disable=SC1090
source "${PROXY_ENV}"
: "${HTTP_PROXY:?HTTP_PROXY가 비어 있음}"
: "${HTTPS_PROXY:?HTTPS_PROXY가 비어 있음}"
: "${NO_PROXY:?NO_PROXY가 비어 있음}"

target=/etc/systemd/system/docker.service.d/sadp-proxy.conf
temporary=$(mktemp)
trap 'rm -f "${temporary}"' EXIT
cat >"${temporary}" <<EOF
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY}"
Environment="HTTPS_PROXY=${HTTPS_PROXY}"
Environment="NO_PROXY=${NO_PROXY}"
EOF

if [[ ${CHECK_ONLY} == true ]]; then
  command -v docker >/dev/null 2>&1 || {
    printf '[FAIL] Docker가 없다. monitoring 이미지 동기화 전에 설치해야 함\n' >&2
    exit 1
  }
  systemctl is-active --quiet docker || {
    printf '[FAIL] docker service가 active가 아님\n' >&2
    exit 1
  }
  [[ -f ${target} ]] && cmp -s "${temporary}" "${target}" || {
    printf '[FAIL] Docker daemon proxy가 계약과 다름. node phase를 적용하고 Docker를 재시작해야 함\n' >&2
    exit 1
  }
  daemon_environment=$(systemctl show docker --property=Environment --value)
  for expected in \
    "HTTP_PROXY=${HTTP_PROXY}" \
    "HTTPS_PROXY=${HTTPS_PROXY}" \
    "NO_PROXY=${NO_PROXY}"; do
    grep -Fq "${expected}" <<<"${daemon_environment}" || {
      printf '[FAIL] 실행 중 Docker daemon에 %s 미반영. systemctl restart docker 필요\n' \
        "${expected%%=*}" >&2
      exit 1
    }
  done
  printf '[OK]   Docker daemon이 계약 Squid/NO_PROXY를 사용함\n'
  exit 0
fi

if [[ ${APPLY} == false ]]; then
  printf '# %s\n' "${target}"
  cat "${temporary}"
  printf '[INFO] 적용 후 유지보수 창에서 실행: systemctl restart docker\n'
  exit 0
fi

[[ ${EUID} -eq 0 ]] || {
  printf '[FAIL] --apply는 root 권한이 필요함\n' >&2
  exit 1
}
install -D -m 0644 "${temporary}" "${target}"
systemctl daemon-reload
printf '[OK]   Docker daemon Squid proxy 설정 설치: %s\n' "${target}"
printf '[INFO] Docker는 자동 재시작하지 않았다. monitoring 이미지 동기화 전에 실행: systemctl restart docker\n'
