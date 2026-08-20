#!/usr/bin/env bash
# Verify the rendered allowlist through Squid without changing the host or cluster.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
EXPECT_DIRECT_BLOCKED=false
[[ ${1:-} != --expect-direct-blocked ]] || EXPECT_DIRECT_BLOCKED=true

cd "${ROOT}"
python3 scripts/site/render-network.py --check
source platform/network/proxy.env
command -v curl >/dev/null || { echo "[FAIL] curl이 필요함" >&2; exit 1; }

allowed=(
  https://acme-staging-v02.api.letsencrypt.org/directory
  https://acme-v02.api.letsencrypt.org/directory
  https://registry.npmjs.org/next
  https://pypi.org/simple/pip/
  https://ftp.kaist.ac.kr/ubuntu/
)
for target in "${allowed[@]}"; do
  # ACME directory는 cert-manager와 같은 GET으로 확인하며, package URL에도 GET은 안전하다.
  curl --silent --show-error --fail --location --max-time 20 \
    --proxy "${HTTPS_PROXY}" "${target}" >/dev/null
  echo "[OK] Squid 허용: ${target}"
done

if curl --silent --show-error --fail --head --max-time 10 \
  --proxy "${HTTPS_PROXY}" https://example.com/ >/dev/null 2>&1; then
  echo "[FAIL] allowlist 밖 example.com이 Squid를 통과함" >&2
  exit 1
fi
echo "[OK] Squid 비허용 목적지 차단"

if [[ ${EXPECT_DIRECT_BLOCKED} == true ]]; then
  if curl --silent --show-error --fail --head --max-time 10 \
    --noproxy '*' https://example.com/ >/dev/null 2>&1; then
    echo "[FAIL] 직접 인터넷 연결이 열려 있음" >&2
    exit 1
  fi
  echo "[OK] 직접 인터넷 연결 차단"
fi
