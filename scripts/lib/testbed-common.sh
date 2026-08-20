#!/usr/bin/env bash
# 공통 경로/함수. 이 파일은 source 전용이며 Secret 값을 출력하지 않는다.
set -euo pipefail

TESTBED_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
KUBECTL_BIN=${KUBECTL_BIN:-/var/lib/rancher/rke2/bin/kubectl}
KUBECONFIG_PATH=${KUBECONFIG_PATH:-/etc/rancher/rke2/rke2.yaml}
HELM_BIN=${HELM_BIN:-helm}
# 제품명과 같은 상태 경로만 사용해 다른 배포 환경의 이름/경로가 계약에 섞이지 않게 한다.
TESTBED_STATE_DIR=${SADP_STATE_DIR:-/var/lib/sadp}
CREDENTIAL_DIR=${TESTBED_STATE_DIR}/credentials
BACKUP_DIR=${TESTBED_STATE_DIR}/backups
IMAGE_DIR=${TESTBED_STATE_DIR}/images

export KUBECONFIG=${KUBECONFIG_PATH}
umask 077

kctl() { "${KUBECTL_BIN}" --kubeconfig "${KUBECONFIG_PATH}" "$@"; }
hctl() { "${HELM_BIN}" --kubeconfig "${KUBECONFIG_PATH}" "$@"; }

die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
note() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK]   %s\n' "$*"; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "필수 명령을 찾을 수 없음: $1"
}

require_root() {
  [[ $(id -u) -eq 0 ]] || die "클러스터 bootstrap은 root로 실행해야 함"
}

ensure_state_dirs() {
  install -d -m 0700 "${TESTBED_STATE_DIR}" "${CREDENTIAL_DIR}" "${BACKUP_DIR}" "${IMAGE_DIR}"
}

ensure_text_file() {
  local path=$1 value=$2
  if [[ ! -s ${path} ]]; then
    printf '%s' "${value}" >"${path}"
    chmod 0600 "${path}"
  fi
}

ensure_random_file() {
  local path=$1
  if [[ ! -s ${path} ]]; then
    local value
    value=$(openssl rand -hex 32)
    printf '%s' "${value}" >"${path}"
    chmod 0600 "${path}"
  fi
}

read_secret_file() {
  local path=$1
  [[ -s ${path} ]] || die "Secret 상태 파일 없음: ${path}"
  tr -d '\r\n' <"${path}"
}

ensure_namespace() {
  local namespace=$1
  kctl create namespace "${namespace}" --dry-run=client -o yaml | kctl apply -f - >/dev/null
}

# 워크로드 Namespace 를 계약에서 읽는다. 스크립트마다 research-beta 를 박아 두면
# WORKLOAD_NAMESPACE 를 바꾼 사이트에서 배포·검수·Secret 경로가 조용히 어긋난다.
# 계약이 default-deny egress 를 거는 Namespace 가 곧 워크로드 Namespace 다.
workload_namespace() {
  python3 - "${TESTBED_ROOT}/contracts/platform-production.yaml" <<'PY'
import sys

import yaml

document = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
network = ((document.get("spec") or {}).get("network") or {})
namespaces = network.get("defaultDenyNamespaces") or []
if len(namespaces) != 1:
    raise SystemExit("[FAIL] network.defaultDenyNamespaces 가 정확히 하나여야 한다")
print(namespaces[0])
PY
}

# Keycloak 배포 위치를 계약에서 읽는다. external 이면 Keycloak과 PostgreSQL이 클러스터 밖에
# 있으므로 설치, bootstrap, 백업에서 in-cluster 전용 단계를 건너뛴다.
keycloak_deployment() {
  python3 - "${TESTBED_ROOT}/contracts/platform-production.yaml" <<'PY'
import sys

import yaml

document = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
keycloak = (document.get("spec") or {}).get("keycloak") or {}
print(keycloak.get("deployment") or "in-cluster")
PY
}

keycloak_is_external() {
  [[ $(keycloak_deployment) == external ]]
}

apply_generic_secret_from_files() {
  local namespace=$1 name=$2
  shift 2
  kctl create secret generic "${name}" -n "${namespace}" "$@" \
    --dry-run=client -o yaml | kctl apply -f - >/dev/null
}
