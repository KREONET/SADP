#!/usr/bin/env bash
# StorageClass가 전혀 없는 테스트베드에만 검토된 local-path provisioner를 설치한다.
set -euo pipefail

source "$(dirname "$0")/../lib/testbed-common.sh"

APPLY=false
MANIFEST=docs/examples/local-path-storage.yaml

while (($#)); do
  case "$1" in
    --apply) APPLY=true ;;
    -h|--help)
      cat <<'EOF'
usage: sudo bash ./sadp --install-local-path-storage [--apply]

StorageClass가 하나도 없을 때만 저장소의 고정 버전 local-path provisioner를 준비한다.
기본 모드는 클러스터를 읽고 계획만 출력하며, --apply가 실제 리소스를 설치한다.
기존 StorageClass가 있으면 자동 설치나 기본값 변경을 하지 않는다.
EOF
      exit 0
      ;;
    *) echo "[FAIL] 알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
  shift
done

require_command python3
[[ -x ${KUBECTL_BIN} ]] || die "kubectl 없음: ${KUBECTL_BIN}"
[[ -f ${MANIFEST} ]] || die "local-path manifest 없음: ${MANIFEST}"

storage_json=$(kctl get storageclass -o json)
storage_state=$(python3 -c '
import json, sys
document = json.load(sys.stdin)
items = document.get("items") or []
local = next(
    (item for item in items if (item.get("metadata") or {}).get("name") == "local-path"),
    None,
)
provisioner = (local or {}).get("provisioner") or "-"
print(f"{len(items)}\t{provisioner}")
' <<<"${storage_json}")
IFS=$'\t' read -r storage_count local_provisioner <<<"${storage_state}"
[[ ${local_provisioner} != - ]] || local_provisioner=

if ((storage_count > 0)); then
  if [[ -z ${local_provisioner} ]]; then
    ok "기존 StorageClass ${storage_count}개 감지: local-path 자동 설치 생략"
    exit 0
  fi
  [[ ${local_provisioner} == rancher.io/local-path ]] \
    || die "local-path StorageClass의 provisioner가 예상과 다름: ${local_provisioner}"
  kctl get deployment -n local-path-storage local-path-provisioner >/dev/null 2>&1 \
    || die "local-path StorageClass만 있고 provisioner Deployment가 없는 부분 설치 상태"
  ok "local-path provisioner 기존 설치 감지"
  exit 0
fi

note "StorageClass 없음: 고정 버전 local-path provisioner 설치 대상"
printf '       %q ' "${KUBECTL_BIN}" --kubeconfig "${KUBECONFIG_PATH}" apply -f "${MANIFEST}"
printf '\n'
printf '       %q ' "${KUBECTL_BIN}" --kubeconfig "${KUBECONFIG_PATH}" \
  annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite
printf '\n'
if [[ ${APPLY} != true ]]; then
  note "--apply 전까지 클러스터는 변경되지 않음"
  exit 0
fi

require_root
kctl apply -f "${MANIFEST}"
kctl rollout status deployment/local-path-provisioner \
  -n local-path-storage --timeout=5m
kctl annotate storageclass local-path \
  storageclass.kubernetes.io/is-default-class=true --overwrite
ok "local-path provisioner 설치 및 기본 StorageClass 지정 완료"
