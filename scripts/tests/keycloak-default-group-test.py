#!/usr/bin/env python3
"""Keycloak 연합 사용자 자동 연결, developer 수렴과 Portal SLO를 검증한다."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile

import yaml


ROOT = Path(__file__).resolve().parents[2]
BOOTSTRAP = ROOT / "scripts/cluster/bootstrap-testbed-services.sh"
INSTALL = ROOT / "scripts/cluster/install-testbed-platform.sh"
EXTERNAL = ROOT / "platform/keycloak/external/configure-default-developer.sh"
EXTERNAL_TEST_USER = ROOT / "platform/keycloak/external/configure-test-user.sh"
COMPOSE = ROOT / "platform/keycloak/external/docker-compose.yml"
REMOTE = ROOT / "scripts/cluster/configure-external-keycloak.sh"
VERIFY = ROOT / "scripts/verify/verify-testbed.sh"
PORTAL_VERIFY = ROOT / "scripts/verify/verify-portal-auth.sh"
PORTAL_AUTH = ROOT / "apps/portal-lite/ui/auth.ts"
PORTAL_LOGIN = ROOT / "apps/portal-lite/ui/app/(legacy)/login/page.tsx"
PORTAL_ACCOUNT = ROOT / "apps/portal-lite/ui/app/(legacy)/account/page.tsx"
PORTAL_LOGIN_FLOW = ROOT / "apps/portal-lite/ui/lib/login-flow.ts"
TIME_SYNC = ROOT / "platform/keycloak/external/configure-time-sync.sh"
AUTHENTIK_SAML = ROOT / "scripts/ops/configure-authentik-saml.sh"
SAML_VERIFY = ROOT / "scripts/verify/verify-saml-federation.sh"


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"[OK]   {message}")


for script in (
    BOOTSTRAP,
    INSTALL,
    EXTERNAL,
    EXTERNAL_TEST_USER,
    REMOTE,
    VERIFY,
    PORTAL_VERIFY,
    TIME_SYNC,
    AUTHENTIK_SAML,
    SAML_VERIFY,
):
    subprocess.run(["bash", "-n", str(script)], check=True, cwd=ROOT)
check(True, "Keycloak 기본 그룹 스크립트 bash syntax")

bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
install = INSTALL.read_text(encoding="utf-8")
external = EXTERNAL.read_text(encoding="utf-8")
external_test_user = EXTERNAL_TEST_USER.read_text(encoding="utf-8")
remote = REMOTE.read_text(encoding="utf-8")
verify = VERIFY.read_text(encoding="utf-8")
portal_verify = PORTAL_VERIFY.read_text(encoding="utf-8")
portal_auth = PORTAL_AUTH.read_text(encoding="utf-8")
portal_login = PORTAL_LOGIN.read_text(encoding="utf-8")
portal_account = PORTAL_ACCOUNT.read_text(encoding="utf-8")
portal_login_flow = PORTAL_LOGIN_FLOW.read_text(encoding="utf-8")
check(
    "if keycloak_is_external; then" in install
    and "external_keycloak_endpoints=" in install
    and ".items[]?.endpoints[]?" in install
    and 'kctl rollout status -n keycloak statefulset/keycloak-postgresql' in install,
    "platform 설치는 external Keycloak에서 EndpointSlice만 검증",
)
check(
    "registrationAllowed=false" in bootstrap
    and 'kc update "default-groups/${developer_group_id}"' in bootstrap,
    "in-cluster는 self-registration을 닫은 채 developer 기본 그룹만 추가",
)
check(
    "kc get default-groups" in bootstrap
    and '.id == $id and .name == "developer"' in bootstrap,
    "in-cluster 기본 그룹 적용 후 ID와 이름 검증",
)
check(
    'update "default-groups/${developer_group_id}"' in external
    and "get default-groups" in external
    and "delete" not in external,
    "external은 다른 기본 그룹을 삭제하지 않는 개별 endpoint 사용",
)
check(
    "configure-external-keycloak.sh --apply" in bootstrap
    and "StrictHostKeyChecking=yes" in remote
    and "BatchMode=yes" in remote
    and "KEYCLOAK_ENV_FILE" in remote
    and "configure-default-developer.sh" in remote,
    "전체 설치는 관리자 Secret을 보내지 않고 외부 VM의 Keycloak 정책을 SSH로 수렴",
)
check(
    "KEYCLOAK_REMOTE_TIME_SCRIPT" in remote
    and "SADP_NTP_SERVERS" in remote
    and "--runtime auto --apply" in remote,
    "외부 Keycloak 수렴은 realm 변경 전에 VM NTP 동기화를 강제",
)
check(
    "<\"${local_script}\"" in remote
    and "KEYCLOAK_REMOTE_ENV_FILE" in remote
    and "KEYCLOAK_REMOTE_KCADM" in remote,
    "원격 설치는 최신 스크립트만 전송하고 VM의 EnvironmentFile/kcadm 사용",
)
check(
    'external.get("port")' in remote
    and 'KEYCLOAK_SERVER="http://$8:$9"' in remote,
    "외부 Keycloak 수렴은 loopback이 아닌 계약의 bind address/port 사용",
)
check(
    'keycloak.get("samlSpEntityId") or keycloak.get("issuer")' in remote
    and 'KEYCLOAK_SAML_SP_ENTITY_ID="${10}"' in remote
    and ".config.entityId = $entity_id" in external
    and '.config.validateSignature = "true"' in external,
    "외부 Keycloak SAML SP EntityID와 서명 검증은 계약에서 반복 수렴",
)
check(
    "KC_CLI_PASSWORD" in external
    and '--password "${KC_ADMIN_PASSWORD}"' not in external
    and "kcadm_home=$(mktemp" in remote
    and '--config "${SADP_KCADM_CONFIG:?}"' in remote,
    "외부 Keycloak 관리자 Secret은 argv/지속 kcadm session에 남기지 않음",
)
check(
    'client_secret_response=$(mktemp "${CREDENTIAL_DIR}/.keycloak-client-secrets.XXXXXX")'
    in remote
    and 'clients/${uuid}/client-secret' in remote
    and 'os.replace(temporary, target)' in remote
    and 'os.chmod(target, 0o600)' in remote,
    "외부 Keycloak 현재 client secret은 SSH 응답을 root-only 파일로 원자 교체",
)
check(
    'KC_BOOTSTRAP_ADMIN_PASSWORD' in remote
    and 'admin_password=$(env_file_value "$1" KC_BOOTSTRAP_ADMIN_PASSWORD)' in remote
    and 'base64.b64decode(payload, validate=True)' in remote,
    "외부 관리자 자격증명은 VM 안에서만 읽고 client secret 응답만 엄격히 해석",
)
external_branch = bootstrap.split("if keycloak_is_external; then", 1)[1].split("else", 1)[0]
check(
    external_branch.index("configure-external-keycloak.sh --apply")
    < external_branch.index("현재 client secret 회수 실패")
    and "openssl rand" not in external_branch,
    "OpenBao 시드 전 현재 외부 client secret 회수를 강제하고 임의 생성을 금지",
)
check(
    'base64 -w0 <"${test_user_file}"' in remote
    and 'base64 -w0 <"${test_password_file}"' in remote
    and '"${REMOTE_TEST_USER_SCRIPT}"' in remote
    and "IFS= read -r encoded_username" in external_test_user
    and "IFS= read -r encoded_password" in external_test_user
    and 'printf \'%s\' "${test_password}" |' in external_test_user
    and 'users/${user_id}/reset-password' in external_test_user
    and '--password "${test_password}"' not in external_test_user,
    "외부 acceptance 자격증명은 SSH/kcadm stdin으로만 전달",
)
check(
    "platform-admin viewer" in external_test_user
    and 'users/${user_id}/groups/${group_id}' in external_test_user
    and 'role-mappings/realm/composite' in external_test_user
    and 'role-mappings/clients/${client_uuid}/composite' in external_test_user,
    "외부 acceptance 사용자는 realm/client role을 반복 수렴 후 검증",
)
check(
    "root@${keycloak_external_address}" in verify
    and "KC_CLI_PASSWORD" in verify
    and "kcadm_home=$(mktemp" in verify
    and '--config "${kcadm_config}"' in verify
    and "keycloak-external-admin-password" not in verify,
    "외부 Keycloak 검증은 관리자 Secret을 복사하지 않고 VM 내부에서 실행",
)
check(
    ".items[]?.endpoints[]?" in verify,
    "외부 Keycloak 검증도 EndpointSlice 중첩 JSONPath를 사용하지 않음",
)
check(
    "실제 Keycloak 로그인/세션 role 검증 실패(누락:" in portal_verify,
    "Portal 로그인 검증은 누락 claim을 값 노출 없이 보고",
)
check(
    'name.startswith("$ACTION_ID_")' in portal_verify
    and '-H "Origin: ${portal_origin}" --form "${logout_field}="' in portal_verify
    and '"${portal_origin}/api/auth/signout"' not in portal_verify,
    "Portal 로그아웃 검증은 실제 Server Action과 Keycloak RP logout을 사용",
)
check(
    'error: "/login"' in portal_auth
    and 'checks: ["pkce", "state", "nonce"]' in portal_auth,
    "Portal Auth.js 오류는 로그인 복구 화면으로 가고 PKCE/state/nonce를 모두 검증",
)
check(
    "needsAuthenticationRecovery(params.error, refreshFailed)" in portal_login
    and "fresh: recovery" in portal_login
    and 'session.error === "RefreshTokenError"' in portal_account,
    "SessionExpired/OAuth/refresh 실패는 사용자 동작 기반 공통 로그인 복구로 수렴",
)
check(
    'await actions.signOut({ redirect: false })' in portal_login_flow
    and 'params.prompt = "login"' in portal_login_flow
    and "ui_locales" in portal_login_flow
    and "safeLoginCallback(options.callbackUrl)" in portal_login_flow,
    "복구 요청은 앱 세션 제거 후 안전한 callback과 prompt/locale로 새 로그인을 시작",
)
check(
    "fresh authentication reused a validation parameter" in portal_verify
    and "provider error leaked into visible recovery UI" in portal_verify
    and "callbackUrl=/my-apps" in portal_verify,
    "Portal acceptance는 새 authorization 값·오류 비노출·내부 callback 복귀를 검증",
)
for body, label in ((bootstrap, "in-cluster"), (external, "external")):
    check(
        "oidc-hardcoded-group-idp-mapper" in body
        and "FORCE" in body
        and "/developer" in body,
        f"{label} IdP 로그인은 기존 사용자도 developer로 수렴",
    )
    check(
        "post.logout.redirect.uris" in body,
        f"{label} Portal RP-initiated logout 반환 URI 설정",
    )
    check(
        "sadp-trusted-saml-first-login" in body
        and "idp-create-user-if-unique" in body
        and "idp-auto-link" in body
        and "firstBrokerLoginFlowAlias" in body
        and ("trustEmail=true" in body or ".trustEmail = true" in body),
        f"{label} LIFE 사용자는 앱과 무관하게 입력 화면 없이 기존 계정에 연결",
    )
    check(
        "duplicateEmailsAllowed=false" in body
        and "editUsernameAllowed=false" in body,
        f"{label} 자동 연결 realm은 중복 이메일과 사용자명 변경 차단",
    )
    check(
        "saml-username-idp-mapper" in body
        and "STABLE_SAML_USERNAME_TEMPLATE='${ATTRIBUTE.http://schemas.goauthentik.io/2021/02/saml/username}'" in body,
        f"{label} SAML username은 Authentik 기본 Username URI에서 생성",
    )

compose = yaml.safe_load(COMPOSE.read_text(encoding="utf-8"))
config_service = compose["services"]["keycloak-config"]
check(
    config_service["depends_on"]["keycloak"]["condition"] == "service_healthy"
    and config_service["environment"]["KEYCLOAK_REALM"]
    == "${KEYCLOAK_REALM:?set KEYCLOAK_REALM}",
    "external compose job은 Keycloak Ready와 명시적 realm을 요구",
)
for name in (
    "KEYCLOAK_IDP_ALIAS",
    "KEYCLOAK_SAML_SP_ENTITY_ID",
    "KEYCLOAK_IDP_METADATA_URL",
    "KEYCLOAK_IDP_SSO_URL",
    "PORTAL_CLIENT_ID",
    "PORTAL_POST_LOGOUT_REDIRECT_URI",
):
    check(name in config_service["environment"], f"external compose job 입력: {name}")

# 실제 Keycloak 대신 kcadm 호출 표면을 흉내 내어 exact group ID와 PUT/GET postcondition,
# 반복 실행 안전성을 확인한다. 자격증명은 임시 프로세스 환경에만 둔다.
with tempfile.TemporaryDirectory(prefix="sadp-keycloak-default-group-") as temp_dir:
    temp = Path(temp_dir)
    call_log = temp / "calls.log"
    fake_kcadm = temp / "kcadm.sh"
    fake_kcadm.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == config && $2 == credentials ]]; then
  printf 'config credentials\\n' >>"${KCADM_TEST_LOG}"
  exit 0
fi
printf '%s\\n' "$*" >>"${KCADM_TEST_LOG}"
if [[ $1 == get && $2 == groups ]]; then
  printf 'group-developer,developer\\n'
elif [[ $1 == get && $2 == default-groups ]]; then
  grep -q '^update default-groups/group-developer ' "${KCADM_TEST_LOG}"
  printf 'group-developer,developer\\n'
elif [[ $1 == update && $2 == default-groups/group-developer ]]; then
  :
elif [[ $1 == update && $2 == realms/test-realm ]]; then
  :
elif [[ $1 == get && $2 == realms/test-realm ]]; then
  printf '{"registrationAllowed":false,"duplicateEmailsAllowed":false,"editUsernameAllowed":false}\n'
elif [[ $1 == get && $2 == authentication/flows ]]; then
  if [[ -f ${KCADM_TEST_FLOW_STATE} ]]; then
    printf 'flow-trusted,sadp-trusted-saml-first-login,false,basic-flow\n'
  fi
elif [[ $1 == create && $2 == authentication/flows ]]; then
  : >"${KCADM_TEST_FLOW_STATE}"
elif [[ $1 == get && $2 == authentication/flows/sadp-trusted-saml-first-login/executions ]]; then
  if [[ -f ${KCADM_TEST_CREATE_EXECUTION_STATE} ]]; then
    printf 'execution-create,idp-create-user-if-unique,ALTERNATIVE,false\n'
  fi
  if [[ -f ${KCADM_TEST_AUTOLINK_EXECUTION_STATE} ]]; then
    printf 'execution-autolink,idp-auto-link,ALTERNATIVE,false\n'
  fi
elif [[ $1 == create && $2 == authentication/flows/sadp-trusted-saml-first-login/executions/execution ]]; then
  if [[ $* == *'provider=idp-create-user-if-unique'* ]]; then
    : >"${KCADM_TEST_CREATE_EXECUTION_STATE}"
  elif [[ $* == *'provider=idp-auto-link'* ]]; then
    : >"${KCADM_TEST_AUTOLINK_EXECUTION_STATE}"
  else
    exit 2
  fi
elif [[ $1 == update && $2 == authentication/flows/sadp-trusted-saml-first-login/executions ]]; then
  :
elif [[ $1 == get && $2 == identity-provider/instances/test-idp ]]; then
  if [[ -f ${KCADM_TEST_IDP_FLOW_STATE} ]]; then
    printf '{"providerId":"saml","enabled":true,"firstBrokerLoginFlowAlias":"sadp-trusted-saml-first-login","trustEmail":true,"config":{"entityId":"https://sso.example.test/realms/test-realm/","useMetadataDescriptorUrl":"true","metadataDescriptorUrl":"https://idp.example.test/metadata","singleSignOnServiceUrl":"https://idp.example.test/sso","validateSignature":"true","wantAssertionsSigned":"true","wantAuthnRequestsSigned":"false"}}\n'
  else
    printf '{"providerId":"saml","config":{}}\n'
  fi
elif [[ $1 == update && $2 == identity-provider/instances/test-idp ]]; then
  : >"${KCADM_TEST_IDP_FLOW_STATE}"
elif [[ $1 == get && $2 == identity-provider/instances/test-idp/mappers ]]; then
  if [[ $* == *'--format csv'* ]]; then
    if [[ -f ${KCADM_TEST_MAPPER_STATE} ]]; then
      printf 'mapper-developer,portal-default-developer,oidc-hardcoded-group-idp-mapper\n'
    fi
  else
    if [[ -f ${KCADM_TEST_MAPPER_STATE} ]]; then
      printf '%s\n' '[{"id":"mapper-username","name":"Username","identityProviderMapper":"saml-username-idp-mapper","config":{"syncMode":"IMPORT","template":"${NAMEID}","target":"LOCAL"}},{"id":"mapper-developer","name":"portal-default-developer","identityProviderMapper":"oidc-hardcoded-group-idp-mapper"}]'
    else
      printf '%s\n' '[{"id":"mapper-username","name":"Username","identityProviderMapper":"saml-username-idp-mapper","config":{"syncMode":"IMPORT","template":"${NAMEID}","target":"LOCAL"}}]'
    fi
  fi
elif [[ $1 == create && $2 == identity-provider/instances/test-idp/mappers ]]; then
  : >"${KCADM_TEST_MAPPER_STATE}"
  printf 'mapper-developer\n'
elif [[ $1 == update && $2 == identity-provider/instances/test-idp/mappers/mapper-developer ]]; then
  :
elif [[ $1 == update && $2 == identity-provider/instances/test-idp/mappers/mapper-username ]]; then
  : >"${KCADM_TEST_USERNAME_MAPPER_STATE}"
elif [[ $1 == get && $2 == identity-provider/instances/test-idp/mappers/mapper-developer ]]; then
  printf '{"identityProviderMapper":"oidc-hardcoded-group-idp-mapper","config":{"syncMode":"FORCE","group":"/developer"}}\n'
elif [[ $1 == get && $2 == identity-provider/instances/test-idp/mappers/mapper-username ]]; then
  [[ -f ${KCADM_TEST_USERNAME_MAPPER_STATE} ]]
  printf '%s\n' '{"identityProviderMapper":"saml-username-idp-mapper","config":{"syncMode":"IMPORT","template":"${ATTRIBUTE.http://schemas.goauthentik.io/2021/02/saml/username}","target":"LOCAL"}}'
elif [[ $1 == get && $2 == clients ]]; then
  printf 'portal-uuid,portal-beta\n'
elif [[ $1 == update && $2 == clients/portal-uuid ]]; then
  : >"${KCADM_TEST_CLIENT_STATE}"
elif [[ $1 == get && $2 == clients/portal-uuid ]]; then
  [[ -f ${KCADM_TEST_CLIENT_STATE} ]]
  printf '{"redirectUris":["https://portal.example.test/api/auth/callback/keycloak"],"webOrigins":["https://portal.example.test"],"attributes":{"post.logout.redirect.uris":"https://portal.example.test/portal"}}\n'
else
  printf 'unexpected fake kcadm call\\n' >&2
  exit 2
fi
""",
        encoding="utf-8",
    )
    fake_kcadm.chmod(0o700)
    environment = os.environ.copy()
    environment.update(
        {
            "KCADM": str(fake_kcadm),
            "KCADM_TEST_LOG": str(call_log),
            "KCADM_TEST_FLOW_STATE": str(temp / "flow.state"),
            "KCADM_TEST_CREATE_EXECUTION_STATE": str(temp / "create-execution.state"),
            "KCADM_TEST_AUTOLINK_EXECUTION_STATE": str(temp / "autolink-execution.state"),
            "KCADM_TEST_IDP_FLOW_STATE": str(temp / "idp-flow.state"),
            "KCADM_TEST_MAPPER_STATE": str(temp / "mapper.state"),
            "KCADM_TEST_CLIENT_STATE": str(temp / "client.state"),
            "KCADM_TEST_USERNAME_MAPPER_STATE": str(temp / "username-mapper.state"),
            "KEYCLOAK_REALM": "test-realm",
            "KEYCLOAK_IDP_ALIAS": "test-idp",
            "KEYCLOAK_SAML_SP_ENTITY_ID": "https://sso.example.test/realms/test-realm/",
            "KEYCLOAK_IDP_METADATA_URL": "https://idp.example.test/metadata",
            "KEYCLOAK_IDP_SSO_URL": "https://idp.example.test/sso",
            "PORTAL_CLIENT_ID": "portal-beta",
            "PORTAL_POST_LOGOUT_REDIRECT_URI": "https://portal.example.test/portal",
            "KC_ADMIN_USER": "test-admin",
            "KC_ADMIN_PASSWORD": "test-password",
        }
    )
    for _ in range(2):
        result = subprocess.run(
            ["bash", str(EXTERNAL)],
            cwd=ROOT,
            env=environment,
            check=True,
            text=True,
            capture_output=True,
        )
        check(
            "SAML EntityID/LIFE 자동 연결/developer와 Portal callback/origin/logout URI 적용" in result.stdout
            and "test-password" not in result.stdout + result.stderr,
            "external Keycloak 수렴 job 성공 및 Secret 비출력",
        )

    calls = call_log.read_text(encoding="utf-8")
    check(
        calls.count("update default-groups/group-developer -r test-realm -n") == 2,
        "developer 기본 그룹 PUT 반복 실행 안전",
    )
    check(
        calls.count("create identity-provider/instances/test-idp/mappers") == 1
        and calls.count("update identity-provider/instances/test-idp/mappers/mapper-developer") == 1,
        "developer IdP mapper 생성 후 반복 실행은 update",
    )
    check(
        calls.count("update clients/portal-uuid") == 2,
        "Portal callback/origin/logout URI 반복 적용 안전",
    )
    check(
        calls.count(
            "update identity-provider/instances/test-idp/mappers/mapper-username"
        )
        == 2,
        "SAML username은 Authentik 기본 Username URI로 반복 수렴",
    )
    check(
        calls.count("create authentication/flows -r test-realm") == 1
        and calls.count(
            "create authentication/flows/sadp-trusted-saml-first-login/executions/execution"
        )
        == 2
        and calls.count(
            "update authentication/flows/sadp-trusted-saml-first-login/executions"
        )
        == 4,
        "trusted SAML first login flow 생성 후 반복 실행은 update",
    )
    check(
        sum(
            line.startswith("update identity-provider/instances/test-idp -r")
            for line in calls.splitlines()
        )
        == 2,
        "모든 앱이 쓰는 IdP에 first login flow 반복 바인딩",
    )
    check("delete" not in calls, "기존 default group 삭제 호출 없음")

print("Keycloak default developer group regression test passed")
