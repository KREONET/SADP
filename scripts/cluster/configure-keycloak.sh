#!/usr/bin/env bash
# 이미 실행 중인 Keycloak의 realm/client/role/IdP만 SADP 계약으로 수렴시킨다.
# Keycloak 본체를 설치·재시작하지 않아 사후 설정과 서비스 lifecycle의 권한 경계를 나눈다.
set -euo pipefail

source "$(dirname "$0")/../lib/testbed-common.sh"

APPLY=false
SERVER_URL=
ADMIN_USER_FILE=
ADMIN_PASSWORD_FILE=
CONTRACT_FILE=${SADP_CONTRACT_FILE:-${TESTBED_ROOT}/contracts/platform-production.yaml}
PORTAL_VALUES_FILE=${SADP_PORTAL_VALUES_FILE:-${TESTBED_ROOT}/apps/portal-lite/values-beta.yaml}
VERSIONS_FILE=${SADP_VERSIONS_FILE:-${TESTBED_ROOT}/versions.lock.yaml}
KCADM_RUNNER=${SADP_KCADM_RUNNER:-${TESTBED_ROOT}/scripts/cluster/keycloak-kcadm-in-pod.sh}
KCADM_NAMESPACE=keycloak
KCADM_TARGET=
KCADM_CONFIG=
EPHEMERAL_POD=false
temporary_secret_files=()

usage() {
  cat <<'EOF'
사용법: configure-keycloak.sh \
  [--server-url https://<KEYCLOAK_HOST>] \
  --admin-user-file <ROOT_ONLY_ADMIN_USER_FILE> \
  --admin-password-file <ROOT_ONLY_ADMIN_PASSWORD_FILE> [--apply]

기본은 계약과 실행 계획만 검증한다. --apply를 주면 이미 실행 중인 Keycloak을
반복 안전하게 수렴시킨다. Keycloak 설치·재시작은 하지 않는다.
EOF
}

while (($#)); do
  case $1 in
    --server-url) SERVER_URL=${2:?--server-url 값 필요}; shift ;;
    --admin-user-file) ADMIN_USER_FILE=${2:?--admin-user-file 값 필요}; shift ;;
    --admin-password-file) ADMIN_PASSWORD_FILE=${2:?--admin-password-file 값 필요}; shift ;;
    --apply) APPLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "알 수 없는 인자: $1" ;;
  esac
  shift
done

[[ -n ${ADMIN_USER_FILE} && -n ${ADMIN_PASSWORD_FILE} ]] \
  || die "--admin-user-file과 --admin-password-file이 모두 필요"
for command in python3 stat base64; do require_command "${command}"; done
require_root

validate_credential_file() {
  local path=$1 label=$2 mode
  [[ ${path} == /* && -f ${path} && ! -L ${path} ]] \
    || die "${label}는 symlink가 아닌 일반 절대경로 파일이어야 함"
  [[ $(stat -c '%u' "${path}") == 0 ]] || die "${label}는 root 소유여야 함"
  mode=$(stat -c '%a' "${path}")
  [[ ${mode} == 400 || ${mode} == 600 ]] || die "${label} mode는 0400 또는 0600이어야 함"
  python3 - "${path}" <<'PY' || die "${label}는 비어 있지 않은 한 줄 파일이어야 함"
import pathlib
import sys

value = pathlib.Path(sys.argv[1]).read_bytes().rstrip(b"\r\n")
if not value or b"\n" in value or b"\r" in value or b"\0" in value:
    raise SystemExit(1)
PY
}

validate_credential_file "${ADMIN_USER_FILE}" "Keycloak 관리자 ID 파일"
validate_credential_file "${ADMIN_PASSWORD_FILE}" "Keycloak 관리자 비밀번호 파일"
[[ -r ${CONTRACT_FILE} && -r ${PORTAL_VALUES_FILE} && -r ${VERSIONS_FILE} ]] \
  || die "Keycloak 계약/Portal values/버전 SSOT를 읽을 수 없음"

mapfile -t contract_values < <(python3 - "${CONTRACT_FILE}" "${PORTAL_VALUES_FILE}" \
  "${VERSIONS_FILE}" <<'PY'
import sys

import yaml

contract = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
portal = yaml.safe_load(open(sys.argv[2], encoding="utf-8")) or {}
versions = yaml.safe_load(open(sys.argv[3], encoding="utf-8")) or {}
spec = contract.get("spec") or {}
keycloak = spec.get("keycloak") or {}
external = keycloak.get("external") or {}
idp = keycloak.get("identityProvider") or {}
sso = next(
    (item for item in (spec.get("platformServices") or []) if item.get("name") == "sso"),
    {},
)
idp_keys = (
    "alias", "displayName", "providerId", "metadataDescriptorUrl", "singleSignOnServiceUrl"
)
idp_values = [str(idp.get(key) or "").strip() for key in idp_keys]
if any(idp_values) and not all(idp_values):
    raise SystemExit("[FAIL] Keycloak SAML IdP 계약값은 모두 비우거나 모두 설정해야 함")
if idp_values and all(idp_values) and idp_values[2] != "saml":
    raise SystemExit("[FAIL] Keycloak identityProvider.providerId는 saml이어야 함")
deployment = str(keycloak.get("deployment") or "in-cluster").strip()
if deployment not in {"in-cluster", "external"}:
    raise SystemExit("[FAIL] Keycloak deployment는 in-cluster|external이어야 함")
values = [
    deployment,
    str(spec.get("baseDomain") or "").strip(),
    str(keycloak.get("realm") or "").strip(),
    str(keycloak.get("portalClientID") or "").strip(),
    str((spec.get("hosts") or {}).get("sso") or sso.get("host") or "").strip(),
    str(sso.get("namespace") or "").strip(),
    str(sso.get("service") or "").strip(),
    str(sso.get("port") or "").strip(),
    str(external.get("address") or "").strip(),
    str(external.get("port") or "").strip(),
    str((portal.get("exposure") or {}).get("host") or "").strip(),
    str(((versions.get("platform") or {}).get("keycloak")) or "").strip(),
    *idp_values,
    str(keycloak.get("samlSpEntityId") or keycloak.get("issuer") or "").strip(),
]
required = list(range(1, 8)) + [10, 11]
if deployment == "external":
    required.extend((8, 9))
if any(not values[index] for index in required):
    raise SystemExit("[FAIL] Keycloak 수렴에 필요한 계약/Portal/버전 값 누락")
print("\n".join(values))
PY
)

KEYCLOAK_DEPLOYMENT=${contract_values[0]}
BASE_DOMAIN=${contract_values[1]}
KEYCLOAK_REALM=${contract_values[2]}
PORTAL_CLIENT_ID=${contract_values[3]}
SSO_HOST=${contract_values[4]}
KEYCLOAK_SERVICE_NAMESPACE=${contract_values[5]}
KEYCLOAK_SERVICE=${contract_values[6]}
KEYCLOAK_SERVICE_PORT=${contract_values[7]}
KEYCLOAK_EXTERNAL_ADDRESS=${contract_values[8]}
KEYCLOAK_EXTERNAL_PORT=${contract_values[9]}
PORTAL_HOST=${contract_values[10]}
KEYCLOAK_VERSION=${contract_values[11]}
IDP_ALIAS=${contract_values[12]}
IDP_DISPLAY_NAME=${contract_values[13]}
IDP_PROVIDER_ID=${contract_values[14]}
IDP_METADATA_URL=${contract_values[15]}
IDP_SSO_URL=${contract_values[16]}
KEYCLOAK_SAML_SP_ENTITY_ID=${contract_values[17]}
KCADM_NAMESPACE=${KEYCLOAK_SERVICE_NAMESPACE}
SECURE_DEMO_HOST=secure-demo.${BASE_DOMAIN}
OPENBAO_HOST=openbao.${BASE_DOMAIN}

if [[ -z ${SERVER_URL} ]]; then
  if [[ ${KEYCLOAK_DEPLOYMENT} == external ]]; then
    SERVER_URL="http://${KEYCLOAK_EXTERNAL_ADDRESS}:${KEYCLOAK_EXTERNAL_PORT}"
  else
    SERVER_URL="http://${KEYCLOAK_SERVICE}.${KEYCLOAK_SERVICE_NAMESPACE}.svc.cluster.local:${KEYCLOAK_SERVICE_PORT}"
  fi
fi
SERVER_URL=$(python3 - "${SERVER_URL}" "${SSO_HOST}" "${KEYCLOAK_SERVICE}" \
  "${KEYCLOAK_SERVICE_NAMESPACE}" "${KEYCLOAK_EXTERNAL_ADDRESS}" <<'PY'
import sys
from urllib.parse import urlsplit

url, sso_host, service, namespace, external_address = sys.argv[1:]
try:
    parsed = urlsplit(url)
    parsed.port
except ValueError as error:
    raise SystemExit(f"[FAIL] --server-url 포트 형식 오류: {error}")
allowed_hosts = {
    sso_host.lower(), service.lower(), f"{service}.{namespace}".lower(),
    f"{service}.{namespace}.svc".lower(), f"{service}.{namespace}.svc.cluster.local".lower(),
}
if external_address:
    allowed_hosts.add(external_address.lower())
if (
    parsed.scheme not in {"http", "https"}
    or not parsed.hostname
    or parsed.username is not None
    or parsed.password is not None
    or parsed.query
    or parsed.fragment
    or parsed.path not in {"", "/"}
):
    raise SystemExit("[FAIL] --server-url은 credential/query/fragment/path 없는 HTTP(S) base URL이어야 함")
if parsed.hostname.lower() not in allowed_hosts:
    raise SystemExit("[FAIL] --server-url host는 계약의 SSO host, Keycloak Service, external address만 허용")
print(url.rstrip("/"))
PY
)

note "Keycloak 사후 수렴 계획: deployment=${KEYCLOAK_DEPLOYMENT}, realm/client/group/role 계약 적용"
note "관리자 ID/비밀번호는 root-only 파일에서 kcadm Pod stdin으로만 전달"
if [[ ${KEYCLOAK_DEPLOYMENT} == external ]]; then
  note "SSH 없이 고정 Keycloak ${KEYCLOAK_VERSION} 일회성 CLI Pod로 external Admin API에 접속"
else
  note "기존 in-cluster Keycloak Pod의 kcadm을 사용"
fi
[[ -z ${IDP_ALIAS} ]] \
  || note "계약의 SAML IdP/first-login flow/username/developer group mapper도 수렴"
note "Keycloak 본체 설치·재시작은 하지 않음"
if [[ ${APPLY} != true ]]; then
  note "적용하려면 같은 명령 끝에 --apply를 붙인다"
  exit 0
fi

for command in jq openssl; do require_command "${command}"; done
[[ -x ${KUBECTL_BIN} ]] || die "kubectl 없음: ${KUBECTL_BIN}"
[[ -s ${KCADM_RUNNER} ]] || die "kcadm Pod wrapper 없음: ${KCADM_RUNNER}"
ensure_state_dirs
for state_file in "${CREDENTIAL_DIR}/keycloak-test-user" \
  "${CREDENTIAL_DIR}/keycloak-test-password"; do
  [[ ! -e ${state_file} || ( -f ${state_file} && ! -L ${state_file} ) ]] \
    || die "Keycloak acceptance 상태 경로가 일반 파일이 아님: ${state_file}"
done
ensure_text_file "${CREDENTIAL_DIR}/keycloak-test-user" test-admin
ensure_random_file "${CREDENTIAL_DIR}/keycloak-test-password"
chmod 0600 "${CREDENTIAL_DIR}/keycloak-test-user" "${CREDENTIAL_DIR}/keycloak-test-password"
chown 0:0 "${CREDENTIAL_DIR}/keycloak-test-user" "${CREDENTIAL_DIR}/keycloak-test-password"

cleanup() {
  local status=$?
  trap - EXIT
  set +e
  if [[ -n ${KCADM_TARGET} && -n ${KCADM_CONFIG} ]]; then
    kctl exec -n "${KCADM_NAMESPACE}" "${KCADM_TARGET}" -- rm -f "${KCADM_CONFIG}" \
      >/dev/null 2>&1
  fi
  if [[ ${EPHEMERAL_POD} == true && -n ${KCADM_TARGET} ]]; then
    kctl delete -n "${KCADM_NAMESPACE}" "${KCADM_TARGET}" --ignore-not-found --wait=false \
      >/dev/null 2>&1
  fi
  rm -f "${temporary_secret_files[@]}"
  exit "${status}"
}
trap cleanup EXIT

KCADM_CONFIG="/tmp/sadp-kcadm-${RANDOM}-${RANDOM}.config"
if [[ ${KEYCLOAK_DEPLOYMENT} == in-cluster ]]; then
  KUBECONFIG_PATH=${KUBECONFIG_PATH} kctl rollout status -n "${KEYCLOAK_SERVICE_NAMESPACE}" \
    deployment/"${KEYCLOAK_SERVICE}" --timeout=15m >/dev/null \
    || die "in-cluster Keycloak Deployment가 Ready가 아님"
  KCADM_NAMESPACE=${KEYCLOAK_SERVICE_NAMESPACE}
  KCADM_TARGET="deploy/${KEYCLOAK_SERVICE}"
else
  kctl get namespace "${KCADM_NAMESPACE}" >/dev/null 2>&1 \
    || die "일회성 Keycloak CLI Pod를 실행할 ${KCADM_NAMESPACE} Namespace가 없음"
  pod_name="sadp-keycloak-kcadm-${RANDOM}-${RANDOM}"
  KCADM_TARGET="pod/${pod_name}"
  EPHEMERAL_POD=true
  # Secret/ConfigMap/ServiceAccount volume을 만들지 않고, 세션은 Pod /tmp에만 남겨
  # 성공·실패 모두 EXIT trap이 Pod와 config를 한께 제거한다.
  cat <<EOF | kctl create -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${KCADM_NAMESPACE}
  labels:
    platform.example.io/component: keycloak-admin-cli
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: kcadm
      image: quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}
      imagePullPolicy: IfNotPresent
      command: [sh, -c, 'while :; do sleep 30; done']
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
EOF
  kctl wait -n "${KCADM_NAMESPACE}" "${KCADM_TARGET}" --for=condition=Ready \
    --timeout=5m >/dev/null || die "일회성 Keycloak CLI Pod Ready 실패"
fi

export SADP_KCADM_POD=${KCADM_TARGET}
export SADP_KCADM_NAMESPACE=${KCADM_NAMESPACE}
export SADP_KCADM_CONFIG=${KCADM_CONFIG}
export KUBECTL_BIN KUBECONFIG_PATH

kc() { bash "${KCADM_RUNNER}" "$@"; }
kc_input() { bash "${KCADM_RUNNER}" "$@"; }

# 두 자격증명은 host 환경변수/argv를 거치지 않고 wrapper stdin으로만 건너간다.
{
  tr -d '\r\n' <"${ADMIN_USER_FILE}" | base64 -w0
  printf '\n'
  tr -d '\r\n' <"${ADMIN_PASSWORD_FILE}" | base64 -w0
  printf '\n'
} | kc config credentials --server "${SERVER_URL}" --realm master >/dev/null \
  || die "Keycloak 관리자 인증 실패"

realm_document=$(jq -nc --arg realm "${KEYCLOAK_REALM}" '{
  realm:$realm, enabled:true, sslRequired:"external", registrationAllowed:false,
  duplicateEmailsAllowed:false, editUsernameAllowed:false,
  bruteForceProtected:true, failureFactor:5
}')
if kc get "realms/${KEYCLOAK_REALM}" >/dev/null 2>&1; then
  kc_input update "realms/${KEYCLOAK_REALM}" -f - <<<"${realm_document}" >/dev/null
else
  kc_input create realms -f - <<<"${realm_document}" >/dev/null
fi

ensure_group() {
  local group=$1 rows count
  rows=$(kc get groups -r "${KEYCLOAK_REALM}" -q search="${group}")
  count=$(jq --arg group "${group}" '[.[] | select(.name == $group)] | length' <<<"${rows}")
  ((count <= 1)) || die "Keycloak group ${group}이 둘 이상임"
  ((count == 1)) || kc create groups -r "${KEYCLOAK_REALM}" -s name="${group}" >/dev/null
}
for group in platform-admin app-admin developer viewer; do ensure_group "${group}"; done

developer_groups=$(kc get groups -r "${KEYCLOAK_REALM}" -q search=developer)
developer_group_id=$(jq -er '
  [.[] | select(.name == "developer")] as $matches
  | select(($matches | length) == 1) | $matches[0].id
' <<<"${developer_groups}") || die "Keycloak developer group을 정확히 하나 찾지 못함"
kc update "default-groups/${developer_group_id}" -r "${KEYCLOAK_REALM}" -n >/dev/null

atomic_store_client_secret() {
  local client_uuid=$1 target=$2 response value_tmp
  [[ ! -e ${target} || ( -f ${target} && ! -L ${target} ) ]] \
    || die "Keycloak client Secret 상태 경로가 일반 파일이 아님: ${target}"
  response=$(mktemp "${CREDENTIAL_DIR}/.keycloak-client-response.XXXXXX")
  value_tmp=$(mktemp "${CREDENTIAL_DIR}/.keycloak-client-secret.XXXXXX")
  temporary_secret_files+=("${response}" "${value_tmp}")
  kc get "clients/${client_uuid}/client-secret" -r "${KEYCLOAK_REALM}" >"${response}"
  jq -jer '.value | select(type == "string" and length > 0)' "${response}" >"${value_tmp}" \
    || die "Keycloak client Secret 회수 실패"
  chmod 0600 "${value_tmp}"
  chown 0:0 "${value_tmp}"
  mv -fT "${value_tmp}" "${target}"
  rm -f "${response}"
}

ensure_groups_mapper() {
  local client_uuid=$1 rows count mapper_id document
  rows=$(kc get "clients/${client_uuid}/protocol-mappers/models" -r "${KEYCLOAK_REALM}")
  count=$(jq '[.[] | select(.name == "groups")] | length' <<<"${rows}")
  ((count <= 1)) || die "Keycloak groups protocol mapper가 둘 이상임"
  mapper_id=$(jq -r '.[] | select(.name == "groups") | .id' <<<"${rows}")
  document=$(jq -nc --arg id "${mapper_id}" '{
    name:"groups", protocol:"openid-connect", protocolMapper:"oidc-group-membership-mapper",
    config:{"full.path":"false", "claim.name":"groups", "id.token.claim":"true",
      "access.token.claim":"true", "userinfo.token.claim":"true"}
  } + (if $id == "" then {} else {id:$id} end)')
  if [[ -z ${mapper_id} ]]; then
    kc_input create "clients/${client_uuid}/protocol-mappers/models" -r "${KEYCLOAK_REALM}" \
      -f - <<<"${document}" >/dev/null
  else
    kc_input update "clients/${client_uuid}/protocol-mappers/models/${mapper_id}" \
      -r "${KEYCLOAK_REALM}" -f - <<<"${document}" >/dev/null
  fi
}

ensure_client() {
  local client_id=$1 secret_file=$2 redirects=$3 origins=$4 post_logout=$5
  local clients count client_uuid document
  clients=$(kc get clients -r "${KEYCLOAK_REALM}" -q clientId="${client_id}")
  count=$(jq --arg client "${client_id}" '[.[] | select(.clientId == $client)] | length' \
    <<<"${clients}")
  ((count <= 1)) || die "Keycloak client ${client_id}가 둘 이상임"
  client_uuid=$(jq -r --arg client "${client_id}" \
    '.[] | select(.clientId == $client) | .id' <<<"${clients}")
  document=$(jq -nc --arg client_id "${client_id}" --argjson redirects "${redirects}" \
    --argjson origins "${origins}" --arg post_logout "${post_logout}" '{
      clientId:$client_id, enabled:true, publicClient:false,
      clientAuthenticatorType:"client-secret", standardFlowEnabled:true,
      directAccessGrantsEnabled:false, redirectUris:$redirects, webOrigins:$origins,
      attributes:{"post.logout.redirect.uris":$post_logout}
    }')
  if [[ -z ${client_uuid} ]]; then
    # secret을 요청 문서에 주지 않아 Keycloak이 새 client의 값을 생성하게 한다.
    client_uuid=$(kc_input create clients -r "${KEYCLOAK_REALM}" -i -f - <<<"${document}")
  else
    # update 문서에 secret을 넣지 않으므로 기존 client는 임의 회전되지 않는다.
    kc_input update "clients/${client_uuid}" -r "${KEYCLOAK_REALM}" -f - \
      <<<"${document}" >/dev/null
  fi
  ensure_groups_mapper "${client_uuid}"
  atomic_store_client_secret "${client_uuid}" "${secret_file}"
  ENSURED_CLIENT_UUID=${client_uuid}
}

ensure_client secure-demo-prod "${CREDENTIAL_DIR}/keycloak-secure-demo-client-secret" \
  "[\"https://${SECURE_DEMO_HOST}/oauth2/callback\"]" \
  "[\"https://${SECURE_DEMO_HOST}\"]" ""
ensure_client openbao "${CREDENTIAL_DIR}/keycloak-openbao-client-secret" \
  "[\"https://${OPENBAO_HOST}/ui/vault/auth/oidc/oidc/callback\",\"http://localhost:8250/oidc/callback\"]" \
  "[\"https://${OPENBAO_HOST}\"]" ""
ensure_client "${PORTAL_CLIENT_ID}" "${CREDENTIAL_DIR}/keycloak-portal-client-secret" \
  "[\"https://${PORTAL_HOST}/api/auth/callback/keycloak\"]" \
  "[\"https://${PORTAL_HOST}\"]" "https://${PORTAL_HOST}/portal"
portal_client_uuid=${ENSURED_CLIENT_UUID}

for role in platform-admin viewer; do
  kc get "roles/${role}" -r "${KEYCLOAK_REALM}" >/dev/null 2>&1 \
    || kc create roles -r "${KEYCLOAK_REALM}" -s name="${role}" >/dev/null
  kc get "clients/${portal_client_uuid}/roles/${role}" -r "${KEYCLOAK_REALM}" >/dev/null 2>&1 \
    || kc create "clients/${portal_client_uuid}/roles" -r "${KEYCLOAK_REALM}" \
      -s name="${role}" >/dev/null
  kc add-roles -r "${KEYCLOAK_REALM}" --gname "${role}" --rolename "${role}" \
    >/dev/null
  kc add-roles -r "${KEYCLOAK_REALM}" --gname "${role}" --cclientid "${PORTAL_CLIENT_ID}" \
    --rolename "${role}" >/dev/null
done

TRUSTED_FIRST_LOGIN_FLOW=sadp-trusted-saml-first-login
STABLE_SAML_USERNAME_TEMPLATE='${ATTRIBUTE.http://schemas.goauthentik.io/2021/02/saml/username}'
ensure_trusted_first_login_flow() {
  local flows count executions provider execution_id document
  flows=$(kc get authentication/flows -r "${KEYCLOAK_REALM}")
  count=$(jq --arg alias "${TRUSTED_FIRST_LOGIN_FLOW}" \
    '[.[] | select(.alias == $alias)] | length' <<<"${flows}")
  ((count <= 1)) || die "Keycloak trusted SAML first-login flow가 둘 이상임"
  if ((count == 0)); then
    document=$(jq -nc --arg alias "${TRUSTED_FIRST_LOGIN_FLOW}" '{
      alias:$alias, description:"SADP trusted SAML first login",
      providerId:"basic-flow", topLevel:true, builtIn:false
    }')
    kc_input create authentication/flows -r "${KEYCLOAK_REALM}" -f - \
      <<<"${document}" >/dev/null
  fi
  for provider in idp-create-user-if-unique idp-auto-link; do
    executions=$(kc get "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions" \
      -r "${KEYCLOAK_REALM}")
    count=$(jq --arg provider "${provider}" \
      '[.[] | select(.providerId == $provider)] | length' <<<"${executions}")
    ((count <= 1)) || die "Keycloak first-login execution ${provider}가 둘 이상임"
    if ((count == 0)); then
      jq -nc --arg provider "${provider}" '{provider:$provider}' |
        kc_input create "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions/execution" \
          -r "${KEYCLOAK_REALM}" -f - >/dev/null
      executions=$(kc get "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions" \
        -r "${KEYCLOAK_REALM}")
    fi
    execution_id=$(jq -er --arg provider "${provider}" \
      '.[] | select(.providerId == $provider) | .id' <<<"${executions}")
    jq -nc --arg id "${execution_id}" '{id:$id, requirement:"ALTERNATIVE"}' |
      kc_input update "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions" \
        -r "${KEYCLOAK_REALM}" -f - >/dev/null
  done
}

ensure_idp_mapper() {
  local mapper_kind=$1 mapper_name=$2 document=$3 rows count mapper_id update_document
  rows=$(kc get "identity-provider/instances/${IDP_ALIAS}/mappers" -r "${KEYCLOAK_REALM}")
  count=$(jq --arg name "${mapper_name}" '[.[] | select(.name == $name)] | length' \
    <<<"${rows}")
  ((count <= 1)) || die "Keycloak IdP mapper ${mapper_name}이 둘 이상임"
  mapper_id=$(jq -r --arg name "${mapper_name}" '.[] | select(.name == $name) | .id' \
    <<<"${rows}")
  if [[ -z ${mapper_id} ]]; then
    kc_input create "identity-provider/instances/${IDP_ALIAS}/mappers" \
      -r "${KEYCLOAK_REALM}" -f - <<<"${document}" >/dev/null
  else
    update_document=$(jq --arg id "${mapper_id}" '. + {id:$id}' <<<"${document}")
    kc_input update "identity-provider/instances/${IDP_ALIAS}/mappers/${mapper_id}" \
      -r "${KEYCLOAK_REALM}" -f - <<<"${update_document}" >/dev/null
  fi
}

if [[ -n ${IDP_ALIAS} ]]; then
  ensure_trusted_first_login_flow
  idp_args=(
    -r "${KEYCLOAK_REALM}" -s alias="${IDP_ALIAS}" -s displayName="${IDP_DISPLAY_NAME}"
    -s providerId="${IDP_PROVIDER_ID}" -s enabled=true -s trustEmail=true
    -s firstBrokerLoginFlowAlias="${TRUSTED_FIRST_LOGIN_FLOW}"
    -s 'config."useMetadataDescriptorUrl"=true'
    -s "config.\"metadataDescriptorUrl\"=${IDP_METADATA_URL}"
    -s "config.\"singleSignOnServiceUrl\"=${IDP_SSO_URL}"
    -s "config.\"entityId\"=${KEYCLOAK_SAML_SP_ENTITY_ID}"
    -s 'config."validateSignature"=true' -s 'config."wantAssertionsSigned"=true'
    -s 'config."wantAuthnRequestsSigned"=false' -s 'config."principalType"=SUBJECT'
    -s 'config."nameIDPolicyFormat"=urn:oasis:names:tc:SAML:2.0:nameid-format:persistent'
    -s 'config."syncMode"=IMPORT'
  )
  if kc get "identity-provider/instances/${IDP_ALIAS}" -r "${KEYCLOAK_REALM}" >/dev/null 2>&1; then
    kc update "identity-provider/instances/${IDP_ALIAS}" "${idp_args[@]}" >/dev/null
  else
    kc create identity-provider/instances "${idp_args[@]}" >/dev/null
  fi
  username_mapper_document=$(jq -nc --arg name sadp-stable-saml-username \
    --arg alias "${IDP_ALIAS}" --arg template "${STABLE_SAML_USERNAME_TEMPLATE}" '{
      name:$name, identityProviderAlias:$alias,
      identityProviderMapper:"saml-username-idp-mapper",
      config:{syncMode:"IMPORT", template:$template, target:"LOCAL"}
    }')
  ensure_idp_mapper saml-username-idp-mapper sadp-stable-saml-username \
    "${username_mapper_document}"
  developer_mapper_document=$(jq -nc --arg alias "${IDP_ALIAS}" '{
    name:"portal-default-developer", identityProviderAlias:$alias,
    identityProviderMapper:"oidc-hardcoded-group-idp-mapper",
    config:{syncMode:"FORCE", group:"/developer"}
  }')
  ensure_idp_mapper oidc-hardcoded-group-idp-mapper portal-default-developer \
    "${developer_mapper_document}"
fi

users=$(kc get users -r "${KEYCLOAK_REALM}")
user_id=$(jq -r --rawfile username "${CREDENTIAL_DIR}/keycloak-test-user" '
  ($username | sub("[\\r\\n]+$"; "")) as $wanted
  | .[] | select(.username == $wanted) | .id
' <<<"${users}" | head -n1)
user_document=$(jq -nc --rawfile username "${CREDENTIAL_DIR}/keycloak-test-user" \
  --arg domain "${BASE_DOMAIN}" '{
    username:($username | sub("[\\r\\n]+$"; "")), enabled:true, emailVerified:true,
    email:(($username | sub("[\\r\\n]+$"; "")) + "@" + $domain),
    firstName:"SADP", lastName:"Tester"
  }')
if [[ -z ${user_id} ]]; then
  user_id=$(kc_input create users -r "${KEYCLOAK_REALM}" -i -f - <<<"${user_document}")
fi
kc_input update "users/${user_id}" -r "${KEYCLOAK_REALM}" -f - \
  <<<"${user_document}" >/dev/null
jq -nc --rawfile value "${CREDENTIAL_DIR}/keycloak-test-password" '{
  type:"password", value:($value | sub("[\\r\\n]+$"; "")), temporary:false
}' | kc_input update "users/${user_id}/reset-password" -r "${KEYCLOAK_REALM}" -f - >/dev/null
for group in platform-admin viewer; do
  group_id=$(kc get groups -r "${KEYCLOAK_REALM}" -q search="${group}" |
    jq -r --arg group "${group}" '.[] | select(.name == $group) | .id' | head -n1)
  [[ -n ${group_id} ]] || die "Keycloak acceptance user 대상 group ${group} 누락"
  kc update "users/${user_id}/groups/${group_id}" -r "${KEYCLOAK_REALM}" -n \
    >/dev/null
done

ok "Keycloak realm/group/client/role/acceptance user 계약 수렴(값은 출력하지 않음)"
