#!/usr/bin/env bash
# 로컬 containerd 이미지로 hello, secure-demo, Portal Lite를 배포한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

PULL_DOCKERCONFIG=${SADP_REGISTRY_PULL_DOCKERCONFIG:-${CREDENTIAL_DIR}/registry-pull-dockerconfig.json}
PUSH_DOCKERCONFIG=${SADP_REGISTRY_PUSH_DOCKERCONFIG:-${CREDENTIAL_DIR}/registry-push-dockerconfig.json}
PULL_FILE_REQUIRED=false
PUSH_FILE_REQUIRED=false
while (($#)); do
  case "$1" in
    --registry-pull-dockerconfig)
      PULL_DOCKERCONFIG=${2:?--registry-pull-dockerconfig 값 필요}
      PULL_FILE_REQUIRED=true
      shift
      ;;
    --registry-push-dockerconfig)
      PUSH_DOCKERCONFIG=${2:?--registry-push-dockerconfig 값 필요}
      PUSH_FILE_REQUIRED=true
      shift
      ;;
    -h|--help)
      cat <<EOF
usage: sudo bash $0 [options]
  --registry-pull-dockerconfig <file>  앱 pull 전용 root-owned Docker config
  --registry-push-dockerconfig <file>  빌드 push 전용 root-owned Docker config

파일을 생략하면 ${CREDENTIAL_DIR}/registry-{pull,push}-dockerconfig.json 또는
이미 존재하는 Kubernetes Secret을 사용한다. pull과 push 자격증명은 서로 달라야 한다.
EOF
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

require_root
for command in jq stat sha256sum; do require_command "${command}"; done
[[ ${PULL_DOCKERCONFIG} == /* && ${PUSH_DOCKERCONFIG} == /* ]] || \
  die "registry Docker config는 root-only 절대경로로 지정해야 함"
ensure_state_dirs
cd "${TESTBED_ROOT}"
kctl get crd externalsecrets.external-secrets.io >/dev/null

# containerd는 auth가 있으면 반드시 base64(username:password)로 해석한다. auths map만
# 확인하면 raw token을 auth에 넣은 JSON도 설치를 통과하고 모든 Pod pull을 막는다.
dockerconfig_filter='
  def validCredential:
    type == "object" and (
      ((.auth // "") as $auth
        | ($auth | type) == "string" and ($auth | length) > 0
        and (try ($auth | @base64d | contains(":")) catch false))
      or
      (((.auth // "") == "")
        and ((.username // "") | type) == "string" and ((.username // "") | length) > 0
        and ((.password // "") | type) == "string" and ((.password // "") | length) > 0)
    );
  type == "object"
  and (.auths | type == "object")
  and (.auths | length > 0)
  and all(.auths[]; validCredential)
'

# Namespace 를 박아 두면 WORKLOAD_NAMESPACE 를 바꾼 사이트에서 엉뚱한 곳에 배포된다.
# 계약이 default-deny egress 를 거는 Namespace 가 곧 워크로드 Namespace 다.
WORKLOAD_NAMESPACE=$(python3 - <<'PY'
import yaml

spec = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))["spec"]
namespaces = spec["network"].get("defaultDenyNamespaces") or []
if len(namespaces) != 1:
    raise SystemExit("[FAIL] network.defaultDenyNamespaces 가 정확히 하나여야 한다")
print(namespaces[0])
PY
) || exit 1
ok "워크로드 Namespace: ${WORKLOAD_NAMESPACE}"

# pull 계정은 배포 Pod가 읽기만 하고 push 계정은 kaniko가 쓰기까지 한다. push config를
# pull Secret으로 복제하면 모든 AppGroup Pod에 쓰기 권한이 퍼지므로 두 입력을 강제로 분리한다.
mapfile -t registry_contract < <(python3 - <<'PY'
import yaml
import re

values = yaml.safe_load(open("contracts/values-platform-production.yaml", encoding="utf-8"))
registry = values["platform"]["registry"]
path = str(registry["pullSecretRemotePath"])
if not re.fullmatch(r"platform/registry/[a-z0-9]([-a-z0-9.]*[a-z0-9])?", path):
    raise SystemExit("[FAIL] platform.registry.pullSecretRemotePath 계약값이 허용 경로가 아님")
print(str(registry["pullSecretName"]))
print(path)

portal = yaml.safe_load(open("apps/portal-lite/values-beta.yaml", encoding="utf-8"))
config = portal["configuration"]["config"]
print(str(config["PORTAL_BUILD_DOCKER_CONFIG_NAME"]))
print(str(config["PORTAL_BUILD_DOCKER_CONFIG_KEY"]))
PY
) || exit 1
PULL_SECRET_NAME=${registry_contract[0]:?registry pull Secret 이름 없음}
REGISTRY_REMOTE_PATH=${registry_contract[1]:?registry pull remote path 없음}
PUSH_SECRET_NAME=${registry_contract[2]:?registry push Secret 이름 없음}
PUSH_SECRET_KEY=${registry_contract[3]:?registry push Secret key 없음}
[[ ${PULL_SECRET_NAME} != "${PUSH_SECRET_NAME}" ]] || \
  die "registry pull/push Kubernetes Secret 이름이 같음: 계약/config를 분리하라"

validate_root_dockerconfig() {
  local path=$1 purpose=$2 owner mode
  [[ -f ${path} && ! -L ${path} ]] || die "${purpose} Docker config가 일반 파일이 아님: ${path}"
  owner=$(stat -c '%u' "${path}")
  mode=$(stat -c '%a' "${path}")
  [[ ${owner} == 0 ]] || die "${purpose} Docker config 소유자는 root여야 함: ${path}"
  [[ ${mode} == 400 || ${mode} == 600 ]] || \
    die "${purpose} Docker config mode는 0400 또는 0600이어야 함: ${path}"
  jq -e "${dockerconfig_filter}" "${path}" >/dev/null \
    || die "${purpose} Docker config auth는 base64(username:password) 형식이어야 함: ${path}"
}

pull_config() {
  if [[ -f ${PULL_DOCKERCONFIG} ]]; then
    cat "${PULL_DOCKERCONFIG}"
  else
    kctl get secret "${PULL_SECRET_NAME}" -n "${WORKLOAD_NAMESPACE}" -o json |
      jq -er 'select(.type == "kubernetes.io/dockerconfigjson"
        and ((.data[".dockerconfigjson"] // "") != ""))
        | .data[".dockerconfigjson"] | @base64d'
  fi
}
push_config() {
  if [[ -f ${PUSH_DOCKERCONFIG} ]]; then
    cat "${PUSH_DOCKERCONFIG}"
  else
    kctl get secret "${PUSH_SECRET_NAME}" -n "${WORKLOAD_NAMESPACE}" -o json |
      jq -er --arg key "${PUSH_SECRET_KEY}" '
        (.data[$key] // "") | select(length > 0) | @base64d'
  fi
}

if [[ -f ${PULL_DOCKERCONFIG} ]]; then
  validate_root_dockerconfig "${PULL_DOCKERCONFIG}" pull
elif [[ ${PULL_FILE_REQUIRED} == true ]]; then
  die "지정한 pull Docker config 없음: ${PULL_DOCKERCONFIG}"
elif ! kctl get secret "${PULL_SECRET_NAME}" -n "${WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
  die "pull 자격증명 없음: root-owned ${PULL_DOCKERCONFIG} 또는 기존 ${WORKLOAD_NAMESPACE}/${PULL_SECRET_NAME} 필요"
fi
pull_config | jq -e "${dockerconfig_filter}" \
  >/dev/null || die "${WORKLOAD_NAMESPACE}/${PULL_SECRET_NAME}의 Docker config 형식 오류"

if [[ -f ${PUSH_DOCKERCONFIG} ]]; then
  validate_root_dockerconfig "${PUSH_DOCKERCONFIG}" push
elif [[ ${PUSH_FILE_REQUIRED} == true ]]; then
  die "지정한 push Docker config 없음: ${PUSH_DOCKERCONFIG}"
elif ! kctl get secret "${PUSH_SECRET_NAME}" -n "${WORKLOAD_NAMESPACE}" >/dev/null 2>&1; then
  die "빌드 push 자격증명 없음: root-owned ${PUSH_DOCKERCONFIG} 또는 기존 ${WORKLOAD_NAMESPACE}/${PUSH_SECRET_NAME} 필요; Portal 단일 앱 source build를 안전하게 제공할 수 없음"
fi
push_config | jq -e "${dockerconfig_filter}" \
  >/dev/null || die "${WORKLOAD_NAMESPACE}/${PUSH_SECRET_NAME}의 Docker config 형식 오류"

pull_digest=$(pull_config | jq -cS . | sha256sum | awk '{print $1}')
push_digest=$(push_config | jq -cS . | sha256sum | awk '{print $1}')
[[ ${pull_digest} != "${push_digest}" ]] || die \
  "pull/push Docker config가 동일함: read-only pull 계정과 write 가능한 build 계정을 분리하라"
unset pull_digest push_digest
ok "registry pull/push 자격증명 분리와 Docker config 형식 확인"

# 두 입력을 모두 검증한 뒤에만 Secret을 바꾼다. push 누락으로 실패하면서 pull만
# 갱신되는 반쪽 상태를 남기지 않는다.
if [[ -f ${PULL_DOCKERCONFIG} ]]; then
  kctl create secret generic "${PULL_SECRET_NAME}" -n "${WORKLOAD_NAMESPACE}" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="${PULL_DOCKERCONFIG}" --dry-run=client -o yaml |
    kctl apply -f - >/dev/null
fi
if [[ -f ${PUSH_DOCKERCONFIG} ]]; then
  kctl create secret generic "${PUSH_SECRET_NAME}" -n "${WORKLOAD_NAMESPACE}" \
    --from-file="${PUSH_SECRET_KEY}=${PUSH_DOCKERCONFIG}" --dry-run=client -o yaml |
    kctl apply -f - >/dev/null
fi

# AppGroup Namespace는 Zone Secret을 직접 읽지 않는다. pull 전용 값만 OpenBao 공통
# 경로에 넣고 ESO가 Namespace별 dockerconfigjson Secret으로 동기화한다.
OPENBAO_INIT_FILE=${TESTBED_STATE_DIR}/openbao-init.json
[[ -s ${OPENBAO_INIT_FILE} ]] || die "OpenBao 초기화 파일 없음: ${OPENBAO_INIT_FILE}"
OPENBAO_POD=openbao-0
OPENBAO_ADDR=https://openbao.openbao.svc.cluster.local:8200
bao_root_input() {
  {
    jq -er '.root_token' "${OPENBAO_INIT_FILE}"
    cat
  } | kctl exec -i -n openbao "${OPENBAO_POD}" -- sh -ceu '
    IFS= read -r BAO_TOKEN
    export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
    shift
    exec bao "$@"
  ' sh "${OPENBAO_ADDR}" "$@"
}
pull_config | jq -Rs '{data:{dockerconfigjson:.}}' |
  bao_root_input write -format=json "kv/data/${REGISTRY_REMOTE_PATH}" - >/dev/null
ok "AppGroup registry pull 전용 credential를 OpenBao 공통 경로에 동기화"

render_apply() {
  local release=$1 values=$2
  # 렌더에 -n 을 넘겨야 Release.Namespace 가 워크로드 Namespace 로 고정된다.
  # 차트가 모든 객체에 metadata.namespace 를 명시하고 status-reader Role 처럼
  # 다른 Namespace 로 나가는 객체도 있으므로 apply 에는 -n 을 주지 않는다.
  hctl template "${release}" charts/app-profile -n "${WORKLOAD_NAMESPACE}" \
    -f contracts/values-platform-production.yaml -f "${values}" | kctl apply -f - >/dev/null
}
render_apply hello apps/hello/values-beta.yaml
render_apply secure-demo apps/secure-demo/values-beta.yaml
render_apply portal-lite apps/portal-lite/values-beta.yaml

bash scripts/node/install-squid-egress.sh --check
kctl apply -f platform/network/egress-policies.yaml >/dev/null

# 테스트베드는 registry 대신 동일한 local tag를 노드 containerd에 다시 import한다.
# Deployment spec이 같아도 새 image digest를 사용하도록 Pod template을 명시적으로 갱신한다.
for deployment in hello secure-demo portal-lite; do
  kctl rollout restart -n "${WORKLOAD_NAMESPACE}" deployment/${deployment} >/dev/null
done

security_policy_accepted() {
  kctl get securitypolicy -n "${WORKLOAD_NAMESPACE}" secure-demo-oidc -o json 2>/dev/null | \
    jq -e '.status.ancestors[].conditions[] | select(.type=="Accepted" and .status=="True")' >/dev/null
}
for _ in {1..15}; do
  security_policy_accepted && break
  sleep 2
done
if ! security_policy_accepted; then
  # CoreDNS split-horizon이 기존 controller Pod보다 늦게 반영된 재실행 상황.
  kctl rollout restart -n envoy-gateway-system deployment/envoy-gateway >/dev/null
  kctl rollout status -n envoy-gateway-system deployment/envoy-gateway --timeout=5m >/dev/null
  for _ in {1..60}; do
    security_policy_accepted && break
    sleep 2
  done
fi
security_policy_accepted || die "secure-demo OIDC SecurityPolicy 미수락"

kctl wait -n "${WORKLOAD_NAMESPACE}" externalsecret/secure-demo-runtime --for=condition=Ready --timeout=5m >/dev/null
kctl wait -n "${WORKLOAD_NAMESPACE}" externalsecret/secure-demo-oidc-client --for=condition=Ready --timeout=5m >/dev/null
kctl wait -n "${WORKLOAD_NAMESPACE}" externalsecret/portal-lite-auth --for=condition=Ready --timeout=5m >/dev/null
for deployment in hello secure-demo portal-lite; do
  kctl rollout status -n "${WORKLOAD_NAMESPACE}" deployment/${deployment} --timeout=10m >/dev/null
done
ok "hello(public), secure-demo(OIDC+ESO), Portal Lite(Auth.js+ESO), default-deny egress 배포 Ready"
