#!/usr/bin/env bash
# Keycloak realm/client/user와 OpenBao auth/policy/KV를 값 노출 없이 초기화한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"
source "$(dirname "$0")/../lib/machine-auth.sh"

ROTATE_TEST_PASSWORD=false
while (($#)); do
  case "$1" in
    --rotate-test-password) ROTATE_TEST_PASSWORD=true ;;
    -h|--help)
      echo "usage: sudo $0 [--rotate-test-password]"
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done

require_root
for command in jq openssl python3; do require_command "${command}"; done
ensure_state_dirs
cd "${TESTBED_ROOT}"

if [[ ${ROTATE_TEST_PASSWORD} == true ]]; then
  rotated_password=$(openssl rand -hex 32)
  rotated_file=$(mktemp "${CREDENTIAL_DIR}/.keycloak-test-password.XXXXXX")
  printf '%s' "${rotated_password}" >"${rotated_file}"
  install -m 0600 "${rotated_file}" "${CREDENTIAL_DIR}/keycloak-test-password"
  rm -f "${rotated_file}"
  unset rotated_password
  ok "Keycloak test user credential file 회전(값은 출력하지 않음)"
fi

mapfile -t contract_values < <(python3 - <<'PY'
import re
import shlex
import yaml
doc = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))
keycloak = doc["spec"]["keycloak"]
idp = keycloak.get("identityProvider") or {}
print(doc["spec"]["baseDomain"])
for key in ("alias", "displayName", "providerId", "metadataDescriptorUrl", "singleSignOnServiceUrl"):
    print(str(idp.get(key) or ""))
# realm/client/issuer 를 박아 두면 다른 realm 을 쓰는 사이트에서 없는 realm 을 만들거나
# 앱이 못 쓰는 issuer 를 OpenBao 에 넣는다. 계약이 정한 값을 그대로 쓴다.
print(str(keycloak.get("realm") or ""))
print(str(keycloak.get("portalClientID") or ""))
print(str(keycloak.get("issuer") or ""))
print(str(keycloak.get("samlSpEntityId") or keycloak.get("issuer") or ""))
portal = yaml.safe_load(open("apps/portal-lite/values-beta.yaml", encoding="utf-8"))
print(str((portal.get("exposure") or {}).get("host") or ""))
PY
)
BASE_DOMAIN=${contract_values[0]}
IDP_ALIAS=${contract_values[1]}
IDP_DISPLAY_NAME=${contract_values[2]}
IDP_PROVIDER_ID=${contract_values[3]}
IDP_METADATA_URL=${contract_values[4]}
IDP_SSO_URL=${contract_values[5]}
KEYCLOAK_REALM=${contract_values[6]:?계약에 keycloak.realm 이 없다}
PORTAL_CLIENT_ID=${contract_values[7]:?계약에 keycloak.portalClientID 가 없다}
KEYCLOAK_ISSUER=${contract_values[8]:?계약에 keycloak.issuer 가 없다}
KEYCLOAK_SAML_SP_ENTITY_ID=${contract_values[9]:?계약에 keycloak.samlSpEntityId 가 없다}
PORTAL_HOST=${contract_values[10]:?Portal values에 exposure.host가 없다}
SECURE_DEMO_HOST=secure-demo.${BASE_DOMAIN}
OPENBAO_HOST=openbao.${BASE_DOMAIN}

if keycloak_is_external; then
  # 외부 Keycloak의 최초 realm/client/IdP 생성은 VM 책임이다. 이후 보안 정책은 SSH로
  # 원격 수렴시키고, in-cluster 전용 test user/client 생성만 건너뛴다.
  note "Keycloak deployment=external: 기존 realm 정책을 외부 VM에 원격 수렴한다"
  note "절차는 docs/keycloak-external.md 를 따른다"
  # 외부 VM의 관리자 Secret은 VM 밖으로 복사하지 않는다. SSH로 최신 수렴 스크립트만
  # 보내 원격 EnvironmentFile을 읽게 한다. client secret은 현재 Keycloak 값을 수렴 성공
  # 뒤 암호화된 SSH 응답으로 회수하므로 stale 로컬 파일이나 임의 생성값을 시드하지 않는다.
  bash scripts/cluster/configure-external-keycloak.sh --apply
  for credential in keycloak-secure-demo-client-secret keycloak-portal-client-secret \
    keycloak-openbao-client-secret; do
    [[ -s ${CREDENTIAL_DIR}/${credential} ]] || die \
      "외부 Keycloak 현재 client secret 회수 실패: ${CREDENTIAL_DIR}/${credential}"
    [[ $(stat -c '%a' "${CREDENTIAL_DIR}/${credential}") == 600 ]] \
      || die "외부 Keycloak client secret 파일 mode가 0600이 아님: ${credential}"
  done
  # Auth.js 서명 키는 Keycloak 과 무관한 클러스터 자체 값이라 여기서 만들어도 된다.
  ensure_random_file "${CREDENTIAL_DIR}/portal-auth-secret"
else
kctl rollout status -n keycloak deployment/keycloak --timeout=15m >/dev/null

kc() { kctl exec -n keycloak deploy/keycloak -- /opt/keycloak/bin/kcadm.sh "$@"; }
kc_input() { kctl exec -i -n keycloak deploy/keycloak -- /opt/keycloak/bin/kcadm.sh "$@"; }
# kcadm의 --password는 파일 입력 옵션이 없다. host의 kubectl exec command에 값을 넣으면
# apiserver audit requestURI와 프로세스 목록에 남으므로, 고정된 Pod-side shell에만 stdin으로
# 넘긴다. Pod 안에서 짧게 argv가 되는 것은 kcadm 자체 제약이며 host/API에는 값이 보이지 않는다.
kc_login_from_files() {
  local user_file=$1 password_file=$2 legacy_newline=${3:-false}
  {
    tr -d '\r\n' <"${user_file}" | base64 -w0
    printf '\n'
    tr -d '\r\n' <"${password_file}" | base64 -w0
    printf '\n'
  } | kctl exec -i -n keycloak deploy/keycloak -- sh -ceu '
    IFS= read -r encoded_user
    IFS= read -r encoded_password
    user=$(printf "%s" "$encoded_user" | base64 -d)
    password=$(printf "%s" "$encoded_password" | base64 -d)
    if [ "$1" = true ]; then
      password="${password}
"
    fi
    exec /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://localhost:8080 --realm master --user "$user" --password "$password"
  ' sh "${legacy_newline}"
}

set_user_password() {
  local realm=$1 user_id=$2 password_file=$3
  jq -nc --rawfile value "${password_file}" \
    '{type:"password", value:($value | sub("[\\r\\n]+$"; "")), temporary:false}' |
    kc_input update "users/${user_id}/reset-password" -r "${realm}" -f - >/dev/null
}
if ! kc_login_from_files "${CREDENTIAL_DIR}/keycloak-admin-user" \
  "${CREDENTIAL_DIR}/keycloak-admin-password" false >/dev/null 2>&1; then
  # Older bootstrap runs wrote openssl output with a trailing LF and Kubernetes
  # correctly preserved that byte in the environment variable. Recover once,
  # then normalize both Keycloak and the root-only credential file.
  kc_login_from_files "${CREDENTIAL_DIR}/keycloak-admin-user" \
    "${CREDENTIAL_DIR}/keycloak-admin-password" true >/dev/null
  admin_user_id=$(kc get users -r master |
    jq -r --rawfile username "${CREDENTIAL_DIR}/keycloak-admin-user" \
      '($username | sub("[\\r\\n]+$"; "")) as $wanted | .[] | select(.username == $wanted) | .id' |
    head -n1)
  [[ -n ${admin_user_id} ]] || die "Keycloak master admin user를 찾지 못함"
  normalized_password=$(mktemp "${CREDENTIAL_DIR}/.keycloak-admin-password.XXXXXX")
  tr -d '\r\n' <"${CREDENTIAL_DIR}/keycloak-admin-password" >"${normalized_password}"
  set_user_password master "${admin_user_id}" "${normalized_password}"
  install -m 0600 "${normalized_password}" "${CREDENTIAL_DIR}/keycloak-admin-password"
  rm -f "${normalized_password}"
  apply_generic_secret_from_files keycloak keycloak-bootstrap \
    --from-file=username="${CREDENTIAL_DIR}/keycloak-admin-user" \
    --from-file=password="${CREDENTIAL_DIR}/keycloak-admin-password"
  ok "legacy Keycloak bootstrap 비밀번호의 trailing newline 정규화"
fi
if ! kc get realms/${KEYCLOAK_REALM} >/dev/null 2>&1; then
  kc create realms -s realm="${KEYCLOAK_REALM}" -s enabled=true -s sslRequired=external \
    -s registrationAllowed=false -s duplicateEmailsAllowed=false -s editUsernameAllowed=false \
    -s bruteForceProtected=true -s failureFactor=5 >/dev/null
else
  kc update realms/${KEYCLOAK_REALM} -s enabled=true -s sslRequired=external \
    -s registrationAllowed=false -s duplicateEmailsAllowed=false -s editUsernameAllowed=false \
    -s bruteForceProtected=true -s failureFactor=5 >/dev/null
fi

for group in platform-admin app-admin developer viewer; do
  groups=$(kc get groups -r "${KEYCLOAK_REALM}" -q search="${group}")
  if ! jq -e --arg group "${group}" '.[] | select(.name == $group)' <<<"${groups}" >/dev/null; then
    kc create groups -r "${KEYCLOAK_REALM}" -s name="${group}" >/dev/null
  fi
done

# 연합 IdP로 처음 들어온 사용자는 realm에 새로 import된다. developer Realm Default
# Group은 최초 생성 경계를 지키고, 아래 IdP mapper는 기존 연합 사용자도 다음 로그인 때
# 같은 그룹으로 수렴시킨다. defaultGroups 배열 전체를 바꾸면 운영자가 추가한 기본 그룹을
# 덮어쓸 수 있으므로 여기서는 group ID 전용 endpoint만 반복 안전하게 호출한다.
developer_groups=$(kc get groups -r "${KEYCLOAK_REALM}" -q search=developer)
developer_group_id=$(jq -er '
  [.[] | select(.name == "developer")] as $matches
  | select(($matches | length) == 1)
  | $matches[0].id
' <<<"${developer_groups}") || die "Keycloak developer group을 정확히 하나 찾지 못함"
kc update "default-groups/${developer_group_id}" -r "${KEYCLOAK_REALM}" -n >/dev/null
default_groups=$(kc get default-groups -r "${KEYCLOAK_REALM}")
jq -e --arg id "${developer_group_id}" \
  '.[] | select(.id == $id and .name == "developer")' <<<"${default_groups}" >/dev/null \
  || die "Keycloak developer 기본 그룹 적용 후 검증 실패"
ok "Keycloak 신규 사용자 기본 그룹 developer 적용"

ensure_client() {
  local client_id=$1 secret_file=$2 redirects=$3 origins=$4 post_logout=${5:-}
  local clients id
  clients=$(kc get clients -r "${KEYCLOAK_REALM}" -q clientId="${client_id}")
  id=$(jq -r '.[0].id // empty' <<<"${clients}")
  client_document() {
    jq -nc --arg client_id "${client_id}" --rawfile secret "${secret_file}" \
      --argjson redirects "${redirects}" --argjson origins "${origins}" \
      --arg post_logout "${post_logout}" '{
        clientId:$client_id, enabled:true, publicClient:false,
        clientAuthenticatorType:"client-secret", standardFlowEnabled:true,
        directAccessGrantsEnabled:false,
        secret:($secret | sub("[\\r\\n]+$"; "")),
        redirectUris:$redirects, webOrigins:$origins
      } + (if $post_logout == "" then {} else {
        attributes:{"post.logout.redirect.uris":$post_logout}
      } end)'
  }
  if [[ -z ${id} ]]; then
    id=$(client_document | kc_input create clients -r "${KEYCLOAK_REALM}" -i -f -)
  else
    client_document | kc_input update "clients/${id}" -r "${KEYCLOAK_REALM}" -f - >/dev/null
  fi
  mappers=$(kc get "clients/${id}/protocol-mappers/models" -r "${KEYCLOAK_REALM}")
  if ! jq -e '.[] | select(.name == "groups")' <<<"${mappers}" >/dev/null; then
    kc create "clients/${id}/protocol-mappers/models" -r "${KEYCLOAK_REALM}" \
      -s name=groups -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
      -s 'config."full.path"=false' -s 'config."claim.name"=groups' \
      -s 'config."id.token.claim"=true' -s 'config."access.token.claim"=true' \
      -s 'config."userinfo.token.claim"=true' >/dev/null
  fi
  ENSURED_CLIENT_UUID=${id}
}

# redirect URI 는 반드시 큰따옴표로 감싼다. 작은따옴표면 ${..._HOST} 가 확장되지 않아
# 리터럴 문자열이 client 에 등록되고 로그인이 조용히 깨진다.
#
# clientId 는 charts/app-profile/templates/securitypolicy.yaml 이 만드는
# "<app.name>-<app.environment>" 와 반드시 같아야 한다. 다르면 SecurityPolicy 는
# discovery 만 보고 Accepted 가 되고, 실제 로그인에서야 Keycloak 이 client 를 못 찾는다.
ensure_client secure-demo-prod "${CREDENTIAL_DIR}/keycloak-secure-demo-client-secret" \
  "[\"https://${SECURE_DEMO_HOST}/oauth2/callback\"]" \
  "[\"https://${SECURE_DEMO_HOST}\"]"
ensure_client openbao "${CREDENTIAL_DIR}/keycloak-openbao-client-secret" \
  "[\"https://${OPENBAO_HOST}/ui/vault/auth/oidc/oidc/callback\",\"http://localhost:8250/oidc/callback\"]" \
  "[\"https://${OPENBAO_HOST}\"]"
ensure_client "${PORTAL_CLIENT_ID}" "${CREDENTIAL_DIR}/keycloak-portal-client-secret" \
  "[\"https://${PORTAL_HOST}/api/auth/callback/keycloak\"]" \
  "[\"https://${PORTAL_HOST}\"]" \
  "https://${PORTAL_HOST}/portal"
portal_client_uuid=${ENSURED_CLIENT_UUID}

# 그룹명과 같은 realm/client role을 매핑해 토큰의 realm_access와
# resource_access.portal-beta를 모두 서버 세션에서 검증할 수 있게 한다.
for role in platform-admin viewer; do
  if ! kc get "roles/${role}" -r "${KEYCLOAK_REALM}" >/dev/null 2>&1; then
    kc create roles -r "${KEYCLOAK_REALM}" -s name="${role}" >/dev/null
  fi
  if ! kc get "clients/${portal_client_uuid}/roles/${role}" -r "${KEYCLOAK_REALM}" >/dev/null 2>&1; then
    kc create "clients/${portal_client_uuid}/roles" -r "${KEYCLOAK_REALM}" -s name="${role}" >/dev/null
  fi
  kc add-roles -r "${KEYCLOAK_REALM}" --gname "${role}" --rolename "${role}" >/dev/null 2>&1 || true
  kc add-roles -r "${KEYCLOAK_REALM}" --gname "${role}" --cclientid "${PORTAL_CLIENT_ID}" \
    --rolename "${role}" >/dev/null 2>&1 || true
done

# First Broker Login은 client별 가입이 아니라 realm의 IdP 연결 경계다. 이 flow를 IdP에
# 한 번 묶으면 이후 설치하는 모든 OIDC 앱도 같은 LIFE 계정을 재사용한다. 서명된 사내 IdP와
# 가입/중복/이름 변경이 닫힌 realm에서만 이메일 자동 연결을 허용한다.
TRUSTED_FIRST_LOGIN_FLOW=sadp-trusted-saml-first-login
STABLE_SAML_USERNAME_TEMPLATE='${ATTRIBUTE.http://schemas.goauthentik.io/2021/02/saml/username}'
ensure_trusted_first_login_flow() {
  local flows flow_count flow_document executions provider execution_count execution_id
  flows=$(kc get authentication/flows -r "${KEYCLOAK_REALM}")
  flow_count=$(jq --arg alias "${TRUSTED_FIRST_LOGIN_FLOW}" \
    '[.[] | select(.alias == $alias)] | length' <<<"${flows}")
  ((flow_count <= 1)) || die "Keycloak trusted SAML first login flow가 둘 이상임"
  if ((flow_count == 0)); then
    flow_document=$(jq -nc --arg alias "${TRUSTED_FIRST_LOGIN_FLOW}" '{
      alias:$alias,
      description:"서명된 LIFE SAML 사용자를 입력 화면 없이 생성하거나 기존 계정에 연결한다.",
      providerId:"basic-flow", topLevel:true, builtIn:false
    }')
    kc_input create authentication/flows -r "${KEYCLOAK_REALM}" -f - \
      <<<"${flow_document}" >/dev/null
  fi

  for provider in idp-create-user-if-unique idp-auto-link; do
    executions=$(kc get "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions" \
      -r "${KEYCLOAK_REALM}")
    execution_count=$(jq --arg provider "${provider}" \
      '[.[] | select(.providerId == $provider)] | length' <<<"${executions}")
    ((execution_count <= 1)) \
      || die "Keycloak first login execution '${provider}'가 둘 이상임"
    if ((execution_count == 0)); then
      jq -nc --arg provider "${provider}" '{provider:$provider}' |
        kc_input create \
          "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions/execution" \
          -r "${KEYCLOAK_REALM}" -f - >/dev/null
      executions=$(kc get "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions" \
        -r "${KEYCLOAK_REALM}")
    fi
    execution_id=$(jq -er --arg provider "${provider}" \
      '.[] | select(.providerId == $provider) | .id' <<<"${executions}") \
      || die "Keycloak first login execution '${provider}' 생성 실패"
    jq -nc --arg id "${execution_id}" '{id:$id, requirement:"ALTERNATIVE"}' |
      kc_input update "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions" \
        -r "${KEYCLOAK_REALM}" -f - >/dev/null
  done

  executions=$(kc get "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions" \
    -r "${KEYCLOAK_REALM}")
  jq -e '
    length == 2
    and ([.[] | select(
      .providerId == "idp-create-user-if-unique" and .requirement == "ALTERNATIVE"
    )] | length == 1)
    and ([.[] | select(
      .providerId == "idp-auto-link" and .requirement == "ALTERNATIVE"
    )] | length == 1)
  ' <<<"${executions}" >/dev/null \
    || die "Keycloak trusted SAML first login flow 검증 실패"
}
ensure_trusted_first_login_flow

# 선택적 상위 SAML IdP. alias는 로그인 URL에 박히므로 다음 서버에서도
# 계약의 값을 그대로 쓴다. 서명 검증은 metadata descriptor에서 받아오므로
# 인증서를 스크립트에 박지 않는다.
ensure_identity_provider() {
  local alias=$1 display=$2 provider=$3 metadata_url=$4 sso_url=$5 sp_entity_id=$6
  [[ -z ${alias} || -z ${metadata_url} ]] && return 0
  local args=(
    -r "${KEYCLOAK_REALM}"
    -s alias="${alias}"
    -s displayName="${display}"
    -s providerId="${provider}"
    -s enabled=true
    -s trustEmail=true
    -s firstBrokerLoginFlowAlias="${TRUSTED_FIRST_LOGIN_FLOW}"
    -s 'config."useMetadataDescriptorUrl"=true'
    -s "config.\"metadataDescriptorUrl\"=${metadata_url}"
    -s "config.\"singleSignOnServiceUrl\"=${sso_url}"
    -s "config.\"entityId\"=${sp_entity_id}"
    -s 'config."validateSignature"=true'
    -s 'config."wantAssertionsSigned"=true'
    -s 'config."wantAuthnRequestsSigned"=false'
    -s 'config."principalType"=SUBJECT'
    -s 'config."nameIDPolicyFormat"=urn:oasis:names:tc:SAML:2.0:nameid-format:persistent'
    -s 'config."syncMode"=IMPORT'
    -s 'config."postBindingResponse"=false'
    -s 'config."postBindingAuthnRequest"=false'
  )
  if kc get "identity-provider/instances/${alias}" -r "${KEYCLOAK_REALM}" >/dev/null 2>&1; then
    kc update "identity-provider/instances/${alias}" "${args[@]}" >/dev/null
  else
    kc create identity-provider/instances "${args[@]}" >/dev/null
  fi
}
ensure_identity_provider "${IDP_ALIAS}" "${IDP_DISPLAY_NAME}" "${IDP_PROVIDER_ID}" \
  "${IDP_METADATA_URL}" "${IDP_SSO_URL}" "${KEYCLOAK_SAML_SP_ENTITY_ID}"

# Realm default group은 최초 import 뒤에는 다시 적용되지 않는다. Hardcoded Group
# mapper의 FORCE sync가 매 SAML 로그인에서 /developer를 보장해야 기존 사용자도 포털에
# 들어올 수 있다. mapper가 IdP보다 먼저 만들어질 수 없어서 IdP 구성 직후에 둔다.
if [[ -n ${IDP_ALIAS} ]]; then
  [[ ${IDP_PROVIDER_ID} == saml ]] \
    || die "trusted username mapper는 SAML IdP에서만 적용 가능"
  mapper_rows=$(kc get "identity-provider/instances/${IDP_ALIAS}/mappers" -r "${KEYCLOAK_REALM}")
  username_mapper_count=$(jq \
    '[.[] | select(.identityProviderMapper == "saml-username-idp-mapper")] | length' \
    <<<"${mapper_rows}")
  ((username_mapper_count <= 1)) \
    || die "Keycloak SAML username mapper가 둘 이상이라 대상을 결정할 수 없음"
  username_mapper_id=$(jq -r \
    '.[] | select(.identityProviderMapper == "saml-username-idp-mapper") | .id' \
    <<<"${mapper_rows}")
  username_mapper_name=$(jq -r \
    '.[] | select(.identityProviderMapper == "saml-username-idp-mapper") | .name' \
    <<<"${mapper_rows}")
  username_mapper_name=${username_mapper_name:-sadp-stable-saml-username}
  username_mapper_document=$(jq -nc --arg name "${username_mapper_name}" \
    --arg alias "${IDP_ALIAS}" --arg template "${STABLE_SAML_USERNAME_TEMPLATE}" '{
      name:$name,
      identityProviderAlias:$alias,
      identityProviderMapper:"saml-username-idp-mapper",
      config:{syncMode:"IMPORT", template:$template, target:"LOCAL"}
    }')
  if [[ -z ${username_mapper_id} ]]; then
    username_mapper_id=$(kc_input create "identity-provider/instances/${IDP_ALIAS}/mappers" \
      -r "${KEYCLOAK_REALM}" -i -f - <<<"${username_mapper_document}")
  else
    username_mapper_update=$(jq --arg id "${username_mapper_id}" '. + {id:$id}' \
      <<<"${username_mapper_document}")
    kc_input update "identity-provider/instances/${IDP_ALIAS}/mappers/${username_mapper_id}" \
      -r "${KEYCLOAK_REALM}" -f - <<<"${username_mapper_update}" >/dev/null
  fi
  kc get "identity-provider/instances/${IDP_ALIAS}/mappers/${username_mapper_id}" \
    -r "${KEYCLOAK_REALM}" | jq -e --arg template "${STABLE_SAML_USERNAME_TEMPLATE}" '
      .identityProviderMapper == "saml-username-idp-mapper"
      and .config.syncMode == "IMPORT"
      and .config.template == $template
      and .config.target == "LOCAL"
  ' >/dev/null || die "Keycloak SAML Authentik username URI mapper 검증 실패"

  mapper_name=portal-default-developer
  mapper_rows=$(kc get "identity-provider/instances/${IDP_ALIAS}/mappers" -r "${KEYCLOAK_REALM}")
  mapper_count=$(jq --arg name "${mapper_name}" \
    '[.[] | select(.name == $name)] | length' <<<"${mapper_rows}")
  ((mapper_count <= 1)) || die "Keycloak developer IdP mapper가 둘 이상이라 대상을 결정할 수 없음"
  mapper_id=$(jq -r --arg name "${mapper_name}" \
    '.[] | select(.name == $name) | .id' <<<"${mapper_rows}")
  mapper_document=$(jq -nc --arg name "${mapper_name}" --arg alias "${IDP_ALIAS}" '{
    name:$name,
    identityProviderAlias:$alias,
    identityProviderMapper:"oidc-hardcoded-group-idp-mapper",
    config:{syncMode:"FORCE", group:"/developer"}
  }')
  if [[ -z ${mapper_id} ]]; then
    mapper_id=$(kc_input create "identity-provider/instances/${IDP_ALIAS}/mappers" \
      -r "${KEYCLOAK_REALM}" -i -f - <<<"${mapper_document}")
  else
    kc_input update "identity-provider/instances/${IDP_ALIAS}/mappers/${mapper_id}" \
      -r "${KEYCLOAK_REALM}" -f - <<<"${mapper_document}" >/dev/null
  fi
  kc get "identity-provider/instances/${IDP_ALIAS}/mappers/${mapper_id}" \
    -r "${KEYCLOAK_REALM}" | jq -e '
      .identityProviderMapper == "oidc-hardcoded-group-idp-mapper"
      and .config.syncMode == "FORCE"
      and .config.group == "/developer"
    ' >/dev/null || die "Keycloak developer IdP mapper 적용 후 검증 실패"
  ok "Keycloak SAML Authentik username URI/developer 그룹 매퍼 적용"
fi

users=$(kc get users -r "${KEYCLOAK_REALM}")
user_id=$(jq -r --rawfile username "${CREDENTIAL_DIR}/keycloak-test-user" \
  '($username | sub("[\\r\\n]+$"; "")) as $wanted | .[] | select(.username == $wanted) | .id' \
  <<<"${users}" | head -n1)
if [[ -z ${user_id} ]]; then
  user_id=$(jq -nc --rawfile username "${CREDENTIAL_DIR}/keycloak-test-user" \
    --arg domain "${BASE_DOMAIN}" '{
      username:($username | sub("[\\r\\n]+$"; "")), enabled:true, emailVerified:true,
      email:(($username | sub("[\\r\\n]+$"; "")) + "@" + $domain)
    }' | kc_input create users -r "${KEYCLOAK_REALM}" -i -f -)
fi
jq -nc --rawfile username "${CREDENTIAL_DIR}/keycloak-test-user" --arg domain "${BASE_DOMAIN}" '{
  username:($username | sub("[\\r\\n]+$"; "")), enabled:true, emailVerified:true,
  email:(($username | sub("[\\r\\n]+$"; "")) + "@" + $domain),
  firstName:"SADP", lastName:"Tester"
}' | kc_input update "users/${user_id}" -r "${KEYCLOAK_REALM}" -f - >/dev/null
set_user_password "${KEYCLOAK_REALM}" "${user_id}" "${CREDENTIAL_DIR}/keycloak-test-password"
for group in platform-admin viewer; do
  group_id=$(kc get groups -r "${KEYCLOAK_REALM}" -q search="${group}" | jq -r --arg group "${group}" '.[] | select(.name == $group) | .id' | head -n1)
  kc update "users/${user_id}/groups/${group_id}" -r "${KEYCLOAK_REALM}" -n >/dev/null 2>&1 || true
done
ok "Keycloak ${KEYCLOAK_REALM} realm, realm/client role, confidential client 3개, test user 구성"
fi

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
  die "OpenBao는 이미 초기화됐지만 ${init_file}이 없어 자동 unseal/bootstrap 불가"
fi

for index in 0 1; do
  # unseal key를 kubectl exec 인자에 넣으면 apiserver audit request와 host 프로세스
  # 목록에 복구 재료가 남는다. 고정된 Pod-side shell이 stdin에서만 읽게 한다.
  jq -er ".unseal_keys_b64[${index}]" "${init_file}" |
    kctl exec -i -n openbao "${openbao_pod}" -- sh -ceu '
      IFS= read -r unseal_key
      export BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
      exec bao operator unseal "$unseal_key"
    ' sh "${bao_addr}" >/dev/null
done
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
  "${CREDENTIAL_DIR}/keycloak-secure-demo-client-secret"
seed_kv_file_key "${kv_prefix}/portal-lite" AUTH_KEYCLOAK_SECRET \
  "${CREDENTIAL_DIR}/keycloak-portal-client-secret"
seed_kv_file_key "${kv_prefix}/portal-lite" AUTH_SECRET \
  "${CREDENTIAL_DIR}/portal-auth-secret"

# 기계 API 키는 OpenBao KV와 ESO role이 모두 준비된 뒤에만 만든다. keycloak 모드는
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

# role 마다 bound_claims 로 Keycloak group 을 묶는다. 이것이 없으면 realm 에 로그인할 수
# 있는 사람은 누구나 그 role 을 그대로 assume 한다(groups_claim 은 claim 위치만 알려 줄 뿐
# 접근을 제한하지 않는다). 일반 사용자 role 만 의도적으로 묶지 않는다.
#
# bound_claims 는 map 이라 CLI 의 key=value 로는 전달되지 않는다(문자열로 들어가 매칭이
# 조용히 실패한다). 반드시 JSON 본문으로 쓴다.
oidc_role() {
  local role=$1 policy=$2
  jq -n --arg r "${role}" --arg p "${policy}" --arg h "${OPENBAO_HOST}" '{
    role_type:"oidc", user_claim:"preferred_username", groups_claim:"groups",
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
jq -n --arg h "${OPENBAO_HOST}" '{
  role_type:"oidc", user_claim:"preferred_username", groups_claim:"groups",
  bound_audiences:["openbao"], token_policies:["app-user"], token_ttl:"1h",
  allowed_redirect_uris:[
    ("https://" + $h + "/ui/vault/auth/oidc/oidc/callback"),
    "http://localhost:8250/oidc/callback"
  ]}' | bao_input write auth/oidc/role/user - >/dev/null

# client secret 은 argv 에 남기지 않도록 stdin JSON 으로만 넘긴다.
# default_role 은 가장 약한 user 다. role 을 지정하지 않고 들어온 로그인이 관리자 권한을
# 받으면 안 된다.
jq -nc --arg discovery "${KEYCLOAK_ISSUER}" \
  --rawfile secret "${CREDENTIAL_DIR}/keycloak-openbao-client-secret" '{
    oidc_discovery_url:$discovery, oidc_client_id:"openbao",
    oidc_client_secret:($secret | sub("[\\r\\n]+$"; "")), default_role:"user"
  }' | bao_input write auth/oidc/config - >/dev/null
kctl wait -n openbao pod/${openbao_pod} --for=condition=Ready --timeout=5m >/dev/null
ok "OpenBao audit/KV v2/Kubernetes auth/최소권한 policy/OIDC 구성"
