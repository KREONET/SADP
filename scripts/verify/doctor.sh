#!/usr/bin/env bash
# 설치 단계를 순서대로 확인하고 "처음 막힌 단계 하나"와 원인 후보, 다음 명령을 출력한다.
#
#   sudo bash ./sadp --doctor --env-file /etc/sadp/site.env
#
# 읽기 전용이다. 클러스터·호스트를 바꾸지 않고(apply/annotate/restart/delete 없음) Secret 값,
# 로그 원문, URL, IP를 출력하지 않는다. verify-testbed가 전부를 검사해 실패를 나열한다면, doctor는
# 처음 설치하는 사람이 "지금 무엇을 해야 하는가" 하나만 보도록 첫 실패에서 멈춘다. 뒤 단계는
# 앞 단계가 끝나야 의미가 있으므로(예: OpenBao sealed면 ESO 실패는 결과일 뿐) 계속 보지 않는다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"
source "$(dirname "$0")/../lib/openbao-oidc.sh"
source "$(dirname "$0")/../lib/diagnose.sh"

ENV_FILE=
while (($#)); do
  case "$1" in
    --env-file) ENV_FILE=${2:?--env-file 값 필요}; shift ;;
    -h|--help)
      echo "usage: sudo bash ./sadp --doctor --env-file <site.env>"
      exit 0
      ;;
    *) printf '[FAIL] 알 수 없는 인자: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
cd "${TESTBED_ROOT}"

STAGES=(
  "site.env 위치와 검증"
  "생성물과 site.env 동기화"
  "Squid egress와 IdP relay"
  "클러스터 접근"
  "OpenBao seal·revision"
  "ExternalSecret 공급"
  "Gateway와 SecurityPolicy"
  "Portal"
)
stage_index=0

stage() {
  stage_index=$((stage_index + 1))
  printf '\n[STAGE %d/%d] %s\n' "${stage_index}" "${#STAGES[@]}" "${STAGES[stage_index - 1]}"
}

# 원인 출력(이미 [CAUSE]/[NEXT]를 냈을 수 있음) 뒤 첫 실패 단계를 밝히고 끝낸다.
stop() {
  [[ -z ${1:-} ]] || diag_next "$1"
  printf '\n[STOP] 처음 막힌 단계: %d/%d %s. 위 [NEXT]를 처리한 뒤 doctor를 다시 실행하라\n' \
    "${stage_index}" "${#STAGES[@]}" "${STAGES[stage_index - 1]}" >&2
  exit 1
}

# --- 1. site.env ---------------------------------------------------------------
stage
if [[ -z ${ENV_FILE} ]]; then
  echo "[FAIL] --env-file이 없음(자동 탐색하지 않음)" >&2
  for candidate in environments/site.env /etc/sadp/site.env; do
    if [[ -e ${candidate} ]]; then
      printf '[INFO] 후보 있음: %s\n' "${candidate}" >&2
    else
      printf '[INFO] 후보 없음: %s\n' "${candidate}" >&2
    fi
  done
  stop "이 사이트의 상류 site.env를 --env-file로 지정하라(설치기 기본값 /etc/sadp/site.env)"
fi
[[ -r ${ENV_FILE} ]] || stop "site.env를 읽을 수 없음: 경로와 권한을 확인하라(root 전용 파일이면 sudo)"
python3 scripts/site/configure-site.py --env-file "${ENV_FILE}" --check >/dev/null \
  || stop "위 [FAIL]의 변수를 고친 뒤 다시 실행하라(값 형식은 docs/site-configuration.md)"
ok "site.env 검증 통과"

# --- 2. 생성물 -------------------------------------------------------------------
stage
python3 scripts/site/configure-site.py --env-file "${ENV_FILE}" --check-rendered >/dev/null \
  || stop "python3 scripts/site/configure-site.py --env-file ${ENV_FILE} --write → bash ./sadp --test → commit/push"
ok "checkout 생성물이 site.env와 일치"

# --- 3. Squid / relay -------------------------------------------------------------
stage
squid_ip=$(python3 -c 'import yaml; print(yaml.safe_load(open("contracts/platform-production.yaml"))["spec"]["network"]["squid"]["internalIP"])')
relay_enabled=$(diag_relay_enabled)
if grep -Fq " ${squid_ip}/" <<<"$(ip -4 addr show 2>/dev/null || true)"; then
  [[ $(id -u) -eq 0 ]] || stop "Squid/relay 설치 상태 확인에는 root가 필요하다: sudo로 다시 실행하라"
  bash scripts/node/install-squid-egress.sh --check >/dev/null \
    || stop "sudo bash ./sadp --install-squid --check 로 원인을 보고, 설정 drift면 --install-squid --skip-package-install"
  if [[ ${relay_enabled} == true ]]; then
    bash scripts/node/install-idp-relay.sh --check >/dev/null \
      || stop "sudo bash ./sadp --install-idp-relay 계획 → --apply → --check"
  fi
  if [[ ${relay_enabled} == true ]]; then
    ok "이 호스트의 Squid·IdP relay 설치 상태 일치"
  else
    ok "이 호스트의 Squid 설치 상태 일치(IdP relay 꺼짐)"
  fi
else
  note "이 호스트는 Squid egress 호스트가 아님. 그 호스트에서 sudo bash ./sadp --install-squid --check 를 따로 확인하라"
fi
route_rc=0
python3 scripts/lib/diagnose.py node-idp-route || route_rc=$?
# relay를 쓰거나 이름을 해석하지 못하면 판정 자체를 하지 않는다. 같은 [OK]로 찍으면 route를
# 확인한 것으로 오해한다.
if ((route_rc == 1 || route_rc == 2)); then
  stop ""
elif [[ ${relay_enabled} == true ]]; then
  ok "IdP relay 사용 중이라 이 노드의 IdP route 판정 생략"
elif ((route_rc == 3)); then
  note "이 노드에서 IdP 이름을 해석하지 못해 route 판정을 생략함"
else
  ok "이 노드의 외부 IdP route 확인"
fi

# --- 4. 클러스터 접근 --------------------------------------------------------------
stage
[[ -r ${KUBECONFIG_PATH} ]] || stop "kubeconfig(${KUBECONFIG_PATH})를 읽을 수 없음: control-plane에서 sudo로 실행하라"
kctl get nodes -o name >/dev/null 2>&1 \
  || stop "Kubernetes API에 접속하지 못함: sudo systemctl status rke2-server 와 kubeconfig를 확인하라"
check_cluster_topology >/dev/null 2>&1 \
  || stop "계약의 노드 목록과 실제 Ready 노드가 다름: kubectl get nodes 와 site.env WORKER_NODES를 맞춰라"
diag_node_inotify || stop ""
ok "Kubernetes API와 노드 구성 확인"

# --- 5. OpenBao -------------------------------------------------------------------
stage
bao_status=$(kctl exec -n openbao openbao-0 -- env \
  BAO_ADDR=https://openbao.openbao.svc.cluster.local:8200 BAO_CACERT=/openbao/tls/ca.crt \
  bao status -format=json 2>/dev/null || true)
if ! jq -e 'type == "object"' <<<"${bao_status}" >/dev/null 2>&1; then
  kctl get pod -n openbao openbao-0 -o name >/dev/null 2>&1 \
    || stop "OpenBao Pod가 없음: sudo bash ./sadp --install-platform 계획을 확인하라"
  stop "OpenBao 상태를 읽지 못함: kubectl -n openbao get pod openbao-0 -o wide 와 Events를 보라"
fi
jq -e '.initialized == true' <<<"${bao_status}" >/dev/null \
  || stop "OpenBao 미초기화: sudo bash scripts/cluster/bootstrap-testbed-services.sh --init-only"
jq -e '.sealed == false' <<<"${bao_status}" >/dev/null \
  || stop "OpenBao sealed: sudo bash ./sadp --unseal-openbao 계획 → --apply"
openbao_report_ondelete_revision_lag openbao 2>/dev/null >/dev/null
[[ ${OPENBAO_REVISION_LAGGING:-false} != true ]] \
  || stop "OnDelete라 OpenBao Pod가 옛 revision: 유지보수 창에서 Pod 삭제(PVC 유지) 후 sudo bash ./sadp --unseal-openbao --apply (docs/recovery.md OnDelete Pod 교체)"
ok "OpenBao initialized/unsealed, Pod revision 최신"

# --- 6. ESO -----------------------------------------------------------------------
stage
WORKLOAD_NAMESPACE=$(workload_namespace)
mapfile -t external_secrets < <(kctl get externalsecret -n "${WORKLOAD_NAMESPACE}" -o json 2>/dev/null \
  | jq -r '.items[]?.metadata.name' 2>/dev/null || true)
((${#external_secrets[@]})) \
  || stop "${WORKLOAD_NAMESPACE}에 ExternalSecret이 없음: 앱 배포 전 단계다(sudo bash ./sadp --install --env-file ${ENV_FILE} --phase cluster 계획)"
for name in "${external_secrets[@]}"; do
  if ! diag_external_secret "${WORKLOAD_NAMESPACE}" "${name}"; then
    stop ""
  fi
done
ok "ExternalSecret ${#external_secrets[@]}개 Ready(값 미조회)"

# --- 7. Gateway / SecurityPolicy ---------------------------------------------------
stage
mapfile -t gateway_values < <(python3 - <<'PY'
import yaml

spec = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))["spec"]
print(spec["gateway"]["namespace"])
print(spec["gateway"]["name"])
PY
)
kctl get gateway -n "${gateway_values[0]}" "${gateway_values[1]}" -o json 2>/dev/null \
  | jq -e '.status.conditions[]? | select(.type == "Programmed" and .status == "True")' >/dev/null \
  || { diag_deployment envoy-gateway-system envoy-gateway || true
       stop "kubectl -n ${gateway_values[0]} get gateway ${gateway_values[1]} -o jsonpath='{.status.listeners}' 로 listener condition을 보라"; }
envoy_deployment=$(kctl get deployment -n "${gateway_values[0]}" \
  -l "gateway.envoyproxy.io/owning-gateway-name=${gateway_values[1]}" -o name 2>/dev/null | head -1 || true)
if [[ -n ${envoy_deployment} ]]; then
  diag_deployment "${gateway_values[0]}" "${envoy_deployment##*/}" || stop ""
fi
if kctl get securitypolicy -n "${WORKLOAD_NAMESPACE}" secure-demo-oidc >/dev/null 2>&1; then
  diag_security_policy "${WORKLOAD_NAMESPACE}" secure-demo-oidc || stop ""
else
  note "secure-demo-oidc SecurityPolicy 없음(앱 배포 전이면 정상)"
fi
ok "Gateway Programmed, Envoy rollout 정상, OIDC SecurityPolicy Accepted"

# --- 8. Portal --------------------------------------------------------------------
stage
if kctl get deployment -n "${WORKLOAD_NAMESPACE}" portal-lite >/dev/null 2>&1; then
  diag_deployment "${WORKLOAD_NAMESPACE}" portal-lite || stop ""
  diag_portal_logs "${WORKLOAD_NAMESPACE}" || stop ""
  ok "Portal 가용, 최근 30분 로그에 IdP 연결 실패 없음(원문 미출력)"
else
  note "portal-lite Deployment 없음(SADP_DEPLOY_APPS=false이거나 앱 배포 전)"
fi

printf '\n[OK]   doctor: 모든 단계 정상. 전체 acceptance는 sudo bash ./sadp --verify-testbed\n'
