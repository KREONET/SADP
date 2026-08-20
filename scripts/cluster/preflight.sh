#!/usr/bin/env bash
# 원툴 설치가 리소스를 만들기 전에 RKE2와 영속 스토리지의 실제 사용 가능성을 검증한다.
set -euo pipefail

source "$(dirname "$0")/../lib/testbed-common.sh"

for command in python3 jq "${HELM_BIN}"; do require_command "${command}"; done
[[ -x ${KUBECTL_BIN} ]] || die "kubectl 없음: ${KUBECTL_BIN}"

echo "== 버전 =="
kctl version --short 2>/dev/null || kctl version
"${HELM_BIN}" version --short

echo "== 노드 =="
kctl get nodes -o wide
node_count=$(kctl get nodes -o json | jq '.items | length')
not_ready=$(kctl get nodes -o json | jq -r '.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True") | not) | .metadata.name')
[[ ${node_count} -eq 3 ]] || die "RKE2 노드는 정확히 3대여야 함: ${node_count}"
[[ -z ${not_ready} ]] || die "Ready가 아닌 RKE2 노드: ${not_ready//$'\n'/,}"
server_count=$(kctl get nodes -o json | jq '[.items[] | select(
  .metadata.labels["node-role.kubernetes.io/control-plane"] != null
  or .metadata.labels["node-role.kubernetes.io/master"] != null
)] | length')
worker_count=$((node_count - server_count))
[[ ${server_count} -eq 1 && ${worker_count} -eq 2 ]] \
  || die "RKE2 역할은 server 1대 + worker 2대여야 함: server=${server_count}, worker=${worker_count}"
ok "RKE2 노드 3/3 Ready(server 1 + worker 2)"

echo "== StorageClass(기본값 1개 필수) =="
kctl get storageclass
default_storage_classes=$(kctl get storageclass -o json | jq '[.items[] | select(
  .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true"
  or .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true"
)] | length')
[[ ${default_storage_classes} -eq 1 ]] \
  || die "기본 StorageClass는 정확히 1개여야 함: ${default_storage_classes}"

preflight_namespace="sadp-preflight-$(date +%s)-$$"
preflight_created=false
cleanup() {
  if [[ ${preflight_created} == true ]]; then
    kctl delete namespace "${preflight_namespace}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "== 동적 provisioning 실검증 =="
kctl create namespace "${preflight_namespace}" >/dev/null
preflight_created=true
kctl -n "${preflight_namespace}" apply -f - <<'PVC'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: preflight-pvc}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
PVC
kctl -n "${preflight_namespace}" wait --for=jsonpath='{.status.phase}'=Bound pvc/preflight-pvc --timeout=90s
ok "기본 StorageClass dynamic provisioning 정상"

echo "== 여유 자원(Devtron CI는 worker) =="
kctl top nodes 2>/dev/null || echo "metrics-server 미설치(선택)"

if kctl get crd applications.argoproj.io >/dev/null 2>&1 \
  && kctl get deployment -n devtroncd argocd-repo-server >/dev/null 2>&1; then
  ok "Devtron/Argo CD 기존 설치 감지"
else
  note "Devtron/Argo CD 없음: 원툴 cluster apply가 고정 버전으로 설치함"
fi
