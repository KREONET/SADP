#!/usr/bin/env bash
# 실패 원인 분류 wrapper. source 전용이며 호출자는 kctl을 준비한다(testbed-common.sh).
#
# kubectl로 필요한 객체만 읽어 scripts/lib/diagnose.py에 넘긴다. 분류와 [CAUSE]/[NEXT] 출력은
# 파이썬 쪽 한 곳에서 해서 verify-testbed, 설치 단계, doctor가 같은 판정을 낸다.
# 반환: 0 정상, 1 문제 발견(원인·다음 행동 출력). 클러스터는 바꾸지 않는다.
set -euo pipefail

SADP_DIAGNOSE=${SADP_DIAGNOSE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/diagnose.py}

diag_relay_enabled() {
  python3 - "${TESTBED_ROOT:-.}/contracts/platform-production.yaml" <<'PY' 2>/dev/null || echo false
import sys
import yaml

spec = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["spec"]
relay = (spec.get("network") or {}).get("identityProviderRelay") or {}
print(str(bool(relay.get("enabled"))).lower())
PY
}

diag_security_policy() {
  local namespace=$1 name=$2 document
  document=$(kctl get securitypolicy -n "${namespace}" "${name}" -o json 2>/dev/null) || {
    printf '[CAUSE] SecurityPolicy %s/%s 없음\n' "${namespace}" "${name}" >&2
    printf '[NEXT] 앱 배포(sudo bash ./sadp --deploy-apps)와 Argo 동기화를 확인하라\n' >&2
    return 1
  }
  python3 "${SADP_DIAGNOSE}" security-policy --relay-enabled "$(diag_relay_enabled)" <<<"${document}"
}

diag_external_secret() {
  local namespace=$1 name=$2 item events store_name store_kind store='{}'
  item=$(kctl get externalsecret -n "${namespace}" "${name}" -o json 2>/dev/null) || {
    printf '[CAUSE] ExternalSecret %s/%s 없음\n' "${namespace}" "${name}" >&2
    printf '[NEXT] 앱 배포(sudo bash ./sadp --deploy-apps)와 Argo 동기화를 확인하라\n' >&2
    return 1
  }
  events=$(kctl get events -n "${namespace}" \
    --field-selector "involvedObject.kind=ExternalSecret,involvedObject.name=${name}" \
    -o json 2>/dev/null || echo '{}')
  store_name=$(jq -r '.spec.secretStoreRef.name // empty' <<<"${item}")
  store_kind=$(jq -r '.spec.secretStoreRef.kind // "SecretStore"' <<<"${item}")
  if [[ -n ${store_name} ]]; then
    if [[ ${store_kind} == ClusterSecretStore ]]; then
      store=$(kctl get clustersecretstore "${store_name}" -o json 2>/dev/null || echo '{}')
    else
      store=$(kctl get secretstore -n "${namespace}" "${store_name}" -o json 2>/dev/null || echo '{}')
    fi
  fi
  jq -n --argjson item "${item}" --argjson events "${events}" --argjson store "${store}" \
    '{externalSecret: $item, events: $events, store: $store}' \
    | python3 "${SADP_DIAGNOSE}" external-secret
}

diag_deployment() {
  local namespace=$1 name=$2 item selector pods
  item=$(kctl get deployment -n "${namespace}" "${name}" -o json 2>/dev/null) || {
    printf '[CAUSE] Deployment %s/%s 없음\n' "${namespace}" "${name}" >&2
    printf '[NEXT] 앱 배포(sudo bash ./sadp --deploy-apps)와 Argo 동기화를 확인하라\n' >&2
    return 1
  }
  selector=$(jq -r '.spec.selector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",")' \
    <<<"${item}")
  pods=$(kctl get pods -n "${namespace}" -l "${selector}" -o json 2>/dev/null || echo '{"items":[]}')
  jq -n --argjson item "${item}" --argjson pods "${pods}" '{deployment: $item, pods: $pods}' \
    | python3 "${SADP_DIAGNOSE}" deployment
}

# 로그 원문은 화면에 내지 않는다. 분류기가 패턴 일치만 보고 결과를 출력한다.
diag_portal_logs() {
  local namespace=$1
  kctl logs -n "${namespace}" deploy/portal-lite --all-containers --since=30m --tail=400 2>/dev/null \
    | python3 "${SADP_DIAGNOSE}" portal-logs --relay-enabled "$(diag_relay_enabled)"
}

# 상세 분류가 없는 [FAIL] 뒤에 붙이는 다음 행동 한 줄.
diag_next() {
  printf '[NEXT] %s\n' "$*" >&2
}

# 각 노드의 inotify 한도를 그 노드에 이미 떠 있는 rke2-canal Pod로 읽는다(읽기 전용 exec).
# 원격 노드에 SSH하지 않고도 모든 노드를 볼 수 있고, /proc/sys/fs/inotify는 노드 값이다.
diag_node_inotify() {
  local daemonset selector pods name node payload instances watches
  # 통과해도 "몇 대를 읽었는지"를 호출자가 알릴 수 있게 남긴다(못 읽은 노드는 세지 않는다).
  DIAG_INOTIFY_NODE_COUNT=0
  daemonset=$(kctl get daemonset -n kube-system rke2-canal -o json 2>/dev/null) || {
    printf '[WARN] rke2-canal DaemonSet이 없어 노드 inotify 한도를 원격으로 읽지 못함(각 노드에서 --install-node-sysctl --check)\n' >&2
    return 0
  }
  selector=$(jq -r '.spec.selector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",")' \
    <<<"${daemonset}")
  pods=$(kctl get pods -n kube-system -l "${selector}" -o json 2>/dev/null || echo '{"items":[]}')
  payload='{}'
  while read -r name node; do
    [[ -n ${name} && -n ${node} ]] || continue
    instances=$(kctl exec -n kube-system "${name}" -c calico-node -- \
      cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null | tr -d '[:space:]' || true)
    watches=$(kctl exec -n kube-system "${name}" -c calico-node -- \
      cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null | tr -d '[:space:]' || true)
    [[ -z ${instances} || -z ${watches} ]] || DIAG_INOTIFY_NODE_COUNT=$((DIAG_INOTIFY_NODE_COUNT + 1))
    payload=$(jq --arg node "${node}" --arg i "${instances}" --arg w "${watches}" \
      '.[$node] = {"fs.inotify.max_user_instances": (if $i == "" then null else $i end),
                   "fs.inotify.max_user_watches": (if $w == "" then null else $w end)}' <<<"${payload}")
  done < <(jq -r '.items[] | select(.status.phase == "Running") | "\(.metadata.name) \(.spec.nodeName)"' \
    <<<"${pods}")
  jq -n --argjson nodes "${payload}" '{nodes: $nodes}' | python3 "${SADP_DIAGNOSE}" node-inotify
}

# Namespace의 CrashLoop 컨테이너 직전 로그를 모아 연쇄 장애의 첫 원인을 고른다. 로그 원문은
# 분류기 입력으로만 쓰고 출력하지 않는다.
diag_namespace_crashloops() {
  local namespace=$1 pods logs pod container text
  pods=$(kctl get pods -n "${namespace}" -o json 2>/dev/null) || return 0
  logs='{}'
  while read -r pod container; do
    [[ -n ${pod} && -n ${container} ]] || continue
    text=$(kctl logs -n "${namespace}" "${pod}" -c "${container}" --previous --tail=50 2>/dev/null || true)
    logs=$(jq --arg key "${pod}/${container}" --arg text "${text}" '.[$key] = $text' <<<"${logs}")
  done < <(jq -r '.items[] | .metadata.name as $pod | .status.containerStatuses[]?
      | select(.state.waiting.reason == "CrashLoopBackOff" or .lastState.terminated != null)
      | "\($pod) \(.name)"' <<<"${pods}")
  jq -n --argjson pods "${pods}" --argjson logs "${logs}" '{pods: $pods, logs: $logs}' \
    | python3 "${SADP_DIAGNOSE}" crashloop-logs
}

# PORTAL_HOST가 BASE_DOMAIN(apex)이면 인증서 SAN에 apex가 있어야 한다. wildcard(*.domain)는
# 한 단계 아래만 덮어 apex를 덮지 못한다. Secret data는 읽지 않는다: ACME는 Certificate의
# spec.dnsNames, 제공 인증서는 공개 인증서 파일의 SAN만 본다.
diag_portal_apex_tls() {
  local -a facts
  local apex source namespace certificate provided
  mapfile -t facts < <(python3 - "${TESTBED_ROOT:-.}" <<'PY'
import pathlib
import sys

import yaml

root = pathlib.Path(sys.argv[1])
spec = yaml.safe_load((root / "contracts/platform-production.yaml").read_text(encoding="utf-8"))["spec"]
portal = yaml.safe_load((root / "apps/portal-lite/values-beta.yaml").read_text(encoding="utf-8"))
host = str((portal.get("exposure") or {}).get("host") or "")
tls = spec.get("tls") or {}
secret = str(spec["gateway"].get("wildcardTlsSecret") or "")
certificate = secret if tls.get("source") != "acme" or tls.get("issuerMode") == "production" else secret + "-staging"
path = str((tls.get("provided") or {}).get("certificatePath") or "")
if path and not path.startswith("/"):
    path = str(root / path)
print("true" if host == spec["baseDomain"] else "false")
print(spec["baseDomain"])
print(tls.get("source") or "")
print(spec["gateway"]["namespace"])
print(certificate)
print(path)
PY
  ) || return 0
  [[ ${facts[0]:-false} == true ]] || return 0
  apex=${facts[1]} source=${facts[2]} namespace=${facts[3]} certificate=${facts[4]} provided=${facts[5]}
  if [[ ${source} == acme ]]; then
    local document
    document=$(kctl get certificate -n "${namespace}" "${certificate}" -o json 2>/dev/null) || return 0
    if jq -e --arg apex "${apex}" '(.spec.dnsNames // []) | index($apex) != null' <<<"${document}" >/dev/null; then
      return 0
    fi
    printf '[CAUSE] Portal이 루트 도메인인데 Certificate %s의 dnsNames에 루트 도메인이 없음(wildcard는 apex를 덮지 못함)\n' "${certificate}" >&2
    printf '[NEXT] python3 scripts/site/render-exposure.py --check 후 platform/cert-manager/resources.yaml을 동기화하고 Certificate Ready를 기다려라\n' >&2
    return 1
  fi
  if [[ ! -r ${provided} ]]; then
    printf '[INFO] 제공 인증서 파일을 이 호스트에서 읽을 수 없어 루트 도메인 SAN 확인을 생략함\n' >&2
    return 0
  fi
  if openssl x509 -noout -ext subjectAltName -in "${provided}" 2>/dev/null | grep -Fq "DNS:${apex}"; then
    return 0
  fi
  printf '[CAUSE] Portal이 루트 도메인인데 제공 인증서 SAN에 루트 도메인이 없음(wildcard는 apex를 덮지 못함)\n' >&2
  printf '[NEXT] 루트 도메인을 SAN에 포함한 인증서로 교체하거나 site.env PORTAL_HOST를 비워 portal.<BASE_DOMAIN>을 쓰라\n' >&2
  return 1
}
