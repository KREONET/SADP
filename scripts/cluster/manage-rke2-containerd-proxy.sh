#!/usr/bin/env bash
# 이미 모든 노드에서 실행 중인 Canal/Calico image를 잠깐 재사용해 host의 proxy 파일을
# 수렴한다. host root 쓰기 때문에 privileged가 필요하지만 리소스와 권한은 작업 직후 제거한다.
set -euo pipefail

source "$(dirname "$0")/../lib/testbed-common.sh"

MODE=plan
WAIT_SECONDS=300

usage() {
  cat <<'EOF'
usage: sudo bash ./sadp --manage-containerd-proxy [--apply|--check]

control-plane에서 모든 Linux 노드의 RKE2 containerd proxy를 같은 생성 입력으로 수렴한다.
기본 plan은 Ready Canal/Calico image와 노드 순서만 검사하고 리소스를 만들지 않는다.
--apply는 관리 블록을 쓰고, --check는 수동 재시작 뒤 실행 중 RKE2/containerd 환경까지
검사한다. 두 모드의 임시 ConfigMap/DaemonSet은 성공·실패·signal 모두에서 삭제된다.
RKE2 서비스는 이 명령이 재시작하지 않는다.
EOF
}

while (($#)); do
  case "$1" in
    --apply) MODE=apply ;;
    --check) MODE=check ;;
    --wait-seconds) WAIT_SECONDS=${2:?--wait-seconds 값 필요}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done
[[ ${WAIT_SECONDS} =~ ^[1-9][0-9]*$ ]] || die "--wait-seconds는 양의 정수여야 함"

for command in python3 jq; do require_command "${command}"; done
[[ -x ${KUBECTL_BIN} ]] || die "kubectl 없음: ${KUBECTL_BIN}"
proxy_env=${TESTBED_ROOT}/platform/network/proxy.env
installer=${TESTBED_ROOT}/scripts/node/install-rke2-containerd-proxy.sh
[[ -f ${proxy_env} && ! -L ${proxy_env} ]] || die "생성 proxy 입력이 일반 파일이 아님"
[[ -f ${installer} && ! -L ${installer} ]] || die "node installer가 일반 파일이 아님"

# 로컬 설치기와 같은 parser가 credential 없는 입력인지 먼저 확인한다. plan 호출은 값이나
# 관리 블록을 출력하지 않으며 role은 여기서 실제 노드마다 자동 판별한다.
bash "${installer}" --role server --proxy-env "${proxy_env}" >/dev/null

temporary_dir=$(mktemp -d)
manifest=${temporary_dir}/daemonset.yaml
nodes_json=${temporary_dir}/nodes.json
pods_json=${temporary_dir}/pods.json
cleanup_registered=false
resource_name="sadp-containerd-proxy-$(date +%s)-$$"

cleanup() {
  local status=$?
  if [[ ${cleanup_registered} == true ]]; then
    kctl -n kube-system delete daemonset "${resource_name}" --ignore-not-found --wait=false \
      >/dev/null 2>&1 || true
    kctl -n kube-system delete configmap "${resource_name}" --ignore-not-found --wait=false \
      >/dev/null 2>&1 || true
  fi
  rm -rf "${temporary_dir}"
  return "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

kctl get nodes -o json >"${nodes_json}"
kctl get pods -n kube-system -o json >"${pods_json}"

mapfile -t selected < <(python3 - "${nodes_json}" "${pods_json}" <<'PY'
import json
import sys

nodes = json.load(open(sys.argv[1], encoding="utf-8"))
pods = json.load(open(sys.argv[2], encoding="utf-8"))
linux_nodes = sorted(
    item["metadata"]["name"]
    for item in nodes.get("items", [])
    if (item.get("status") or {}).get("nodeInfo", {}).get("operatingSystem") == "linux"
)
if not linux_nodes:
    raise SystemExit("[FAIL] Linux node가 없음")

candidates: dict[str, list[tuple[str, str, str]]] = {}
for pod in pods.get("items", []):
    node = (pod.get("spec") or {}).get("nodeName")
    if node not in linux_nodes:
        continue
    conditions = (pod.get("status") or {}).get("conditions") or []
    if not any(item.get("type") == "Ready" and item.get("status") == "True" for item in conditions):
        continue
    pod_name = (pod.get("metadata") or {}).get("name", "")
    for container in (pod.get("spec") or {}).get("containers") or []:
        container_name = str(container.get("name") or "")
        image = str(container.get("image") or "")
        marker = f"{pod_name} {container_name} {image}".lower()
        if image and ("calico" in marker or "canal" in marker):
            candidates.setdefault(image, []).append((node, pod_name, container_name))

for image, rows in sorted(candidates.items()):
    by_node = {row[0]: row for row in rows}
    if all(node in by_node for node in linux_nodes):
        print(image)
        for node in linux_nodes:
            print("\t".join(by_node[node]))
        break
else:
    raise SystemExit("[FAIL] 모든 Linux node에서 Ready인 공통 Canal/Calico image를 찾지 못함")
PY
)
image=${selected[0]:-}
[[ -n ${image} ]] || die "중앙 수렴 image 선택 실패"

for row in "${selected[@]:1}"; do
  IFS=$'\t' read -r node pod container <<<"${row}"
  kctl exec -n kube-system "${pod}" -c "${container}" -- sh -ec '
    for command in sh nsenter cp chmod mkdir rm sleep; do
      command -v "$command" >/dev/null
    done
  ' >/dev/null || die "${node}의 선택 Canal/Calico image에 중앙 수렴 필수 도구가 없음"
done
ok "모든 Linux node의 Ready Canal/Calico image와 sh/nsenter/cp/chmod/mkdir/rm/sleep 확인"

print_restart_plan() {
  local server node
  mapfile -t workers < <(jq -r '
    .items[]
    | select(.status.nodeInfo.operatingSystem == "linux")
    | select((.metadata.labels["node-role.kubernetes.io/control-plane"] // "") == "")
    | select((.metadata.labels["node-role.kubernetes.io/master"] // "") == "")
    | .metadata.name
  ' "${nodes_json}" | sort)
  server=$(jq -r '
    [.items[]
      | select(.status.nodeInfo.operatingSystem == "linux")
      | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != null
          or .metadata.labels["node-role.kubernetes.io/master"] != null)
      | .metadata.name] | if length == 1 then .[0] else empty end
  ' "${nodes_json}")
  [[ -n ${server} ]] || die "server node가 정확히 하나가 아님"

  note "수동 순차 재시작(worker 한 대씩, server 마지막):"
  for node in "${workers[@]}"; do
    printf '       kubectl drain %q --ignore-daemonsets --delete-emptydir-data\n' "${node}"
    printf "       ssh %q 'sudo systemctl restart rke2-agent'\n" "${node}"
    printf '       kubectl wait --for=condition=Ready node/%q --timeout=10m\n' "${node}"
    printf '       kubectl uncordon %q\n' "${node}"
  done
  printf '       kubectl drain %q --ignore-daemonsets --delete-emptydir-data\n' "${server}"
  printf '       sudo systemctl restart rke2-server\n'
  printf '       kubectl wait --for=condition=Ready node/%q --timeout=10m\n' "${server}"
  printf '       kubectl uncordon %q\n' "${server}"
  printf '       sudo bash ./sadp --manage-containerd-proxy --check\n'
  printf '       sudo bash ./sadp --preflight --image-pull-only\n'
}

if [[ ${MODE} == plan ]]; then
  note "plan: 리소스를 만들지 않음. 적용은 sudo bash ./sadp --manage-containerd-proxy --apply"
  print_restart_plan
  exit 0
fi
require_root

cat >"${manifest}" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${resource_name}
  namespace: kube-system
spec:
  selector:
    matchLabels: {app.kubernetes.io/name: ${resource_name}}
  template:
    metadata:
      labels: {app.kubernetes.io/name: ${resource_name}}
    spec:
      automountServiceAccountToken: false
      hostNetwork: true
      hostPID: true
      nodeSelector: {kubernetes.io/os: linux}
      tolerations: [{operator: Exists}]
      containers:
        - name: converge
          image: ${image}
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
          env:
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
          command: [/bin/sh, -ec]
          args:
            - |
              stage=/host/var/lib/sadp/containerd-proxy-converge
              result="\${stage}/\${NODE_NAME}.${MODE}.ok"
              mkdir -p "\${stage}"
              rm -f "\${result}"
              cp /payload/install-rke2-containerd-proxy.sh "\${stage}/installer.sh"
              cp /payload/proxy.env "\${stage}/proxy.env"
              chmod 0700 "\${stage}/installer.sh"
              chmod 0600 "\${stage}/proxy.env"
              nsenter -t 1 -m -p -n -- /bin/bash \
                /var/lib/sadp/containerd-proxy-converge/installer.sh \
                --proxy-env /var/lib/sadp/containerd-proxy-converge/proxy.env --${MODE}
              : >"\${result}"
              while :; do sleep 30; done
          readinessProbe:
            exec: {command: [/bin/sh, -ec, 'test -f "/host/var/lib/sadp/containerd-proxy-converge/\${NODE_NAME}.${MODE}.ok"']}
            periodSeconds: 2
          volumeMounts:
            - {name: host-root, mountPath: /host}
            - {name: payload, mountPath: /payload, readOnly: true}
      volumes:
        - name: host-root
          hostPath: {path: /, type: Directory}
        - name: payload
          configMap: {name: ${resource_name}, defaultMode: 0444}
EOF

# 첫 create가 중간 실패해도 ConfigMap을 남기지 않도록 생성 시도 전에 cleanup 대상을 등록한다.
cleanup_registered=true
kctl -n kube-system create configmap "${resource_name}" \
  --from-file=proxy.env="${proxy_env}" \
  --from-file=install-rke2-containerd-proxy.sh="${installer}" \
  --dry-run=client -o yaml | kctl apply -f - >/dev/null
kctl apply -f "${manifest}" >/dev/null
kctl rollout status -n kube-system daemonset/"${resource_name}" \
  --timeout="${WAIT_SECONDS}s" >/dev/null || {
  kctl get pod -n kube-system -l "app.kubernetes.io/name=${resource_name}" \
    -o custom-columns='NODE:.spec.nodeName,POD:.metadata.name,PHASE:.status.phase,REASON:.status.containerStatuses[0].state.waiting.reason,MESSAGE:.status.containerStatuses[0].state.waiting.message' >&2 || true
  die "중앙 containerd proxy ${MODE} 수렴 실패"
}
ok "모든 Linux node containerd proxy ${MODE} 완료; 임시 DaemonSet/ConfigMap은 종료 시 삭제"
print_restart_plan
