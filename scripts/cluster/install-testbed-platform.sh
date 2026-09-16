#!/usr/bin/env bash
# wildcard TLS와 사이트 고유 리소스를 설치한다. 외부 IdP는 관리하지 않는다.
# Helm 차트(ESO/Reloader/OpenBao/monitoring)의 소유자는 Argo 이고 여기서는 Ready 만 확인한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

SKIP_MONITORING_IMAGE_SYNC=false

while (($#)); do
  case "$1" in
    --skip-monitoring-image-sync) SKIP_MONITORING_IMAGE_SYNC=true ;;
    -h|--help)
      cat <<'EOF'
usage: sudo scripts/cluster/install-testbed-platform.sh [--skip-monitoring-image-sync]

--skip-monitoring-image-sync는 통합 설치기가 Argo bootstrap 전에 Prometheus/Loki/Alloy 이미지를
모든 노드에 선배포한 경우에만 사용한다. 직접 실행할 때는 기본 동기화를 유지한다.
EOF
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

require_root
for command in openssl python3 jq base64 stat; do require_command "${command}"; done
[[ -x ${KUBECTL_BIN} ]] || die "kubectl 없음: ${KUBECTL_BIN}"
ensure_state_dirs
cd "${TESTBED_ROOT}"
source platform/network/proxy.env

mapfile -t contract_values < <(python3 - <<'PY'
import yaml
doc = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))
spec = doc["spec"]
tls = spec["tls"]
print(spec["baseDomain"])
print(tls["provided"]["certificatePath"])
print(tls["provided"]["privateKeyPath"])
# staging ACME 는 운영 Secret 을 건드리지 않으려고 별도 이름으로 발급된다.
# verify-d5.sh 와 같은 규칙을 써야 두 스크립트가 같은 Secret 을 본다.
secret = spec["gateway"]["wildcardTlsSecret"]
if tls["source"] == "acme" and tls["issuerMode"] != "production":
    secret += "-staging"
print(secret)
print(tls["source"])
print(str(bool((spec.get("monitoring") or {}).get("enabled", True))).lower())
PY
)
BASE_DOMAIN=${contract_values[0]}
CERT_FILE=${TESTBED_ROOT}/${contract_values[1]}
KEY_FILE=${TESTBED_ROOT}/${contract_values[2]}
TLS_SECRET=${contract_values[3]}
TLS_SOURCE=${contract_values[4]}
INSTALL_MONITORING=${contract_values[5]}
REUSE_EXISTING_TLS=false
temporary_paths=()
cleanup() {
  local path
  for path in "${temporary_paths[@]}"; do rm -f "${path}"; done
}
trap cleanup EXIT

# 플랫폼 Helm 차트의 소유자는 Argo 다(docs/installation.md 단계 6). 이 스크립트는 단계 8이라
# Application 이 이미 있어야 한다. 여기서 helm install 을 하면 Argo 가 helm template 으로 만든
# 리소스에 release 어노테이션이 없어 "cannot be imported into the current release" 로 깨진다.
require_argo_application() {
  local application=$1
  kctl get applications.argoproj.io -n devtroncd "${application}" >/dev/null 2>&1 \
    || die "Argo Application ${application} 없음. docs/installation.md 단계 6(GitOps bootstrap)을 먼저 끝내라"
}

# 기존 Gateway Secret 을 임시 파일로 꺼낸다. Secret 이 없으면 1을 돌려주고 아무것도 만들지 않는다.
load_gateway_tls() {
  kctl get secret -n envoy-gateway-system "${TLS_SECRET}" >/dev/null 2>&1 || return 1
  CERT_FILE=$(mktemp "${TESTBED_STATE_DIR}/existing-wildcard-cert.XXXXXX")
  KEY_FILE=$(mktemp "${TESTBED_STATE_DIR}/existing-wildcard-key.XXXXXX")
  temporary_paths+=("${CERT_FILE}" "${KEY_FILE}")
  chmod 0600 "${CERT_FILE}" "${KEY_FILE}"
  kctl get secret -n envoy-gateway-system "${TLS_SECRET}" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d >"${CERT_FILE}"
  kctl get secret -n envoy-gateway-system "${TLS_SECRET}" \
    -o jsonpath='{.data.tls\.key}' | base64 -d >"${KEY_FILE}"
}

validate_wildcard_files() {
  openssl x509 -in "${CERT_FILE}" -noout >/dev/null
  openssl pkey -in "${KEY_FILE}" -noout >/dev/null
  openssl x509 -in "${CERT_FILE}" -checkend 604800 -noout >/dev/null \
    || die "wildcard 인증서의 잔여 유효기간이 7일 미만"
  san=$(openssl x509 -in "${CERT_FILE}" -noout -ext subjectAltName)
  grep -Fq "DNS:*.${BASE_DOMAIN}" <<<"${san}" || die "wildcard SAN 누락: *.${BASE_DOMAIN}"
  grep -Fq "DNS:${BASE_DOMAIN}" <<<"${san}" || die "apex SAN 누락: ${BASE_DOMAIN}"
  cert_hash=$(openssl x509 -in "${CERT_FILE}" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)
  key_hash=$(openssl pkey -in "${KEY_FILE}" -pubout -outform DER | sha256sum | cut -d' ' -f1)
  [[ ${cert_hash} == "${key_hash}" ]] || die "wildcard 인증서와 private key가 일치하지 않음"
  key_mode=$(stat -c '%a' "${KEY_FILE}")
  (( (8#${key_mode} & 077) == 0 )) || die "private key 권한이 너무 넓음(${key_mode}); 600 권장"
  ok "wildcard SAN/유효기간/key 일치/파일 권한 검증"
}

if [[ ${TLS_SOURCE} == acme ]]; then
  # DNS-01 경로에서 wildcard Secret 의 주인은 cert-manager 다. 제공 PEM 을 요구해서도,
  # 아래 provided 분기처럼 Certificate 를 지우고 정적 Secret 으로 덮어써서도 안 된다.
  REUSE_EXISTING_TLS=true
  note "cert-manager 설치와 DNS-01 node route preflight 뒤 Certificate ${TLS_SECRET} Ready를 기다림"
elif [[ ! -r ${CERT_FILE} || ! -r ${KEY_FILE} ]]; then
  load_gateway_tls || die "제공 PEM도 기존 Gateway TLS Secret도 없음"
  REUSE_EXISTING_TLS=true
  note "로컬 제공 PEM이 없어 기존 envoy-gateway-system/${TLS_SECRET}을 검증 후 재사용"
fi

if [[ ${TLS_SOURCE} == provided ]]; then
  validate_wildcard_files
fi

check_cluster_topology

kctl apply -f platform/dns/rke2-coredns-config.yaml >/dev/null
kctl rollout status -n kube-system deployment/rke2-coredns-rke2-coredns --timeout=5m >/dev/null
ok "CoreDNS 계약 설정 적용"

# Forgejo에 push할 자격증명이 없는 동안 원격 main의 예전 manifest가 수동 배포를 되돌리지 않게 한다.
for application in platform-bootstrap platform-resources hello-beta; do
  if kctl get applications.argoproj.io -n devtroncd "${application}" >/dev/null 2>&1; then
    kctl get applications.argoproj.io -n devtroncd "${application}" -o yaml >"${TESTBED_STATE_DIR}/argo-${application}-before.yaml"
    if [[ -n $(kctl get applications.argoproj.io -n devtroncd "${application}" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null) ]]; then
      kctl patch applications.argoproj.io -n devtroncd "${application}" --type=merge \
        -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
      note "Argo 자동 동기화 일시 중지: ${application}"
    fi
  fi
done

kctl apply -f argocd/applications/cert-manager.yaml >/dev/null
proxy_applied=false
for _ in {1..60}; do
  controller_env=$(kctl get deployment -n cert-manager cert-manager -o json)
  if jq -e '
    [.spec.template.spec.containers[0].env[]? |
      select(.name == "HTTP_PROXY" or .name == "HTTPS_PROXY")] |
    length == 2
  ' <<<"${controller_env}" >/dev/null; then
    proxy_applied=true
    break
  fi
  sleep 2
done
[[ ${proxy_applied} == true ]] || die "cert-manager controller proxy env 미적용"
kctl rollout status -n cert-manager deployment/cert-manager --timeout=10m >/dev/null
for component in cert-manager-webhook cert-manager-cainjector; do
  component_proxy=$(kctl get deployment -n cert-manager "${component}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HTTPS_PROXY")].value}')
  [[ -z ${component_proxy} ]] || die "${component}에 proxy가 잘못 적용됨"
done
ok "cert-manager controller 전용 Squid proxy와 내부 recursive DNS 적용"

wait_cert_manager_api() {
  local component attempt result
  # controller Ready만으로는 webhook endpoint와 cainjector의 CA 반영을 보장하지 못합니다.
  for component in cert-manager-webhook cert-manager-cainjector; do
    note "${component} 준비 대기"
    kctl rollout status -n cert-manager "deployment/${component}" --timeout=5m >/dev/null \
      || die "${component} 미기동. cert-manager Pod/이벤트를 확인하라"
  done
  for attempt in {1..30}; do
    # 실제 admission 경로를 확인하되 인증서 리소스는 아직 저장하지 않습니다.
    if result=$(kctl apply --dry-run=server --request-timeout=10s \
        -f platform/exposure/internal-ca.yaml 2>&1); then
      ok "cert-manager webhook/API 서버 검증 통과"
      return 0
    fi
    case "${result}" in
      *"failed calling webhook"*|*"failed to call webhook"*) ;;
      *) printf '%s\n' "${result}" >&2; die "내부 CA manifest 서버 검증 실패" ;;
    esac
    if ((attempt == 1 || attempt % 5 == 0)); then
      note "cert-manager admission 준비 대기(${attempt}/30)"
    fi
    ((attempt == 30)) || sleep 2
  done
  printf '%s\n' "${result}" >&2
  die "cert-manager webhook/API 준비 timeout. endpoint와 CA 주입 상태를 확인하라"
}
wait_cert_manager_api

# 일반 인터넷 DNS 성공은 RFC2136 authoritative endpoint의 TCP/UDP 경로 증거가 아니다.
# 실제 controller가 Ready인 node마다 host network probe를 통과해야 Certificate 대기를 시작한다.
bash scripts/cluster/preflight-cert-manager-dns01.sh --apply
if [[ ${TLS_SOURCE} == acme ]]; then
  certificate_found=false
  for _ in {1..60}; do
    if kctl get certificate -n envoy-gateway-system "${TLS_SECRET}" >/dev/null 2>&1; then
      certificate_found=true
      break
    fi
    sleep 2
  done
  [[ ${certificate_found} == true ]] \
    || die "wildcard Certificate ${TLS_SECRET}이 생성되지 않음. platform-resources 동기화를 확인하라"
  if ! kctl wait certificate -n envoy-gateway-system "${TLS_SECRET}" \
      --for=condition=Ready --timeout=15m >/dev/null; then
    note "값 비노출 검사: kubectl -n envoy-gateway-system get certificate ${TLS_SECRET} -o jsonpath='{.status.conditions}{\"\\n\"}'"
    note "값 비노출 검사: kubectl -n cert-manager get challenge,order"
    die "wildcard Certificate Ready 실패. DNS-01 route/Order/Challenge를 복구한 뒤 이 단계부터 재실행하라"
  fi
  load_gateway_tls \
    || die "Certificate Ready인데 대상 TLS Secret 객체가 없음: envoy-gateway-system/${TLS_SECRET}"
  validate_wildcard_files
  ok "DNS-01 preflight 뒤 wildcard Certificate와 대상 TLS Secret Ready"
fi

ensure_namespace envoy-gateway-system
if [[ ${REUSE_EXISTING_TLS} == false ]]; then
  if kctl get certificate -n envoy-gateway-system "${TLS_SECRET}" >/dev/null 2>&1; then
    kctl delete certificate -n envoy-gateway-system "${TLS_SECRET}" --wait=true >/dev/null
    note "제공 Secret을 덮어쓰던 cert-manager Certificate 제거: ${TLS_SECRET}"
  fi
  kctl create secret tls "${TLS_SECRET}" -n envoy-gateway-system \
    --cert="${CERT_FILE}" --key="${KEY_FILE}" --dry-run=client -o yaml | kctl apply -f - >/dev/null
  ok "제공 wildcard 인증서를 envoy-gateway-system/${TLS_SECRET}에 적용"
else
  ok "기존 wildcard TLS Secret을 변경 없이 재사용"
fi

kctl apply -f platform/exposure/internal-ca.yaml >/dev/null
kctl wait -n cert-manager certificate/beta-internal-ca --for=condition=Ready --timeout=5m >/dev/null
ok "내부 서비스 TLS용 CA Ready"

for name in portal-auth-secret app-db-password app-api-token; do
  ensure_random_file "${CREDENTIAL_DIR}/${name}"
done
note "Identity Provider는 외부 운영 경계다. SADP는 IdP/realm/client/사용자/그룹을 설치하거나 변경하지 않음"

ensure_namespace external-secrets
ensure_namespace reloader
ensure_namespace openbao
require_argo_application external-secrets
require_argo_application reloader
kctl rollout status -n external-secrets deployment/external-secrets --timeout=10m >/dev/null \
  || die "External Secrets 미기동. Argo Application external-secrets 동기화 상태를 먼저 확인하라"
kctl rollout status -n reloader deployment/reloader-reloader --timeout=10m >/dev/null \
  || die "Reloader 미기동. Argo Application reloader 동기화 상태를 먼저 확인하라"
ok "External Secrets / Reloader Ready 확인(Argo 소유)"

kctl apply -f platform/openbao/resources.yaml >/dev/null
kctl wait -n openbao certificate/openbao-server --for=condition=Ready --timeout=5m >/dev/null
ca_file=$(mktemp "${TESTBED_STATE_DIR}/openbao-ca.XXXXXX")
temporary_paths+=("${ca_file}")
kctl get secret -n cert-manager beta-internal-ca-keypair -o jsonpath='{.data.ca\.crt}' | base64 -d >"${ca_file}"
for namespace in openbao "$(workload_namespace)" "$(platform_route_namespace)"; do
  ensure_namespace "${namespace}"
  kctl create configmap openbao-ca -n "${namespace}" --from-file=ca.crt="${ca_file}" \
    --dry-run=client -o yaml | kctl apply -f - >/dev/null
done
require_argo_application openbao
kctl wait -n openbao pod/openbao-0 --for=jsonpath='{.status.phase}'=Running --timeout=10m >/dev/null \
  || die "openbao-0 미기동. Argo Application openbao 동기화 상태를 먼저 확인하라"
ok "OpenBao Raft/PVC/audit/internal TLS Ready 확인(Argo 소유, 초기화 전)"

# ReferenceGrant/HTTPRoute가 가리키는 선택 Namespace가 manifest 중간보다 늦게 나오면 같은
# apply가 NamespaceNotFound로 중단된다. parser 기반 preflight가 Namespace만 먼저 만든다.
python3 scripts/cluster/prepare-exposure-namespaces.py --apply
kctl apply -f platform/exposure/resources.yaml >/dev/null
ok "HTTPS Gateway와 플랫폼 routes 적용 완료"
# 외부 Grafana 통합 운영용 읽기 백엔드. Grafana 자체는 클러스터 밖에 있으므로 설치하지 않고,
# Prometheus/Loki 와 로그 수집기(Alloy)만 둔다. 노출과 인증은 계약의 MACHINE_AUTH_SERVICES 가
# 담당한다(docs/external-observability.md).
#
# 워커 노드는 인터넷 egress 가 차단돼 있어 registry 에서 이미지를 받지 못한다. 설치 전에
# 반드시 모든 노드에 이미지를 배포해야 한다. 안 하면 워커에서 ImagePullBackOff 로 죽는다.
# 차트 버전은 Argo Application 이 들고 있으므로 여기서 versions.lock.yaml 을 읽지 않는다.
#
# 이미지 목록은 저장소가 소유한다. 그래야 다른 서버에서도 같은 이미지로 재현된다.
# 사이트 전용으로 덧붙일 이미지가 있으면 상태 디렉터리 목록이 우선한다.
monitoring_images=${TESTBED_ROOT}/platform/monitoring/images.txt
if [[ -s ${TESTBED_STATE_DIR}/monitoring-images.txt ]]; then
  monitoring_images=${TESTBED_STATE_DIR}/monitoring-images.txt
  note "사이트 전용 monitoring 이미지 목록 사용: ${monitoring_images}"
fi
if [[ ${INSTALL_MONITORING} != true ]]; then
  note "spec.monitoring.enabled=false: Prometheus/Loki/Alloy 설치 확인을 건너뜀"
elif [[ ! -s ${monitoring_images} ]]; then
  note "monitoring 이미지 목록이 없어 스택 설치를 건너뜀: ${monitoring_images}"
  note "docs/external-observability.md 의 이미지 배포 절차를 먼저 수행한다"
else
  # 원툴 설치기는 Argo Application 생성 전에 이미지를 선배포한다. 이 스크립트를 직접 부르는
  # 레거시/진단 경로만 여기서 동기화해 어느 진입점도 폐쇄망 worker pull에 기대지 않게 한다.
  if [[ ${SKIP_MONITORING_IMAGE_SYNC} == true ]]; then
    note "원툴 cluster 단계가 monitoring 이미지를 Argo bootstrap 전에 선배포함"
  else
    bash scripts/cluster/sync-external-images.sh --image-list "${monitoring_images}"
  fi
  for application in prometheus loki alloy; do require_argo_application "${application}"; done
  kctl rollout status -n monitoring deployment/prometheus-server --timeout=10m >/dev/null \
    || die "Prometheus 미기동. Argo Application prometheus 동기화 상태를 먼저 확인하라"
  kctl rollout status -n monitoring statefulset/loki --timeout=10m >/dev/null \
    || die "Loki 미기동. Argo Application loki 동기화 상태를 먼저 확인하라"
  kctl rollout status -n monitoring daemonset/alloy --timeout=10m >/dev/null \
    || die "Alloy 미기동. Argo Application alloy 동기화 상태를 먼저 확인하라"
  ok "Prometheus/Loki/Alloy Ready 확인(Argo 소유, 외부 Grafana 백엔드)"
fi
