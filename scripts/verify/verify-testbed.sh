#!/usr/bin/env bash
# 값 자체를 출력하지 않고 테스트베드의 핵심 acceptance를 검증한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"
source "$(dirname "$0")/../lib/machine-auth.sh"
source "$(dirname "$0")/../lib/openbao-oidc.sh"

require_root
require_command curl
require_command python3
require_command jq
require_command sha256sum
fail=0
check() { if "$@"; then ok "$*"; else printf '[FAIL] %s\n' "$*" >&2; fail=1; fi; }
WORKLOAD_NAMESPACE=$(workload_namespace) || exit 1

mapfile -t contract_values < <(python3 - <<'PY'
import yaml

doc = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))
spec = doc["spec"]
squid = spec["network"]["squid"]
public = spec.get("public") or {}
print(spec["baseDomain"])
print(spec["gateway"]["vip"])
print(f'http://{squid["internalIP"]}:{squid["port"]}')
print(public.get("mode") or "")
print(public.get("ip") or "")
interfaces = spec["network"].get("interfaces") or {}
print(interfaces.get("internal") or "")
print(interfaces.get("external") or "")
print(",".join(str(item) for item in interfaces.get("guarded") or []))
print(",".join(str(item) for item in spec["network"]["allowedPorts"]["internalTCP"]))
# Gateway 이름을 박아 두면 이름을 바꾼 사이트에서 멀쩡한 클러스터가
# [FAIL] 로 보인다. 검수 스크립트도 계약에서 읽는다.
print(spec["gateway"]["name"])
print(spec["gateway"]["namespace"])
portal = yaml.safe_load(open("apps/portal-lite/values-beta.yaml", encoding="utf-8"))
hello = yaml.safe_load(open("apps/hello/values-beta.yaml", encoding="utf-8"))
portal_host = str((portal.get("exposure") or {}).get("host") or "")
hello_host = str((hello.get("exposure") or {}).get("host") or "")
print(portal_host)
public_hosts = [hello_host, portal_host]
public_hosts.extend(str(item.get("host") or "") for item in spec.get("platformServices") or [])
print(",".join(dict.fromkeys(item for item in public_hosts if item)))
app_groups = spec.get("appGroups") or {}
print(app_groups.get("namespacePrefix") or "")
print(app_groups.get("maxServices") or 0)
print(public.get("nodeName") or "")
print(hello_host)
PY
)
base_domain=${contract_values[0]}
vip=${contract_values[1]}
expected_proxy=${contract_values[2]}
public_mode=${contract_values[3]}
public_ip=${contract_values[4]}
internal_interface=${contract_values[5]}
external_interface=${contract_values[6]}
guarded_interfaces=${contract_values[7]}
blocked_tcp_ports=${contract_values[8]}
gateway_name=${contract_values[9]}
gateway_namespace=${contract_values[10]}
portal_host=${contract_values[11]:?Portal values에 exposure.host가 없다}
public_https_hosts=${contract_values[12]}
app_group_namespace_prefix=${contract_values[13]:?AppGroup Namespace prefix가 없다}
app_group_max_services=${contract_values[14]:?AppGroup 서비스 상한이 없다}
public_ip_node=${contract_values[15]}
hello_host=${contract_values[16]:?Hello values에 exposure.host가 없다}

check_cluster_topology || fail=1

# 계약의 Pod CIDR은 RKE2 설치 뒤 자동으로 고쳐지지 않는다. 실제 Node 할당 대역과
# Squid client ACL을 함께 보지 않으면 노드 curl만 성공하고 Pod CONNECT는 403이 된다.
live_kubernetes_service_ip=$(kctl get service kubernetes \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
live_cluster_dns_ip=$(kctl get service -n kube-system \
  -l k8s-app=kube-dns -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null || true)
if kctl get nodes -o json \
    | python3 scripts/verify/verify-live-network-contract.py \
        contracts/platform-production.yaml \
        "${live_kubernetes_service_ip}" "${live_cluster_dns_ip}"; then
  ok "실제 Pod/Service CIDR, 계약, Squid client ACL 일치"
else
  fail=1
fi

# --- 로컬 노드 network identity ------------------------------------------
# verify는 control-plane 노드에서 root로 실행되므로 이 절은 "실행 중인 이 노드"만
# 검증한다. worker NIC은 각 worker에서 install-rke2-network-identity.sh가 설치
# 시점에 MAC으로 검증하며, 여기서 원격으로 다시 확인하지 않는다.
node_dropin=/etc/rancher/rke2/config.yaml.d/10-internal-network.yaml
guard_unit=/etc/systemd/system/sadp-rke2-interface-guard.service

for pair in "internal ${internal_interface}" "external ${external_interface}"; do
  role=${pair%% *}
  name=${pair#* }
  [[ -n ${name} ]] || continue
  ip link show "${name}" >/dev/null 2>&1 \
    && ok "${role} interface 존재: ${name}" \
    || { printf '[FAIL] %s interface 없음: %s\n' "${role}" "${name}" >&2; fail=1; }
done

if [[ -s ${node_dropin} ]]; then
  node_ip=$(sed -n 's/^node-ip: *//p' "${node_dropin}" | tr -d '\r')
  ip -o -4 addr show dev "${internal_interface}" 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | grep -qx "${node_ip}" \
    && ok "node-ip가 internal interface에 바인딩됨: ${internal_interface}" \
    || { printf '[FAIL] node-ip(%s)가 %s에 없음\n' "${node_ip}" "${internal_interface}" >&2; fail=1; }
else
  printf '[FAIL] RKE2 내부망 drop-in 없음: %s\n' "${node_dropin}" >&2
  fail=1
fi

ip -4 route show default | grep -Eq "(^| )dev ${external_interface}( |$)" \
  && ok "default route가 external interface에 있음: ${external_interface}" \
  || { printf '[FAIL] default route가 %s에 없음\n' "${external_interface}" >&2; fail=1; }

# guard unit은 fail-open이다. Before= 는 순서만 잡고 의존은 만들지 않아, 이 unit이
# 실패해도 rke2는 그대로 뜨고 그때 관리 포트는 열려 있다. 그래서 unit 상태와 실제
# iptables 규칙을 여기서 함께 확인한다.
if [[ -s ${guard_unit} ]]; then
  systemctl is-active --quiet sadp-rke2-interface-guard.service \
    && ok "interface guard unit active" \
    || { echo '[FAIL] sadp-rke2-interface-guard.service 가 active 가 아니다(관리 포트가 열려 있을 수 있음)' >&2; fail=1; }
  # 계약의 전체 차단 대상(external/guarded)과 정확한 포트로 기존 check 경로를
  # 재사용한다. check_family가 INPUT 연결과 각 DROP 규칙을 IPv4/IPv6 모두 검사하므로,
  # SLAAC만 받은 guarded NIC도 검수에서 빠지지 않는다.
  guard_args=(
    --external-interface "${external_interface}"
    --blocked-tcp-ports "${blocked_tcp_ports}"
  )
  IFS=, read -ra guarded_list <<<"${guarded_interfaces}"
  for guarded_name in ${guarded_list[@]+"${guarded_list[@]}"}; do
    [[ -z ${guarded_name} ]] || guard_args+=(--guarded-interface "${guarded_name}")
  done
  if bash scripts/node/install-rke2-interface-guard.sh "${guard_args[@]}" --check >/dev/null; then
    ok "계약의 모든 non-internal NIC에서 IPv4/IPv6 관리 포트 차단"
  else
    echo '[FAIL] interface guard 규칙이 현재 계약과 일치하지 않음' >&2
    fail=1
  fi
else
  printf '[FAIL] interface guard unit 없음: %s\n' "${guard_unit}" >&2
  fail=1
fi

# guard unit의 ExecStart에 박힌 MAC과 현재 NIC의 MAC을 비교한다. 재부팅으로
# interface 이름이 밀려 eth1이 다른 NIC을 가리키게 되면 여기서 잡힌다.
if [[ -s ${guard_unit} ]]; then
  for pair in "external ${external_interface}"; do
    role=${pair%% *}
    name=${pair#* }
    [[ -n ${name} ]] || continue
    recorded=$(sed -n "s/.*--${role}-mac \([0-9a-fA-F:]*\).*/\1/p" "${guard_unit}" | head -1)
    [[ -n ${recorded} ]] || continue
    actual=$(cat "/sys/class/net/${name}/address" 2>/dev/null || true)
    [[ ${recorded,,} == "${actual,,}" ]] \
      && ok "${role} interface MAC이 guard unit 기록과 일치: ${name}" \
      || { printf '[FAIL] %s interface MAC drift: unit=%s actual=%s\n' "${role}" "${recorded}" "${actual}" >&2; fail=1; }
  done
fi
kctl get gateway -n "${gateway_namespace}" "${gateway_name}" -o json | \
  jq -e '.status.conditions[] | select(.type=="Programmed" and .status=="True")' >/dev/null \
  && ok "Envoy Gateway Programmed" || { echo '[FAIL] Gateway Programmed 아님' >&2; fail=1; }

# RKE2 기본 ingress-nginx는 hostPort 80/443을 노드마다 선점한다. 살아 있으면 공인 IP로 온
# 요청이 Envoy 대신 nginx로 가서 기본 backend 404와 fake 인증서를 돌려준다.
if [[ -z $(kctl get daemonset -n kube-system rke2-ingress-nginx-controller \
  --ignore-not-found -o name 2>/dev/null) ]]; then
  ok "RKE2 기본 ingress-nginx 비활성"
else
  echo '[FAIL] rke2-ingress-nginx-controller 가 살아 있다(노드 80/443 선점).' >&2
  echo '       /etc/rancher/rke2/config.yaml 의 disable 에 rke2-ingress-nginx 를 넣고' >&2
  echo '       rke2-server 를 재시작한다. 기준은 rke/control-node/config.yaml 이다.' >&2
  fail=1
fi

if bash scripts/verify/verify-squid-egress.sh; then
  ok "Squid npm/pip/apt allowlist 및 일반 목적지 차단"
else
  echo '[FAIL] Squid egress acceptance' >&2
  fail=1
fi
controller_proxy=$(kctl get deployment -n cert-manager cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HTTPS_PROXY")].value}' 2>/dev/null)
[[ ${controller_proxy} == "${expected_proxy}" ]] \
  && ok "cert-manager controller Squid proxy" \
  || { echo "[FAIL] cert-manager controller proxy: ${controller_proxy}" >&2; fail=1; }
for component in cert-manager-webhook cert-manager-cainjector; do
  component_proxy=$(kctl get deployment -n cert-manager "${component}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HTTPS_PROXY")].value}' 2>/dev/null)
  [[ -z ${component_proxy} ]] && ok "${component} proxy 미적용" \
    || { echo "[FAIL] ${component}에 proxy가 적용됨" >&2; fail=1; }
done
kctl get networkpolicy -n "${WORKLOAD_NAMESPACE}" default-deny-egress >/dev/null 2>&1 \
  && kctl get networkpolicy -n cert-manager cert-manager-controller-egress >/dev/null 2>&1 \
  && ok "Namespace default-deny와 cert-manager 최소 egress 정책" \
  || { echo '[FAIL] egress NetworkPolicy 누락' >&2; fail=1; }

for resource in secure-demo-runtime secure-demo-oidc-client portal-lite-auth; do
  external_secret=$(kctl get externalsecret -n "${WORKLOAD_NAMESPACE}" "${resource}" -o json)
  if jq -e '.status.conditions[] | select(.type=="Ready" and .status=="True")' \
      <<<"${external_secret}" >/dev/null; then
    ok "ExternalSecret ${resource} Ready"
  else
    reason=$(jq -r '[.status.conditions[]? | select(.type=="Ready") | .reason, .message] | map(select(. != null)) | join(": ")' \
      <<<"${external_secret}")
    echo "[FAIL] ExternalSecret ${resource}: ${reason:-Ready condition 없음}" >&2
    store_name=$(jq -r '.spec.secretStoreRef.name // empty' <<<"${external_secret}")
    if [[ -n ${store_name} ]]; then
      store_status=$(kctl get secretstore -n "${WORKLOAD_NAMESPACE}" "${store_name}" -o json)
      store_reason=$(jq -r '[.status.conditions[]? | .reason, .message] | map(select(. != null)) | join(": ")' \
        <<<"${store_status}")
      echo "[INFO] SecretStore ${store_name}: ${store_reason:-condition 없음}" >&2
    fi
    event_message=$(kctl get events -n "${WORKLOAD_NAMESPACE}" \
      --field-selector "involvedObject.kind=ExternalSecret,involvedObject.name=${resource}" \
      --sort-by=.lastTimestamp -o json | jq -r '.items[-1].message // empty')
    [[ -z ${event_message} ]] || echo "[INFO] ExternalSecret event: ${event_message}" >&2
    fail=1
  fi
done

mapfile -t registry_secrets < <(python3 - <<'PY'
import yaml

values = yaml.safe_load(open("contracts/values-platform-production.yaml", encoding="utf-8"))
print(values["platform"]["registry"]["pullSecretName"])
portal = yaml.safe_load(open("apps/portal-lite/values-beta.yaml", encoding="utf-8"))
config = portal["configuration"]["config"]
print(config["PORTAL_BUILD_DOCKER_CONFIG_NAME"])
print(config["PORTAL_BUILD_DOCKER_CONFIG_KEY"])
PY
)
registry_pull_secret=${registry_secrets[0]}
registry_push_secret=${registry_secrets[1]}
registry_push_key=${registry_secrets[2]}
if [[ ${registry_pull_secret} == "${registry_push_secret}" ]]; then
  echo '[FAIL] registry pull/push Kubernetes Secret 이름이 같음' >&2
  fail=1
fi
if pull_digest=$(kctl get secret "${registry_pull_secret}" -n "${WORKLOAD_NAMESPACE}" -o json |
    jq -er 'select(.type == "kubernetes.io/dockerconfigjson")
      | .data[".dockerconfigjson"] | @base64d' |
    jq -ecS '
      def validCredential:
        type == "object" and (
          ((.auth // "") as $auth
            | ($auth | type) == "string" and ($auth | length) > 0
            and (try ($auth | @base64d | contains(":")) catch false))
          or
          (((.auth // "") == "")
            and ((.username // "") | type) == "string" and ((.username // "") | length) > 0
            and ((.password // "") | type) == "string" and ((.password // "") | length) > 0)
        );
      select(type == "object" and (.auths | type == "object") and (.auths | length > 0)
        and all(.auths[]; validCredential))' |
    sha256sum | awk '{print $1}'); then
  ok "research Zone registry pull 전용 Secret 형식"
else
  echo "[FAIL] research Zone ${registry_pull_secret} Secret 누락 또는 형식 오류" >&2
  fail=1
  pull_digest=""
fi
if push_digest=$(kctl get secret "${registry_push_secret}" -n "${WORKLOAD_NAMESPACE}" -o json |
    jq -er --arg key "${registry_push_key}" '.data[$key] | @base64d' |
    jq -ecS '
      def validCredential:
        type == "object" and (
          ((.auth // "") as $auth
            | ($auth | type) == "string" and ($auth | length) > 0
            and (try ($auth | @base64d | contains(":")) catch false))
          or
          (((.auth // "") == "")
            and ((.username // "") | type) == "string" and ((.username // "") | length) > 0
            and ((.password // "") | type) == "string" and ((.password // "") | length) > 0)
        );
      select(type == "object" and (.auths | type == "object") and (.auths | length > 0)
        and all(.auths[]; validCredential))' |
    sha256sum | awk '{print $1}'); then
  ok "Portal build registry push 전용 Secret 형식"
else
  echo "[FAIL] ${registry_push_secret}/${registry_push_key} 누락: Portal 단일 앱 source build 사용 불가" >&2
  fail=1
  push_digest=""
fi
if [[ -n ${pull_digest} && -n ${push_digest} ]]; then
  if [[ ${pull_digest} != "${push_digest}" ]]; then
    ok "registry pull/push Docker config 분리"
  else
    echo '[FAIL] registry pull/push Docker config가 동일함(쓰기 credential이 앱 Pod로 전파될 위험)' >&2
    fail=1
  fi
fi
unset pull_digest push_digest

for deployment in hello secure-demo portal-lite; do
  deployment_json=$(kctl get deployment -n "${WORKLOAD_NAMESPACE}" "${deployment}" -o json)
  available=$(jq -r '.status.availableReplicas // 0' <<<"${deployment_json}")
  if [[ ${available:-0} -ge 1 ]]; then
    ok "${deployment} available"
  else
    deployment_reason=$(jq -r '[.status.conditions[]? | select(.status=="False") | .reason, .message] | map(select(. != null)) | join(": ")' \
      <<<"${deployment_json}")
    pod_reason=$(kctl get pods -n "${WORKLOAD_NAMESPACE}" -l "app.kubernetes.io/name=${deployment}" -o json | \
      jq -r '[.items[] | .metadata.name as $name | .status.containerStatuses[]? | select(.ready != true) | [$name, (.state.waiting.reason // .state.terminated.reason // "not-ready"), (.state.waiting.message // "")] | join(": ")] | join("; ")')
    echo "[FAIL] ${deployment} unavailable: ${deployment_reason:-condition 없음}; ${pod_reason:-Pod 상태 없음}" >&2
    fail=1
  fi
done

if kctl exec -n "${WORKLOAD_NAMESPACE}" deploy/portal-lite -- node -e \
  "fetch('https://example.com',{signal:AbortSignal.timeout(5000)}).then(()=>process.exit(0)).catch(()=>process.exit(1))" \
  >/dev/null 2>&1; then
  echo '[FAIL] 일반 Portal Pod가 allowlist 밖 인터넷에 직접 접근함' >&2
  fail=1
else
  ok "일반 Portal Pod direct 인터넷 차단"
fi
IFS=, read -ra https_hosts <<<"${public_https_hosts}"
for fqdn in ${https_hosts[@]+"${https_hosts[@]}"}; do
  code=$(curl -ksS --resolve "${fqdn}:443:${vip}" -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 20 "https://${fqdn}/" || true)
  [[ ${code} =~ ^(200|302|303|307|308)$ ]] && ok "HTTPS ${fqdn} -> ${code}" \
    || { echo "[FAIL] HTTPS ${fqdn} -> ${code}" >&2; fail=1; }
done

# NetworkPolicy는 Pod 연결만 다룬다. 직원 브라우저가 앱 응답의 악성 script를 실행해
# 별도 origin으로 통신하는 경계는 Gateway가 실제 응답에 붙인 헤더로 검증한다.
hello_headers=$(curl -ksS --resolve "${hello_host}:443:${vip}" -D - -o /dev/null \
  --connect-timeout 5 --max-time 20 "https://${hello_host}/" || true)
if grep -Eiq '^cache-control:[[:space:]]*no-store[[:space:]]*$' <<<"${hello_headers}" \
  && grep -Eiq "^content-security-policy:.*connect-src 'self'" <<<"${hello_headers}" \
  && grep -Eiq '^cross-origin-resource-policy:[[:space:]]*same-origin[[:space:]]*$' <<<"${hello_headers}" \
  && grep -Eiq '^x-content-type-options:[[:space:]]*nosniff[[:space:]]*$' <<<"${hello_headers}"; then
  ok "일반 외부 앱 브라우저 응답 보안 헤더"
else
  echo '[FAIL] 일반 외부 앱 브라우저 응답 보안 헤더 누락' >&2
  fail=1
fi

portal_url=https://${portal_host}
portal_resolve="${portal_host}:443:${vip}"
# 홈(/)은 로그인하면 PaaS 대시보드, 미인증이면 메인 페이지(/portal)로 보낸다.
# 로그인 후 대시보드 marker 검사는 세션이 필요하므로 scripts/verify/verify-portal-auth.sh가 맡고,
# 여기서는 미인증 redirect와 메인 페이지 렌더링만 확인한다.
portal_home_headers=$(curl -ksS --resolve "${portal_resolve}" --connect-timeout 5 --max-time 20 \
  -D - -o /dev/null "${portal_url}/" || true)
grep -Eq '^HTTP/[^ ]+ 30[2378]' <<<"${portal_home_headers}" \
  && grep -Eiq '^location: .*(%2F|/)portal[[:space:]]*$' <<<"${portal_home_headers}" \
  && ok "Portal 미인증 홈 -> 메인 페이지 이동" \
  || { echo '[FAIL] Portal 홈 미인증 redirect' >&2; fail=1; }
portal_main=$(curl -ksS --resolve "${portal_resolve}" --connect-timeout 5 --max-time 20 \
  "${portal_url}/portal" || true)
grep -Eqi 'SADP' <<<"${portal_main}" \
  && grep -q '로그인' <<<"${portal_main}" \
  && ok "Portal 메인 페이지 로그인 진입점" \
  || { echo '[FAIL] Portal 메인 페이지 로그인 진입점 없음' >&2; fail=1; }
portal_providers=$(curl -ksS --resolve "${portal_resolve}" --connect-timeout 5 --max-time 20 \
  "${portal_url}/api/auth/providers" || true)
jq -e '.oidc.id == "oidc" and .oidc.type == "oidc"' <<<"${portal_providers}" >/dev/null \
  && ok "Portal Auth.js 외부 OIDC provider" || { echo '[FAIL] Portal OIDC provider' >&2; fail=1; }
portal_login=$(curl -ksS --resolve "${portal_resolve}" --connect-timeout 5 --max-time 20 \
  "${portal_url}/login" || true)
grep -q 'SSO로 로그인' <<<"${portal_login}" \
  && ok "Portal 로그인 UI" || { echo '[FAIL] Portal 로그인 UI' >&2; fail=1; }
# API v1 계약 marker는 app/layout.tsx meta라 로그인 없이 보이는 /login에서도 확인할 수 있다.
grep -q 'nextjs-authjs-server' <<<"${portal_login}" \
  && grep -q 'profile.profile.exposure' <<<"${portal_login}" \
  && grep -q 'profile.generated.valuesTemplate' <<<"${portal_login}" \
  && ! grep -q 'profile.normalized' <<<"${portal_login}" \
  && ok "Portal Next.js/API v1 계약 일치" \
  || { echo '[FAIL] Portal 브라우저/API 계약 불일치' >&2; fail=1; }
portal_account_headers=$(curl -ksS --resolve "${portal_resolve}" --connect-timeout 5 --max-time 20 \
  -D - -o /dev/null "${portal_url}/account" || true)
grep -Eq '^HTTP/[^ ]+ 30[2378]' <<<"${portal_account_headers}" \
  && grep -Eiq '^location: .*\/login\?callbackUrl=(%2F|/)account' <<<"${portal_account_headers}" \
  && ok "Portal 미인증 /account 로그인 이동" \
  || { echo '[FAIL] Portal 보호 페이지 redirect' >&2; fail=1; }
if bash scripts/verify/verify-portal-auth.sh; then
  ok "Portal 외부 OIDC discovery와 로그인 시작 흐름"
else
  echo '[FAIL] Portal 외부 OIDC 인증 흐름' >&2
  fail=1
fi
portal_public_api_code=$(curl -ksS --resolve "${portal_resolve}" --connect-timeout 5 --max-time 20 \
  -o /dev/null -w '%{http_code}' "${portal_url}/api/v1/health" || true)
[[ ${portal_public_api_code} == 401 ]] \
  && ok "Portal API BFF 미인증 요청 차단" \
  || { echo "[FAIL] Portal API BFF 미인증 health -> ${portal_public_api_code}" >&2; fail=1; }

# 공개 /api/v1/*는 Auth.js 세션과 역할을 검사하는 BFF라 익명 curl로 기능 검증할 수 없다.
# Go API는 같은 Pod의 loopback만 열기 때문에, 값이 없는 acceptance 신원으로 내부 계약을
# 직접 검증한다. Secret이나 실제 사용자 신원은 stdin/응답에 넣지 않는다.
portal_pod=$(kctl get pods -n "${WORKLOAD_NAMESPACE}" \
  -l app.kubernetes.io/name=portal-lite -o json 2>/dev/null | jq -r '
    [.items[] | select(.status.phase == "Running")][0].metadata.name // empty
  ')
portal_api_request() {
  local method=$1 path=$2 body=${3-}
  [[ -n ${portal_pod} ]] || return 1
  printf '%s' "${body}" | kctl exec -i -n "${WORKLOAD_NAMESPACE}" "${portal_pod}" -- node -e '
    (async () => {
      const method = process.argv[1];
      const path = process.argv[2];
      const chunks = [];
      for await (const chunk of process.stdin) chunks.push(chunk);
      const body = Buffer.concat(chunks).toString("utf8");
      const options = {
        method,
        headers: {"content-type": "application/json", "x-portal-user": "acceptance@invalid"},
        signal: AbortSignal.timeout(20000),
      };
      if (method !== "GET" && method !== "HEAD") options.body = body;
      const response = await fetch("http://127.0.0.1:8081" + path, options);
      const text = await response.text();
      process.stdout.write(JSON.stringify({status: response.status, body: text}));
    })().catch(() => process.exit(1));
  ' "${method}" "${path}"
}

portal_health_result=$(portal_api_request GET /api/v1/health || true)
jq -e '.status == 200 and ((.body | fromjson) | .status == "ok" and .service == "portal-lite")' \
  <<<"${portal_health_result}" >/dev/null \
  && ok "Portal loopback API health" || { echo '[FAIL] Portal loopback API health' >&2; fail=1; }
portal_catalog_result=$(portal_api_request GET /api/v1/catalog || true)
portal_catalog=$(jq -r '.body // empty' <<<"${portal_catalog_result}" 2>/dev/null || true)
# jq 프로그램은 작은따옴표라 셸이 확장하지 않는다. Namespace 는 --arg 로 넘겨야 한다.
jq -e --arg ns "${WORKLOAD_NAMESPACE}" '
  .forgejoConnected == true and .submissionEnabled == true and
  .autoApprove == false and .zone.id == $ns and
  .secretInputAllowed == true and
  ([.templates[].exposure] | sort) == ["oidc", "public"]
' <<<"${portal_catalog}" >/dev/null \
  && ok "Portal catalog 단일 Zone 및 기본 수동 승인 계약" \
  || { echo '[FAIL] Portal catalog 계약' >&2; fail=1; }
jq -e --arg prefix "${app_group_namespace_prefix}" --argjson max "${app_group_max_services}" '
  .appGroups.enabled == true and
  .appGroups.namespacePrefix == $prefix and
  .appGroups.maxServices == $max and
  (.appGroups.exposureModes | index("external")) != null and
  (.appGroups.exposureModes | index("internal")) != null and
  (.appGroups.egressModes | index("custom")) != null
' <<<"${portal_catalog}" >/dev/null \
  && ok "Portal AppGroup Compose 제출 준비" \
  || { echo '[FAIL] Portal AppGroup 비활성: OpenBao registry pull seed/role과 catalog 계약 확인' >&2; fail=1; }
# 사이트가 beta 등 다른 환경을 선택해도 같은 API 계약을 검증한다.
portal_environment=$(jq -er '.environment' <<<"${portal_catalog}")
portal_project=$(jq -er '.projects[0]' <<<"${portal_catalog}")
portal_profile_payload=$(jq -nc --arg environment "${portal_environment}" --arg project "${portal_project}" '
  {appName:"acceptance-app",project:$project,environment:$environment,
   gitRepository:"https://forgejo.example.invalid/research/acceptance-app.git",branch:"main",
   dockerfile:"Dockerfile",containerPort:8080,exposure:"oidc",resourceSize:"small"}
')
portal_profile_result=$(portal_api_request POST /api/v1/app-profiles/validate \
  "${portal_profile_payload}" || true)
portal_profile=$(jq -r '.body // empty' <<<"${portal_profile_result}" 2>/dev/null || true)
# OIDC client ID도 현재 카탈로그의 환경 이름으로 확인한다.
jq -e --arg client "acceptance-app-${portal_environment}" '
  .valid == true and
  .generated.valuesTemplate == "apps/_template/values-sso.yaml" and
  .generated.oidcClientId == $client and
  .generated.expectedAnonymousStatus == 302
' <<<"${portal_profile}" >/dev/null \
  && ok "Portal AppProfile OIDC 사전검증 API" \
  || { echo '[FAIL] Portal AppProfile 검증 API' >&2; fail=1; }
portal_deploy_result=$(portal_api_request POST /api/v1/deployment-requests '{}' || true)
portal_deploy_code=$(jq -r '.status // 0' <<<"${portal_deploy_result}" 2>/dev/null || true)
[[ ${portal_deploy_code} == 422 ]] && ok "Portal 자동 배포 API 활성(빈 프로필 422 검증)" \
  || { echo "[FAIL] Portal deployment-requests -> ${portal_deploy_code}" >&2; fail=1; }

printf -v portal_group_name 'verify-compose-%05d-%05d' "${RANDOM}" "${RANDOM}"
portal_compose=$'services:\n  frontend:\n    image: docker.io/library/nginx:1.27.4-alpine\n    expose:\n      - 80\n    depends_on:\n      - redis\n  redis:\n    image: docker.io/library/redis:7.4.2-alpine\n    expose:\n      - 6379\n'
portal_group_payload=$(jq -nc --arg group "${portal_group_name}" --arg compose "${portal_compose}" \
  --arg environment "${portal_environment}" --arg project "${portal_project}" '
  {
    group: $group, project: $project, environment: $environment, resourceSize: "small",
    compose: $compose,
    services: [
      {
        name: "frontend", exposure: {mode: "internal"},
        networkPolicy: {egressMode: "custom", allowedApps: [{app: "redis", port: 6379}]}
      },
      {
        name: "redis", exposure: {mode: "internal"},
        networkPolicy: {
          egressMode: "blocked", ingress: {allowedApps: [{app: "frontend", port: 6379}]}
        }
      }
    ]
  }
')
portal_group_result=$(portal_api_request POST /api/v1/app-groups/validate \
  "${portal_group_payload}" || true)
jq -e --arg group "${portal_group_name}" \
  --arg namespace "${app_group_namespace_prefix}${portal_group_name}" '
  .status == 200 and
  ((.body | fromjson) as $plan |
    $plan.valid == true and $plan.source.type == "compose" and
    $plan.group.name == $group and $plan.group.namespace == $namespace and
    ([$plan.services[].profile.app.name] | sort) == ["frontend", "redis"] and
    ([$plan.services[].profile.service.internalAddress] | sort) ==
      ["frontend." + $namespace + ".svc:80", "redis." + $namespace + ".svc:6379"])
' <<<"${portal_group_result}" >/dev/null \
  && ok "Portal Compose 다중 앱 사전검증 API" \
  || { echo '[FAIL] Portal Compose 다중 앱 사전검증 API' >&2; fail=1; }

portal_openapi_result=$(portal_api_request GET /api/v1/openapi.yaml || true)
portal_openapi=$(jq -r '.body // empty' <<<"${portal_openapi_result}" 2>/dev/null || true)
if python3 -c '
import sys, yaml
spec = yaml.safe_load(sys.stdin)
paths = spec["paths"]
assert spec["openapi"] == "3.1.1"
assert "/api/v1/catalog" in paths
assert "/api/v1/app-profiles/validate" in paths
assert "/api/v1/app-groups/validate" in paths
assert "/api/v1/app-groups" in paths
assert "delete" in paths["/api/v1/deployment-requests/{requestID}"]
deployment_post = paths["/api/v1/deployment-requests"]["post"]
assert "202" in deployment_post["responses"]
assert any(
    parameter.get("$ref") == "#/components/parameters/OptionalIdempotencyKey"
    for parameter in deployment_post["parameters"]
)
assert spec["components"]["securitySchemes"]["oidc"]["type"] == "oauth2"
assert "forgejoConnected" in spec["components"]["schemas"]["Catalog"]["required"]
def resolve(schema):
    # DeploymentRequestInput 처럼 $ref 한 겹으로 감싼 스키마도 계약을 검사한다.
    seen = set()
    while "$ref" in schema:
        ref = schema["$ref"]
        assert ref not in seen, f"순환 $ref: {ref}"
        seen.add(ref)
        node = spec
        for part in ref.removeprefix("#/").split("/"):
            node = node[part]
        schema = node
    return schema
assert resolve(spec["components"]["schemas"]["DeploymentRequestInput"])["additionalProperties"] is False
request_schema = resolve(spec["components"]["schemas"]["DeploymentRequest"])
# 사용자 응답은 공통 스키마를 allOf로 합성하므로 기반 속성까지 확인한다.
properties = dict(request_schema.get("properties") or {})
for part in request_schema.get("allOf") or []:
    properties.update(resolve(part).get("properties") or {})
states = properties["state"]["enum"]
assert "deleting" in states and "deleted" in states
assert "application/problem+json" in spec["components"]["responses"]["ValidationError"]["content"]
' <<<"${portal_openapi}"; then
  ok "Portal OpenAPI 3.1.1 구조/현재·향후 계약 검증"
else
  echo '[FAIL] Portal OpenAPI 문서 구조/계약' >&2
  fail=1
fi

kctl get securitypolicy -n "${WORKLOAD_NAMESPACE}" secure-demo-oidc -o json | \
  jq -e '.status.ancestors[].conditions[] | select(.type=="Accepted" and .status=="True")' >/dev/null \
  && ok "secure-demo SecurityPolicy Accepted" \
  || { echo '[FAIL] secure-demo SecurityPolicy 미수락' >&2; fail=1; }
oidc_code=$(curl -ksS --resolve "secure-demo.${base_domain}:443:${vip}" \
  -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 \
  "https://secure-demo.${base_domain}/" || true)
[[ ${oidc_code} == 302 ]] && ok "secure-demo 미인증 요청 OIDC redirect" \
  || { echo "[FAIL] secure-demo OIDC redirect -> ${oidc_code}" >&2; fail=1; }

# 외부 IdP는 SADP의 관리 대상이 아니다. discovery와 Portal OIDC 시작 흐름은
# verify-portal-auth.sh가 공개 endpoint만 사용해 읽기 전용으로 검증한다.
status=$(kctl exec -n openbao openbao-0 -- env \
  BAO_ADDR=https://openbao.openbao.svc.cluster.local:8200 BAO_CACERT=/openbao/tls/ca.crt \
  bao status -format=json 2>/dev/null || true)
jq -e '.initialized == true and .sealed == false and .storage_type == "raft"' <<<"${status}" >/dev/null \
  && ok "OpenBao initialized/unsealed/Raft" || { echo '[FAIL] OpenBao status' >&2; fail=1; }
# OpenBao StatefulSet은 OnDelete라 템플릿 변경(oidc-preflight 추가 등)이 기존 Pod에 반영되지
# 않아도 위 상태 검사는 통과한다. 다음 OIDC 단계가 exec 실패로 멈추기 전에 경고로 드러낸다.
openbao_report_ondelete_revision_lag openbao

# 실제 키 값은 읽거나 출력하지 않는다. Secret의 key 이름, ExternalSecret Ready, 정책의
# 인증 방식과 sanitize 여부만 확인한다.
machine_auth_load_contract
if [[ ${MACHINE_AUTH_MODE} == api-key ]]; then
  if machine_auth_validate_api_key_contract; then
    store_ready=$(kctl -n "${MACHINE_AUTH_NAMESPACE}" get secretstore \
      "${MACHINE_AUTH_SECRET_STORE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ ${store_ready} == True ]] && ok "machine-auth SecretStore Ready" \
      || { echo '[FAIL] machine-auth SecretStore가 Ready가 아님' >&2; fail=1; }
    for client in "${MACHINE_AUTH_CLIENTS[@]}"; do
      credential_file=$(machine_auth_export_path "${client}")
      if [[ -s ${credential_file} && $(stat -c '%a' "${credential_file}") == 600 \
          && $(stat -c '%u' "${credential_file}") == 0 \
          && $(stat -c '%g' "${credential_file}") == 0 ]]; then
        ok "${client} machine-auth 전달 파일 root:0600"
      else
        echo "[FAIL] ${client} machine-auth 전달 파일 권한/소유자" >&2
        fail=1
      fi
      external_secret="${MACHINE_AUTH_SECRET_PREFIX}${client}"
      ready=$(kctl -n "${MACHINE_AUTH_NAMESPACE}" get externalsecret "${external_secret}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
      [[ ${ready} == True ]] && ok "${client} machine-auth ExternalSecret Ready" \
        || { echo "[FAIL] ${client} machine-auth ExternalSecret" >&2; fail=1; }
      kctl -n "${MACHINE_AUTH_NAMESPACE}" get secret \
        "${MACHINE_AUTH_SECRET_PREFIX}${client}-api-keys" -o json 2>/dev/null |
        jq -e --arg client "${client}" '.data | has($client)' >/dev/null \
        && ok "${client} Gateway credential key 이름 존재" \
        || { echo "[FAIL] ${client} Gateway credential key 이름" >&2; fail=1; }
    done
    for service in "${MACHINE_AUTH_SERVICES[@]}"; do
      policy_document=$(kctl -n "${MACHINE_AUTH_NAMESPACE}" get securitypolicy \
        "${service}-machine-auth" -o json 2>/dev/null || true)
      jq -e --arg header "${MACHINE_AUTH_HEADER}" '
          .spec.apiKeyAuth.sanitize == true
          and .spec.apiKeyAuth.extractFrom[0].headers == [$header]
          and (.spec.jwt | not)
          and .spec.authorization.defaultAction == "Deny"
        ' <<<"${policy_document}" >/dev/null \
        && ok "${service} API key/CIDR 정책 및 header sanitize" \
        || { echo "[FAIL] ${service} API key/CIDR 정책" >&2; fail=1; }
      jq -e '
        any(.status.ancestors[]?.conditions[]?;
          .type == "Accepted" and .status == "True")
        ' <<<"${policy_document}" >/dev/null \
        && ok "${service} SecurityPolicy Accepted" \
        || { echo "[FAIL] ${service} SecurityPolicy 미수락" >&2; fail=1; }
    done
  else
    fail=1
  fi
elif [[ ${MACHINE_AUTH_MODE} == oidc ]]; then
  for service in "${MACHINE_AUTH_SERVICES[@]}"; do
    kctl -n "${MACHINE_AUTH_NAMESPACE}" get securitypolicy "${service}-machine-auth" \
      -o json 2>/dev/null | jq -e '
        (.spec.jwt.providers | length) > 0
        and (.spec.apiKeyAuth | not)
        and .spec.authorization.defaultAction == "Deny"
      ' >/dev/null \
      && ok "${service} 외부 OIDC JWT/CIDR machine-auth 정책" \
      || { echo "[FAIL] ${service} 외부 OIDC machine-auth 정책" >&2; fail=1; }
  done
else
  echo '[FAIL] machine-auth mode 계약 오류' >&2
  fail=1
fi

http_code=$(curl -sS --resolve "hello.${base_domain}:80:${vip}" -o /dev/null \
  -w '%{http_code}' --max-time 10 "http://hello.${base_domain}/" || true)
[[ ${http_code} == 301 ]] && ok "HTTP 80 -> HTTPS 301" \
  || { echo "[FAIL] HTTP redirect -> ${http_code}" >&2; fail=1; }

if [[ ${public_mode} == direct ]]; then
  # direct 모드는 공인 IP가 노드 외부 NIC에 있으므로 Envoy Service가 그 주소를
  # externalIPs로 들고 있어야 한다. 없으면 공인 443이 nginx나 빈 소켓으로 떨어진다.
  envoy_service=$(kctl get svc -n "${gateway_namespace}" \
    -l "gateway.envoyproxy.io/owning-gateway-name=${gateway_name}" -o name | head -1)
  envoy_service_document=""
  if [[ -n ${envoy_service} ]]; then
    envoy_service_document=$(kctl get -n "${gateway_namespace}" "${envoy_service}" \
      -o json 2>/dev/null || true)
  fi
  if jq -e --arg ip "${public_ip}" '
      (.spec.externalIPs // []) | index($ip) != null
    ' <<<"${envoy_service_document}" >/dev/null 2>&1; then
    ok "direct 모드 Envoy Service externalIPs 에 공인 IP 존재"
  else
    echo '[FAIL] Envoy Service externalIPs 에 공인 IP가 없다(platform/exposure/resources.yaml 미적용).' >&2
    fail=1
  fi

  if [[ -n ${public_ip_node} ]] \
      && kctl get node "${public_ip_node}" >/dev/null 2>&1; then
    ok "direct 모드 공인 IP 노드 계약과 실제 Node 존재"
  else
    echo '[FAIL] direct 모드 spec.public.nodeName이 없거나 실제 Node와 불일치' >&2
    fail=1
  fi
  jq -e '.spec.externalTrafficPolicy == "Local"' \
    <<<"${envoy_service_document}" >/dev/null 2>&1 \
    && ok "direct 모드 Envoy Service externalTrafficPolicy=Local" \
    || { echo '[FAIL] direct 모드 Envoy Service가 Local이 아님' >&2; fail=1; }

  proxy_node=$(kctl -n "${gateway_namespace}" get envoyproxy \
    "$(python3 -c 'import yaml; print(yaml.safe_load(open("contracts/platform-production.yaml"))["spec"]["gateway"]["proxyConfigName"])')" \
    -o jsonpath='{.spec.provider.kubernetes.envoyDeployment.pod.nodeSelector.kubernetes\.io/hostname}' \
    2>/dev/null || true)
  [[ -n ${public_ip_node} && ${proxy_node} == "${public_ip_node}" ]] \
    && ok "direct 모드 Envoy Pod 공인 IP 노드 선택자" \
    || { echo '[FAIL] direct 모드 Envoy Pod nodeSelector 불일치' >&2; fail=1; }

  service_name=${envoy_service#service/}
  service_selector=$(jq -r '
    (.spec.selector // {}) | to_entries | map("\(.key)=\(.value)") | join(",")
  ' <<<"${envoy_service_document}")
  envoy_pods=$(kctl -n "${gateway_namespace}" get pod -l "${service_selector}" -o json \
    2>/dev/null || true)
  jq -e --arg node "${public_ip_node}" '
    (.items | length) > 0
    and all(.items[];
      .spec.nodeName == $node
      and any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  ' <<<"${envoy_pods}" >/dev/null 2>&1 \
    && ok "direct 모드 Envoy Pod 위치/Readiness" \
    || { echo '[FAIL] direct 모드 Envoy Pod 위치 또는 Readiness' >&2; fail=1; }

  endpoint_slices=$(kctl -n "${gateway_namespace}" get endpointslice \
    -l "kubernetes.io/service-name=${service_name}" -o json 2>/dev/null || true)
  jq -e --arg node "${public_ip_node}" '
    any(.items[]?.endpoints[]?;
      .nodeName == $node and .conditions.ready != false)
  ' <<<"${endpoint_slices}" >/dev/null 2>&1 \
    && ok "direct 모드 Local Service의 공인 IP 노드 endpoint Ready" \
    || { echo '[FAIL] direct 모드 Local Service endpoint가 공인 IP 노드에서 Ready가 아님' >&2; fail=1; }

  # 공인 IP가 실제로 Envoy 인증서를 내미는지까지 본다. nginx fake 인증서면 즉시 실패다.
  public_subject=$(echo | openssl s_client -connect "${public_ip}:443" \
    -servername "hello.${base_domain}" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)
  if [[ ${public_subject} == *"${base_domain}"* ]]; then
    ok "공인 443 -> Envoy Gateway 인증서 일치"
  else
    echo "[FAIL] 공인 443 인증서가 계약 도메인이 아니다: ${public_subject:-없음}" >&2
    fail=1
  fi

  public_code=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
    --resolve "hello.${base_domain}:443:${public_ip}" "https://hello.${base_domain}/" || true)
  [[ ${public_code} == 200 ]] && ok "공인 443 -> hello 200" \
    || { echo "[FAIL] 공인 443 hello 응답 ${public_code}(404면 nginx가 선점 중)" >&2; fail=1; }
elif curl -fsS -o /dev/null --connect-timeout 5 --max-time 10 \
  "https://hello.${base_domain}/" 2>/dev/null; then
  ok "공인 443 -> Envoy Gateway"
else
  note "공인 443은 아직 경계 NAT에 연결됨: NAT 80/443 -> ${vip} 필요"
fi

exit "${fail}"
