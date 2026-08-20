#!/usr/bin/env bash
# SADP가 요구하는 Devtron/Argo CD가 전혀 없을 때만 고정 버전으로 설치한다.
# 기존 설치를 자동 upgrade하지 않는 이유는 Devtron DB migration과 운영 중단을 별도 검토해야 하기 때문이다.
set -euo pipefail

source "$(dirname "$0")/../lib/testbed-common.sh"

APPLY=false
DEVTRON_NAMESPACE=devtroncd
DEVTRON_RELEASE=devtron
DEVTRON_REPOSITORY=https://helm.devtron.ai
WAIT_SECONDS=1800

usage() {
  cat <<'EOF'
사용법: install-devtron.sh [--apply]

기본은 현재 상태와 설치 계획만 확인한다. --apply를 주면 Devtron/번들 Argo CD가 전혀
없는 클러스터에 versions.lock.yaml의 고정 버전을 설치한다. 정상 기존 설치는 건드리지
않고, 다른 버전이나 Helm이 소유하지 않는 부분 설치는 자동 덮어쓰기하지 않는다.
EOF
}

while (($#)); do
  case "$1" in
    --apply) APPLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

for command in python3 "${HELM_BIN}"; do require_command "${command}"; done
[[ -x ${KUBECTL_BIN} ]] || die "kubectl 없음: ${KUBECTL_BIN}"

mapfile -t devtron_versions < <(python3 - "${TESTBED_ROOT}/versions.lock.yaml" <<'PY'
import sys

import yaml

document = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
delivery = document.get("delivery") or {}
for key in ("devtronOperator", "devtronOperatorChart"):
    value = str(delivery.get(key) or "").strip()
    if not value:
        raise SystemExit(f"[FAIL] versions.lock.yaml delivery.{key} 누락")
    print(value)
PY
)
DEVTRON_APP_VERSION=${devtron_versions[0]}
DEVTRON_CHART_VERSION=${devtron_versions[1]}

HTTP_PROXY=
HTTPS_PROXY=
NO_PROXY=
if [[ -r ${TESTBED_ROOT}/platform/network/proxy.env ]]; then
  # Helm repository와 Devtron installer가 같은 승인 Squid 경로를 써야 폐쇄망 설치가 재현된다.
  source "${TESTBED_ROOT}/platform/network/proxy.env"
fi

delivery_resources_exist() {
  kctl get crd applications.argoproj.io >/dev/null 2>&1 \
    && kctl get deployment -n "${DEVTRON_NAMESPACE}" argocd-repo-server >/dev/null 2>&1 \
    && kctl get statefulset -n "${DEVTRON_NAMESPACE}" argocd-application-controller >/dev/null 2>&1 \
    && kctl get deployment -n "${DEVTRON_NAMESPACE}" devtron >/dev/null 2>&1
}

installer_applied() {
  [[ $(kctl get installer -n "${DEVTRON_NAMESPACE}" installer-devtron \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true) == Applied ]]
}

delivery_ready() {
  installer_applied \
    && delivery_resources_exist \
    && kctl rollout status deployment/argocd-repo-server -n "${DEVTRON_NAMESPACE}" --timeout=5s >/dev/null 2>&1 \
    && kctl rollout status statefulset/argocd-application-controller -n "${DEVTRON_NAMESPACE}" --timeout=5s >/dev/null 2>&1 \
    && kctl rollout status deployment/devtron -n "${DEVTRON_NAMESPACE}" --timeout=5s >/dev/null 2>&1
}

release_exists=false
installed_chart=
installed_app_version=
if hctl status "${DEVTRON_RELEASE}" -n "${DEVTRON_NAMESPACE}" >/dev/null 2>&1; then
  release_exists=true
  mapfile -t installed_release < <(hctl list -n "${DEVTRON_NAMESPACE}" -f "^${DEVTRON_RELEASE}$" -o json \
    | python3 -c 'import json,sys; rows=json.load(sys.stdin); row=rows[0] if rows else {}; print(row.get("chart", "")); print(row.get("app_version", ""))')
  installed_chart=${installed_release[0]:-}
  installed_app_version=${installed_release[1]:-}
fi

expected_chart="devtron-operator-${DEVTRON_CHART_VERSION}"
if [[ ${release_exists} == true ]] \
  && { [[ ${installed_chart} != "${expected_chart}" ]] \
    || [[ ${installed_app_version} != "${DEVTRON_APP_VERSION}" ]]; }; then
  die "Devtron release가 계약과 다름(chart=${installed_chart:-unknown}, app=${installed_app_version:-unknown}); expected chart=${expected_chart}, app=${DEVTRON_APP_VERSION}; 자동 upgrade/downgrade하지 않음"
fi

verify_release_values() {
  hctl get values "${DEVTRON_RELEASE}" -n "${DEVTRON_NAMESPACE}" -o json \
    | EXPECTED_HTTP_PROXY=${HTTP_PROXY:-} \
      EXPECTED_HTTPS_PROXY=${HTTPS_PROXY:-} \
      EXPECTED_NO_PROXY=${NO_PROXY:-} \
      python3 -c '
import json
import os
import sys

values = json.load(sys.stdin)
required = [
    (("installer", "modules"), ["cicd"]),
    (("argo-cd", "enabled"), True),
    (("components", "devtron", "service", "type"), "ClusterIP"),
]
if os.environ.get("EXPECTED_HTTP_PROXY") or os.environ.get("EXPECTED_HTTPS_PROXY"):
    for root in (("configs",), ("global", "configs")):
        required.extend(
            (
                (root + ("HTTP_PROXY",), os.environ.get("EXPECTED_HTTP_PROXY", "")),
                (root + ("HTTPS_PROXY",), os.environ.get("EXPECTED_HTTPS_PROXY", "")),
                (root + ("NO_PROXY",), os.environ.get("EXPECTED_NO_PROXY", "")),
            )
        )

mismatches = []
for path, expected in required:
    actual = values
    for key in path:
        if not isinstance(actual, dict) or key not in actual:
            actual = None
            break
        actual = actual[key]
    if actual != expected:
        mismatches.append(".".join(path))
if mismatches:
    print(",".join(mismatches))
    raise SystemExit(1)
'
}

if [[ ${release_exists} == true ]]; then
  if ! contract_mismatches=$(verify_release_values); then
    die "Devtron release 설정이 SADP 계약과 다름(${contract_mismatches:-확인 불가}); 자동 덮어쓰기하지 않음"
  fi
fi

if delivery_ready; then
  [[ ${release_exists} == true ]] \
    || die "Ready인 Devtron/Argo CD가 있지만 승인 Helm release ${DEVTRON_NAMESPACE}/${DEVTRON_RELEASE}가 없어 자동 채택하지 않음"
  ok "기존 Devtron ${DEVTRON_APP_VERSION}/Argo CD Ready: namespace=${DEVTRON_NAMESPACE} (자동 변경 없음)"
  exit 0
fi

if [[ ${release_exists} == true ]]; then
  die "승인 버전/설정의 Devtron Helm release가 있지만 Installer/Devtron/Argo CD가 Ready가 아님; 자동 재적용하지 않으므로 devtroncd 상태를 확인하라"
fi

if [[ ${release_exists} == false ]]; then
  partial_resources=false
  if kctl get namespace "${DEVTRON_NAMESPACE}" >/dev/null 2>&1 \
    && [[ -n $(kctl get all -n "${DEVTRON_NAMESPACE}" --ignore-not-found -o name 2>/dev/null) ]]; then
    partial_resources=true
  fi
  kctl get crd applications.argoproj.io >/dev/null 2>&1 && partial_resources=true
  kctl get crd installers.installer.devtron.ai >/dev/null 2>&1 && partial_resources=true
  kctl get installer -n "${DEVTRON_NAMESPACE}" installer-devtron >/dev/null 2>&1 \
    && partial_resources=true
  [[ ${partial_resources} != true ]] \
    || die "Helm release 없이 Devtron/Argo CD 일부 리소스가 존재함; 소유권을 확인한 뒤 수동으로 정리 또는 채택해야 함"
fi

note "Devtron ${DEVTRON_APP_VERSION} / chart ${DEVTRON_CHART_VERSION}와 번들 Argo CD가 필요함"
helm_contract_args=(
  --set 'installer.modules={cicd}'
  --set argo-cd.enabled=true
  # Devtron UI가 별도 LoadBalancer를 만들면 Envoy Gateway 단일 진입점 계약을 우회한다.
  --set components.devtron.service.type=ClusterIP
)
if [[ -n ${HTTP_PROXY:-} || -n ${HTTPS_PROXY:-} ]]; then
  helm_no_proxy=${NO_PROXY:-}
  helm_no_proxy=${helm_no_proxy//,/\,}
  # inception installer와 이후 microservice 모두 같은 승인 Squid/no-proxy 경계를 사용한다.
  helm_contract_args+=(
    --set-string "configs.HTTP_PROXY=${HTTP_PROXY:-}"
    --set-string "configs.HTTPS_PROXY=${HTTPS_PROXY:-}"
    --set-string "configs.NO_PROXY=${helm_no_proxy}"
    --set-string "global.configs.HTTP_PROXY=${HTTP_PROXY:-}"
    --set-string "global.configs.HTTPS_PROXY=${HTTPS_PROXY:-}"
    --set-string "global.configs.NO_PROXY=${helm_no_proxy}"
  )
fi

if [[ ${APPLY} != true ]]; then
  printf '       '
  printf '%q ' "${HELM_BIN}" upgrade --install "${DEVTRON_RELEASE}" devtron/devtron-operator \
    --namespace "${DEVTRON_NAMESPACE}" --create-namespace --version "${DEVTRON_CHART_VERSION}" \
    "${helm_contract_args[@]}"
  printf '\n'
  note "적용하려면 sudo bash ./sadp --install-devtron --apply"
  exit 0
fi

require_root
hctl repo add devtron "${DEVTRON_REPOSITORY}" --force-update >/dev/null
hctl repo update devtron >/dev/null

helm_args=(upgrade --install "${DEVTRON_RELEASE}" devtron/devtron-operator
  --namespace "${DEVTRON_NAMESPACE}"
  --create-namespace
  --version "${DEVTRON_CHART_VERSION}"
  "${helm_contract_args[@]}")
hctl "${helm_args[@]}"

deadline=$((SECONDS + WAIT_SECONDS))
until installer_applied; do
  installer_status=$(kctl get installer -n "${DEVTRON_NAMESPACE}" installer-devtron \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  case "${installer_status}" in
    Failed|Error) die "Devtron Installer 상태가 ${installer_status}; devtroncd의 Installer/Pod 로그를 확인하라" ;;
  esac
  ((SECONDS < deadline)) \
    || die "Devtron Installer가 Applied가 되지 않음(timeout=${WAIT_SECONDS}s, status=${installer_status:-생성 대기})"
  sleep 10
done


delivery_resources_exist \
  || die "Devtron Installer는 Applied지만 필수 Devtron/Argo CD 리소스가 없음"

kctl rollout status deployment/argocd-repo-server -n "${DEVTRON_NAMESPACE}" --timeout=15m >/dev/null
kctl rollout status statefulset/argocd-application-controller -n "${DEVTRON_NAMESPACE}" --timeout=15m >/dev/null
kctl rollout status deployment/devtron -n "${DEVTRON_NAMESPACE}" --timeout=15m >/dev/null
ok "Devtron ${DEVTRON_APP_VERSION}와 번들 Argo CD Ready"
