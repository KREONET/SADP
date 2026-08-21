#!/usr/bin/env bash
# host의 수렴 로직은 유지하면서 kcadm만 기존 Keycloak Pod 또는 일회성 CLI Pod에서
# 실행해 클러스터 호스트에 별도 CLI와 session config를 남기지 않는다.
set -euo pipefail

: "${SADP_KCADM_POD:?SADP_KCADM_POD is required}"
: "${SADP_KCADM_NAMESPACE:?SADP_KCADM_NAMESPACE is required}"
: "${SADP_KCADM_CONFIG:?SADP_KCADM_CONFIG is required}"
: "${KUBECTL_BIN:?KUBECTL_BIN is required}"
: "${KUBECONFIG_PATH:?KUBECONFIG_PATH is required}"

[[ ${SADP_KCADM_POD} =~ ^(pod/|deploy/)?[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] \
  || { echo "[FAIL] kcadm Pod 대상 형식 오류" >&2; exit 1; }
[[ ${SADP_KCADM_NAMESPACE} =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] \
  || { echo "[FAIL] kcadm Namespace 형식 오류" >&2; exit 1; }
[[ ${SADP_KCADM_CONFIG} =~ ^/tmp/[A-Za-z0-9._-]+$ ]] \
  || { echo "[FAIL] kcadm config 경로 형식 오류" >&2; exit 1; }

kube=("${KUBECTL_BIN}" --kubeconfig "${KUBECONFIG_PATH}" exec -i \
  -n "${SADP_KCADM_NAMESPACE}" "${SADP_KCADM_POD}" --)

if [[ ${1:-} == config && ${2:-} == credentials ]]; then
  # host stdin의 base64 두 줄을 Pod 안에서만 복원한다. 실제 값은 kubectl argv,
  # API request URI, 환경변수에 올라가지 않고 kcadm 자체의 제약 때문에 Pod 안 argv에만 짧게 존재한다.
  exec "${kube[@]}" sh -ceu '
    IFS= read -r encoded_user
    IFS= read -r encoded_password
    user=$(printf "%s" "${encoded_user}" | base64 -d)
    password=$(printf "%s" "${encoded_password}" | base64 -d)
    config=$1
    shift
    exec /opt/keycloak/bin/kcadm.sh "$@" --user "${user}" --password "${password}" \
      --config "${config}"
  ' sh "${SADP_KCADM_CONFIG}" "$@"
fi

# create/update -f - 문서와 일반 조회는 원래 stdin/stdout을 그대로 Pod의 kcadm에 연결한다.
exec "${kube[@]}" /opt/keycloak/bin/kcadm.sh "$@" --config "${SADP_KCADM_CONFIG}"
