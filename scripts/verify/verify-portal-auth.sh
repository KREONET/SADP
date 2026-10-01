#!/usr/bin/env bash
# 외부 IdP를 변경하지 않고 OIDC discovery와 Portal Authorization Code 시작점만 검증한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"
source "$(dirname "$0")/../lib/oidc-discovery.sh"

require_root
for command in curl jq python3; do require_command "${command}"; done
ensure_state_dirs
cd "${TESTBED_ROOT}"

mapfile -t contract_values < <(python3 - <<'PY'
import yaml

contract = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))["spec"]
identity = contract.get("identityProvider") or {}
portal = yaml.safe_load(open("apps/portal-lite/values-beta.yaml", encoding="utf-8"))
print(contract["gateway"]["vip"])
print((portal.get("exposure") or {}).get("host") or "")
for field in (
    "managed", "sourceProtocol", "issuer", "authorizationEndpoint", "tokenEndpoint",
    "jwksURI", "portalClientID", "endSessionEndpoint",
):
    print(identity.get(field) or "")
PY
)
vip=${contract_values[0]}
portal_host=${contract_values[1]:?Portal values에 exposure.host가 없다}
managed=${contract_values[2]}
source_protocol=${contract_values[3]}
# issuer는 정규화하지 않는다. discovery URL만 공용 함수가 `${issuer%/}`로 만든다.
issuer=${contract_values[4]}
authorization_endpoint=${contract_values[5]}
token_endpoint=${contract_values[6]}
jwks_uri=${contract_values[7]}
portal_client_id=${contract_values[8]}
end_session_endpoint=${contract_values[9]}
portal_origin=https://${portal_host}

[[ ${managed} == external ]] || die "identityProvider.managed는 external이어야 함"
[[ ${source_protocol} == openid || ${source_protocol} == saml ]] \
  || die "identityProvider.sourceProtocol은 openid 또는 saml이어야 함"
for value in "${issuer}" "${authorization_endpoint}" "${token_endpoint}" "${jwks_uri}"; do
  [[ ${value} == https://* ]] || die "외부 OIDC endpoint는 HTTPS여야 함"
done
[[ -n ${portal_client_id} ]] || die "identityProvider.portalClientID가 비어 있음"

run_dir=$(mktemp -d "${TESTBED_STATE_DIR}/.portal-auth.XXXXXX")
chmod 0700 "${run_dir}"
cleanup() { rm -rf -- "${run_dir}"; }
trap cleanup EXIT
cookie_jar=${run_dir}/cookies.txt

# control-plane에서는 기존처럼 호출 환경의 proxy 설정을 따른다(proxy 인자 비움).
sadp_oidc_discovery_verify "${issuer}" "${authorization_endpoint}" "${token_endpoint}" \
  "${jwks_uri}" "${end_session_endpoint}" \
  || die "외부 OIDC discovery와 계약 endpoint가 일치하지 않음"
ok "외부 OIDC discovery와 공개 계약 일치"

curl_portal=(
  --silent --show-error --fail-with-body --insecure
  --resolve "${portal_host}:443:${vip}"
  --cookie "${cookie_jar}" --cookie-jar "${cookie_jar}"
  --connect-timeout 5 --max-time 30
)

providers=$(curl "${curl_portal[@]}" "${portal_origin}/api/auth/providers")
jq -e '.oidc.id == "oidc" and .oidc.type == "oidc"' <<<"${providers}" >/dev/null \
  || die "Portal Auth.js에 외부 OIDC provider가 없음"
ok "Portal Auth.js 외부 OIDC provider"

login_html=$(curl "${curl_portal[@]}" "${portal_origin}/login")
grep -q 'SSO로 로그인' <<<"${login_html}" \
  || die "Portal 로그인 화면에 외부 SSO 진입점이 없음"
ok "Portal 외부 SSO 로그인 화면"

csrf_json=$(curl "${curl_portal[@]}" "${portal_origin}/api/auth/csrf")
csrf_token=$(jq -er '.csrfToken | select(type == "string" and length > 20)' <<<"${csrf_json}") \
  || die "Auth.js CSRF token이 없음"
signin=$(curl "${curl_portal[@]}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'X-Auth-Return-Redirect: 1' \
  --data-urlencode "csrfToken=${csrf_token}" \
  --data-urlencode "callbackUrl=${portal_origin}/" \
  "${portal_origin}/api/auth/signin/oidc")
authorize_url=$(jq -er '.url | select(type == "string")' <<<"${signin}") \
  || die "Auth.js가 OIDC authorization URL을 만들지 못함"

python3 - "${authorize_url}" "${authorization_endpoint}" "${portal_client_id}" \
  "${portal_origin}/api/auth/callback/oidc" <<'PY'
import sys
from urllib.parse import parse_qs, urlsplit

actual, expected_endpoint, expected_client, expected_redirect = sys.argv[1:]
url = urlsplit(actual)
endpoint = urlsplit(expected_endpoint)
if (url.scheme, url.netloc, url.path) != (endpoint.scheme, endpoint.netloc, endpoint.path):
    raise SystemExit("authorization endpoint가 계약과 다름")
query = parse_qs(url.query)
checks = {
    "response_type": "code",
    "client_id": expected_client,
    "redirect_uri": expected_redirect,
    "code_challenge_method": "S256",
}
for name, expected in checks.items():
    if query.get(name) != [expected]:
        raise SystemExit(f"authorization parameter 불일치: {name}")
if "openid" not in set(query.get("scope", [""])[0].split()):
    raise SystemExit("openid scope 누락")
for name in ("state", "nonce", "code_challenge"):
    if not query.get(name, [""])[0]:
        raise SystemExit(f"authorization parameter 누락: {name}")
PY
ok "Portal OIDC Authorization Code + PKCE/state/nonce 시작 흐름"

if [[ ${source_protocol} == saml ]]; then
  note "SAML assertion과 계정 정책은 외부 broker가 소유한다. 이 검사는 broker의 OIDC 표면까지만 확인했다."
else
  note "사용자 로그인 완료와 그룹 claim은 외부 IdP 테스트 계정으로 브라우저에서 확인한다."
fi
