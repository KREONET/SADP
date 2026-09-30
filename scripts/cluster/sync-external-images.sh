#!/usr/bin/env bash
# 서드파티 이미지를 새로 받아 검증한 한 archive만 모든 Linux RKE2 노드에 배포한다.
#
# Docker image metadata와 `docker save` 성공은 blob 완전성을 보장하지 않는다. 그래서 이 경로는
# RKE2 containerd의 작업 전용 Namespace에서 node platform별 content를 fetch하고 OCI archive를
# export한 뒤, manifest 참조와 모든 blob digest를 독립 검증하기 전에는 loader를 만들지 않는다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

LOADER="sadp-image-loader-$(date +%s)-$$"
TRANSFER_NAMESPACE="sadp-image-transfer-$(date +%s)-$$"
IMAGE_LIST=
IMAGES=()
KEEP_ARCHIVE=false
CTR_BIN=${RKE2_CTR_BIN:-/var/lib/rancher/rke2/bin/ctr}
CTR_ADDRESS=${RKE2_CONTAINERD_ADDRESS:-/run/k3s/containerd/containerd.sock}
PULL_ATTEMPTS=${SADP_IMAGE_PULL_ATTEMPTS:-3}
PULL_TIMEOUT=${SADP_IMAGE_PULL_TIMEOUT:-300}
EXPORT_TIMEOUT=${SADP_IMAGE_EXPORT_TIMEOUT:-600}
loader_created=false
namespace_created=false
operation_complete=false
archive=
partial_archive=
quarantined_archive=
pull_error_file=

usage() {
  cat <<'EOF'
usage: sudo bash ./sadp --sync-images --image <ref> [--image ...]
       sudo bash ./sadp --sync-images --image-list <file> [--keep-archive]

모든 Linux node platform을 확인한 뒤 RKE2 containerd의 전용 임시 Namespace에서 새로
content fetch/export한다. unpack 없이 원본 blob을 확보하고 archive 검증 후 임시 loader로 보내며,
각 노드에서 `ctr images check --quiet`가 complete를 반환해야 성공한다.

--image-list 는 한 줄에 이미지 참조 하나를 적은 파일이다. # 주석과 빈 줄은 무시한다.
이미지 참조는 반드시 고정 tag 또는 sha256 digest를 포함해야 하며 latest는 거부한다.
digest 입력은 import 뒤 workload가 쓸 `:sadp-sha256-<digest>` alias를 만든다.
--keep-archive 는 검증한 OCI tar와 checksum을 mode 0600으로 상태 디렉터리에 남긴다.

예:
  sudo bash ./sadp --sync-images \
    --image quay.io/prometheus/prometheus:v3.1.0 \
    --image docker.io/grafana/loki:3.3.2
EOF
}

while (($#)); do
  case "$1" in
    --image) IMAGES+=("${2:-}"); shift ;;
    --image-list) IMAGE_LIST=${2:-}; shift ;;
    --keep-archive) KEEP_ARCHIVE=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

if [[ -n ${IMAGE_LIST} ]]; then
  [[ -r ${IMAGE_LIST} ]] || die "이미지 목록을 읽을 수 없음: ${IMAGE_LIST}"
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line%%#*}
    line=$(printf '%s' "${line}" | tr -d '[:space:]')
    [[ -n ${line} ]] && IMAGES+=("${line}")
  done <"${IMAGE_LIST}"
fi

[[ ${#IMAGES[@]} -gt 0 ]] || die "--image 또는 --image-list 로 이미지를 지정해야 함"
[[ ${PULL_ATTEMPTS} =~ ^[1-9][0-9]*$ ]] || die "SADP_IMAGE_PULL_ATTEMPTS는 양의 정수여야 함"
[[ ${PULL_TIMEOUT} =~ ^[1-9][0-9]*$ ]] || die "SADP_IMAGE_PULL_TIMEOUT은 양의 정수여야 함"
[[ ${EXPORT_TIMEOUT} =~ ^[1-9][0-9]*$ ]] || die "SADP_IMAGE_EXPORT_TIMEOUT은 양의 정수여야 함"

digest_alias() {
  local image=$1 name repository digest last
  name=${image%@sha256:*}
  digest=${image##*@sha256:}
  last=${name##*/}
  if [[ ${last} == *:* ]]; then
    repository=${name%:*}
  else
    repository=${name}
  fi
  printf '%s:sadp-sha256-%s\n' "${repository}" "${digest}"
}

for image in "${IMAGES[@]}"; do
  [[ -n ${image} && ${image} != *[[:space:]]* && ${image} != *://* ]] \
    || die "image 참조 형식 오류: ${image}"
  if [[ ${image} == *@* ]]; then
    [[ ${image} =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]] \
      || die "sha256 digest image 참조 형식 오류: ${image}"
  else
    last=${image##*/}
    [[ ${last} == *:* && -n ${last##*:} ]] || die "이미지에 태그나 digest 가 없음: ${image}"
    [[ ${last##*:} != latest ]] || die "가변 태그(latest)는 노드 간 불일치를 만든다: ${image}"
  fi
done

require_root
for command in python3 timeout sha256sum; do require_command "${command}"; done
[[ -x ${KUBECTL_BIN} ]] || die "kubectl 없음: ${KUBECTL_BIN}"
[[ -x ${CTR_BIN} ]] || die "RKE2 ctr 없음: ${CTR_BIN}"
[[ -S ${CTR_ADDRESS} ]] || die "RKE2 containerd socket 없음: ${CTR_ADDRESS}"
ensure_state_dirs
install -d -m 0700 "${IMAGE_DIR}/quarantine"
cd "${TESTBED_ROOT}"

# 생성 입력에서 승인한 세 변수만 읽으며 credential을 받는 ctr 옵션은 사용하지 않는다. 임의
# shell을 source하지 않고, containerd daemon에도 같은 값이 실제 반영됐는지 먼저 확인한다.
proxy_env=platform/network/proxy.env
bash scripts/node/install-rke2-containerd-proxy.sh \
  --role server --proxy-env "${proxy_env}" --check >/dev/null
declare -A proxy_values=()
while IFS= read -r line || [[ -n ${line} ]]; do
  [[ ${line} == 'export '* ]] || continue
  assignment=${line#export }
  name=${assignment%%=*}
  value=${assignment#*=}
  case ${name} in HTTP_PROXY|HTTPS_PROXY|NO_PROXY) ;; *) continue ;; esac
  [[ ${value} != '"'* && ${value} != "'"* ]] || value=${value:1:${#value}-2}
  proxy_values["${name}"]=${value}
done <"${proxy_env}"
HTTP_PROXY=${proxy_values[HTTP_PROXY]}
HTTPS_PROXY=${proxy_values[HTTPS_PROXY]}
NO_PROXY=${proxy_values[NO_PROXY]}
http_proxy=${HTTP_PROXY}
https_proxy=${HTTPS_PROXY}
no_proxy=${NO_PROXY}
export HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy

ctr_global() {
  "${CTR_BIN}" --address "${CTR_ADDRESS}" "$@"
}

ctr_transfer() {
  ctr_global --namespace "${TRANSFER_NAMESPACE}" "$@"
}

cleanup_loader() {
  [[ ${loader_created} == true ]] || return 0
  kctl delete daemonset -n kube-system "${LOADER}" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  loader_created=false
}

cleanup_namespace() {
  local attempt
  local -a refs=() leases=()
  [[ ${namespace_created} == true ]] || return 0
  for attempt in 1 2 3; do
    mapfile -t refs < <(ctr_transfer images ls --quiet 2>/dev/null || true)
    if ((${#refs[@]})); then
      ctr_transfer images remove --sync "${refs[@]}" >/dev/null 2>&1 || true
    fi
    mapfile -t leases < <(ctr_transfer leases list --quiet 2>/dev/null || true)
    for lease in "${leases[@]}"; do
      ctr_transfer leases delete "${lease}" >/dev/null 2>&1 || true
    done
    if ctr_global namespaces remove "${TRANSFER_NAMESPACE}" >/dev/null 2>&1; then
      namespace_created=false
      return 0
    fi
    sleep $((attempt * 2))
  done
  printf '[WARN] stage=cleanup namespace=%s 임시 Namespace 정리 실패\n' \
    "${TRANSFER_NAMESPACE}" >&2
  printf '[WARN] 수동 확인: sudo %q --address %q namespaces list --quiet\n' \
    "${CTR_BIN}" "${CTR_ADDRESS}" >&2
  printf '[WARN] 수동 정리: sudo %q --address %q namespaces remove %q\n' \
    "${CTR_BIN}" "${CTR_ADDRESS}" "${TRANSFER_NAMESPACE}" >&2
  return 1
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  set +e
  cleanup_loader
  cleanup_namespace
  [[ -z ${pull_error_file} ]] || rm -f -- "${pull_error_file}"
  [[ -z ${partial_archive} ]] || rm -f -- "${partial_archive}"
  if [[ ${operation_complete} != true && -n ${archive} && -z ${quarantined_archive} ]]; then
    rm -f -- "${archive}" "${archive}.sha256"
  fi
  if [[ ${operation_complete} == true && ${KEEP_ARCHIVE} != true && -n ${archive} ]]; then
    rm -f -- "${archive}" "${archive}.sha256"
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

node_json=$(kctl get nodes -o json)
node_records_text=$(python3 -c '
import json, sys
document = json.load(sys.stdin)
for node in document.get("items", []):
    info = (node.get("status") or {}).get("nodeInfo") or {}
    if info.get("operatingSystem") != "linux":
        continue
    name = (node.get("metadata") or {}).get("name") or ""
    architecture = info.get("architecture") or ""
    if not name or not architecture:
        raise SystemExit("Linux node name/architecture 누락")
    print(f"{name}\tlinux/{architecture}")
' <<<"${node_json}") || die "Kubernetes node platform 정보를 해석하지 못함"
node_records=()
[[ -z ${node_records_text} ]] || mapfile -t node_records <<<"${node_records_text}"
linux_node_count=${#node_records[@]}
((linux_node_count > 0)) || die "Linux 노드를 찾지 못함"

declare -A node_platform_by_name=() platform_seen=()
platforms=()
for record in "${node_records[@]}"; do
  IFS=$'\t' read -r node platform <<<"${record}"
  node_platform_by_name["${node}"]=${platform}
  if [[ ! -v "platform_seen[${platform}]" ]]; then
    platforms+=("${platform}")
    platform_seen["${platform}"]=true
  fi
done
ok "Linux node ${linux_node_count}대 platform 확인: ${platforms[*]}"

ctr_global namespaces create "${TRANSFER_NAMESPACE}" >/dev/null \
  || die "stage=namespace-create namespace=${TRANSFER_NAMESPACE}"
namespace_created=true

pull_error_file=${IMAGE_DIR}/.${LOADER}.pull-error
install -m 0600 /dev/null "${pull_error_file}"

classify_pull_error() {
  # URL의 digest/서명 숫자가 HTTP 상태 코드로 오인되지 않도록 원문은 내부에서만 읽는다.
  python3 - "$1" "$2" <<'PYCLASSIFY'
import pathlib
import re
import sys

status = int(sys.argv[1])
try:
    with pathlib.Path(sys.argv[2]).open("rb") as stream:
        stream.seek(0, 2)
        stream.seek(max(0, stream.tell() - 65536))
        text = stream.read().decode("utf-8", errors="replace")
except OSError:
    text = ""
text = re.sub(r'https?://[^\s"<>]+', '<url>', text, flags=re.I)
patterns = re.compile(
    r'\bHTTP(?:/[0-9.]+| error)?[ \t]+([45][0-9]{2})\b'
    r'|\bstatus(?:[ \t]*code)?[ \t:=]+([45][0-9]{2})\b'
    r'|\b([45][0-9]{2})[ \t]+(?:Forbidden|Unauthorized|Not Found|Too Many Requests|'
    r'Internal Server Error|Bad Gateway|Service Unavailable|Gateway Timeout)\b', re.I
)
codes = [next(value for value in match.groups() if value) for match in patterns.finditer(text)]
if status == 124:
    reason = "pull-timeout"
elif codes:
    reason = "http-" + codes[-1]
elif re.search(r'\bforbidden\b|access denied|insufficient_scope', text, re.I):
    reason = "access-denied"
elif re.search(r'\bunauthorized\b|authentication required', text, re.I):
    reason = "authentication"
elif re.search(r'x509:|certificate verify failed|certificate verification failed', text, re.I):
    reason = "tls-certificate"
elif re.search(r'TLS handshake timeout', text, re.I):
    reason = "tls-timeout"
elif re.search(r'timeout|timed out|deadline exceeded', text, re.I):
    reason = "network-timeout"
elif re.search(r'temporary failure', text, re.I):
    reason = "temporary-failure"
elif re.search(r'no such host|server misbehaving|name resolution', text, re.I):
    reason = "dns"
elif re.search(r'connection reset', text, re.I):
    reason = "connection-reset"
elif re.search(r'connection refused|no route to host|network is unreachable', text, re.I):
    reason = "connect"
elif re.search(r'not found', text, re.I):
    reason = "not-found"
else:
    reason = "unknown"
print(reason)
PYCLASSIFY
}

retryable_pull_error() {
  case "$1" in
    http-5[0-9][0-9]|pull-timeout|network-timeout|tls-timeout|connection-reset|temporary-failure) return 0 ;;
    *) return 1 ;;
  esac
}

pull_image_platform() {
  local image=$1 platform=$2 attempt status=0 reason
  # 이미 unpack된 snapshot이 있으면 images pull은 원본 layer fetch를 생략할 수 있다.
  # export에는 압축 blob이 필요하므로 unpack하지 않는 content fetch로 확보한다.
  for ((attempt = 1; attempt <= PULL_ATTEMPTS; attempt++)); do
    : >"${pull_error_file}"
    if timeout "${PULL_TIMEOUT}" "${CTR_BIN}" --address "${CTR_ADDRESS}" \
      --namespace "${TRANSFER_NAMESPACE}" content fetch --skip-metadata --platform "${platform}" "${image}" \
      >/dev/null 2>"${pull_error_file}"; then
      ok "stage=pull image=${image} platform=${platform}"
      return 0
    else
      status=$?
    fi
    reason=$(classify_pull_error "${status}" "${pull_error_file}")
    if ((attempt < PULL_ATTEMPTS)) && retryable_pull_error "${reason}"; then
      note "stage=pull image=${image} platform=${platform} reason=${reason} exit=${status}; 재시도 ${attempt}/${PULL_ATTEMPTS} (시도별 제한 ${PULL_TIMEOUT}s)"
      sleep $((attempt * 2))
      continue
    fi
    die "stage=pull image=${image} platform=${platform} reason=${reason} exit=${status} attempt=${attempt}/${PULL_ATTEMPTS} timeout=${PULL_TIMEOUT}s 실패(credential 및 원문 응답은 출력하지 않음)"
  done
}

image_target_digest() {
  ctr_transfer images inspect "$1" | python3 -c '
import json, sys
document = json.load(sys.stdin)
target = document.get("target") or document.get("Target") or {}
print(target.get("digest") or target.get("Digest") or "")
'
}

archive_images=()
for image in "${IMAGES[@]}"; do
  for platform in "${platforms[@]}"; do
    pull_image_platform "${image}" "${platform}"
  done
  if [[ ${image} == *@sha256:* ]]; then
    requested_digest=${image##*@}
    actual_digest=$(image_target_digest "${image}")
    [[ ${actual_digest} == "${requested_digest}" ]] \
      || die "stage=digest-check image=${image} 원 digest 불일치"
    local_alias=$(digest_alias "${image}")
    ctr_transfer images tag "${image}" "${local_alias}" >/dev/null \
      || die "stage=digest-alias image=${image} alias 생성 실패"
    alias_digest=$(image_target_digest "${local_alias}")
    [[ ${alias_digest} == "${requested_digest}" ]] \
      || die "stage=digest-alias image=${image} alias digest 불일치"
    archive_images+=("${local_alias}")
    ok "stage=digest-alias image=${image} alias=${local_alias}"
  else
    archive_images+=("${image}")
  fi
done

archive=${IMAGE_DIR}/external-images-$(date +%Y%m%d-%H%M%S)-$$.tar
partial_archive=${archive}.partial
platform_args=()
for platform in "${platforms[@]}"; do platform_args+=(--platform "${platform}"); done
if ! timeout "${EXPORT_TIMEOUT}" "${CTR_BIN}" --address "${CTR_ADDRESS}" \
  --namespace "${TRANSFER_NAMESPACE}" images export "${platform_args[@]}" \
  "${partial_archive}" "${archive_images[@]}" >/dev/null; then
  die "stage=export image=<image-set> OCI archive 생성 실패"
fi
chmod 0600 "${partial_archive}"

verify_args=(--archive "${partial_archive}")
for platform in "${platforms[@]}"; do verify_args+=(--platform "${platform}"); done
for image in "${archive_images[@]}"; do verify_args+=(--expected-ref "${image}"); done
if ! python3 scripts/cluster/verify-image-archive.py "${verify_args[@]}"; then
  quarantined_archive=${IMAGE_DIR}/quarantine/$(basename "${archive}").invalid
  mv -- "${partial_archive}" "${quarantined_archive}"
  chmod 0600 "${quarantined_archive}"
  partial_archive=
  die "stage=archive-verify image=<image-set> 실패; 격리=${quarantined_archive}"
fi
mv -- "${partial_archive}" "${archive}"
partial_archive=
chmod 0600 "${archive}"
ok "stage=archive-verify image=${#archive_images[@]}개; node 전송 허용"

# rke2-canal은 모든 Linux node에서 이미 Ready인 image라 IfNotPresent가 registry egress를
# 만들지 않는다. 전 노드 Ready 여부를 먼저 확인해 부분 캐시를 loader 성공으로 오인하지 않는다.
loader_image=$(python3 -c '
import json, sys
document = json.load(sys.stdin)
spec = document.get("spec") or {}
status = document.get("status") or {}
containers = ((spec.get("template") or {}).get("spec") or {}).get("containers") or []
if not containers or not containers[0].get("image"):
    raise SystemExit("loader image 누락")
desired = int(status.get("desiredNumberScheduled") or 0)
ready = int(status.get("numberReady") or 0)
expected = int(sys.argv[1])
if desired != expected or ready != expected:
    raise SystemExit(f"rke2-canal Ready 불완전: desired={desired}, ready={ready}, linux={expected}")
print(containers[0]["image"])
' "${linux_node_count}" <<<"$(kctl get daemonset -n kube-system rke2-canal -o json)") \
  || die "loader로 재사용할 rke2-canal image가 모든 Linux node에 준비되지 않음"

loader_created=true
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
      nodeSelector: {kubernetes.io/os: linux}
      tolerations: [{operator: Exists}]
      containers:
        - name: loader
          image: ${loader_image}
          imagePullPolicy: IfNotPresent
          command: [/bin/sh, -c, 'trap : TERM INT; sleep infinity & wait']
          # containerd socket과 host ctr 접근은 import 동안만 필요하며 trap이 DaemonSet을 지운다.
          securityContext: {privileged: true, runAsUser: 0}
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

kctl rollout status -n kube-system "daemonset/${LOADER}" --timeout=10m >/dev/null \
  || die "stage=loader-ready image=${loader_image} 실패"
mapfile -t loader_pods < <(kctl get pods -n kube-system -l "app=${LOADER}" -o name)
[[ ${#loader_pods[@]} -eq ${linux_node_count} ]] \
  || die "stage=loader-ready Linux node=${linux_node_count}, loader Pod=${#loader_pods[@]}"

for pod in "${loader_pods[@]}"; do
  node=$(kctl get -n kube-system "${pod}" -o jsonpath='{.spec.nodeName}')
  node_platform=${node_platform_by_name[${node}]:-}
  [[ -n ${node_platform} ]] || die "stage=import node=${node} platform을 찾지 못함"
  if ! kctl exec -i -n kube-system "${pod}" -- /bin/sh -c \
    'umask 077; cat > /staging/external-images.tar' <"${archive}"; then
    die "stage=transfer node=${node} image=<image-set> 실패"
  fi
  if ! kctl exec -n kube-system "${pod}" -- /hostbin/ctr \
    --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
    images import --platform "${node_platform}" /staging/external-images.tar >/dev/null; then
    die "stage=import node=${node} image=<image-set> 실패"
  fi
  kctl exec -n kube-system "${pod}" -- rm -f /staging/external-images.tar >/dev/null 2>&1 || true

  for image in "${archive_images[@]}"; do
    ready_refs=$(kctl exec -n kube-system "${pod}" -- /hostbin/ctr \
      --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
      images check --quiet "name==${image}") \
      || die "stage=complete-check node=${node} image=${image} 실행 실패"
    grep -Fxq -- "${image}" <<<"${ready_refs}" \
      || die "stage=complete-check node=${node} image=${image} content 불완전"
  done
  ok "stage=complete-check node=${node} image=${#archive_images[@]}개 complete"
done

cleanup_loader
cleanup_namespace || die "stage=cleanup namespace=${TRANSFER_NAMESPACE} 수동 정리 필요"

if [[ ${KEEP_ARCHIVE} == true ]]; then
  checksum=${archive}.sha256
  (cd "$(dirname "${archive}")" && sha256sum "$(basename "${archive}")") >"${checksum}"
  chmod 0600 "${checksum}"
  ok "검증 archive/checksum 보관: ${archive}"
fi
operation_complete=true
ok "모든 Linux node에서 image ${#archive_images[@]}개 content complete 확인"
