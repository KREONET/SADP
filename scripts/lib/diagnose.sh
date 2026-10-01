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
