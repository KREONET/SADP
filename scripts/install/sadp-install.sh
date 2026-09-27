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
INTERACTIVE=false

usage() {
  cat <<'EOF'
SADP 통합 설치기

사용법:
  sudo bash ./sadp --install --env-file /etc/sadp/site.env [--phase <phase>] [--apply]

phase:
  render   site.env 검증과 계약/매니페스트 생성. 실제 클러스터는 변경하지 않음
  node     현재 호스트 이름으로 server/agent를 판별해 노드 설정 적용
  cluster  control-plane에서 GitOps/플랫폼/서비스/앱/검수를 순서대로 실행
  all      env 렌더·GitOps 반영·노드 순차 재시작·TLS 전환·서비스 설치(기본)

옵션:
  --node-name <name>  hostname -s 대신 WORKER_NODES/CONTROL_PLANE_HOSTNAME의 이름 사용
  --allow-dirty       render --apply에서 기존 worktree 변경을 검토했음을 명시
  --apply             실제 적용. all은 유지보수 중단을 포함해 자동 재시작함
  --interactive       질문으로 --env-file을 생성한 뒤 같은 phase 실행

안전한 기본 동작:
  --apply가 없으면 site.env와 실행 계획만 검사한다. 개별 node/cluster --apply는
  checkout이 site.env와 정확히 일치해야 한다. all은 렌더한 생성물만 commit/push한다.
  --interactive는 --apply 없이도 답변을 검증해 env 파일을 저장한 뒤 계획을 출력한다.
EOF
}

while (($#)); do
  case "$1" in
    --env-file) ENV_FILE=${2:?--env-file 값 필요}; shift ;;
    --phase) PHASE=${2:?--phase 값 필요}; shift ;;
    --node-name) NODE_NAME=${2:?--node-name 값 필요}; shift ;;
    --allow-dirty) ALLOW_DIRTY=true ;;
    --apply) APPLY=true ;;
    --interactive) INTERACTIVE=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[FAIL] 알 수 없는 인자: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "${PHASE}" in
  render|node|cluster|all) ;;
  *) printf '[FAIL] --phase는 render|node|cluster|all 중 하나여야 함\n' >&2; exit 2 ;;
esac
if [[ ${INTERACTIVE} == true ]]; then
  args=(--output "${ENV_FILE}" --phase "${PHASE}")
  [[ ${APPLY} == false ]] || args+=(--apply)
  [[ -z ${NODE_NAME} ]] || args+=(--node-name "${NODE_NAME}")
  [[ ${ALLOW_DIRTY} == false ]] || args+=(--allow-dirty)
  exec python3 scripts/install/sadp-install-wizard.py "${args[@]}"
fi
[[ -r ${ENV_FILE} ]] || { printf '[FAIL] site.env를 읽을 수 없음: %s\n' "${ENV_FILE}" >&2; exit 1; }
if [[ ${PHASE} == all ]]; then
  args=(--env-file "${ENV_FILE}")
  [[ ${APPLY} == false ]] || args+=(--apply)
  [[ -z ${NODE_NAME} ]] || args+=(--node-name "${NODE_NAME}")
  [[ ${ALLOW_DIRTY} == false ]] || args+=(--allow-dirty)
  exec python3 scripts/install/sadp-install-all.py "${args[@]}"
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
note "외부 OIDC issuer 연결: ${OIDC_ISSUER} (IdP 설정은 설치기 관리 대상 아님)"

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

  # 이후 containerd/Helm/이미지 작업이 모두 계약 프록시를 전제로 한다. Squid 담당 노드에서는
  # 다른 node 설정보다 먼저 프록시를 올려야 원툴 설치 순서가 env 검증 → egress 준비 → 소비자
  # 설정이 된다. Squid 자체 package만 승인된 direct mirror 또는 기존 upstream proxy로 bootstrap한다.
  if [[ ${NODE_IP} == "${SQUID_INTERNAL_IP}" ]]; then
    step "계약 기반 Squid egress 선행 설치" bash scripts/node/install-squid-egress.sh
  fi

  node_config=(bash scripts/node/install-rke2-node-config.sh --role "${NODE_ROLE}")
  identity=(bash scripts/node/install-rke2-network-identity.sh
    --role "${NODE_ROLE}"
    --internal-ip "${NODE_IP}"
    --internal-interface "${INTERNAL_INTERFACE}"
    --external-interface "${EXTERNAL_INTERFACE}"
    --service-cidr "${SERVICE_CIDR}")
  [[ ${NODE_ROLE} != agent ]] \
    || identity+=(--server-url "https://${RKE2_SERVER_ENDPOINT}:9345")

  guard=(bash scripts/node/install-rke2-interface-guard.sh
    --external-interface "${EXTERNAL_INTERFACE}"
    --blocked-tcp-ports "${INTERNAL_ALLOWED_TCP_PORTS}")
  IFS=, read -ra guarded_entries <<<"${GUARDED_INTERFACES}"
  for guarded in "${guarded_entries[@]}"; do
    [[ -z ${guarded} ]] || guard+=(--guarded-interface "${guarded}")
  done
  containerd_proxy=(bash scripts/node/install-rke2-containerd-proxy.sh --role "${NODE_ROLE}")
  docker_proxy=(bash scripts/node/install-docker-proxy.sh)

  if [[ ${APPLY} == true ]]; then
    node_config+=(--apply)
    identity+=(--apply)
    guard+=(--apply)
    containerd_proxy+=(--apply)
    docker_proxy+=(--apply)
  fi
  step "RKE2 계약 소유 설정 병합" "${node_config[@]}"
  step "RKE2 내부망 identity 고정" "${identity[@]}"
  step "외부/guarded interface 관리 포트 guard" "${guard[@]}"
  step "RKE2 embedded containerd proxy" "${containerd_proxy[@]}"
  if [[ ${NODE_ROLE} == server ]]; then
    step "monitoring image pull용 Docker daemon proxy" "${docker_proxy[@]}"
  fi

  upstream_address=${CLUSTER_UPSTREAM_DNS%:*}
  if [[ -n ${CLUSTER_UPSTREAM_DNS} && ${NODE_IP} == "${upstream_address}" ]]; then
    step "CoreDNS용 내부 DNS forwarder" bash scripts/node/install-dns-forwarder.sh
  fi

  if [[ ${APPLY} == true ]]; then
    note "RKE2는 자동 재시작하지 않았다. 노드를 drain한 유지보수 창에서 systemctl restart rke2-${NODE_ROLE} 실행 후 Ready를 확인한다"
    if [[ ${NODE_ROLE} == server ]]; then
      note "Docker도 자동 재시작하지 않았다. cluster phase 전에 systemctl restart docker 후 --install-docker-proxy --check를 실행한다"
    fi
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
      kctl get applications.argoproj.io -n devtroncd "${application}" >/dev/null 2>&1 \
        || missing+=("${application}")
    done
    ((${#missing[@]})) || { ok "Argo app-of-apps Application 생성 확인"; return 0; }
    sleep 5
  done
  die "Argo Application 생성 timeout: ${missing[*]}"
}

wait_for_install_revision() {
  local application deadline revision status
  [[ ${SADP_INSTALL_ALL:-false} == true ]] || return 0
  [[ ${SADP_INSTALL_REVISION:-} =~ ^[0-9a-f]{40}$ ]] || die "통합 설치 Git revision 없음"
  for application in platform-bootstrap platform-resources; do
    kctl annotate applications.argoproj.io -n devtroncd "${application}" \
      argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    deadline=$((SECONDS + 900))
    while ((SECONDS < deadline)); do
      revision=$(kctl get applications.argoproj.io -n devtroncd "${application}" \
        --request-timeout=15s -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)
      status=$(kctl get applications.argoproj.io -n devtroncd "${application}" \
        --request-timeout=15s -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
      [[ ${revision} != "${SADP_INSTALL_REVISION}" || ${status} != Synced ]] || break
      sleep 5
    done
    [[ ${revision} == "${SADP_INSTALL_REVISION}" && ${status} == Synced ]] \
      || die "${application}이 이번 설치 revision으로 동기화되지 않음"
  done
}

# Devtron Helm repository와 뒤의 외부 image pull을 시작하기 전에 실제 허용/차단 요청으로 Squid를
# 확인한다. proxy.env 파일 존재만 검사하면 daemon 미기동이나 잘못된 allowlist를 늦게 발견한다.
step "패키지·차트 설치 전 Squid egress 확인" bash scripts/verify/verify-squid-egress.sh

step "StorageClass 부재 시 local-path 준비" \
  bash scripts/cluster/install-local-path-storage.sh --apply

step "기존 RKE2 클러스터 선행 조건 검사" bash scripts/cluster/preflight.sh

step "monitoring image pull용 Docker daemon Squid 확인" \
  bash scripts/node/install-docker-proxy.sh --check

# Prometheus/Loki/Alloy Application이 생긴 뒤 이미지를 넣으면 폐쇄망 worker에서 먼저
# ImagePullBackOff가 난다. 원툴 경로는 Argo bootstrap 전에 승인 목록을 Squid 경유로 받아
# 모든 노드 containerd에 넣고, 뒤 platform 단계에는 중복 동기화를 건너뛰라고 알린다.
monitoring_images=${ROOT}/platform/monitoring/images.txt
state_root=${SADP_STATE_DIR:-/var/lib/sadp}
if [[ -s ${state_root}/monitoring-images.txt ]]; then
  monitoring_images=${state_root}/monitoring-images.txt
  note "사이트 전용 monitoring 이미지 목록 사용: ${monitoring_images}"
fi
monitoring_images_preloaded=false
if [[ ${SADP_INSTALL_MONITORING} != true ]]; then
  note "SADP_INSTALL_MONITORING=false: monitoring image 선배포를 건너뜀"
elif [[ -s ${monitoring_images} ]]; then
  step "Prometheus/Loki/Alloy 이미지 Squid 경유 선배포" \
    bash scripts/cluster/sync-external-images.sh --image-list "${monitoring_images}"
  monitoring_images_preloaded=true
else
  note "monitoring 이미지 목록이 없어 선배포를 건너뜀: ${monitoring_images}"
fi

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

platform_install=(bash scripts/cluster/install-testbed-platform.sh)
[[ ${monitoring_images_preloaded} != true ]] \
  || platform_install+=(--skip-monitoring-image-sync)
step "SADP 플랫폼 기반 서비스 설치" "${platform_install[@]}"
if [[ ${APPLY} == true ]]; then
  wait_for_install_revision
fi

if [[ ${EXISTING_GATEWAY_TLS_READY} != true ]]; then
  note "TLS 인증서 준비 단계이므로 서비스 초기화·앱 배포·검수를 보류한다"
  note "인증서 Ready 확인 후 site.env의 TLS 진행값을 갱신하고 render→commit/push→cluster를 다시 실행한다"
  exit 0
fi

if [[ -n ${SADP_PREBUILT_BUNDLE:-} ]]; then
  step "사전 빌드 bundle 검증과 전체 노드 import" \
    bash scripts/cluster/import-prebuilt-images.sh --bundle "${SADP_PREBUILT_BUNDLE}" --apply
elif [[ ${SADP_BUILD_IMAGES} == true ]]; then
  build=(bash scripts/cluster/build-local-images.sh)
  [[ -z ${SADP_BUILD_NODE} ]] || build+=(--build-node "${SADP_BUILD_NODE}")
  step "SADP 로컬 이미지 빌드와 전체 노드 import" "${build[@]}"
fi

if [[ ${SADP_INSTALL_ALL:-false} == true ]]; then
  # 단일 명령 설치가 복구 재료 사용까지 명시적으로 수행한다. 개별 cluster 경계는 유지한다.
  step "OpenBao 초기화와 root-only 복구 재료 준비" \
    bash scripts/cluster/bootstrap-testbed-services.sh --init-only
  step "OpenBao 명시적 unseal 및 active Ready" bash scripts/ops/unseal-openbao.sh --apply
fi

step "OpenBao 서비스 초기화(OIDC config 제외)" \
  bash scripts/cluster/bootstrap-testbed-services.sh --skip-openbao-oidc

# 외부 IdP client는 관리자가 미리 만들고 Secret 파일을 배치한다. Certificate/Gateway/discovery 중
# 하나라도 실패하면 OpenBao OIDC config API는 호출하지 않는다.
step "Gateway/TLS/OIDC discovery preflight 후 OpenBao OIDC 설정" \
  bash scripts/ops/configure-openbao-oidc.sh --apply

if [[ ${SADP_DEPLOY_APPS} == true ]]; then
  if [[ ${APPLY} == true ]]; then
    require_input_file "${SADP_REGISTRY_PULL_DOCKERCONFIG}" "Registry pull Docker config"
    require_input_file "${SADP_REGISTRY_PUSH_DOCKERCONFIG}" "Registry push Docker config"
  fi
  if [[ ${SADP_INSTALL_ALL:-false} == true ]]; then
    step "Portal Forgejo 봇 자격증명을 OpenBao에 공급" \
      bash scripts/cluster/install-portal-backend.sh --token-only \
        --forgejo-token-file "${SADP_PORTAL_FORGEJO_TOKEN_FILE:?통합 설치 Portal token 파일 필요}"
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
