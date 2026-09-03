#!/usr/bin/env bash
# lock에 고정된 RKE2 release만 설치하고 서비스 재시작은 유지보수 경계로 남긴다.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT}"

ROLE=
TARGET_VERSION=
DRAINED_NODE=
APPLY=false
RKE2_BIN=${SADP_RKE2_BIN:-/usr/local/bin/rke2}

usage() {
  cat <<'EOF'
기존 RKE2 노드 업데이트

사용법:
  sudo bash ./sadp --upgrade-rke2 --role agent \
    --drained-node <현재노드명> [--target-version <VERSION>] [--apply]
  sudo bash ./sadp --upgrade-rke2 --role server \
    [--target-version <VERSION>] [--apply]

기본 목표는 versions.lock.yaml의 platform.rke2다. agent 적용은 control-plane에서 해당
노드를 drain했다는 명시적 확인이 필요하다. server 적용 전에는 전체 SADP 백업을 자동 생성한다.
공식 installer가 release checksum을 검증해 바이너리를 교체하지만 RKE2 서비스는 재시작하지 않는다.
EOF
}

while (($#)); do
  case "$1" in
    --role) ROLE=${2:?--role 값 필요}; shift ;;
    --target-version) TARGET_VERSION=${2:?--target-version 값 필요}; shift ;;
    --drained-node) DRAINED_NODE=${2:?--drained-node 값 필요}; shift ;;
    --apply) APPLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[FAIL] 알 수 없는 인자: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
note() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK]   %s\n' "$*"; }

case ${ROLE} in server|agent) ;; *) die "--role은 server|agent 중 하나여야 함" ;; esac
[[ -x ${RKE2_BIN} ]] || die "기존 RKE2 설치를 찾을 수 없음: ${RKE2_BIN}"
[[ -r versions.lock.yaml ]] || die "versions.lock.yaml을 읽을 수 없음"

locked_version=$(python3 - <<'PY'
import yaml
value = str((yaml.safe_load(open("versions.lock.yaml", encoding="utf-8")) or {})["platform"]["rke2"])
print(value)
PY
)
[[ -n ${TARGET_VERSION} ]] || TARGET_VERSION=${locked_version}
[[ ${TARGET_VERSION} == "${locked_version}" ]] \
  || die "목표 ${TARGET_VERSION}이 versions.lock.yaml platform.rke2=${locked_version}와 다름"

current_version=$("${RKE2_BIN}" --version 2>/dev/null | \
  sed -nE 's/^rke2 version (v[0-9]+\.[0-9]+\.[0-9]+\+rke2r[0-9]+).*/\1/p' | head -n 1)
[[ -n ${current_version} ]] || die "현재 RKE2 버전을 판독할 수 없음"

comparison=$(python3 - "${current_version}" "${TARGET_VERSION}" <<'PY'
import re
import sys

pattern = re.compile(r"^v([0-9]+)\.([0-9]+)\.([0-9]+)\+rke2r([0-9]+)$")
parsed = []
for value in sys.argv[1:]:
    match = pattern.fullmatch(value)
    if not match:
        raise SystemExit(f"[FAIL] 지원하지 않는 RKE2 버전 형식: {value}")
    parsed.append(tuple(map(int, match.groups())))
current, target = parsed
if target[:2] > (current[0], current[1] + 1):
    raise SystemExit("[FAIL] RKE2 minor 버전을 한 번에 건너뛸 수 없음; 중간 minor lock부터 순서대로 업데이트")
print((target > current) - (target < current))
PY
) || exit 1

note "RKE2 role=${ROLE} current=${current_version} target=${TARGET_VERSION}"
if ((comparison == 0)); then
  ok "이미 목표 RKE2 ${TARGET_VERSION}"
  exit 0
fi
((comparison > 0)) || die "RKE2 downgrade는 지원하지 않음: ${current_version} -> ${TARGET_VERSION}"

node_name=$(hostname -s)
if [[ ${ROLE} == agent ]]; then
  [[ ${DRAINED_NODE} == "${node_name}" ]] \
    || die "agent 업데이트는 --drained-node ${node_name} 확인이 필요함"
fi

installer_url=${SADP_RKE2_INSTALLER_URL:-https://raw.githubusercontent.com/rancher/rke2/${TARGET_VERSION}/install.sh}
note "공식 RKE2 installer: ${installer_url}"
note "설치 후 자동 재시작하지 않음: systemctl restart rke2-${ROLE}"
if [[ ${APPLY} == false ]]; then
  note "계획만 확인함. 적용하려면 같은 명령에 --apply"
  exit 0
fi

[[ $(id -u) -eq 0 ]] || die "RKE2 적용은 root로 실행해야 함"
systemctl is-active --quiet "rke2-${ROLE}.service" \
  || die "업데이트 전 rke2-${ROLE}.service가 active가 아님"

if [[ ${ROLE} == server ]]; then
  note "server 업데이트 전 RKE2/OpenBao 전체 백업"
  bash scripts/ops/backup-testbed.sh
fi

tmp_dir=$(mktemp -d -t sadp-rke2-upgrade.XXXXXXXXXX)
trap 'rm -rf "${tmp_dir}"' EXIT
installer=${tmp_dir}/install.sh
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "${installer_url}" --output "${installer}"
grep -q 'INSTALL_RKE2_VERSION' "${installer}" \
  || die "다운로드한 파일이 RKE2 installer 형식이 아님"
chmod 0700 "${installer}"

env INSTALL_RKE2_VERSION="${TARGET_VERSION}" INSTALL_RKE2_TYPE="${ROLE}" \
  sh "${installer}"
installed_version=$("${RKE2_BIN}" --version 2>/dev/null | \
  sed -nE 's/^rke2 version (v[0-9]+\.[0-9]+\.[0-9]+\+rke2r[0-9]+).*/\1/p' | head -n 1)
[[ ${installed_version} == "${TARGET_VERSION}" ]] \
  || die "설치 후 RKE2 binary 버전 불일치: ${installed_version:-unknown}"
ok "RKE2 binary/package ${TARGET_VERSION} 설치 완료"
note "서비스는 아직 이전 process다. 승인된 창에서 systemctl restart rke2-${ROLE} 실행 후 Ready 확인"
