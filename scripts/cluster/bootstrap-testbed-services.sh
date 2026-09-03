#!/usr/bin/env bash
# 외부 IdP는 변경하지 않고 OpenBao auth/policy/KV만 값 비노출 방식으로 초기화한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"
source "$(dirname "$0")/../lib/machine-auth.sh"
source "$(dirname "$0")/../lib/openbao-eso.sh"

SKIP_OPENBAO_OIDC=false
while (($#)); do
  case "$1" in
    --skip-openbao-oidc) SKIP_OPENBAO_OIDC=true ;;
    -h|--help)
      cat <<'EOF'
usage: sudo scripts/cluster/bootstrap-testbed-services.sh [--skip-openbao-oidc]

SADP는 IdP, realm, client, 사용자 또는 그룹을 만들거나 변경하지 않는다.
OIDC client secret 세 개는 docs/identity-provider.md에 따라 외부 IdP에서 발급한 뒤
/var/lib/sadp/credentials 아래 root:root 0600 파일로 먼저 배치한다.
EOF
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

require_root
for command in jq openssl python3 stat; do require_command "${command}"; done
ensure_state_dirs
cd "${TESTBED_ROOT}"

mapfile -t identity_values < <(python3 - <<'PY'
import yaml

spec = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))["spec"]
identity = spec.get("identityProvider") or {}
print(str(spec.get("baseDomain") or ""))
print(str(identity.get("groupsClaim") or "groups"))
print(str(identity.get("sourceProtocol") or ""))
PY
)
BASE_DOMAIN=${identity_values[0]:?계약에 baseDomain이 없다}
OIDC_GROUPS_CLAIM=${identity_values[1]:?계약에 identityProvider.groupsClaim이 없다}
IDENTITY_SOURCE_PROTOCOL=${identity_values[2]:?계약에 identityProvider.sourceProtocol이 없다}
OPENBAO_HOST=openbao.${BASE_DOMAIN}

require_oidc_client_secret() {
  local name=$1 path="${CREDENTIAL_DIR}/$1" owner mode
  [[ -f ${path} && ! -L ${path} && -s ${path} ]] || die "외부 IdP client secret 파일 없음: ${path}"
  owner=$(stat -c '%u:%g' "${path}")
  mode=$(stat -c '%a' "${path}")
  [[ ${owner} == 0:0 && ${mode} == 600 ]] \
    || die "외부 IdP client secret은 root:root 0600이어야 함: ${path}"
}
for credential in oidc-secure-demo-client-secret oidc-portal-client-secret oidc-openbao-client-secret; do
  require_oidc_client_secret "${credential}"
done
ensure_random_file "${CREDENTIAL_DIR}/portal-auth-secret"
note "외부 IdP 연결(source=${IDENTITY_SOURCE_PROTOCOL})의 사전 발급 client secret 확인; IdP 설정은 변경하지 않음"

openbao_pod=openbao-0
kctl wait -n openbao pod/${openbao_pod} --for=jsonpath='{.status.phase}'=Running --timeout=10m >/dev/null
bao_addr=https://openbao.openbao.svc.cluster.local:8200
init_file=${TESTBED_STATE_DIR}/openbao-init.json
status_json=$(kctl exec -n openbao "${openbao_pod}" -- env BAO_ADDR="${bao_addr}" \
  BAO_CACERT=/openbao/tls/ca.crt bao status -format=json 2>/dev/null || true)
# `kubectl exec` appends this informational line to stdout when `bao status`
# returns 2 for the normal sealed/uninitialized state.
status_json=$(sed '/^command terminated with exit code /d' <<<"${status_json}")
if [[ -z ${status_json} ]]; then
  status_json='{}'
fi
initialized=$(jq -r '.initialized // false' <<<"${status_json}")
if [[ ${initialized} != true ]]; then
  init_tmp=${init_file}.tmp
  kctl exec -n openbao "${openbao_pod}" -- env BAO_ADDR="${bao_addr}" \
    BAO_CACERT=/openbao/tls/ca.crt bao operator init \
    -key-shares=3 -key-threshold=2 -format=json >"${init_tmp}"
  chmod 0600 "${init_tmp}"
  jq -e '.root_token and (.unseal_keys_b64 | length == 3)' "${init_tmp}" >/dev/null
  mv "${init_tmp}" "${init_file}"
  ok "OpenBao 초기화(3 shares, threshold 2); 복구 재료는 root-only 상태 디렉터리에 저장"
elif [[ ! -s ${init_file} ]]; then
  die "OpenBao는 이미 초기화됐지만 ${init_file}이 없어 unseal/bootstrap 불가"
fi

# 초기화 직후나 재기동 뒤 sealed 상태를 bootstrap이 암묵적으로 풀면 운영자가 복구 재료 사용을
# 승인할 경계가 사라진다. 상태만 확인하고 별도 --apply 명령을 명시한 뒤 다시 실행하게 한다.
openbao_require_unsealed 5m
bao() {
  # root token은 kubectl exec 인자/환경에 넣지 않는다. 고정된 shell이 stdin 첫 줄을
  # 받아 Pod 안에서만 환경변수로 올리고, 실제 bao에는 EOF를 전달한다.
  jq -er '.root_token' "${init_file}" |
    kctl exec -i -n openbao "${openbao_pod}" -- sh -ceu '
      IFS= read -r BAO_TOKEN
      export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
      shift
      exec bao "$@"
    ' sh "${bao_addr}" "$@"
}
bao_input() {
  # JSON/HCL 본문이 필요한 호출은 token 다음 바이트부터 그대로 bao stdin으로 넘긴다.
  # 이 함수는 유한한 pipe/heredoc의 오른쪽에서만 호출해야 한다.
  {
    jq -er '.root_token' "${init_file}"
    cat
  } | kctl exec -i -n openbao "${openbao_pod}" -- sh -ceu '
    IFS= read -r BAO_TOKEN
    export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
    shift
    exec bao "$@"
  ' sh "${bao_addr}" "$@"
}

bao audit list -format=json | jq -e 'has("file/")' >/dev/null \
  || die "OpenBao declarative file audit 장치가 활성화되지 않음"
if ! bao secrets list -format=json | jq -e 'has("kv/")' >/dev/null; then
  bao secrets enable -path=kv -version=2 kv >/dev/null
fi
if ! bao auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null; then
  bao auth enable -path=kubernetes kubernetes >/dev/null
fi
bao write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt="" disable_local_ca_jwt=false >/dev/null
# project/environment 를 beta 로 박아 두면 WORKLOAD_NAMESPACE 를 바꾼 사이트에서
# OpenBao 정책·인증 역할·KV 경로가 전부 ESO 가 요구하는 이름과 어긋나고, ExternalSecret 은
# "could not get secret data from provider" 로만 실패해 원인이 드러나지 않는다.
# 차트가 이름을 만드는 근거와 같은 값(app.project/app.environment)을 values 에서 읽는다.
eval "$(python3 - <<'PY'
import re
import shlex
import yaml

expected = None
for path in ("apps/secure-demo/values-beta.yaml", "apps/portal-lite/values-beta.yaml"):
    app = yaml.safe_load(open(path, encoding="utf-8"))["app"]
    current = (str(app["project"]).strip(), str(app["environment"]).strip())
    if not all(current):
        raise SystemExit(f"[FAIL] {path}: app.project/app.environment 가 비어 있음")
    if expected and current != expected:
        raise SystemExit(f"[FAIL] app.project/app.environment 가 앱마다 다르다: {expected} vs {current}")
    expected = current
print(f"APP_PROJECT='{expected[0]}'")
print(f"APP_ENVIRONMENT='{expected[1]}'")
contract = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))["spec"]
registry_path = str((contract.get("registry") or {}).get("pullSecretRemotePath") or "")
if not registry_path.startswith("platform/registry/"):
    raise SystemExit("[FAIL] registry.pullSecretRemotePath 계약값 오류")
namespaces = (contract.get("network") or {}).get("defaultDenyNamespaces") or []
if len(namespaces) != 1 or not re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", str(namespaces[0])):
    raise SystemExit("[FAIL] workload Namespace 계약값 오류")
print("REGISTRY_PULL_REMOTE_PATH=" + shlex.quote(registry_path))
print("APP_NAMESPACE=" + shlex.quote(str(namespaces[0])))
PY
)" || exit 1
app_namespace="${APP_NAMESPACE}"
kv_prefix="apps/${APP_PROJECT}/${APP_ENVIRONMENT}"
ok "OpenBao 대상 Namespace=${app_namespace} KV=${kv_prefix}"

# 세 앱마다 policy/auth role을 만들지 않는다. Kubernetes auth alias metadata를 경로에
# 넣는 고정 templated policy 하나가 인증한 Namespace/ServiceAccount의 문서만 읽게 한다.
# 포털에는 이 policy/role의 read만 주므로 침해돼도 임의 policy나 관리자 role을 만들 수 없다.
kubernetes_auth_accessor=$(bao auth list -format=json | jq -er '."kubernetes/".accessor')
cat <<HCL | bao_input policy write portal-workload-secret-reader - >/dev/null
path "kv/data/${kv_prefix}/workloads/{{identity.entity.aliases.${kubernetes_auth_accessor}.metadata.service_account_namespace}}/{{identity.entity.aliases.${kubernetes_auth_accessor}.metadata.service_account_name}}" {
  capabilities = ["read"]
}
path "kv/metadata/${kv_prefix}/workloads/{{identity.entity.aliases.${kubernetes_auth_accessor}.metadata.service_account_namespace}}/{{identity.entity.aliases.${kubernetes_auth_accessor}.metadata.service_account_name}}" {
  capabilities = ["read"]
}
HCL
bao write auth/kubernetes/role/portal-zone-app-eso \
  bound_service_account_names="*" \
  bound_service_account_namespaces="${app_namespace}" audience=vault \
  token_policies=portal-workload-secret-reader token_ttl=1h token_max_ttl=4h >/dev/null
bao write auth/kubernetes/role/portal-group-app-eso \
  bound_service_account_names="*" \
  bound_service_account_namespace_selector='{"matchLabels":{"platform.example.io/app-group":"true"}}' \
  audience=vault token_policies=portal-workload-secret-reader \
  token_ttl=1h token_max_ttl=4h >/dev/null

# 이미 운영 중인 두 플랫폼 앱은 workload identity 도입 전의 exact KV 경로와 앱별 role을
# 사용한다. 차트 업그레이드가 재시작 때 Secret을 끊지 않도록 fresh bootstrap에도 같은
# 최소권한 계약을 만든다. 신규 Portal 신청에는 이 함수나 role 생성 권한을 노출하지 않는다.
grant_legacy_static_secret_access() {
  local app_name=$1 role="eso-${APP_PROJECT}-${APP_ENVIRONMENT}-$1"
  cat <<HCL | bao_input policy write "${role}" - >/dev/null
path "kv/data/${kv_prefix}/${app_name}" {
  capabilities = ["read"]
}
path "kv/metadata/${kv_prefix}/${app_name}" {
  capabilities = ["read"]
}
HCL
  bao write "auth/kubernetes/role/${role}" \
    bound_service_account_names="eso-${app_name}" \
    bound_service_account_namespaces="${app_namespace}" audience=vault \
    token_policies="${role}" token_ttl=1h token_max_ttl=4h >/dev/null
}
grant_legacy_static_secret_access secure-demo
grant_legacy_static_secret_access portal-lite

cat <<HCL | bao_input policy write portal-registry-pull-reader - >/dev/null
path "kv/data/${REGISTRY_PULL_REMOTE_PATH}" { capabilities = ["read"] }
path "kv/metadata/${REGISTRY_PULL_REMOTE_PATH}" { capabilities = ["read"] }
HCL
bao write auth/kubernetes/role/portal-group-registry-eso \
  bound_service_account_names=eso-registry \
  bound_service_account_namespace_selector='{"matchLabels":{"platform.example.io/app-group":"true"}}' \
  audience=vault token_policies=portal-registry-pull-reader \
  token_ttl=1h token_max_ttl=4h >/dev/null

# 포털은 사용자 앱 KV 문서만 병합하고 삭제할 수 있다. 정책/role 본문 쓰기 권한은 없다.
# 플랫폼 앱의 exact 경로는 넓은 workload prefix보다 구체적인 deny로 보호한다.
cat <<HCL | bao_input policy write portal-app-secret-writer - >/dev/null
path "kv/data/${kv_prefix}/workloads/*" { capabilities = ["create", "update", "patch"] }
path "kv/metadata/${kv_prefix}/workloads/*" { capabilities = ["read", "delete"] }
path "kv/subkeys/${kv_prefix}/workloads/*" { capabilities = ["read"] }
# 기존 PVC 신청 기록은 apps/<project>/<env>/<app>에 Secret을 저장했다. 재시도·삭제만
# 끝낼 수 있도록 KV 범위는 읽되, policy/role은 아래에서 read만 허용하고 생성·수정하지 않는다.
path "kv/data/${kv_prefix}/+" { capabilities = ["create", "update", "patch"] }
path "kv/metadata/${kv_prefix}/+" { capabilities = ["read", "delete"] }
path "kv/subkeys/${kv_prefix}/+" { capabilities = ["read"] }
path "kv/data/${kv_prefix}/workloads/${app_namespace}/eso-portal-lite" { capabilities = ["deny"] }
path "kv/metadata/${kv_prefix}/workloads/${app_namespace}/eso-portal-lite" { capabilities = ["deny"] }
path "kv/subkeys/${kv_prefix}/workloads/${app_namespace}/eso-portal-lite" { capabilities = ["deny"] }
path "kv/data/${kv_prefix}/workloads/${app_namespace}/eso-secure-demo" { capabilities = ["deny"] }
path "kv/metadata/${kv_prefix}/workloads/${app_namespace}/eso-secure-demo" { capabilities = ["deny"] }
path "kv/subkeys/${kv_prefix}/workloads/${app_namespace}/eso-secure-demo" { capabilities = ["deny"] }
path "kv/data/${kv_prefix}/portal-lite" { capabilities = ["deny"] }
path "kv/metadata/${kv_prefix}/portal-lite" { capabilities = ["deny"] }
path "kv/subkeys/${kv_prefix}/portal-lite" { capabilities = ["deny"] }
path "kv/data/${kv_prefix}/secure-demo" { capabilities = ["deny"] }
path "kv/metadata/${kv_prefix}/secure-demo" { capabilities = ["deny"] }
path "kv/subkeys/${kv_prefix}/secure-demo" { capabilities = ["deny"] }
path "kv/metadata/${REGISTRY_PULL_REMOTE_PATH}" { capabilities = ["read"] }
path "kv/subkeys/${REGISTRY_PULL_REMOTE_PATH}" { capabilities = ["read"] }
path "sys/policies/acl/portal-workload-secret-reader" { capabilities = ["read"] }
path "sys/policies/acl/portal-registry-pull-reader" { capabilities = ["read"] }
path "auth/kubernetes/role/portal-zone-app-eso" { capabilities = ["read"] }
path "auth/kubernetes/role/portal-group-app-eso" { capabilities = ["read"] }
path "auth/kubernetes/role/portal-group-registry-eso" { capabilities = ["read"] }
path "sys/policies/acl/eso-${APP_PROJECT}-${APP_ENVIRONMENT}-*" { capabilities = ["read"] }
path "auth/kubernetes/role/eso-${APP_PROJECT}-${APP_ENVIRONMENT}-*" { capabilities = ["read"] }
path "sys/policies/acl/eso-${APP_PROJECT}-${APP_ENVIRONMENT}-portal-lite" { capabilities = ["deny"] }
path "sys/policies/acl/eso-${APP_PROJECT}-${APP_ENVIRONMENT}-secure-demo" { capabilities = ["deny"] }
path "auth/kubernetes/role/eso-${APP_PROJECT}-${APP_ENVIRONMENT}-portal-lite" { capabilities = ["deny"] }
path "auth/kubernetes/role/eso-${APP_PROJECT}-${APP_ENVIRONMENT}-secure-demo" { capabilities = ["deny"] }
HCL
bao write auth/kubernetes/role/portal-app-secret-writer \
  bound_service_account_names=portal-lite \
  bound_service_account_namespaces="${app_namespace}" audience=vault \
  token_policies=portal-app-secret-writer token_ttl=15m token_max_ttl=1h >/dev/null

# bootstrap을 다시 실행해도 install-portal-backend가 별도로 넣은 FORGEJO_BOT_TOKEN 같은
# 운영 key를 지우면 안 된다. 문서가 이미 있으면 key 하나씩 patch하고, 최초 문서에만 put을
# 사용한다. 값은 stdin으로만 보내므로 host의 argv와 로그에는 나타나지 않는다.
seed_kv_file_key() {
  local remote_path=$1 key=$2 source_file=$3
  [[ -s ${source_file} ]] || die "OpenBao 시드 파일이 비어 있음: ${source_file}"
  if bao kv get -mount=kv "${remote_path}" >/dev/null 2>&1; then
    tr -d '\r\n' <"${source_file}" |
      bao_input kv patch -mount=kv "${remote_path}" "${key}=-" >/dev/null
  else
    tr -d '\r\n' <"${source_file}" |
      bao_input kv put -mount=kv "${remote_path}" "${key}=-" >/dev/null
  fi
}

seed_kv_file_key "${kv_prefix}/secure-demo" DB_PASSWORD \
  "${CREDENTIAL_DIR}/app-db-password"
seed_kv_file_key "${kv_prefix}/secure-demo" API_TOKEN \
  "${CREDENTIAL_DIR}/app-api-token"
seed_kv_file_key "${kv_prefix}/secure-demo" OIDC_CLIENT_SECRET \
  "${CREDENTIAL_DIR}/oidc-secure-demo-client-secret"
seed_kv_file_key "${kv_prefix}/portal-lite" AUTH_OIDC_SECRET \
  "${CREDENTIAL_DIR}/oidc-portal-client-secret"
seed_kv_file_key "${kv_prefix}/portal-lite" AUTH_SECRET \
  "${CREDENTIAL_DIR}/portal-auth-secret"

# 기계 API 키는 OpenBao KV와 ESO role이 모두 준비된 뒤에만 만든다. oidc 모드는
# 이 함수가 값 생성 없이 반환하므로 일반 bootstrap이 인증 모드를 넘나들며 키를 만들거나
# 회전시키지 않는다.
machine_auth_bootstrap

if ! bao auth list -format=json | jq -e 'has("oidc/")' >/dev/null; then
  bao auth enable oidc >/dev/null
fi
cat <<'HCL' | bao_input policy write platform-admin - >/dev/null
path "sys/health" { capabilities = ["read"] }
path "sys/mounts" { capabilities = ["read", "list"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "kv/*" { capabilities = ["create", "read", "update", "delete", "list"] }
HCL

# 예전 app-admin/developer token이 참조하던 이름은 호환을 위해 남기되 Secret 권한은
# 제거한다. 프로젝트 경로 하나에도 플랫폼 앱과 여러 사용자 앱이 함께 있으므로 프로젝트
# wildcard는 테넌트 경계가 아니다. 실제 Secret 권한은 운영 명령이 만드는 exact 앱 policy만
# 부여한다.
cat <<HCL | bao_input policy write app-secrets - >/dev/null
path "sys/health" { capabilities = ["read"] }
path "sys/mounts" { capabilities = ["read", "list"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
HCL

# 일반 로그인 정책에는 Secret 권한을 넣지 않는다. 관리자가 앱별 role/group을 만든 뒤에만
# 해당 앱 경로를 수정·삭제할 수 있어 사용자별 token과 실제 데이터 권한이 일치한다.
cat <<HCL | bao_input policy write app-user - >/dev/null
path "sys/health" { capabilities = ["read"] }
path "sys/mounts" { capabilities = ["read", "list"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
HCL

# role마다 bound_claims로 외부 IdP group을 묶는다. 이것이 없으면 IdP에 로그인할 수
# 있는 사람은 누구나 그 role 을 그대로 assume 한다(groups_claim 은 claim 위치만 알려 줄 뿐
# 접근을 제한하지 않는다). 일반 사용자 role 만 의도적으로 묶지 않는다.
#
# bound_claims 는 map 이라 CLI 의 key=value 로는 전달되지 않는다(문자열로 들어가 매칭이
# 조용히 실패한다). 반드시 JSON 본문으로 쓴다.
oidc_role() {
  local role=$1 policy=$2
  jq -n --arg r "${role}" --arg p "${policy}" --arg h "${OPENBAO_HOST}" \
    --arg groups_claim "${OIDC_GROUPS_CLAIM}" '{
    role_type:"oidc", user_claim:"preferred_username", groups_claim:$groups_claim,
    bound_audiences:["openbao"], token_policies:[$p], token_ttl:"1h",
    bound_claims_type:"string", bound_claims:{groups:[$r]},
    allowed_redirect_uris:[
      ("https://" + $h + "/ui/vault/auth/oidc/oidc/callback"),
      "http://localhost:8250/oidc/callback"
    ]}' | bao_input write "auth/oidc/role/${role}" - >/dev/null
}
oidc_role platform-admin platform-admin
oidc_role app-admin app-user
oidc_role developer app-user

# 일반 사용자 role: bound_claims 없음. group 이 없어도 로그인하면 이 role 을 받는다.
jq -n --arg h "${OPENBAO_HOST}" --arg groups_claim "${OIDC_GROUPS_CLAIM}" '{
  role_type:"oidc", user_claim:"preferred_username", groups_claim:$groups_claim,
  bound_audiences:["openbao"], token_policies:["app-user"], token_ttl:"1h",
  allowed_redirect_uris:[
    ("https://" + $h + "/ui/vault/auth/oidc/oidc/callback"),
    "http://localhost:8250/oidc/callback"
  ]}' | bao_input write auth/oidc/role/user - >/dev/null

if [[ ${SKIP_OPENBAO_OIDC} == true ]]; then
  note "OpenBao OIDC config는 Gateway/TLS/discovery 전용 순서 단계에서 적용하도록 보류"
else
  # 직접 bootstrap 진입점도 같은 fail-closed preflight를 거쳐야 API의 일반적인
  # 'error checking oidc discovery URL' 400으로 원인이 가려지지 않는다.
  bash scripts/ops/configure-openbao-oidc.sh --apply
fi
kctl wait -n openbao pod/${openbao_pod} --for=condition=Ready --timeout=5m >/dev/null
ok "OpenBao audit/KV v2/Kubernetes auth/최소권한 policy/OIDC role 구성"
