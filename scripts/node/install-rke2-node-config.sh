#!/usr/bin/env bash
# 저장소가 생성한 RKE2 노드 설정을 실제 노드 /etc/rancher/rke2/config.yaml 에 반영한다.
#
# rke/control-node/config.yaml 과 rke/worker-node/config.yaml 은 configure-site.py 가
# 계약에서 생성한다. 지금까지 이 파일을 노드로 옮기는 절차가 없어서, 노드가 저장소 계약과
# 어긋난 채로 운영되는 드리프트가 발생했다. 대표 사례가 rke2-ingress-nginx 미비활성이며,
# 이때 hostPort 80/443 을 선점당해 공인 IP 요청이 nginx 404 와 fake 인증서로 떨어진다.
#
# token 같은 노드 고유 값은 저장소가 알 수 없으므로 항상 노드 값을 유지한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

ROLE=
TARGET=/etc/rancher/rke2/config.yaml
APPLY=false
ALL=false
INCLUDE_KEYS=

while (($#)); do
  case "$1" in
    --role) ROLE=${2:-}; shift ;;
    --target) TARGET=${2:-}; shift ;;
    --apply) APPLY=true ;;
    --all) ALL=true ;;
    --include) INCLUDE_KEYS="${INCLUDE_KEYS}${INCLUDE_KEYS:+,}${2:-}"; shift ;;
    -h|--help)
      cat <<'EOF'
usage: sudo scripts/node/install-rke2-node-config.sh --role server|agent [--apply]
                                                [--include <key>]... | [--all]
                                                [--target /etc/rancher/rke2/config.yaml]

기본값은 계약이 소유한 키(disable)만 노드에 맞춘다. 나머지 차이는 보고만 하고 건드리지
않는다. node-taint 나 kube-apiserver-arg 처럼 운영자가 노드에서 조정하는 값을 말없이
덮으면 Pod 재스케줄 같은 부작용이 생기기 때문이다.

--include 는 그 키 하나만 추가로 반영한다. 여러 번 쓸 수 있다. 운영 노드에서 감사 로그처럼
특정 설정만 켤 때 쓴다. 예: --include kube-apiserver-arg
--all 은 템플릿 전체를 반영한다. 값이 아직 없는 신규 노드에만 쓴다. 기존 운영 노드에
쓰면 node-taint 까지 바뀌어 NoExecute 축출이 일어날 수 있다.
--apply 없이 실행하면 변경될 키만 보여주는 dry-run 이다.
token 은 어떤 경우에도 노드 값을 유지하며 화면에 출력하지 않는다.
반영 뒤에는 sudo systemctl restart rke2-server(또는 rke2-agent)가 필요하다.
EOF
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

case "${ROLE}" in
  server) SOURCE=${TESTBED_ROOT}/rke/control-node/config.yaml ;;
  agent) SOURCE=${TESTBED_ROOT}/rke/worker-node/config.yaml ;;
  *) die "--role server|agent 가 필요함" ;;
esac

require_root
require_command python3
[[ -r ${SOURCE} ]] || die "저장소 템플릿을 읽을 수 없음: ${SOURCE}"
[[ -r ${TARGET} ]] || die "노드 설정을 읽을 수 없음: ${TARGET}"

# 템플릿이 계약과 동기화된 상태인지 먼저 확인한다. 어긋난 템플릿을 노드에 밀면 안 된다.
python3 "${TESTBED_ROOT}/scripts/site/configure-site.py" --check >/dev/null 2>&1 ||
  note "configure-site.py --check 를 건너뜀(site.env 미구성). 템플릿 내용만 반영한다."

merged=$(mktemp)
report=$(mktemp)
trap 'rm -f "${merged}" "${report}"' EXIT
chmod 0600 "${merged}"

ALL=${ALL} INCLUDE_KEYS=${INCLUDE_KEYS} SOURCE=${SOURCE} TARGET=${TARGET} \
MERGED=${merged} REPORT=${report} \
python3 <<'PY'
import os
import sys

import yaml

# 계약이 소유하는 키. 노드에서 임의로 바꾸면 외부 진입 경로가 깨진다.
CONTRACT_KEYS = {"disable"}

source = yaml.safe_load(open(os.environ["SOURCE"], encoding="utf-8")) or {}
target = yaml.safe_load(open(os.environ["TARGET"], encoding="utf-8")) or {}
sync_all = os.environ["ALL"] == "true"
included = {item.strip() for item in os.environ.get("INCLUDE_KEYS", "").split(",") if item.strip()}
unknown = sorted(key for key in included if key not in source)
if unknown:
    print(f"[FAIL] --include 한 키가 템플릿에 없다: {', '.join(unknown)}", file=sys.stderr)
    raise SystemExit(1)
allowed = CONTRACT_KEYS | included

merged = dict(target)
changes: list[str] = []
skipped: list[str] = []
for key, value in source.items():
    # token 은 노드 고유 값이다. 템플릿은 항상 빈 문자열이므로 절대 반영하지 않는다.
    if key == "token":
        continue
    if target.get(key) == value:
        continue
    if not sync_all and key not in allowed:
        skipped.append(key)
        continue
    merged[key] = value
    changes.append(key)

# disable 은 계약의 핵심이므로 템플릿에서 빠져 있어도 최소 보장을 남긴다.
disabled = merged.get("disable") or []
if isinstance(disabled, str):
    disabled = [disabled]
if "rke2-ingress-nginx" not in disabled:
    merged["disable"] = [*disabled, "rke2-ingress-nginx"]
    if "disable" not in changes:
        changes.append("disable")

with open(os.environ["MERGED"], "w", encoding="utf-8") as handle:
    handle.write("# Managed by scripts/node/install-rke2-node-config.sh.\n")
    handle.write("# 노드 고유 값(token 등)은 유지되고 계약 소유 키는 저장소 템플릿을 따른다.\n")
    yaml.safe_dump(merged, handle, allow_unicode=True, sort_keys=False)

with open(os.environ["REPORT"], "w", encoding="utf-8") as handle:
    for key in changes:
        # 값이 아니라 키만 적는다. 설정 파일에는 자격증명이 섞일 수 있다.
        handle.write(f"change {key}\n")
    for key in skipped:
        handle.write(f"skip {key}\n")

if not merged.get("token"):
    print("[WARN] 노드 설정에 token 이 비어 있다. 반영 전에 확인이 필요하다.", file=sys.stderr)
PY

if grep -q '^skip ' "${report}"; then
  note "노드에만 있는 차이(건드리지 않음). 의도한 값인지 확인한다:"
  awk '/^skip /{print "       - " $2}' "${report}"
  note "템플릿 값으로 맞추려면 --all 을 붙인다. 운영 노드에서는 영향 확인이 먼저다."
fi

if ! grep -q '^change ' "${report}"; then
  ok "계약 소유 키가 이미 노드와 일치함: ${TARGET}"
  exit 0
fi

note "변경될 키:"
awk '/^change /{print "       - " $2}' "${report}"

if [[ ${APPLY} != true ]]; then
  note "dry-run 이다. 실제로 반영하려면 --apply 를 붙인다."
  exit 0
fi

ensure_state_dirs
backup=${BACKUP_DIR}/$(basename "${TARGET}").$(date +%Y%m%d-%H%M%S)
install -m 0600 "${TARGET}" "${backup}"
install -m 0600 "${merged}" "${TARGET}"
ok "노드 설정 반영 완료. 백업: ${backup}"
if [[ ${ROLE} == server ]]; then
  note "적용하려면: sudo systemctl restart rke2-server"
else
  note "적용하려면: sudo systemctl restart rke2-agent"
fi
