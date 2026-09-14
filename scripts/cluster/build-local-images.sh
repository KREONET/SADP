#!/usr/bin/env bash
# 테스트 이미지를 빌드하고 각 RKE2 containerd에 import한다. push 명령은 없다.
# 빌드는 기본적으로 워커 노드의 임시 Pod에서 돌고, 이 호스트는 조율만 한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

# Next.js 빌드는 코어 수만큼 워커 프로세스를 띄우고 수 GB를 잡는다. control-plane 노드는
# RAM 12GB에 swap이 0이라 여기에 빌드를 얹으면 page cache를 축출했다가 즉시 major fault로
# 다시 읽는 스래싱에 빠지고, etcd/apiserver까지 같이 느려진다(2026-08-10 사고).
# multi는 워커에서 빌드한다. single은 서버의 제한된 Pod를 쓰므로 앱과 빌드 자원을 함께 확보해야 한다.
BUILD_NODE=
EXPORT_ONLY=false
BUILD_ON_CONTROL_PLANE=false
BUILDER_IMAGE=${SADP_BUILDER_IMAGE:-docker.io/library/docker:28.3.3-dind}
BUILDER_MEMORY_LIMIT=${SADP_BUILDER_MEMORY_LIMIT:-10Gi}
BUILDER_CPU_LIMIT=${SADP_BUILDER_CPU_LIMIT:-6}

while (($#)); do
  case "$1" in
    --export-only) EXPORT_ONLY=true ;;
    --build-node) BUILD_NODE=${2:-}; shift ;;
    --build-on-control-plane) BUILD_ON_CONTROL_PLANE=true ;;
    --builder-memory-limit) BUILDER_MEMORY_LIMIT=${2:-}; shift ;;
    --builder-cpu-limit) BUILDER_CPU_LIMIT=${2:-}; shift ;;
    -h|--help)
      cat <<'EOF'
usage: sudo bash scripts/cluster/build-local-images.sh \
  [--build-node <node>] [--builder-memory-limit 10Gi] [--builder-cpu-limit 6] \
  [--build-on-control-plane] [--export-only]

--export-only는 빌드 archive만 만들고 실행 중인 노드 이미지에는 import하지 않는다.

기본 동작은 multi의 워커 또는 single의 서버에 임시 빌더 Pod를 띄워 거기서 Docker 이미지 2개를 빌드하고,
결과 tar만 이 호스트로 받아 전체 노드 containerd에 import 하는 것이다.

--build-node 를 생략하면 Ready 상태이고 cordon 되지 않은 워커 중 allocatable 메모리가
가장 큰 노드를 고른다. single 계약에서는 유일한 서버를 선택한다.
서버를 선택해도 자원 제한이 있는 Pod를 사용하며 host Docker 설치는 하지 않는다.

--builder-memory-limit 은 빌더 Pod의 메모리 상한이다. 빌드가 폭주해도 노드 전체가
스래싱에 빠지는 대신 그 Pod만 OOMKill 되도록 남겨 두는 안전장치이므로 끄지 마라.

--build-on-control-plane 은 워커가 전부 내려간 비상용 우회로다. 이 호스트에 Docker를
설치하고 control-plane 위에서 직접 빌드하므로, 유지보수 창에서만 써라.
EOF
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

require_root
ensure_state_dirs
cd "${TESTBED_ROOT}"

# 잘못된 chart/API/정책을 이미지로 포장하기 전에 로컬에서도 CI와 같은 guard를 실행한다.
bash scripts/tests/render-test.sh
bash scripts/ci-guard.sh

# 루트 .env 전체를 source 하면 명령 치환이 실행되고 서버용 Secret까지 빌드 환경에
# 섞일 수 있다. 전용 파서가 허용한 NEXT_PUBLIC_*만 Docker frontend 빌드에 전달한다.
# 원본 파일은 build context에 넣지 않는다.
portal_ui_build_args=()
portal_ui_env_count=0
if [[ -e .env ]]; then
  [[ -r .env ]] || die "루트 .env를 읽을 수 없음"
  python3 scripts/site/portal-ui-build-env.py --env-file .env --format check
  mapfile -d '' -t portal_ui_assignments \
    < <(python3 scripts/site/portal-ui-build-env.py --env-file .env --format nul)
  portal_ui_env_count=${#portal_ui_assignments[@]}
  portal_ui_env_base64=$(python3 scripts/site/portal-ui-build-env.py --env-file .env --format base64)
  portal_ui_build_args+=(--build-arg "PORTAL_UI_PUBLIC_ENV_B64=${portal_ui_env_base64}")
  ok "루트 .env의 Portal UI 공개 빌드 변수 ${portal_ui_env_count}개 적용"
fi

proxy_args=()
proxy_env_yaml=""
if [[ -r platform/network/proxy.env ]]; then
  source platform/network/proxy.env
  proxy_args=(
    --build-arg "HTTP_PROXY=${HTTP_PROXY}"
    --build-arg "HTTPS_PROXY=${HTTPS_PROXY}"
    --build-arg "NO_PROXY=${NO_PROXY}"
  )
  # dockerd 자신도 base image를 당길 때 프록시가 필요하므로 build-arg와 별개로 넣는다.
  proxy_env_yaml=$(
    printf '        - {name: HTTP_PROXY, value: "%s"}\n' "${HTTP_PROXY}"
    printf '        - {name: HTTPS_PROXY, value: "%s"}\n' "${HTTPS_PROXY}"
    printf '        - {name: NO_PROXY, value: "%s"}\n' "${NO_PROXY}"
    printf '        - {name: http_proxy, value: "%s"}\n' "${HTTP_PROXY}"
    printf '        - {name: https_proxy, value: "%s"}\n' "${HTTPS_PROXY}"
    printf '        - {name: no_proxy, value: "%s"}\n' "${NO_PROXY}"
  )
fi

archive="${IMAGE_DIR}/sadp-state-v1.tar"

# 이미지 이름은 배포가 실제로 요구하는 값이어야 한다. 예전에는 sadp/<app>:testbed-v1 로
# 고정해 import 했는데, 앱 values 는 계약의 registry 경로와 commit SHA 태그를 가리키므로
# pullPolicy=IfNotPresent 가 로컬 이미지를 못 찾고 있지도 않은 registry 로 pull 을 시도했다.
# 그래서 values 를 SSOT 로 삼아 같은 이름으로 빌드하고 import 한다. push 는 여전히 없다.
image_reference() {
  local values=$1
  python3 - "${values}" <<'PY'
import sys, yaml

image = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["image"]
repository = str(image.get("repository") or "").strip()
tag = str(image.get("tag") or "").strip()
if not repository or not tag:
    raise SystemExit(f"[FAIL] {sys.argv[1]}: image.repository/tag 가 비어 있음")
print(f"{repository}:{tag}")
PY
}
TEST_APP_IMAGE=$(image_reference apps/hello/values-beta.yaml) || exit 1
PORTAL_IMAGE=$(image_reference apps/portal-lite/values-beta.yaml) || exit 1
secure_demo_image=$(image_reference apps/secure-demo/values-beta.yaml) || exit 1
# hello 와 secure-demo 는 같은 test-app 이미지를 쓴다. 갈라지면 한쪽이 조용히 못 뜬다.
[[ ${secure_demo_image} == "${TEST_APP_IMAGE}" ]] \
  || die "hello 와 secure-demo 의 image 가 다름: ${TEST_APP_IMAGE} vs ${secure_demo_image}"
ok "빌드 대상 이미지: ${TEST_APP_IMAGE}, ${PORTAL_IMAGE}"

# single만 서버를 허용하고 multi는 워커를 고른다. 역할 label의 빈 값도 서버로 판정한다.
select_build_node() {
  kctl get nodes -o json | python3 scripts/lib/cluster-topology.py \
    --select-builder --build-node "${BUILD_NODE}"
}

builder_pod=sadp-local-image-builder
cleanup_builder() {
  # 종료 중인 Docker 포트가 잠깐 열리지 않게 Pod가 사라진 뒤 정책을 정리한다.
  if kctl delete pod -n kube-system "${builder_pod}" \
    --ignore-not-found --wait=true --timeout=30s >/dev/null 2>&1; then
    kctl delete networkpolicy -n kube-system "${builder_pod}" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

# 워커 노드에 dind Pod를 띄워 거기서 빌드하고, 결과 tar만 이 호스트로 받는다.
build_on_worker() {
  local node=$1
  cleanup_builder
  kctl wait --for=delete pod -n kube-system "${builder_pod}" --timeout=2m >/dev/null 2>&1 || true

  # Docker 제어 포트는 kubectl exec로만 사용하므로 다른 Pod의 진입을 차단한다.
  kctl apply -f - >/dev/null <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${builder_pod}
  namespace: kube-system
spec:
  podSelector:
    matchLabels: {app: sadp-local-image-builder}
  policyTypes: [Ingress]
  ingress: []
YAML
  # nodeName 대신 nodeSelector를 쓴다. 스케줄러를 거쳐야 메모리 상한이 노드 capacity와
  # 대조되고, 자리가 없으면 Pending으로 드러난다.
  kctl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${builder_pod}
  namespace: kube-system
  labels: {app: sadp-local-image-builder}
spec:
  nodeSelector:
    kubernetes.io/hostname: ${node}
  restartPolicy: Never
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 10
  containers:
    - name: builder
      image: ${BUILDER_IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: true
        runAsUser: 0
      env:
        - {name: DOCKER_TLS_CERTDIR, value: ""}
${proxy_env_yaml}
      resources:
        requests: {cpu: "500m", memory: 1Gi}
        limits: {cpu: "${BUILDER_CPU_LIMIT}", memory: "${BUILDER_MEMORY_LIMIT}"}
      volumeMounts:
        - {name: docker-graph, mountPath: /var/lib/docker}
        - {name: workspace, mountPath: /workspace}
  volumes:
    - name: docker-graph
      emptyDir: {}
    - name: workspace
      emptyDir: {}
YAML
  trap cleanup_builder EXIT
  kctl wait --for=condition=Ready pod -n kube-system "${builder_pod}" --timeout=10m >/dev/null \
    || die "${node}: 빌더 Pod가 Ready 되지 않음"

  # dind는 컨테이너가 Ready 된 뒤에도 dockerd 소켓이 열릴 때까지 몇 초가 더 걸린다.
  local i
  for ((i = 0; i < 60; i++)); do
    kctl exec -n kube-system "${builder_pod}" -- docker info >/dev/null 2>&1 && break
    sleep 5
  done
  kctl exec -n kube-system "${builder_pod}" -- docker info >/dev/null 2>&1 \
    || die "${node}: dockerd가 기동하지 않음"
  ok "${node}: 빌더 Pod 기동(메모리 상한 ${BUILDER_MEMORY_LIMIT})"

  # .dockerignore와 같은 기준으로 제외한다. 로컬 node_modules/.next는 700MB가 넘고
  # 이미지 안에서 npm ci가 어차피 다시 설치하므로 워커로 실어 보낼 이유가 없다.
  tar -C "${TESTBED_ROOT}" -cf - \
    --exclude='apps/portal-lite/ui/node_modules' \
    --exclude='apps/portal-lite/ui/.next' \
    --exclude='.env' \
    --exclude='.env.*' \
    --exclude='.git' \
    --exclude='*.tsbuildinfo' \
    apps/test-app apps/portal-lite \
    | kctl exec -i -n kube-system "${builder_pod}" -- tar -C /workspace -xf - \
    || die "${node}: build context 전송 실패"
  ok "${node}: build context 전송"

  # Pod IP(10.42.0.0/16)는 Squid client ACL에 이미 들어 있다. --network host는 빌드
  # 컨테이너를 이 Pod의 netns에 붙여 승인된 출발지로 프록시에 접속하게 한다.
  kctl exec -n kube-system "${builder_pod}" -- docker build --network host \
    "${proxy_args[@]}" -t "${TEST_APP_IMAGE}" /workspace/apps/test-app
  kctl exec -n kube-system "${builder_pod}" -- docker build --network host \
    "${proxy_args[@]}" "${portal_ui_build_args[@]}" \
    -t "${PORTAL_IMAGE}" /workspace/apps/portal-lite

  kctl exec -n kube-system "${builder_pod}" -- docker save \
    -o /workspace/sadp-state-v1.tar "${TEST_APP_IMAGE}" "${PORTAL_IMAGE}"
  # 부분 전송된 tar를 다음 단계가 import 하지 않도록 임시 파일에 받고 성공 후에만 옮긴다.
  kctl exec -n kube-system "${builder_pod}" -- cat /workspace/sadp-state-v1.tar \
    >"${archive}.part" || die "${node}: 이미지 archive 회수 실패"
  mv "${archive}.part" "${archive}"
  chmod 0600 "${archive}"

  cleanup_builder
  trap - EXIT
  ok "${node}: Docker 이미지 2개 빌드 완료(push 없음)"
}

# 워커가 전부 내려갔을 때만 쓰는 우회로. 이 호스트에서 직접 빌드한다.
build_on_this_host() {
  note "control-plane 빌드는 노드 메모리를 그대로 소모한다. 유지보수 창에서만 써라"
  local assignment
  for assignment in ${portal_ui_assignments[@]+"${portal_ui_assignments[@]}"}; do
    export "${assignment}"
  done
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    npm ci --prefix apps/portal-lite/ui
    npm run lint --prefix apps/portal-lite/ui
    npm run typecheck --prefix apps/portal-lite/ui
    npm test --prefix apps/portal-lite/ui
    npm run build --prefix apps/portal-lite/ui
    ok "Portal Next.js TypeScript 검사"
  else
    note "로컬 node/npm 없음: lint/typecheck/test/build는 Docker build에서 실행"
  fi

  if ! command -v docker >/dev/null 2>&1; then
    note "Docker가 없어 테스트용 빌더를 설치함"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
  fi
  systemctl enable --now docker >/dev/null

  # 로컬 Docker bridge CIDR은 Squid client ACL에 넣지 않는다. 테스트베드 빌드만
  # host network를 사용해 승인된 nodeInternalCIDR 출발지로 프록시에 접속한다.
  docker build --network host "${proxy_args[@]}" -t "${TEST_APP_IMAGE}" apps/test-app
  docker build --network host "${proxy_args[@]}" "${portal_ui_build_args[@]}" \
    -t "${PORTAL_IMAGE}" apps/portal-lite
  docker save -o "${archive}" "${TEST_APP_IMAGE}" "${PORTAL_IMAGE}"
  chmod 0600 "${archive}"
  ok "로컬 Docker 이미지 2개 빌드 완료(push 없음)"
}

if [[ ${BUILD_ON_CONTROL_PLANE} == true ]]; then
  [[ -z ${BUILD_NODE} ]] || die "--build-node와 --build-on-control-plane은 같이 쓸 수 없다"
  build_on_this_host
else
  BUILD_NODE=$(select_build_node) || exit 1
  note "빌드 노드 선택: ${BUILD_NODE}"
  build_on_worker "${BUILD_NODE}"
fi

if [[ ${EXPORT_ONLY} == true ]]; then
  python3 scripts/cluster/verify-image-archive.py --archive "${archive}" \
    --expected-ref "${TEST_APP_IMAGE}" --expected-ref "${PORTAL_IMAGE}"
  sha256sum "${archive}" >"${archive}.sha256"
  ok "배포하지 않고 이미지 archive 생성 완료: ${archive}"
  exit 0
fi

# 노드에서 대조할 기준값은 archive 자신에서 뽑는다. `ctr images ls`의 DIGEST는 manifest
# digest인데 `docker image inspect`의 .Id는 config blob digest라서 둘은 정의상 절대 같아지지
# 않는다. archive의 index.json에 적힌 manifest digest가 containerd가 import 후 기록할 바로
# 그 값이므로, 이걸 쓰면 전체 노드가 전송된 바로 그 바이트를 받았는지까지 확인된다.
archive_index_json=$(tar -xOf "${archive}" index.json 2>/dev/null) \
  || die "archive에서 index.json을 읽을 수 없음: ${archive}"
archive_manifest_digest() {
  local image=$1
  printf '%s' "${archive_index_json}" | IMAGE="${image}" python3 -c '
import json, os, sys

want = os.environ["IMAGE"]
for entry in json.load(sys.stdin).get("manifests", []):
    if entry.get("annotations", {}).get("io.containerd.image.name") == want:
        print(entry["digest"])
        break
else:
    raise SystemExit(f"[FAIL] archive에 {want} manifest가 없음")
'
}
expected_test_app_digest=$(archive_manifest_digest "${TEST_APP_IMAGE}") \
  || die "test-app manifest digest를 archive에서 얻지 못함"
expected_portal_digest=$(archive_manifest_digest "${PORTAL_IMAGE}") \
  || die "portal-lite manifest digest를 archive에서 얻지 못함"

# 모든 노드에 이미 캐시된 Argo CD 이미지를 임시 운반 컨테이너로 사용한다.
loader_image=$(python3 -c 'import yaml; print("quay.io/argoproj/argocd:v" + str(yaml.safe_load(open("versions.lock.yaml"))["delivery"]["argoCd"]))')
kctl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: sadp-local-image-loader
  namespace: kube-system
spec:
  selector:
    matchLabels: {app: sadp-local-image-loader}
  template:
    metadata:
      labels: {app: sadp-local-image-loader}
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
cleanup_loader() { kctl delete daemonset -n kube-system sadp-local-image-loader --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup_loader EXIT
kctl rollout status -n kube-system daemonset/sadp-local-image-loader --timeout=5m >/dev/null

mapfile -t loader_pods < <(kctl get pods -n kube-system -l app=sadp-local-image-loader -o name)
# 배포 대상 수는 단일/다중 모드 공통 계약에서 계산해야 이미지 전달도 같은 경계를 따른다.
expected_loader_count=$(python3 - <<'PYCOUNT'
import runpy
import yaml
helper = runpy.run_path("scripts/lib/cluster-topology.py")
with open("contracts/platform-production.yaml", encoding="utf-8") as source:
    print(helper["expected_nodes"](yaml.safe_load(source)))
PYCOUNT
)
[[ ${#loader_pods[@]} -eq ${expected_loader_count} ]] || die "image-loader Pod 수가 계약과 다름: expected=${expected_loader_count}, actual=${#loader_pods[@]}"
for pod in "${loader_pods[@]}"; do
  node=$(kctl get -n kube-system "${pod}" -o jsonpath='{.spec.nodeName}')
  kctl exec -i -n kube-system "${pod}" -- /bin/sh -c 'cat > /staging/sadp-state-v1.tar' <"${archive}"
  kctl exec -n kube-system "${pod}" -- /hostbin/ctr \
    --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
    images import /staging/sadp-state-v1.tar >/dev/null
  actual_test_app_digest=$(kctl exec -n kube-system "${pod}" -- /hostbin/ctr \
    --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
    images ls "name==${TEST_APP_IMAGE}" | awk 'NR == 2 {print $3}')
  actual_portal_digest=$(kctl exec -n kube-system "${pod}" -- /hostbin/ctr \
    --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
    images ls "name==${PORTAL_IMAGE}" | awk 'NR == 2 {print $3}')
  [[ ${actual_test_app_digest} == "${expected_test_app_digest}" ]] \
    || die "${node}: test-app digest 불일치"
  [[ ${actual_portal_digest} == "${expected_portal_digest}" ]] \
    || die "${node}: portal-lite digest 불일치"
  ok "${node}: 로컬 이미지 import와 digest 일치"
done
cleanup_loader
trap - EXIT
sha256sum "${archive}" >"${archive}.sha256"
ok "이미지 archive/checksum 보관: ${IMAGE_DIR}"
