#!/usr/bin/env bash
# 서드파티 컨테이너 이미지를 모든 RKE2 노드의 containerd 에 배포한다.
#
# 워커 노드는 설계상 인터넷 egress 가 차단돼 있어 registry 에서 직접 이미지를 받지 못한다.
# 실제로 RKE2 addon 삭제 job 이 워커에서 다음과 같이 실패한 적이 있다.
#   lookup registry-1.docker.io on 127.0.0.53:53: server misbehaving
# 그래서 인터넷이 있는 서버 노드에서 이미지를 받아 tar 로 만들고, 각 노드의 containerd 에
# ctr images import 로 넣는다. scripts/cluster/build-local-images.sh 가 자체 빌드 이미지에 쓰는
# 방식과 같으며, 이 스크립트는 외부에서 받아오는 이미지를 대상으로 한다.
#
# push 하지 않는다. registry credential 도 다루지 않는다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

LOADER=sadp-external-image-loader
IMAGE_LIST=
IMAGES=()
KEEP_ARCHIVE=false

while (($#)); do
  case "$1" in
    --image) IMAGES+=("${2:-}"); shift ;;
    --image-list) IMAGE_LIST=${2:-}; shift ;;
    --keep-archive) KEEP_ARCHIVE=true ;;
    -h|--help)
      cat <<'EOF'
usage: sudo scripts/cluster/sync-external-images.sh --image <ref> [--image ...]
       sudo scripts/cluster/sync-external-images.sh --image-list <file>
       [--keep-archive]

인터넷이 있는 서버 노드에서 이미지를 받아 모든 노드 containerd 에 import 한다.
워커 노드는 egress 가 막혀 있어 직접 pull 하지 못하므로 이 경로가 필요하다.

--image-list 는 한 줄에 이미지 참조 하나를 적은 파일이다. # 주석과 빈 줄은 무시한다.
이미지 참조는 반드시 태그나 digest 를 포함해야 한다. latest 는 거부한다.
--keep-archive 는 전송용 tar 를 상태 디렉터리에 남긴다(기본은 삭제).

예:
  sudo scripts/cluster/sync-external-images.sh \
    --image quay.io/prometheus/prometheus:v3.1.0 \
    --image docker.io/grafana/loki:3.3.2
EOF
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

if [[ -n ${IMAGE_LIST} ]]; then
  [[ -r ${IMAGE_LIST} ]] || die "이미지 목록을 읽을 수 없음: ${IMAGE_LIST}"
  while IFS= read -r line; do
    line=${line%%#*}
    line=$(printf '%s' "${line}" | tr -d '[:space:]')
    [[ -n ${line} ]] && IMAGES+=("${line}")
  done <"${IMAGE_LIST}"
fi

[[ ${#IMAGES[@]} -gt 0 ]] || die "--image 또는 --image-list 로 이미지를 지정해야 함"

for image in "${IMAGES[@]}"; do
  # 태그 없는 참조는 latest 로 해석돼 노드마다 다른 이미지가 들어갈 수 있다.
  if [[ ${image} != *:* && ${image} != *@sha256:* ]]; then
    die "이미지에 태그나 digest 가 없음: ${image}"
  fi
  if [[ ${image} == *:latest ]]; then
    die "가변 태그(latest)는 노드 간 불일치를 만든다: ${image}"
  fi
done

require_root
require_command python3
ensure_state_dirs
cd "${TESTBED_ROOT}"

command -v docker >/dev/null 2>&1 || die "docker 가 필요함(서버 노드에서 이미지를 받는다)"
systemctl is-active --quiet docker || systemctl start docker

# 서버 노드가 registry 로 나갈 때 승인된 Squid 경로를 쓴다.
if [[ -r platform/network/proxy.env ]]; then
  source platform/network/proxy.env
fi
# docker pull의 실제 네트워크 주체는 CLI가 아니라 daemon이다. 셸 env만 설정하고 통과시키면
# direct egress가 열린 호스트에서 정책을 우회할 수 있으므로 실행 중 daemon 환경까지 확인한다.
bash scripts/node/install-docker-proxy.sh --check

archive=${IMAGE_DIR}/external-images-$(date +%Y%m%d-%H%M%S).tar
note "이미지 ${#IMAGES[@]}개를 서버 노드에서 받는다"
archive_images=()
for image in "${IMAGES[@]}"; do
  docker pull "${image}" >/dev/null || die "이미지 pull 실패: ${image}"
  if [[ ${image} == *@sha256:* ]]; then
    repository=${image%@sha256:*}
    digest=${image#*@}
    local_alias="${repository}:sadp-${digest/:/-}"
    # docker archive는 @sha256 입력의 RepoTag를 비워 버릴 수 있다. save 전에 alias를
    # 붙여야 containerd import 뒤에도 workload가 참조할 결정적 이름이 남는다.
    docker tag "${image}" "${local_alias}"
    archive_images+=("${local_alias}")
    ok "digest 이미지 archive alias: ${local_alias}"
  else
    archive_images+=("${image}")
  fi
  ok "pull 완료: ${image}"
done
docker save -o "${archive}" "${archive_images[@]}" || die "이미지 archive 생성 실패"
chmod 0600 "${archive}"

node_count=$(kctl get nodes --no-headers | wc -l)
[[ ${node_count} -gt 0 ]] || die "노드를 찾지 못함"

cleanup_loader() {
  kctl delete daemonset -n kube-system "${LOADER}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup_loader EXIT

# loader 는 이미 노드에 있는 이미지를 쓴다. 새로 받아야 하면 워커에서 또 막힌다.
loader_image=$(kctl get daemonset -n kube-system rke2-canal \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[[ -n ${loader_image} ]] || die "loader 로 쓸 로컬 이미지를 찾지 못함"

kctl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${LOADER}
  namespace: kube-system
spec:
  selector:
    matchLabels: {app: ${LOADER}}
  template:
    metadata:
      labels: {app: ${LOADER}}
    spec:
      automountServiceAccountToken: false
      tolerations:
        - {operator: Exists}
      containers:
        - name: loader
          image: ${loader_image}
          imagePullPolicy: IfNotPresent
          command: [/bin/sh, -c, 'trap : TERM INT; sleep infinity & wait']
          securityContext:
            privileged: true
            runAsUser: 0
          volumeMounts:
            - {name: rke2-bin, mountPath: /hostbin, readOnly: true}
            - {name: containerd-run, mountPath: /run/k3s/containerd}
            - {name: staging, mountPath: /staging}
      volumes:
        - name: rke2-bin
          hostPath: {path: /var/lib/rancher/rke2/bin, type: Directory}
        - name: containerd-run
          hostPath: {path: /run/k3s/containerd, type: Directory}
        - name: staging
          emptyDir: {}
YAML

kctl rollout status -n kube-system "daemonset/${LOADER}" --timeout=10m >/dev/null
mapfile -t loader_pods < <(kctl get pods -n kube-system -l "app=${LOADER}" -o name)
[[ ${#loader_pods[@]} -eq ${node_count} ]] \
  || die "loader Pod 수(${#loader_pods[@]})가 노드 수(${node_count})와 다름"

for pod in "${loader_pods[@]}"; do
  node=$(kctl get -n kube-system "${pod}" -o jsonpath='{.spec.nodeName}')
  kctl exec -i -n kube-system "${pod}" -- /bin/sh -c 'cat > /staging/external-images.tar' <"${archive}"
  kctl exec -n kube-system "${pod}" -- /hostbin/ctr \
    --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
    images import /staging/external-images.tar >/dev/null
  # import 가 조용히 일부만 성공하는 경우를 막으려고 노드마다 존재를 다시 확인한다.
  for image in "${IMAGES[@]}"; do
    if [[ ${image} == *@sha256:* ]]; then
      repository=${image%@sha256:*}
      digest=${image#*@}
      local_alias="${repository}:sadp-${digest/:/-}"
      kctl exec -n kube-system "${pod}" -- /hostbin/ctr \
        --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
        images ls "name==${local_alias}" | awk 'NR == 2 {found = 1} END {exit !found}' \
        || die "${node}: ${local_alias} alias 확인 실패"
      ok "${node}: digest 이미지 로컬 alias ${local_alias}"
    else
      kctl exec -n kube-system "${pod}" -- /hostbin/ctr \
        --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
        images ls "name==${image}" | awk 'NR == 2 {found = 1} END {exit !found}' \
        || die "${node}: ${image} import 확인 실패"
    fi
  done
  ok "${node}: 이미지 ${#IMAGES[@]}개 import 확인"
done

cleanup_loader
trap - EXIT

if [[ ${KEEP_ARCHIVE} == true ]]; then
  sha256sum "${archive}" >"${archive}.sha256"
  ok "이미지 archive 보관: ${archive}"
else
  rm -f "${archive}"
fi
ok "모든 노드에 이미지 배포 완료. Deployment 의 imagePullPolicy 는 IfNotPresent 로 둔다"
