#!/usr/bin/env bash
# Persist the rendered NMS gateway/worker configuration as a systemd oneshot unit.
set -euo pipefail

MODE=${1:-}
[[ ${MODE} == gateway || ${MODE} == worker ]] || {
  echo "usage: sudo $0 gateway|worker" >&2
  exit 2
}
[[ ${EUID} -eq 0 ]] || { echo "[FAIL] root 권한이 필요함" >&2; exit 1; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT}"
python3 scripts/site/render-network.py --check
grep -q '^NMS_MODE=network$' platform/network/nms-egress.env || {
  echo "[FAIL] 전용 route/SNAT installer는 NMS network 모드에서만 사용 가능" >&2
  exit 1
}

install -D -m 0755 scripts/node/configure-nms-egress.sh /usr/local/sbin/configure-nms-egress.sh
install -D -m 0600 platform/network/nms-egress.env /etc/sadp/nms-egress.env
install -D -m 0644 platform/network/systemd/sadp-nms-egress@.service \
  /etc/systemd/system/sadp-nms-egress@.service
systemctl daemon-reload
systemctl enable --now "sadp-nms-egress@${MODE}.service"
systemctl is-active --quiet "sadp-nms-egress@${MODE}.service"
echo "[OK] sadp-nms-egress@${MODE} 설치 완료"
