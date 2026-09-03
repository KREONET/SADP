#!/usr/bin/env bash
# Portal Lite 백엔드(Go API + Next 세션 프록시)를 클러스터에 설치하고 실사용 경로까지 검증한다.
# 파일 하나만 서버에 두고 직접 실행하는 설치 방식이며, 실행 순서는 다음과 같다.
#   guard → 이미지 → Secret 재료 → Helm apply → Ready 대기 → 경계/권한/API 검증
# 이 스크립트는 Secret 값을 출력하지 않고, 봇 토큰도 argv가 아닌 stdin으로만 전달한다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/testbed-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/openbao-eso.sh"

VALUES_FILE=apps/portal-lite/values-beta.yaml
CONTRACT_FILE=contracts/platform-production.yaml
CONTRACT_VALUES=contracts/values-platform-production.yaml
RELEASE=portal-lite
FORGEJO_TOKEN_FILE=
SKIP_GUARD=false
SKIP_IMAGE=false
CHECK_ONLY=false
TOKEN_ONLY=false

usage() {
  cat >&2 <<'TXT'
usage: sudo bash scripts/cluster/install-portal-backend.sh [옵션]
  --values PATH               app-profile values (기본: apps/portal-lite/values-beta.yaml)
  --contract PATH             플랫폼 계약 (기본: contracts/platform-production.yaml)
  --contract-values PATH      계약 파생 values (기본: contracts/values-platform-production.yaml)
  --forgejo-token-file PATH   Forgejo 봇 토큰 파일을 OpenBao에 넣는다(내용은 출력하지 않음)
  --skip-guard                render-test/ci-guard 생략(직전에 이미 통과한 경우)
  --skip-image                이미지 빌드/노드 import 생략(태그가 이미 노드에 있는 경우)
  --token-only                Forgejo 봇 토큰만 OpenBao에 넣고 끝낸다(배포는 ArgoCD가 한다)
  --check                     설치하지 않고 현재 배포 상태만 검증
TXT
}

while (($#)); do
  case "$1" in
    --values) VALUES_FILE=${2:?--values 값 필요}; shift ;;
    --contract) CONTRACT_FILE=${2:?--contract 값 필요}; shift ;;
    --contract-values) CONTRACT_VALUES=${2:?--contract-values 값 필요}; shift ;;
    --forgejo-token-file) FORGEJO_TOKEN_FILE=${2:?--forgejo-token-file 값 필요}; shift ;;
    --skip-guard) SKIP_GUARD=true ;;
    --skip-image) SKIP_IMAGE=true ;;
    --token-only) TOKEN_ONLY=true ;;
    --check) CHECK_ONLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

require_root
for command in python3 jq curl "${HELM_BIN}"; do require_command "${command}"; done
[[ -x ${KUBECTL_BIN} ]] || die "kubectl을 찾을 수 없음: ${KUBECTL_BIN}"
ensure_state_dirs
cd "${TESTBED_ROOT}"
for file in "${VALUES_FILE}" "${CONTRACT_FILE}" "${CONTRACT_VALUES}"; do
  [[ -r ${file} ]] || die "필요한 파일을 읽을 수 없음: ${file}"
done

# values/계약에서 설치와 검증에 필요한 좌표만 읽는다. Secret 값은 읽지 않는다.
mapfile -t facts < <(python3 - "${VALUES_FILE}" "${CONTRACT_FILE}" <<'PY'
import sys

import yaml

values = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
contract = yaml.safe_load(open(sys.argv[2], encoding="utf-8")) or {}
spec = contract.get("spec") or {}
app = values.get("app") or {}
image = values.get("image") or {}
configuration = values.get("configuration") or {}
config = configuration.get("config") or {}
persistence = values.get("persistence") or {}
rbac = values.get("rbac") or {}
exposure = values.get("exposure") or {}
auth = next(
    (item for item in configuration.get("externalSecrets") or [] if item.get("name") == "auth"),
    {},
)

fields = [
    app.get("name", ""),
    str((((spec.get("network") or {}).get("defaultDenyNamespaces") or [""])[0])),
    f"{image.get('repository', '')}:{image.get('tag', '')}",
    image.get("pullPolicy", ""),
    exposure.get("host", ""),
    (spec.get("gateway") or {}).get("vip", ""),
    str(values.get("replicaCount", "")),
    str(bool(persistence.get("enabled"))).lower(),
    persistence.get("accessMode", ""),
    persistence.get("mountPath", ""),
    config.get("PORTAL_STATE_DIR", ""),
    str(bool(rbac.get("enabled"))).lower(),
    ",".join(rbac.get("namespaces") or []),
    str(rbac.get("tokenAudience", "")),
    auth.get("secretStore", ""),
    auth.get("remotePath", ""),
    ",".join(auth.get("keys") or []),
    config.get("FORGEJO_BASE_URL", ""),
    f"{config.get('FORGEJO_OWNER', '')}/{config.get('FORGEJO_REPO', '')}",
]
if any("\n" in field for field in fields):
    raise SystemExit("values에 개행이 포함된 값이 있어 안전하게 읽을 수 없음")
print("\n".join(fields))
PY
)
app_name=${facts[0]}
namespace=${facts[1]}
image_ref=${facts[2]}
pull_policy=${facts[3]}
portal_host=${facts[4]}
gateway_vip=${facts[5]}
replica_count=${facts[6]}
persistence_enabled=${facts[7]}
access_mode=${facts[8]}
mount_path=${facts[9]}
state_dir=${facts[10]}
rbac_enabled=${facts[11]}
rbac_namespaces=${facts[12]}
token_audience=${facts[13]}
secret_store=${facts[14]}
remote_path=${facts[15]}
secret_keys=${facts[16]}
forgejo_base_url=${facts[17]}
forgejo_repo=${facts[18]}

[[ ${app_name} == portal-lite ]] || die "portal-lite values가 아님: ${VALUES_FILE}"
[[ -n ${namespace} && ${namespace} != -* && ${namespace} != *- ]] \
  || die "app.project/app.environment로 Namespace를 만들 수 없음: '${namespace}'"
[[ -n ${portal_host} && -n ${gateway_vip} ]] || die "exposure.host 또는 gateway VIP가 비어 있음"
service_account=${app_name}
portal_origin=https://${portal_host}

# 저장소 경로 불일치는 재시작 시 신청 이력을 조용히 잃게 만드는 조합이라 설치 전에 막는다.
if [[ ${persistence_enabled} == true ]]; then
  [[ ${mount_path} == "${state_dir}" ]] \
    || die "persistence.mountPath(${mount_path})와 PORTAL_STATE_DIR(${state_dir})가 다름"
  if [[ ${access_mode} == ReadWriteOnce && ${replica_count} != 1 ]]; then
    die "ReadWriteOnce PVC에는 replicaCount=1이어야 함(현재 ${replica_count})"
  fi
else
  note "persistence.enabled=false: 신청 이력이 Pod 재시작에 사라진다"
fi

note "대상 ${namespace}/${app_name} host=${portal_host} image=${image_ref}"
if [[ -n ${forgejo_base_url} ]]; then
  note "Forgejo GitOps=${forgejo_base_url} repo=${forgejo_repo}"
else
  note "Forgejo 미설정: 배포 신청 POST는 503(forgejo_not_configured)으로 응답한다"
fi

# token-only와 check-only도 각각 KV 변경과 ExternalSecret 확인을 수행할 수 있으므로 공통
# 진입 지점에서 sealed 상태를 먼저 차단한다.
openbao_require_unsealed 2m

openbao_root() {
  local init_file=$1
  shift
  jq -er '.root_token' "${init_file}" |
    kctl exec -i -n openbao openbao-0 -- sh -ceu '
      IFS= read -r BAO_TOKEN
      export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
      shift
      exec bao "$@"
    ' sh https://openbao.openbao.svc.cluster.local:8200 "$@"
}
openbao_root_input() {
  local init_file=$1
  shift
  {
    jq -er '.root_token' "${init_file}"
    cat
  } | kctl exec -i -n openbao openbao-0 -- sh -ceu '
    IFS= read -r BAO_TOKEN
    export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
    shift
    exec bao "$@"
  ' sh https://openbao.openbao.svc.cluster.local:8200 "$@"
}

install_forgejo_token() {
  local token_file=$1
  [[ -s ${token_file} ]] || die "Forgejo 토큰 파일이 비어 있음: ${token_file}"
  [[ ${secret_keys} == *FORGEJO_BOT_TOKEN* ]] \
    || die "values의 auth ExternalSecret keys에 FORGEJO_BOT_TOKEN이 없음"
  [[ -n ${remote_path} ]] || die "auth ExternalSecret에 remotePath가 없음"
  local init_file=${TESTBED_STATE_DIR}/openbao-init.json
  [[ -s ${init_file} ]] || die "OpenBao root 재료가 없음: ${init_file}"
  jq -e '.root_token | type == "string" and length > 0' "${init_file}" >/dev/null \
    || die "OpenBao root token을 읽지 못함"
  # patch 는 기존 key(AUTH_SECRET 등)를 보존하지만 경로가 없으면 404만 뱉어 원인이
  # 안 보인다. 여기서 put 으로 새로 만들면 나머지 key 가 없는 채로 덮여 ESO 가 깨지므로,
  # 시드가 먼저 돌았는지 확인하고 아니면 무엇을 실행해야 하는지 알려 준다.
  openbao_root "${init_file}" kv get -mount=kv "${remote_path}" >/dev/null 2>&1 \
    || die "OpenBao kv/${remote_path} 가 없다. scripts/cluster/bootstrap-testbed-services.sh 를 먼저 실행하라"
  # root token과 봇 token 모두 stdin으로만 보낸다. kubectl exec command에는 값이 없어
  # apiserver audit request와 host 프로세스 목록에 자격증명이 남지 않는다.
  tr -d '\r\n' <"${token_file}" |
    openbao_root_input "${init_file}" kv patch -mount=kv "${remote_path}" \
      FORGEJO_BOT_TOKEN=- >/dev/null
  ok "Forgejo 봇 토큰을 OpenBao kv/${remote_path}에 저장(값 미출력)"
}

render_release() {
  hctl template "${RELEASE}" charts/app-profile -n "${namespace}" \
    -f "${CONTRACT_VALUES}" -f "${VALUES_FILE}"
}

apply_release() {
  local include_workload=${1:-true}
  ensure_namespace "${namespace}"
  # 렌더에 -n 을 넘겨 Release.Namespace 를 고정한다. 차트가 객체마다
  # metadata.namespace 를 명시하므로 apply 는 -n 없이 그대로 흘려보낸다.
  if [[ ${include_workload} == true ]]; then
    render_release | kctl apply -f - >/dev/null
  else
    # ExternalSecret 대상이 생기기 전에 새 소비 Pod가 뜨지 않도록 Deployment만 두 번째
    # apply로 미룬다. 기존 Deployment도 이 단계에서는 변경하지 않는다.
    render_release | python3 -c '
import sys
import yaml

documents = [
    document for document in yaml.safe_load_all(sys.stdin)
    if document and document.get("kind") != "Deployment"
]
yaml.safe_dump_all(documents, sys.stdout, sort_keys=False)
' | kctl apply -f - >/dev/null
  fi
  ok "Helm 렌더 결과 apply(${namespace}, workload=${include_workload})"
}

wait_dependencies() {
  local external_secret
  if [[ ${persistence_enabled} == true ]]; then
    kctl wait -n "${namespace}" "pvc/${app_name}-data" \
      --for=jsonpath='{.status.phase}'=Bound --timeout=5m >/dev/null
  fi
  while read -r external_secret; do
    [[ -n ${external_secret} ]] || continue
    wait_external_secret_ready "${namespace}" "${external_secret}" 5m
  done < <(kctl get externalsecret -n "${namespace}" \
    -l app.kubernetes.io/instance="${app_name}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  ok "PVC/ExternalSecret/대상 Secret Ready"
}

wait_workload_ready() {
  kctl rollout status -n "${namespace}" "deployment/${app_name}" --timeout=10m >/dev/null
  ok "Deployment Ready"
}

verify_workload() {
  local json strategy replicas
  json=$(kctl get deployment -n "${namespace}" "${app_name}" -o json)
  strategy=$(jq -r '.spec.strategy.type' <<<"${json}")
  replicas=$(jq -r '.status.readyReplicas // 0' <<<"${json}")
  [[ ${replicas} -ge 1 ]] || die "Ready replica 없음"
  if [[ ${persistence_enabled} == true && ${access_mode} == ReadWriteOnce ]]; then
    [[ ${strategy} == Recreate ]] || die "RWO PVC에는 Recreate 전략이어야 함(현재 ${strategy})"
  fi
  jq -e --arg mount "${mount_path}" '
    .spec.template.spec.containers[0].volumeMounts // [] | any(.mountPath == $mount)
  ' <<<"${json}" >/dev/null || die "컨테이너에 ${mount_path} 볼륨 마운트가 없음"
  jq -e '.spec.template.spec.containers[0].ports | length == 1 and .[0].containerPort == 8080' \
    <<<"${json}" >/dev/null || die "컨테이너 포트가 8080 하나가 아님(Go API 8081이 노출됐을 수 있음)"
  jq -e '.spec.template.spec.securityContext.runAsNonRoot == true' <<<"${json}" >/dev/null \
    || die "runAsNonRoot가 아님"
  jq -e '
    .spec.ports | length == 1 and .[0].port == 8080 and .[0].targetPort == "http"
  ' <<<"$(kctl get service -n "${namespace}" "${app_name}" -o json)" >/dev/null \
    || die "Service가 8080 단일 포트가 아님"
  ok "Deployment/Service 경계: 포트 8080만 노출, 상태 디렉터리 마운트, non-root"
}

verify_secret_material() {
  [[ -n ${secret_keys} ]] || { note "auth ExternalSecret 없음"; return; }
  # key 이름과 "비어 있지 않음"만 본다. 값은 읽지도 출력하지도 않는다.
  local report
  report=$(kctl get secret -n "${namespace}" "${app_name}-auth" -o json |
    jq -r --arg keys "${secret_keys}" '
      ($keys | split(",") | map(select(length > 0))) as $wanted |
      (.data // {}) as $data |
      [
        ($wanted - ($data | keys) | map("missing:" + .)),
        ($wanted | map(select(($data[.] // "") | length == 0)) | map("empty:" + .))
      ] | flatten | join(",")
    ')
  [[ -z ${report} ]] || die "${app_name}-auth Secret 문제: ${report}"
  ok "ExternalSecret 동기화 key 확인(값 미출력): ${secret_keys}"
}

verify_rbac() {
  [[ ${rbac_enabled} == true ]] || { note "rbac.enabled=false: 카탈로그 상태 프로브 비활성"; return; }
  local subject=system:serviceaccount:${namespace}:${service_account}
  local target
  for target in ${rbac_namespaces//,/ }; do
    [[ $(kctl auth can-i list endpointslices --as "${subject}" -n "${target}") == yes ]] \
      || die "${target}에서 EndpointSlice를 읽지 못함"
    [[ $(kctl auth can-i get secrets --as "${subject}" -n "${target}") == no ]] \
      || die "${target}에서 Secret 읽기가 허용됨(최소 권한 위반)"
    [[ $(kctl auth can-i create deployments --as "${subject}" -n "${target}") == no ]] \
      || die "${target}에서 쓰기 권한이 허용됨(최소 권한 위반)"
  done
  [[ $(kctl auth can-i list endpointslices --as "${subject}" -n kube-system) == no ]] \
    || die "허용 목록 밖 Namespace(kube-system)를 읽을 수 있음"
  [[ $(kctl auth can-i list nodes --as "${subject}") == no ]] \
    || die "클러스터 범위 자원을 읽을 수 있음"
  jq -e --arg audience "${token_audience}" '
    .spec.template.spec.volumes // [] |
    map(.projected.sources // [] | map(.serviceAccountToken // empty)) | flatten |
    any(.audience == $audience and (.expirationSeconds // 0) <= 3600)
  ' <<<"$(kctl get deployment -n "${namespace}" "${app_name}" -o json)" >/dev/null \
    || die "audience=${token_audience} 인 만료 토큰 projection이 없음"
  ok "ServiceAccount 최소 권한(허용 Namespace read-only, 클러스터 범위 없음)과 토큰 audience 확인"
}

verify_in_pod() {
  local pod api_health ui_health
  pod=$(kctl get pod -n "${namespace}" -l app.kubernetes.io/instance="${app_name}" \
    --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}')
  [[ -n ${pod} ]] || die "Running Pod를 찾지 못함"
  api_health=$(kctl exec -n "${namespace}" "${pod}" -- \
    wget -qO- -T 5 http://127.0.0.1:8081/healthz)
  [[ ${api_health} == ok ]] || die "Go API /healthz 응답이 정상이 아님"
  ui_health=$(kctl exec -n "${namespace}" "${pod}" -- \
    wget -qO- -T 5 http://127.0.0.1:8080/healthz)
  [[ ${ui_health} == "${api_health}" ]] \
    || die "Next 프록시가 Go API /healthz를 그대로 전달하지 않음"
  if [[ ${persistence_enabled} == true ]]; then
    kctl exec -n "${namespace}" "${pod}" -- sh -c "test -d '${mount_path}' && test -w '${mount_path}'" \
      || die "${mount_path}에 쓸 수 없음"
  fi
  ok "Pod 내부: Go API(8081) 정상, Next(8080)가 백엔드로 프록시, 상태 디렉터리 쓰기 가능"
}

verify_gateway() {
  local curl_common=(
    --silent --show-error --insecure --proto '=https'
    --resolve "${portal_host}:443:${gateway_vip}"
    --connect-timeout 5 --max-time 20
  )
  local body status
  body=$(curl "${curl_common[@]}" --fail-with-body "${portal_origin}/healthz")
  [[ ${body} == ok ]] || die "Gateway 경유 /healthz 실패"
  local path
  for path in /api/v1/catalog /api/v1/openapi.yaml /api/v1/deployment-requests; do
    status=$(curl "${curl_common[@]}" -o /dev/null -w '%{http_code}' "${portal_origin}${path}")
    [[ ${status} == 401 ]] || die "미인증 GET ${path} 응답이 401이 아님(${status})"
  done
  for path in /api/v1/app-profiles/validate /api/v1/deployment-requests; do
    status=$(curl "${curl_common[@]}" -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' --data '{"appName":"probe"}' \
      "${portal_origin}${path}")
    [[ ${status} == 401 ]] || die "미인증 POST ${path} 응답이 401이 아님(${status})"
  done
  ok "Gateway 경유 /healthz 200, 미인증 API GET/POST 401(세션 경계 유효)"
}

# ArgoCD가 릴리스를 소유한 뒤로는 apply_release가 Argo와 소유권을 다투므로,
# 부트스트랩성 작업(Secret 시딩)만 따로 돌릴 수 있어야 한다.
if [[ ${TOKEN_ONLY} == true ]]; then
  [[ -n ${FORGEJO_TOKEN_FILE} ]] || die "--token-only 에는 --forgejo-token-file 이 필요하다"
  install_forgejo_token "${FORGEJO_TOKEN_FILE}"
  ok "토큰만 주입 완료. 배포/동기화는 ArgoCD(application ${app_name}-${environment:-beta})가 한다"
  exit 0
fi

if [[ ${CHECK_ONLY} != true ]]; then
  if [[ ${SKIP_GUARD} != true ]]; then
    bash scripts/tests/render-test.sh
    bash scripts/ci-guard.sh
    ok "render-test/ci-guard 통과"
  fi
  if [[ -n ${FORGEJO_TOKEN_FILE} ]]; then
    install_forgejo_token "${FORGEJO_TOKEN_FILE}"
  elif [[ ${secret_keys} == *FORGEJO_BOT_TOKEN* ]]; then
    note "FORGEJO_BOT_TOKEN은 OpenBao kv/${remote_path}에 이미 있어야 한다"
  fi
  if [[ ${SKIP_IMAGE} != true ]]; then
    bash scripts/cluster/build-local-images.sh
  else
    note "이미지 단계 생략: ${image_ref}(pullPolicy=${pull_policy})가 노드에 있어야 한다"
  fi
  apply_release false
  wait_dependencies
  apply_release true
  if [[ ${SKIP_IMAGE} != true && ${pull_policy} == Never ]]; then
    # 같은 tag를 다시 import했으므로 Pod template 변화 없이도 새 이미지를 쓰게 만든다.
    kctl rollout restart -n "${namespace}" "deployment/${app_name}" >/dev/null
  fi
fi

if [[ ${CHECK_ONLY} == true ]]; then
  wait_dependencies
fi
wait_workload_ready

verify_workload
verify_secret_material
verify_rbac
verify_in_pod
verify_gateway
ok "Portal Lite 백엔드 설치/검증 완료: ${portal_origin}"
