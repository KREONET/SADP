#!/usr/bin/env bash
# 사전 빌드 archive를 검사하고 현재 사이트의 이미지 이름으로 전체 노드에 가져온다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"
BUNDLE=
APPLY=false
while (($#)); do
  case "$1" in
    --bundle) BUNDLE=${2:?bundle 디렉터리 필요}; shift ;;
    --apply) APPLY=true ;;
    -h|--help) echo '사용법: bash ./sadp --import-images --bundle <directory> [--apply]'; exit 0 ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done
[[ -n ${BUNDLE} ]] || die "--bundle 필요"
fields=$(python3 "${TESTBED_ROOT}/scripts/release/image-bundle.py" fields --directory "${BUNDLE}") || die "bundle 검증 실패"
mapfile -t inputs <<<"${fields}"
archive=${inputs[0]}
SOURCE_TEST_APP_IMAGE=${inputs[1]}
SOURCE_PORTAL_IMAGE=${inputs[2]}
cd "${TESTBED_ROOT}"
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
ok "import 대상 이미지: ${TEST_APP_IMAGE}, ${PORTAL_IMAGE}"

[[ ${TEST_APP_IMAGE##*:} == "${SOURCE_TEST_APP_IMAGE##*:}" && ${PORTAL_IMAGE##*:} == "${SOURCE_PORTAL_IMAGE##*:}" ]] \
  || die "site.env의 TEST_APP_IMAGE_TAG/PORTAL_IMAGE_TAG를 bundle sourceRevision으로 렌더해야 함"
note "검증한 bundle을 계약의 전체 노드로 import한다. Secret/GitOps 값은 변경하지 않는다."
[[ ${APPLY} == true ]] || exit 0
require_root
check_cluster_topology
loader_name=sadp-prebuilt-loader-$$
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
expected_test_app_digest=$(archive_manifest_digest "${SOURCE_TEST_APP_IMAGE}") \
  || die "test-app manifest digest를 archive에서 얻지 못함"
expected_portal_digest=$(archive_manifest_digest "${SOURCE_PORTAL_IMAGE}") \
  || die "portal-lite manifest digest를 archive에서 얻지 못함"

# 모든 노드에 이미 캐시된 Argo CD 이미지를 임시 운반 컨테이너로 사용한다.
loader_image=$(python3 -c 'import yaml; print("quay.io/argoproj/argocd:v" + str(yaml.safe_load(open("versions.lock.yaml"))["delivery"]["argoCd"]))')
kctl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${loader_name}
  namespace: kube-system
spec:
  selector:
    matchLabels: {app: ${loader_name}}
  template:
    metadata:
      labels: {app: ${loader_name}}
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
cleanup_loader() { kctl delete daemonset -n kube-system ${loader_name} --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup_loader EXIT
kctl rollout status -n kube-system daemonset/${loader_name} --timeout=5m >/dev/null

mapfile -t loader_pods < <(kctl get pods -n kube-system -l app=${loader_name} -o name)
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
  # bundle의 이름을 이 사이트가 렌더한 값에 연결한다. 기존 immutable tag의 다른 내용은 거부한다.
  for pair in "${SOURCE_TEST_APP_IMAGE}|${TEST_APP_IMAGE}" "${SOURCE_PORTAL_IMAGE}|${PORTAL_IMAGE}"; do
    source_ref=${pair%%|*}; target_ref=${pair#*|}
    [[ ${source_ref} == "${target_ref}" ]] && continue
    existing=$(kctl exec -n kube-system "${pod}" -- /hostbin/ctr \
      --address /run/k3s/containerd/containerd.sock --namespace k8s.io images ls "name==${target_ref}" | awk 'NR == 2 {print $3}')
    if [[ -n ${existing} ]]; then
      expected=$(archive_manifest_digest "${source_ref}")
      [[ ${existing} == "${expected}" ]] || die "${node}: 기존 immutable image 내용이 다름"
      continue
    fi
    kctl exec -n kube-system "${pod}" -- /hostbin/ctr \
      --address /run/k3s/containerd/containerd.sock --namespace k8s.io images tag "${source_ref}" "${target_ref}" >/dev/null
  done
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

ok "이미지 archive/checksum 보관: ${IMAGE_DIR}"
