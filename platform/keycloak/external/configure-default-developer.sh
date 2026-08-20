#!/usr/bin/env bash
# 외부 Keycloak에서 SAML 사용자를 중복 가입 없이 연결하고 developer 그룹/SLO를 수렴시킨다.
set -euo pipefail

# 네이티브 설치는 systemd EnvironmentFile에서 관리자 값 두 개만 읽는다. 파일 전체를
# source하면 systemd 전용 문법이나 다른 Secret까지 shell 환경으로 들어오므로 정확한 key만
# 고르고, 값 자체는 출력하지 않는다. Compose job은 기존처럼 환경변수를 직접 주입한다.
env_file_value() {
  local file=$1 key=$2 rows
  rows=$(sed -n "s/^${key}=//p" "${file}")
  [[ $(grep -c '^' <<<"${rows}") == 1 && -n ${rows} ]] \
    || { echo "[FAIL] ${file}에서 ${key}를 정확히 하나 읽지 못함" >&2; exit 1; }
  if [[ ${rows} == \"*\" && ${rows} == *\" ]]; then
    rows=${rows:1:${#rows}-2}
  elif [[ ${rows} == \'*\' && ${rows} == *\' ]]; then
    rows=${rows:1:${#rows}-2}
  fi
  printf '%s' "${rows}"
}
if [[ -n ${KEYCLOAK_ENV_FILE:-} ]]; then
  KC_ADMIN_USER=${KC_ADMIN_USER:-$(env_file_value "${KEYCLOAK_ENV_FILE}" KC_BOOTSTRAP_ADMIN_USERNAME)}
  KC_ADMIN_PASSWORD=${KC_ADMIN_PASSWORD:-$(env_file_value "${KEYCLOAK_ENV_FILE}" KC_BOOTSTRAP_ADMIN_PASSWORD)}
fi

: "${KEYCLOAK_REALM:?KEYCLOAK_REALM is required}"
: "${KEYCLOAK_IDP_ALIAS:?KEYCLOAK_IDP_ALIAS is required}"
: "${KEYCLOAK_SAML_SP_ENTITY_ID:?KEYCLOAK_SAML_SP_ENTITY_ID is required}"
: "${KEYCLOAK_IDP_METADATA_URL:?KEYCLOAK_IDP_METADATA_URL is required}"
: "${KEYCLOAK_IDP_SSO_URL:?KEYCLOAK_IDP_SSO_URL is required}"
: "${PORTAL_CLIENT_ID:?PORTAL_CLIENT_ID is required}"
: "${PORTAL_POST_LOGOUT_REDIRECT_URI:?PORTAL_POST_LOGOUT_REDIRECT_URI is required}"
: "${KC_ADMIN_USER:?KC_ADMIN_USER or KEYCLOAK_ENV_FILE is required}"
: "${KC_ADMIN_PASSWORD:?KC_ADMIN_PASSWORD or KEYCLOAK_ENV_FILE is required}"

[[ ${KEYCLOAK_IDP_ALIAS} =~ ^[A-Za-z0-9._-]+$ ]] \
  || { echo "[FAIL] KEYCLOAK_IDP_ALIAS 형식 오류" >&2; exit 1; }
[[ ${PORTAL_CLIENT_ID} =~ ^[A-Za-z0-9._-]+$ ]] \
  || { echo "[FAIL] PORTAL_CLIENT_ID 형식 오류" >&2; exit 1; }
[[ ${PORTAL_POST_LOGOUT_REDIRECT_URI} =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/portal$ ]] \
  || { echo "[FAIL] PORTAL_POST_LOGOUT_REDIRECT_URI는 HTTPS host의 /portal URL이어야 함" >&2; exit 1; }
for saml_url in "${KEYCLOAK_SAML_SP_ENTITY_ID}" "${KEYCLOAK_IDP_METADATA_URL}" \
  "${KEYCLOAK_IDP_SSO_URL}"; do
  [[ ${saml_url} == https://* && ${saml_url} != *[[:space:]]* ]] \
    || { echo "[FAIL] SAML EntityID/metadata/SSO URL은 공백 없는 HTTPS URL이어야 함" >&2; exit 1; }
done
portal_origin=${PORTAL_POST_LOGOUT_REDIRECT_URI%/portal}
portal_callback=${portal_origin}/api/auth/callback/keycloak

KCADM=${KCADM:-/opt/keycloak/bin/kcadm.sh}
KEYCLOAK_SERVER=${KEYCLOAK_SERVER:-http://keycloak:8080}
TRUSTED_FIRST_LOGIN_FLOW=sadp-trusted-saml-first-login
STABLE_SAML_USERNAME_TEMPLATE='${ATTRIBUTE.http://schemas.goauthentik.io/2021/02/saml/username}'

# 관리자 값은 compose service의 container 환경 안에서만 읽는다. 비밀번호를 argv에 넣으면
# 같은 VM의 프로세스 목록에 잠깐 노출되므로 kcadm이 지원하는 전용 환경변수로만 넘긴다.
export KC_CLI_PASSWORD=${KC_ADMIN_PASSWORD}
"${KCADM}" config credentials \
  --server "${KEYCLOAK_SERVER}" --realm master \
  --user "${KC_ADMIN_USER}" >/dev/null
unset KC_CLI_PASSWORD KC_ADMIN_PASSWORD

exact_named_id() {
  local csv=$1 wanted=$2 kind=$3 id name extra match_id= matches=0
  while IFS=, read -r id name extra; do
    name=${name%$'\r'}
    [[ ${name} == "${wanted}" ]] || continue
    matches=$((matches + 1))
    match_id=${id}
  done <<<"${csv}"
  if ((matches > 1)); then
    echo "[FAIL] Keycloak ${kind} '${wanted}'가 둘 이상이라 대상을 결정할 수 없음" >&2
    return 1
  fi
  printf '%s' "${match_id}"
}

# 이 flow는 client가 아니라 신뢰한 IdP에 묶인다. 그래서 Portal 뒤에 OIDC 앱을 더 설치해도
# 같은 LIFE 계정은 다시 profile 입력이나 로컬 계정 확인을 거치지 않는다. 임의 이메일을
# 받는 IdP에 auto-link를 쓰면 계정 탈취가 되므로 realm의 가입/중복/이름 변경도 함께 닫는다.
"${KCADM}" update "realms/${KEYCLOAK_REALM}" \
  -s registrationAllowed=false -s duplicateEmailsAllowed=false \
  -s editUsernameAllowed=false >/dev/null
realm_document=$("${KCADM}" get "realms/${KEYCLOAK_REALM}")
grep -Eq '"registrationAllowed"[[:space:]]*:[[:space:]]*false' <<<"${realm_document}" \
  && grep -Eq '"duplicateEmailsAllowed"[[:space:]]*:[[:space:]]*false' <<<"${realm_document}" \
  && grep -Eq '"editUsernameAllowed"[[:space:]]*:[[:space:]]*false' <<<"${realm_document}" \
  || { echo "[FAIL] Keycloak trusted IdP auto-link 안전 조건 검증 실패" >&2; exit 1; }

flow_rows=$("${KCADM}" get authentication/flows -r "${KEYCLOAK_REALM}" \
  --fields id,alias,builtIn,providerId --format csv --noquotes)
trusted_flow_id=$(exact_named_id "${flow_rows}" "${TRUSTED_FIRST_LOGIN_FLOW}" flow)
if [[ -z ${trusted_flow_id} ]]; then
  "${KCADM}" create authentication/flows -r "${KEYCLOAK_REALM}" \
    -s alias="${TRUSTED_FIRST_LOGIN_FLOW}" \
    -s description='서명된 LIFE SAML 사용자를 입력 화면 없이 생성하거나 기존 계정에 연결한다.' \
    -s providerId=basic-flow -s topLevel=true -s builtIn=false >/dev/null
fi

ensure_flow_execution() {
  local provider=$1 rows execution_id
  rows=$("${KCADM}" get "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions" \
    -r "${KEYCLOAK_REALM}" --fields id,providerId,requirement,authenticationFlow \
    --format csv --noquotes)
  execution_id=$(exact_named_id "${rows}" "${provider}" execution)
  if [[ -z ${execution_id} ]]; then
    "${KCADM}" create \
      "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions/execution" \
      -r "${KEYCLOAK_REALM}" -s provider="${provider}" >/dev/null
    rows=$("${KCADM}" get "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions" \
      -r "${KEYCLOAK_REALM}" --fields id,providerId,requirement,authenticationFlow \
      --format csv --noquotes)
    execution_id=$(exact_named_id "${rows}" "${provider}" execution)
  fi
  [[ -n ${execution_id} ]] \
    || { echo "[FAIL] Keycloak first login execution '${provider}' 생성 실패" >&2; exit 1; }
  "${KCADM}" update "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions" \
    -r "${KEYCLOAK_REALM}" -n -s id="${execution_id}" \
    -s requirement=ALTERNATIVE >/dev/null
}

ensure_flow_execution idp-create-user-if-unique
ensure_flow_execution idp-auto-link
flow_executions=$("${KCADM}" get \
  "authentication/flows/${TRUSTED_FIRST_LOGIN_FLOW}/executions" \
  -r "${KEYCLOAK_REALM}" --fields id,providerId,requirement,authenticationFlow \
  --format csv --noquotes)
execution_count=$(grep -cve '^[[:space:]]*$' <<<"${flow_executions}")
create_count=$(awk -F, '$2 == "idp-create-user-if-unique" && $3 == "ALTERNATIVE" {count++} END {print count+0}' \
  <<<"${flow_executions}")
autolink_count=$(awk -F, '$2 == "idp-auto-link" && $3 == "ALTERNATIVE" {count++} END {print count+0}' \
  <<<"${flow_executions}")
[[ ${execution_count} == 2 && ${create_count} == 1 && ${autolink_count} == 1 ]] \
  || { echo "[FAIL] Keycloak trusted SAML first login flow가 정확히 두 execution이 아님" >&2; exit 1; }

group_rows=$("${KCADM}" get groups -r "${KEYCLOAK_REALM}" -q search=developer \
  --fields id,name --format csv --noquotes)
developer_group_id=$(exact_named_id "${group_rows}" developer group)
if [[ -z ${developer_group_id} ]]; then
  "${KCADM}" create groups -r "${KEYCLOAK_REALM}" -s name=developer >/dev/null
  group_rows=$("${KCADM}" get groups -r "${KEYCLOAK_REALM}" -q search=developer \
    --fields id,name --format csv --noquotes)
  developer_group_id=$(exact_named_id "${group_rows}" developer group)
fi
[[ -n ${developer_group_id} ]] \
  || { echo "[FAIL] Keycloak developer group을 찾거나 만들지 못함" >&2; exit 1; }

# 배열 전체를 바꾸지 않고 개별 endpoint를 호출해야 기존 default group이 보존된다.
"${KCADM}" update "default-groups/${developer_group_id}" \
  -r "${KEYCLOAK_REALM}" -n >/dev/null
default_rows=$("${KCADM}" get default-groups -r "${KEYCLOAK_REALM}" \
  --fields id,name --format csv --noquotes)
default_developer_id=$(exact_named_id "${default_rows}" developer group)
[[ ${default_developer_id} == "${developer_group_id}" ]] \
  || { echo "[FAIL] Keycloak developer 기본 그룹 적용 후 검증 실패" >&2; exit 1; }

# Realm default group은 최초 import에만 적용된다. Hardcoded Group mapper를 FORCE로
# 두어 이미 import된 SAML 사용자도 다음 로그인 때 /developer로 수렴시킨다.
idp_document=$("${KCADM}" get "identity-provider/instances/${KEYCLOAK_IDP_ALIAS}" \
  -r "${KEYCLOAK_REALM}") \
  || { echo "[FAIL] Keycloak IdP '${KEYCLOAK_IDP_ALIAS}'를 찾지 못함" >&2; exit 1; }
idp_update=$(jq \
  --arg flow "${TRUSTED_FIRST_LOGIN_FLOW}" \
  --arg entity_id "${KEYCLOAK_SAML_SP_ENTITY_ID}" \
  --arg metadata_url "${KEYCLOAK_IDP_METADATA_URL}" \
  --arg sso_url "${KEYCLOAK_IDP_SSO_URL}" '
    .enabled = true
    | .trustEmail = true
    | .firstBrokerLoginFlowAlias = $flow
    | .config.entityId = $entity_id
    | .config.useMetadataDescriptorUrl = "true"
    | .config.metadataDescriptorUrl = $metadata_url
    | .config.singleSignOnServiceUrl = $sso_url
    | .config.validateSignature = "true"
    | .config.wantAssertionsSigned = "true"
    | .config.wantAuthnRequestsSigned = "false"
  ' <<<"${idp_document}")
"${KCADM}" update "identity-provider/instances/${KEYCLOAK_IDP_ALIAS}" \
  -r "${KEYCLOAK_REALM}" -f - <<<"${idp_update}" >/dev/null
idp_document=$("${KCADM}" get "identity-provider/instances/${KEYCLOAK_IDP_ALIAS}" \
  -r "${KEYCLOAK_REALM}")
jq -e \
  --arg flow "${TRUSTED_FIRST_LOGIN_FLOW}" \
  --arg entity_id "${KEYCLOAK_SAML_SP_ENTITY_ID}" \
  --arg metadata_url "${KEYCLOAK_IDP_METADATA_URL}" \
  --arg sso_url "${KEYCLOAK_IDP_SSO_URL}" '
    .enabled == true
    and .trustEmail == true
    and .firstBrokerLoginFlowAlias == $flow
    and .config.entityId == $entity_id
    and .config.useMetadataDescriptorUrl == "true"
    and .config.metadataDescriptorUrl == $metadata_url
    and .config.singleSignOnServiceUrl == $sso_url
    and .config.validateSignature == "true"
    and .config.wantAssertionsSigned == "true"
    and .config.wantAuthnRequestsSigned == "false"
  ' <<<"${idp_document}" >/dev/null \
  || { echo "[FAIL] Keycloak SAML SP EntityID/IdP 정책 수렴 실패" >&2; exit 1; }

# Authentik 기본 Username 특성의 URI 전체를 로컬 username 기준으로 쓴다. FriendlyName을
# 임의로 가정하면 정상 assertion도 null username이 되므로 실제 Attribute Name과 맞춘다.
# 이 속성이 빠지면 다른 값으로 대체하지 않고 실패시켜 잘못된 SAML 계약을 드러낸다.
grep -Eq '"providerId"[[:space:]]*:[[:space:]]*"saml"' <<<"${idp_document}" \
  || { echo "[FAIL] trusted username mapper는 SAML IdP에서만 적용 가능" >&2; exit 1; }
all_mappers=$("${KCADM}" get \
  "identity-provider/instances/${KEYCLOAK_IDP_ALIAS}/mappers" -r "${KEYCLOAK_REALM}")
username_mapper_count=$(jq '[.[] | select(.identityProviderMapper == "saml-username-idp-mapper")] | length' \
  <<<"${all_mappers}")
((username_mapper_count <= 1)) \
  || { echo "[FAIL] SAML username mapper가 둘 이상이라 대상을 결정할 수 없음" >&2; exit 1; }
username_mapper_id=$(jq -r '.[] | select(.identityProviderMapper == "saml-username-idp-mapper") | .id' \
  <<<"${all_mappers}")
username_mapper_name=$(jq -r \
  '.[] | select(.identityProviderMapper == "saml-username-idp-mapper") | .name' \
  <<<"${all_mappers}")
username_mapper_name=${username_mapper_name:-sadp-stable-saml-username}
username_mapper_document=$(jq -nc --arg name "${username_mapper_name}" \
  --arg alias "${KEYCLOAK_IDP_ALIAS}" --arg template "${STABLE_SAML_USERNAME_TEMPLATE}" '{
    name:$name,
    identityProviderAlias:$alias,
    identityProviderMapper:"saml-username-idp-mapper",
    config:{syncMode:"IMPORT", template:$template, target:"LOCAL"}
  }')
if [[ -z ${username_mapper_id} ]]; then
  username_mapper_id=$("${KCADM}" create \
    "identity-provider/instances/${KEYCLOAK_IDP_ALIAS}/mappers" \
    -r "${KEYCLOAK_REALM}" -i -f - <<<"${username_mapper_document}")
else
  username_mapper_update=$(jq --arg id "${username_mapper_id}" '. + {id:$id}' \
    <<<"${username_mapper_document}")
  "${KCADM}" update \
    "identity-provider/instances/${KEYCLOAK_IDP_ALIAS}/mappers/${username_mapper_id}" \
    -r "${KEYCLOAK_REALM}" -f - <<<"${username_mapper_update}" >/dev/null
fi
"${KCADM}" get \
  "identity-provider/instances/${KEYCLOAK_IDP_ALIAS}/mappers/${username_mapper_id}" \
  -r "${KEYCLOAK_REALM}" | jq -e --arg template "${STABLE_SAML_USERNAME_TEMPLATE}" '
    .identityProviderMapper == "saml-username-idp-mapper"
    and .config.syncMode == "IMPORT"
    and .config.template == $template
    and .config.target == "LOCAL"
  ' >/dev/null || { echo "[FAIL] Keycloak SAML Authentik username URI mapper 검증 실패" >&2; exit 1; }
echo "[OK]   Keycloak SAML Authentik username URI mapper 적용"

mapper_name=portal-default-developer
mapper_rows=$("${KCADM}" get "identity-provider/instances/${KEYCLOAK_IDP_ALIAS}/mappers" \
  -r "${KEYCLOAK_REALM}" --fields id,name,identityProviderMapper --format csv --noquotes)
mapper_id=$(exact_named_id "${mapper_rows}" "${mapper_name}" mapper)
mapper_args=(
  -r "${KEYCLOAK_REALM}"
  -s name="${mapper_name}"
  -s identityProviderAlias="${KEYCLOAK_IDP_ALIAS}"
  -s identityProviderMapper=oidc-hardcoded-group-idp-mapper
  -s 'config."syncMode"=FORCE'
  -s 'config."group"=/developer'
)
if [[ -z ${mapper_id} ]]; then
  mapper_id=$("${KCADM}" create \
    "identity-provider/instances/${KEYCLOAK_IDP_ALIAS}/mappers" \
    "${mapper_args[@]}" -i)
else
  "${KCADM}" update \
    "identity-provider/instances/${KEYCLOAK_IDP_ALIAS}/mappers/${mapper_id}" \
    "${mapper_args[@]}" >/dev/null
fi
mapper_document=$("${KCADM}" get \
  "identity-provider/instances/${KEYCLOAK_IDP_ALIAS}/mappers/${mapper_id}" \
  -r "${KEYCLOAK_REALM}")
grep -Eq '"identityProviderMapper"[[:space:]]*:[[:space:]]*"oidc-hardcoded-group-idp-mapper"' \
  <<<"${mapper_document}" \
  && grep -Eq '"syncMode"[[:space:]]*:[[:space:]]*"FORCE"' <<<"${mapper_document}" \
  && grep -Eq '"group"[[:space:]]*:[[:space:]]*"/developer"' <<<"${mapper_document}" \
  || { echo "[FAIL] Keycloak developer IdP mapper 적용 후 검증 실패" >&2; exit 1; }
echo "[OK]   Keycloak developer default/FORCE mapper 적용"

# 포털 주소를 바꾸면 callback/origin/logout 세 값이 함께 움직여야 한다. logout URI만
# 고치면 새 주소의 로그인 callback이 invalid_redirect_uri로 실패하므로 한 번에 수렴시킨다.
client_rows=$("${KCADM}" get clients -r "${KEYCLOAK_REALM}" \
  -q clientId="${PORTAL_CLIENT_ID}" --fields id,clientId --format csv --noquotes)
portal_client_uuid=$(exact_named_id "${client_rows}" "${PORTAL_CLIENT_ID}" client)
[[ -n ${portal_client_uuid} ]] \
  || { echo "[FAIL] Keycloak Portal client '${PORTAL_CLIENT_ID}'를 찾지 못함" >&2; exit 1; }
"${KCADM}" update "clients/${portal_client_uuid}" -r "${KEYCLOAK_REALM}" \
  -s "redirectUris=[\"${portal_callback}\"]" \
  -s "webOrigins=[\"${portal_origin}\"]" \
  -s "attributes.\"post.logout.redirect.uris\"=${PORTAL_POST_LOGOUT_REDIRECT_URI}" >/dev/null
client_document=$("${KCADM}" get "clients/${portal_client_uuid}" -r "${KEYCLOAK_REALM}")
jq -e --arg callback "${portal_callback}" --arg origin "${portal_origin}" \
  --arg logout "${PORTAL_POST_LOGOUT_REDIRECT_URI}" '
    .redirectUris == [$callback]
    and .webOrigins == [$origin]
    and .attributes["post.logout.redirect.uris"] == $logout
  ' <<<"${client_document}" >/dev/null \
  || { echo "[FAIL] Keycloak Portal callback/origin/logout URI 적용 후 검증 실패" >&2; exit 1; }

echo "[OK]   Keycloak SAML EntityID/LIFE 자동 연결/developer와 Portal callback/origin/logout URI 적용"
