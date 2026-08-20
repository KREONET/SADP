#!/usr/bin/env bash
# RKE2 자체가 아니라 embedded containerd의 외부 image pull만 Squid를 사용하게 한다.
set -euo pipefail

ROLE=
PROXY_ENV=
ROOT_PREFIX=
APPLY=false
RESTART=false

while (($#)); do
  case "$1" in
    --role) ROLE=${2:-}; shift ;;
    --proxy-env) PROXY_ENV=${2:-}; shift ;;
    --root-prefix) ROOT_PREFIX=${2:-}; shift ;;
    --apply) APPLY=true ;;
    --restart) RESTART=true ;;
    -h|--help)
      cat <<'EOF'
usage: sudo scripts/node/install-rke2-containerd-proxy.sh \
  --role server|agent [--proxy-env platform/network/proxy.env] \
  [--root-prefix /host] [--apply] [--restart]

--root-prefix는 host root를 /host에 mount한 privileged Pod에서만 사용한다.
기본 동작은 변경 없이 생성할 관리 블록을 출력한다.
EOF
      exit 0
      ;;
    *) echo "[FAIL] 알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ ${ROLE} == server || ${ROLE} == agent ]] || {
  echo "[FAIL] --role server|agent가 필요함" >&2
  exit 2
}
[[ ${RESTART} == false || ${APPLY} == true ]] || {
  echo "[FAIL] --restart는 --apply와 함께 사용해야 함" >&2
  exit 2
}
if [[ -z ${PROXY_ENV} ]]; then
  PROXY_ENV=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/platform/network/proxy.env
fi
[[ -r ${PROXY_ENV} ]] || {
  echo "[FAIL] proxy env를 읽을 수 없음: ${PROXY_ENV}" >&2
  exit 1
}
if [[ -n ${ROOT_PREFIX} ]]; then
  [[ ${ROOT_PREFIX} == /* && ${ROOT_PREFIX} != / ]] || {
    echo "[FAIL] --root-prefix는 /가 아닌 절대 경로여야 함" >&2
    exit 2
  }
  [[ -d ${ROOT_PREFIX}/etc/default && -d ${ROOT_PREFIX}/proc ]] || {
    echo "[FAIL] host root mount가 아님: ${ROOT_PREFIX}" >&2
    exit 1
  }
fi

# shellcheck disable=SC1090
source "${PROXY_ENV}"
: "${HTTP_PROXY:?HTTP_PROXY가 비어 있음}"
: "${HTTPS_PROXY:?HTTPS_PROXY가 비어 있음}"
: "${NO_PROXY:?NO_PROXY가 비어 있음}"
python_command=(python3)
if ! command -v python3 >/dev/null 2>&1; then
  [[ -n ${ROOT_PREFIX} && -x ${ROOT_PREFIX}/usr/bin/python3 ]] || {
    echo "[FAIL] proxy 검증에 사용할 python3를 찾을 수 없음" >&2
    exit 1
  }
  python_command=(chroot "${ROOT_PREFIX}" /usr/bin/python3)
fi
"${python_command[@]}" - "${HTTP_PROXY}" "${HTTPS_PROXY}" "${NO_PROXY}" <<'PY'
import sys
from urllib.parse import urlsplit

for name, value in zip(("HTTP_PROXY", "HTTPS_PROXY"), sys.argv[1:3]):
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
        raise SystemExit(f"{name}는 credential 없는 http(s) URL이어야 함")
    if any(character.isspace() for character in value):
        raise SystemExit(f"{name}에 공백을 사용할 수 없음")

no_proxy = sys.argv[3]
if not no_proxy or any(character.isspace() for character in no_proxy):
    raise SystemExit("NO_PROXY는 공백 없는 comma 목록이어야 함")
PY

begin='# BEGIN SADP MANAGED CONTAINERD PROXY'
end='# END SADP MANAGED CONTAINERD PROXY'
block=$(cat <<EOF
${begin}
CONTAINERD_HTTP_PROXY=${HTTP_PROXY}
CONTAINERD_HTTPS_PROXY=${HTTPS_PROXY}
CONTAINERD_NO_PROXY=${NO_PROXY}
${end}
EOF
)

if [[ ${APPLY} == false ]]; then
  printf '%s\n' "${block}"
  exit 0
fi

[[ ${EUID} -eq 0 ]] || {
  echo "[FAIL] --apply는 root 권한이 필요함" >&2
  exit 1
}
target=${ROOT_PREFIX}/etc/default/rke2-${ROLE}
temporary=$(mktemp)
trap 'rm -f "${temporary}"' EXIT

if [[ -f ${target} ]]; then
  awk -v begin="${begin}" -v end="${end}" '
    $0 == begin { managed=1; next }
    $0 == end { managed=0; next }
    !managed { print }
  ' "${target}" >"${temporary}"
fi
while [[ -s ${temporary} && $(tail -c 1 "${temporary}" | wc -l) -eq 0 ]]; do
  printf '\n' >>"${temporary}"
done
printf '%s\n' "${block}" >>"${temporary}"
install -m 0600 "${temporary}" "${target}"
echo "[OK] ${target} containerd proxy 설치"

if [[ ${RESTART} == true ]]; then
  service=rke2-${ROLE}
  if [[ -z ${ROOT_PREFIX} ]]; then
    systemctl restart "${service}"
  else
    chroot "${ROOT_PREFIX}" /usr/bin/nsenter -t 1 -m -p -n \
      /usr/bin/systemctl restart "${service}"
  fi
  echo "[OK] ${service} 재시작 요청"
fi
