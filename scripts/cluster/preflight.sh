#!/usr/bin/env bash
# 원툴 설치가 리소스를 만들기 전에 RKE2와 영속 스토리지의 실제 사용 가능성을 검증한다.
set -euo pipefail

source "$(dirname "$0")/../lib/testbed-common.sh"

IMAGE_PULL_ONLY=false
while (($#)); do
  case "$1" in
    --image-pull-only) IMAGE_PULL_ONLY=true ;;
    -h|--help)
      cat <<'EOF'
usage: sudo bash ./sadp --preflight [--image-pull-only]

기본은 계약의 single/multi(1+N) topology, 기본 StorageClass provisioning, 실제 CRI image pull을 검사한다.
--image-pull-only는 topology/StorageClass를 생략하고 모든 Linux node의 proxy/containerd
재시작 반영 여부를 digest 고정 image의 Always pull로 빠르게 재검사한다.
EOF
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

for command in python3 jq; do require_command "${command}"; done
if [[ ${IMAGE_PULL_ONLY} != true ]]; then
  require_command "${HELM_BIN}"
fi
[[ -x ${KUBECTL_BIN} ]] || die "kubectl 없음: ${KUBECTL_BIN}"

if [[ ${IMAGE_PULL_ONLY} != true ]]; then
  echo "== 버전 =="
  kctl version --short 2>/dev/null || kctl version
  "${HELM_BIN}" version --short

  echo "== 노드 =="
  kctl get nodes -o wide
  check_cluster_topology

  echo "== StorageClass(기본값 1개 필수) =="
  kctl get storageclass
  default_storage_classes=$(kctl get storageclass -o json | jq '[.items[] | select(
    .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true"
    or .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true"
  )] | length')
  [[ ${default_storage_classes} -eq 1 ]] \
    || die "기본 StorageClass는 정확히 1개여야 함: ${default_storage_classes}"
fi

preflight_namespace="sadp-preflight-$(date +%s)-$$"
preflight_created=false
cleanup() {
  if [[ ${preflight_created} == true ]]; then
    kctl delete namespace "${preflight_namespace}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

preflight_created=true
kctl create namespace "${preflight_namespace}" >/dev/null
if [[ ${IMAGE_PULL_ONLY} != true ]]; then
  echo "== 동적 provisioning 실검증 =="
  kctl -n "${preflight_namespace}" apply -f - <<'PVC'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: preflight-pvc}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
# WaitForFirstConsumer StorageClass는 소비 Pod가 scheduler에 배치되어야 PV를 만든다.
# Pod가 Running일 필요는 없으므로 provisioning 검증은 PVC Bound까지만 기다린다.
apiVersion: v1
kind: Pod
metadata: {name: preflight-volume-consumer}
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: volume-consumer
      image: registry.k8s.io/pause:3.10@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a
      imagePullPolicy: IfNotPresent
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: data, mountPath: /data}
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: preflight-pvc}
PVC
  kctl -n "${preflight_namespace}" wait --for=jsonpath='{.status.phase}'=Bound pvc/preflight-pvc --timeout=90s
  ok "기본 StorageClass dynamic provisioning 정상"

  echo "== 여유 자원(single은 server, multi는 worker에서 빌드) =="
  kctl top nodes 2>/dev/null || echo "metrics-server 미설치(선택)"

  if kctl get crd applications.argoproj.io >/dev/null 2>&1 \
    && kctl get deployment -n devtroncd argocd-repo-server >/dev/null 2>&1; then
    ok "Devtron/Argo CD 기존 설치 감지"
  else
    note "Devtron/Argo CD 없음: 원툴 cluster apply가 고정 버전으로 설치함"
  fi
fi

echo "== 모든 Linux node 실제 CRI pull =="
kctl -n "${preflight_namespace}" apply -f - <<'PULL'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cri-image-pull
spec:
  selector:
    matchLabels: {app.kubernetes.io/name: sadp-cri-image-pull}
  template:
    metadata:
      labels: {app.kubernetes.io/name: sadp-cri-image-pull}
    spec:
      automountServiceAccountToken: false
      hostNetwork: true
      nodeSelector: {kubernetes.io/os: linux}
      tolerations: [{operator: Exists}]
      containers:
        - name: pull
          image: registry.k8s.io/pause:3.10@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a
          imagePullPolicy: Always
PULL

if ! kctl rollout status -n "${preflight_namespace}" daemonset/cri-image-pull --timeout=180s >/dev/null; then
  kctl get pods -n "${preflight_namespace}" -o json | jq -r '
    .items[]
    | [
        (.spec.nodeName // "<unassigned>"),
        (.metadata.name // "<unknown>"),
        (.status.phase // "<unknown>"),
        (.status.containerStatuses[0].state.waiting.reason // "<none>"),
        (.status.containerStatuses[0].state.waiting.message // "<none>")
      ]
    | @tsv
  ' | awk 'BEGIN {print "NODE\tPOD\tPHASE\tWAITING_REASON\tWAITING_MESSAGE"} {print}' >&2 || true
  cat >&2 <<'EOF'
[NEXT] sudo bash ./sadp --manage-containerd-proxy
[NEXT] Forbidden/403이면 Squid 호스트 access.log의 TCP_DENIED와 redirect 호스트 allowlist를 먼저 확인한다.
[NEXT] Squid 호스트에서 sudo bash ./sadp --discover-registry-egress로 동적 후보를 확인하고 --apply로 반영한다.
[NEXT] allowlist 누락이면 site.env/계약 수정·재렌더 후 Squid 호스트에서 sudo bash ./sadp --install-squid --skip-package-install
[NEXT] Squid allowlist만 바뀌면 RKE2 재시작 없이 --preflight --image-pull-only로 재검사한다.
[NEXT] 아래 apply/순차 재시작은 containerd proxy 설정 변경이 필요한 경우에만 수행한다.
[NEXT] sudo bash ./sadp --manage-containerd-proxy --apply
[NEXT] 위 plan이 출력한 worker 한 대씩 → server 마지막 순서로 RKE2를 수동 재시작한다.
[NEXT] sudo bash ./sadp --manage-containerd-proxy --check
[NEXT] sudo bash ./sadp --preflight --image-pull-only
EOF
  die "모든 Linux node의 실제 CRI pull이 성공하지 않음(Pod log와 환경값은 출력하지 않음)"
fi
ok "모든 Linux node에서 digest 고정 public image Always CRI pull 성공"
