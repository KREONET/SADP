#!/usr/bin/env bash
# site.env 하나를 검증한 뒤 현재 노드 역할과 선택 기능에 맞는 기존 설치기를 순서대로 호출한다.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT}"

ENV_FILE=/etc/sadp/site.env
PHASE=all
APPLY=false
ALLOW_DIRTY=false
NODE_NAME=

usage() {
  cat <<'EOF'
SADP 통합 설치기

사용법:
  sudo bash ./sadp --install --env-file /etc/sadp/site.env --phase <phase> [--apply]

phase:
  render   site.env 검증과 계약/매니페스트 생성. 실제 클러스터는 변경하지 않음
  node     현재 호스트 이름으로 server/agent를 판별해 노드 설정 적용
  cluster  control-plane에서 GitOps/플랫폼/서비스/앱/검수를 순서대로 실행
  all      읽기 전용으로 node + cluster 전체 계획 검사(--apply와 함께 사용할 수 없음)

옵션:
  --node-name <name>  hostname -s 대신 WORKER_NODES/CONTROL_PLANE_HOSTNAME의 이름 사용
  --allow-dirty       render --apply에서 기존 worktree 변경을 검토했음을 명시
  --apply             계획 출력이 아니라 실제 적용. RKE2 서비스는 자동 재시작하지 않음

안전한 기본 동작:
  --apply가 없으면 site.env와 전체 실행 계획만 검사한다. render 이외 phase의 --apply는
  현재 checkout이 site.env와 정확히 일치해야 하며, 생성물을 자동 commit/push하지 않는다.
EOF
}

while (($#)); do
  case "$1" in
    --env-file) ENV_FILE=${2:?--env-file 값 필요}; shift ;;
    --phase) PHASE=${2:?--phase 값 필요}; shift ;;
    --node-name) NODE_NAME=${2:?--node-name 값 필요}; shift ;;
    --allow-dirty) ALLOW_DIRTY=true ;;
    --apply) APPLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[FAIL] 알 수 없는 인자: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "${PHASE}" in
  render|node|cluster|all) ;;
  *) printf '[FAIL] --phase는 render|node|cluster|all 중 하나여야 함\n' >&2; exit 2 ;;
esac
[[ -r ${ENV_FILE} ]] || { printf '[FAIL] site.env를 읽을 수 없음: %s\n' "${ENV_FILE}" >&2; exit 1; }
if [[ ${APPLY} == true && ${PHASE} == all ]]; then
  printf '[FAIL] all phase는 계획 검사 전용이다. node를 적용하고 수동 재시작/Ready 확인 후 cluster를 별도로 적용해야 함\n' >&2
  exit 1
fi
if [[ ${APPLY} == true && $(id -u) -ne 0 && ${PHASE} != render ]]; then
  printf '[FAIL] node/cluster 적용은 root로 실행해야 함\n' >&2
  exit 1
fi

note() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK]   %s\n' "$*"; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

print_command() {
  printf '       '
  printf '%q ' "$@"
  printf '\n'
}

step() {
  local label=$1
  shift
  note "${label}"
  print_command "$@"
  if [[ ${APPLY} == true ]]; then
    "$@"
  fi
}

require_input_file() {
  local path=$1 label=$2 owner mode
  [[ -n ${path} ]] || die "${label} 경로가 site.env에 없음"
  [[ -f ${path} && ! -L ${path} ]] || die "${label}가 일반 파일이 아님: ${path}"
  owner=$(stat -c '%u' "${path}")
  mode=$(stat -c '%a' "${path}")
  [[ ${owner} == 0 ]] || die "${label} 소유자는 root여야 함: ${path}"
  [[ ${mode} == 400 || ${mode} == 600 ]] \
    || die "${label} mode는 0400 또는 0600이어야 함: ${path}"
  [[ -s ${path} ]] || die "${label}가 비어 있음: ${path}"
}

configure=(python3 scripts/site/configure-site.py --env-file "${ENV_FILE}")
if [[ ${PHASE} == render ]]; then
  configure+=(--check)
else
  configure+=(--check-rendered)
fi
"${configure[@]}"

# configure-site의 엄격한 parser/validator를 통과한 값만 source한다. 원본 site.env를
# source하지 않으므로 command substitution이나 Secret처럼 보이는 key가 shell에 들어오지 않는다.
eval "$(python3 scripts/site/configure-site.py --env-file "${ENV_FILE}" --print-install-env)"

if [[ ${APPLY} == true ]]; then
  case "${BASE_DOMAIN}" in
    *.example.invalid|example.invalid) die "예제 BASE_DOMAIN을 실제 설치에 사용할 수 없음" ;;
  esac
  [[ ${FORGEJO_REPO_URL} != *example.invalid* ]] \
    || die "예제 Forgejo URL을 실제 설치에 사용할 수 없음"
  [[ ${OCI_REGISTRY} != *example.invalid* ]] \
    || die "예제 Registry URL을 실제 설치에 사용할 수 없음"
  case "${PUBLIC_IP}" in
    192.0.2.*|198.51.100.*|203.0.113.*) die "문서 전용 PUBLIC_IP를 실제 설치에 사용할 수 없음" ;;
  esac
fi

if [[ ${PHASE} == render ]]; then
  if [[ ${APPLY} == true ]]; then
    write=(python3 scripts/site/configure-site.py --env-file "${ENV_FILE}" --write)
    [[ ${ALLOW_DIRTY} == false ]] || write+=(--allow-dirty)
    step "site.env에서 계약과 전체 생성물 렌더" "${write[@]}"
    note "생성 diff를 검토해 사이트 전용 branch에 commit/push한 뒤 node/cluster phase를 실행한다"
  else
    note "검사만 완료. 생성하려면 --phase render --apply"
  fi
  exit 0
fi

if [[ -z ${NODE_NAME} ]]; then
  NODE_NAME=$(hostname -s)
fi

NODE_ROLE=
NODE_IP=
if [[ ${NODE_NAME} == "${CONTROL_PLANE_HOSTNAME}" ]]; then
  NODE_ROLE=server
  NODE_IP=${CONTROL_PLANE_IP}
else
  IFS=, read -ra worker_entries <<<"${WORKER_NODES}"
  for entry in "${worker_entries[@]}"; do
    worker_name=${entry%%=*}
    worker_ip=${entry#*=}
    if [[ ${NODE_NAME} == "${worker_name}" ]]; then
      NODE_ROLE=agent
      NODE_IP=${worker_ip}
      break
    fi
  done
fi

if [[ ${PHASE} == node || ${PHASE} == all ]]; then
  [[ -n ${NODE_ROLE} ]] \
    || die "현재 노드 '${NODE_NAME}'가 CONTROL_PLANE_HOSTNAME/WORKER_NODES에 없음(--node-name 사용 가능)"
  note "현재 노드: ${NODE_NAME} role=${NODE_ROLE} internal-ip=${NODE_IP}"

  node_config=(bash scripts/node/install-rke2-node-config.sh --role "${NODE_ROLE}")
  identity=(bash scripts/node/install-rke2-network-identity.sh
    --role "${NODE_ROLE}"
    --internal-ip "${NODE_IP}"
    --internal-interface "${INTERNAL_INTERFACE}"
    --external-interface "${EXTERNAL_INTERFACE}"
    --service-cidr "${SERVICE_CIDR}")
  [[ ${NODE_ROLE} != agent ]] \
    || identity+=(--server-url "https://${RKE2_SERVER_ENDPOINT}:9345")
  [[ -z ${NMS_INTERFACE} ]] || identity+=(--nms-interface "${NMS_INTERFACE}")

  guard=(bash scripts/node/install-rke2-interface-guard.sh
    --external-interface "${EXTERNAL_INTERFACE}"
    --blocked-tcp-ports "${INTERNAL_ALLOWED_TCP_PORTS}")
  [[ -z ${NMS_INTERFACE} ]] || guard+=(--nms-interface "${NMS_INTERFACE}")
  IFS=, read -ra guarded_entries <<<"${GUARDED_INTERFACES}"
  for guarded in "${guarded_entries[@]}"; do
    [[ -z ${guarded} ]] || guard+=(--guarded-interface "${guarded}")
  done
  containerd_proxy=(bash scripts/node/install-rke2-containerd-proxy.sh --role "${NODE_ROLE}")

  if [[ ${APPLY} == true ]]; then
    node_config+=(--apply)
    identity+=(--apply)
    guard+=(--apply)
    containerd_proxy+=(--apply)
  fi
  step "RKE2 계약 소유 설정 병합" "${node_config[@]}"
  step "RKE2 내부망 identity 고정" "${identity[@]}"
  step "외부/NMS interface 관리 포트 guard" "${guard[@]}"
  step "RKE2 embedded containerd proxy" "${containerd_proxy[@]}"

  if [[ ${NMS_MODE} == network ]]; then
    nms_role=worker
    [[ ${NODE_IP} != "${NMS_GATEWAY_INTERNAL_IP}" ]] || nms_role=gateway
    step "NMS network egress(${nms_role})" \
      bash scripts/node/install-nms-egress.sh "${nms_role}"
  fi
  if [[ ${NODE_IP} == "${SQUID_INTERNAL_IP}" ]]; then
    step "계약 기반 Squid egress" bash scripts/node/install-squid-egress.sh
  fi
  upstream_address=${CLUSTER_UPSTREAM_DNS%:*}
  if [[ -n ${CLUSTER_UPSTREAM_DNS} && ${NODE_IP} == "${upstream_address}" ]]; then
    step "CoreDNS용 내부 DNS forwarder" bash scripts/node/install-dns-forwarder.sh
  fi

  if [[ ${APPLY} == true ]]; then
    note "RKE2는 자동 재시작하지 않았다. 노드를 drain한 유지보수 창에서 systemctl restart rke2-${NODE_ROLE} 실행 후 Ready를 확인한다"
  fi
fi

if [[ ${PHASE} == node ]]; then
  exit 0
fi

[[ ${NODE_NAME} == "${CONTROL_PLANE_HOSTNAME}" ]] \
  || die "cluster phase는 control-plane '${CONTROL_PLANE_HOSTNAME}'에서만 실행 가능"

KUBECTL_BIN=${KUBECTL_BIN:-/var/lib/rancher/rke2/bin/kubectl}
KUBECONFIG_PATH=${KUBECONFIG_PATH:-/etc/rancher/rke2/rke2.yaml}
kctl() { "${KUBECTL_BIN}" --kubeconfig "${KUBECONFIG_PATH}" "$@"; }

apply_dns_secret() {
  kctl create namespace cert-manager --dry-run=client -o yaml | kctl apply -f - >/dev/null
  kctl create secret generic "${DNS_CREDENTIAL_SECRET_NAME}" -n cert-manager \
    --from-file="${DNS_CREDENTIAL_SECRET_KEY}=${SADP_DNS_TSIG_SECRET_FILE}" \
    --dry-run=client -o yaml | kctl apply -f - >/dev/null
  ok "RFC2136 TSIG Secret을 root 전용 파일에서 적용(값은 출력하지 않음)"
}

wait_for_argo_applications() {
  local deadline missing application
  mapfile -t expected < <(python3 - <<'PY'
import glob
import yaml

for path in sorted(glob.glob("argocd/applications/*.yaml")):
    for document in yaml.safe_load_all(open(path, encoding="utf-8")):
        if isinstance(document, dict) and document.get("kind") == "Application":
            print(document["metadata"]["name"])
PY
  )
  deadline=$((SECONDS + 600))
  while ((SECONDS < deadline)); do
    missing=()
    for application in "${expected[@]}"; do
      kctl get application -n devtroncd "${application}" >/dev/null 2>&1 \
        || missing+=("${application}")
    done
    ((${#missing[@]})) || { ok "Argo app-of-apps Application 생성 확인"; return 0; }
    sleep 5
  done
  die "Argo Application 생성 timeout: ${missing[*]}"
}

step "기존 RKE2 클러스터 선행 조건 검사" bash scripts/cluster/preflight.sh

devtron=(bash scripts/cluster/install-devtron.sh)
[[ ${APPLY} != true ]] || devtron+=(--apply)
step "Devtron과 번들 Argo CD 자동 준비" "${devtron[@]}"

if [[ ${TLS_SOURCE} == acme ]]; then
  if [[ ${APPLY} == true ]]; then
    require_input_file "${SADP_DNS_TSIG_SECRET_FILE}" "RFC2136 TSIG 파일"
    note "RFC2136 TSIG Secret 적용"
    apply_dns_secret
  else
    note "RFC2136 TSIG Secret 적용"
    print_command kubectl -n cert-manager create secret generic "${DNS_CREDENTIAL_SECRET_NAME}" \
      --from-file="${DNS_CREDENTIAL_SECRET_KEY}=${SADP_DNS_TSIG_SECRET_FILE}"
  fi
fi

if [[ ${SADP_INSTALL_GITOPS} == true ]]; then
  if [[ ${APPLY} == true ]]; then
    require_input_file "${SADP_ARGO_REPO_TOKEN_FILE}" "Argo 저장소 token 파일"
  fi
  step "Argo CD Git/Helm repository 연결" \
    bash scripts/cluster/configure-argocd-repo.sh \
      --token-file "${SADP_ARGO_REPO_TOKEN_FILE}" \
      --username "${SADP_ARGO_REPO_USERNAME}"
  step "Argo AppProject 적용" \
    "${KUBECTL_BIN}" --kubeconfig "${KUBECONFIG_PATH}" apply -f argocd/appproject.yaml
  step "Argo app-of-apps bootstrap 적용" \
    "${KUBECTL_BIN}" --kubeconfig "${KUBECONFIG_PATH}" apply -f argocd/bootstrap-application.yaml
  if [[ ${APPLY} == true ]]; then
    wait_for_argo_applications
  else
    note "적용 모드에서는 최대 10분 동안 모든 argocd/applications Application 생성을 기다림"
  fi
else
  note "SADP_INSTALL_GITOPS=false: 기존 Argo GitOps 연결을 사용"
fi

step "SADP 플랫폼 기반 서비스 설치" bash scripts/cluster/install-testbed-platform.sh

if [[ ${EXISTING_GATEWAY_TLS_READY} != true ]]; then
  note "TLS 인증서 준비 단계이므로 서비스 초기화·앱 배포·검수를 보류한다"
  note "인증서 Ready 확인 후 site.env의 TLS 진행값을 갱신하고 render→commit/push→cluster를 다시 실행한다"
  exit 0
fi

if [[ ${SADP_BUILD_IMAGES} == true ]]; then
  build=(bash scripts/cluster/build-local-images.sh)
  [[ -z ${SADP_BUILD_NODE} ]] || build+=(--build-node "${SADP_BUILD_NODE}")
  step "SADP 로컬 이미지 빌드와 전체 노드 import" "${build[@]}"
fi

step "Keycloak/OpenBao 서비스 초기화" bash scripts/cluster/bootstrap-testbed-services.sh

if [[ ${SADP_DEPLOY_APPS} == true ]]; then
  if [[ ${APPLY} == true ]]; then
    require_input_file "${SADP_REGISTRY_PULL_DOCKERCONFIG}" "Registry pull Docker config"
    require_input_file "${SADP_REGISTRY_PUSH_DOCKERCONFIG}" "Registry push Docker config"
  fi
  step "기본 앱과 Portal 배포" bash scripts/cluster/deploy-testbed-apps.sh \
    --registry-pull-dockerconfig "${SADP_REGISTRY_PULL_DOCKERCONFIG}" \
    --registry-push-dockerconfig "${SADP_REGISTRY_PUSH_DOCKERCONFIG}"
fi

if [[ ${SADP_RUN_VERIFY} == true ]]; then
  step "Portal 인증 acceptance" bash scripts/verify/verify-portal-auth.sh
  step "SADP 핵심 acceptance" bash scripts/verify/verify-testbed.sh
fi

ok "SADP 통합 설치 phase=${PHASE} 완료"
