#!/usr/bin/env bash
# Portal Lite 테스트 페이지를 관리자 명령으로 안전하게 켜고 끈다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

require_root
cd "${TESTBED_ROOT}"

mode=${1:-status}
application=portal-lite-beta
namespace=$(workload_namespace) || exit 1

pause_argocd() {
  if kctl get application -n devtroncd "${application}" >/dev/null 2>&1; then
    kctl annotate application -n devtroncd "${application}" \
      argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null
  fi
}

resume_argocd() {
  if kctl get application -n devtroncd "${application}" >/dev/null 2>&1; then
    kctl annotate application -n devtroncd "${application}" \
      argocd.argoproj.io/skip-reconcile- >/dev/null 2>&1 || true
  fi
}

show_status() {
  local replicas ready route paused
  replicas=$(kctl get deployment -n "${namespace}" portal-lite \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || printf 'missing')
  ready=$(kctl get deployment -n "${namespace}" portal-lite \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  ready=${ready:-0}
  if kctl get httproute -n "${namespace}" portal-lite >/dev/null 2>&1; then route=present; else route=absent; fi
  if kctl get application -n devtroncd "${application}" >/dev/null 2>&1; then
    paused=$(kctl get application -n devtroncd "${application}" \
      -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/skip-reconcile}' 2>/dev/null || true)
    paused=${paused:-false}
  else
    paused=not-installed
  fi
  printf 'portal-lite replicas=%s ready=%s route=%s argocdPaused=%s\n' \
    "${replicas}" "${ready}" "${route}" "${paused}"
}

case ${mode} in
  off)
    pause_argocd
    kctl scale deployment -n "${namespace}" portal-lite --replicas=0 >/dev/null
    kctl delete httproute -n "${namespace}" portal-lite --ignore-not-found >/dev/null
    for _ in {1..60}; do
      pods=$(kctl get pods -n "${namespace}" -l app.kubernetes.io/name=portal-lite \
        --no-headers 2>/dev/null | wc -l)
      [[ ${pods} -eq 0 ]] && break
      sleep 1
    done
    [[ ${pods:-1} -eq 0 ]] || die "Portal Pod 종료 시간 초과"
    ok "Portal Lite OFF: Pod 0, 외부 HTTPRoute 제거, Argo reconcile 일시 중지"
    show_status
    ;;
  on)
    hctl template portal-lite charts/app-profile -n "${namespace}" \
      -f contracts/values-platform-production.yaml -f apps/portal-lite/values-beta.yaml | \
      kctl apply -f - >/dev/null
    kctl rollout status -n "${namespace}" deployment/portal-lite --timeout=10m >/dev/null
    kctl wait -n "${namespace}" httproute/portal-lite \
      --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
      --timeout=5m >/dev/null
    resume_argocd
    ok "Portal Lite ON: Deployment Ready, 외부 HTTPRoute Accepted"
    show_status
    ;;
  status)
    show_status
    ;;
  *)
    die "사용법: sudo bash scripts/ops/toggle-portal.sh on|off|status"
    ;;
esac
