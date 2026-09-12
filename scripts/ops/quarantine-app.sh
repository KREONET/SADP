#!/usr/bin/env bash
# 침해 의심 앱은 GitOps self-heal보다 먼저 외부 경로와 실행 Pod를 함께 내려야 한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

APP=
NAMESPACE=
APPLY=false

usage() {
  cat <<'EOF'
사용법:
  sudo bash ./sadp --quarantine-app --app <APP> --namespace <NAMESPACE> [--apply]

기본 동작은 앱의 Argo Application, Deployment, HTTPRoute 상태와 격리 명령만 출력한다.
--apply는 child Application reconcile을 멈추고 HTTPRoute를 제거한 뒤 Deployment를 0으로
축소한다. Service/PVC/Secret/감사 기록은 삭제하지 않는다.

복구는 소스·이미지·노출 원인을 조사하고 알려진 정상 immutable image로 GitOps desired
state를 고친 뒤 수행한다. 먼저 replicas=0/exposure.enabled=false가 동기화되게 한 다음
skip-reconcile annotation을 제거하고 검증된 재개 PR을 사용한다.
EOF
}

while (($#)); do
  case "$1" in
    --app) APP=${2:?--app 값 필요}; shift ;;
    --namespace) NAMESPACE=${2:?--namespace 값 필요}; shift ;;
    --apply) APPLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

[[ ${APP} =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ && ${#APP} -le 40 ]] \
  || die "app은 40자 이하 DNS label이어야 함"
[[ ${NAMESPACE} =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#NAMESPACE} -le 63 ]] \
  || die "namespace는 63자 이하 DNS label이어야 함"
require_command jq

# 파일명을 추측하지 않고 child Application의 destination과 Helm releaseName을 함께 본다.
mapfile -t applications < <(kctl get applications -n devtroncd -o json | jq -r \
  --arg app "${APP}" --arg namespace "${NAMESPACE}" '
    .items[]
    | select(.spec.destination.namespace == $namespace)
    | select(
        any(.spec.sources[]?; ((.helm // {}).releaseName // "") == $app)
        or (((.spec.source // {}).helm // {}).releaseName // "") == $app
      )
    | .metadata.name
  ')
[[ ${#applications[@]} -eq 1 ]] \
  || die "대상 Argo Application이 정확히 하나여야 함: app=${APP} namespace=${NAMESPACE} count=${#applications[@]}"
APPLICATION=${applications[0]}

replicas=$(kctl get deployment -n "${NAMESPACE}" "${APP}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || printf 'missing')
ready=$(kctl get deployment -n "${NAMESPACE}" "${APP}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
ready=${ready:-0}
if kctl get httproute -n "${NAMESPACE}" "${APP}" >/dev/null 2>&1; then
  route=present
else
  route=absent
fi
paused=$(kctl get application -n devtroncd "${APPLICATION}" \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/skip-reconcile}' 2>/dev/null || true)
paused=${paused:-false}
note "대상 application=${APPLICATION} deployment=${NAMESPACE}/${APP} replicas=${replicas} ready=${ready} route=${route} argocdPaused=${paused}"

if [[ ${APPLY} != true ]]; then
  note "계획: child reconcile 중지 -> HTTPRoute 제거 -> Deployment replicas=0 -> Pod 0 확인"
  note "적용하려면 같은 명령에 --apply"
  exit 0
fi

require_root
ensure_state_dirs
incident_dir=${TESTBED_STATE_DIR}/quarantine
install -d -m 0700 "${incident_dir}"
record=${incident_dir}/${NAMESPACE}--${APP}--$(date -u +%Y%m%dT%H%M%SZ).json
kctl get application -n devtroncd "${APPLICATION}" -o json >"${record}"
chmod 0600 "${record}"

kctl annotate application -n devtroncd "${APPLICATION}" \
  argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null
kctl delete httproute -n "${NAMESPACE}" "${APP}" --ignore-not-found >/dev/null
kctl scale deployment -n "${NAMESPACE}" "${APP}" --replicas=0 >/dev/null

pods=1
for _ in {1..60}; do
  pods=$(kctl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${APP}" \
    --no-headers 2>/dev/null | wc -l)
  [[ ${pods} -eq 0 ]] && break
  sleep 1
done
[[ ${pods} -eq 0 ]] || die "격리 중 Pod 종료 시간 초과"
if kctl get httproute -n "${NAMESPACE}" "${APP}" >/dev/null 2>&1; then
  die "격리 뒤 HTTPRoute가 다시 생김; 상위 GitOps Application reconcile 상태를 확인해야 함"
fi

ok "앱 격리 완료: 외부 Route 없음, Pod 0, child Argo reconcile 중지"
note "이전 Application 증거: ${record}"
note "다음 단계: 로그/Secret 접근 범위 보존 -> 자격증명 회전 -> 정상 image와 중지 상태를 GitOps에 반영 -> 검토 후 재개"
