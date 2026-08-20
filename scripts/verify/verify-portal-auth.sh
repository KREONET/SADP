#!/usr/bin/env bash
# 실제 Auth.js -> Keycloak Authorization Code 흐름을 Secret 출력 없이 검증한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

require_root
for command in curl jq python3 shred; do require_command "${command}"; done
ensure_state_dirs
cd "${TESTBED_ROOT}"

mapfile -t contract_values < <(python3 - <<'PY'
import yaml
from urllib.parse import urlparse

doc = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))
print(doc["spec"]["baseDomain"])
print(doc["spec"]["gateway"]["vip"])
# realm 을 박아 두면 realm 이름이 다른 사이트에서 멀쩡한 로그인이 실패로 보인다.
keycloak = doc["spec"].get("keycloak") or {}
print(keycloak.get("realm") or "")
portal = yaml.safe_load(open("apps/portal-lite/values-beta.yaml", encoding="utf-8"))
print((portal.get("exposure") or {}).get("host") or "")
print(urlparse(str(keycloak.get("issuer") or "")).hostname or "")
PY
)
base_domain=${contract_values[0]}
vip=${contract_values[1]}
keycloak_realm=${contract_values[2]:?계약에 keycloak.realm 이 없다}
portal_host=${contract_values[3]:?Portal values에 exposure.host가 없다}
sso_host=${contract_values[4]:?계약의 Keycloak issuer host가 없다}
portal_origin=https://${portal_host}
sso_origin=https://${sso_host}

username_file=${CREDENTIAL_DIR}/keycloak-test-user
password_file=${CREDENTIAL_DIR}/keycloak-test-password
[[ -s ${username_file} && -s ${password_file} ]] \
  || die "Keycloak 테스트 계정 상태 파일이 없음; bootstrap-testbed-services.sh를 먼저 실행"

run_dir=$(mktemp -d "${TESTBED_STATE_DIR}/.portal-auth.XXXXXX")
chmod 0700 "${run_dir}"
cleanup() {
  local file
  for file in "${run_dir}"/*; do
    [[ -f ${file} ]] && shred -u -- "${file}" 2>/dev/null || true
  done
  rmdir "${run_dir}" 2>/dev/null || true
}
trap cleanup EXIT

cookie_jar=${run_dir}/cookies.txt
anon_portal_html=${run_dir}/anon-portal.html
anon_portal_en_html=${run_dir}/anon-portal-en.html
expired_login_html=${run_dir}/expired-login.html
expired_login_en_html=${run_dir}/expired-login-en.html
callback_error_html=${run_dir}/callback-error.html
active_session_expired_html=${run_dir}/active-session-expired.html
csrf_json=${run_dir}/csrf.json
csrf_file=${run_dir}/csrf.txt
recovery_signin_json_first=${run_dir}/recovery-signin-first.json
recovery_signin_json_second=${run_dir}/recovery-signin-second.json
signin_json=${run_dir}/signin.json
authorize_config=${run_dir}/authorize.curl
login_html=${run_dir}/keycloak-login.html
login_config=${run_dir}/keycloak-login.curl
login_result=${run_dir}/login-result.html
session_json=${run_dir}/session.json
account_html=${run_dir}/account.html
home_html=${run_dir}/home.html
home_en_html=${run_dir}/home-en.html
my_apps_html=${run_dir}/my-apps.html
missing_detail_html=${run_dir}/missing-detail.html
logout_action_field=${run_dir}/logout-action-field.txt
signed_out_session=${run_dir}/signed-out-session.json
resignin_json=${run_dir}/resignin.json
reauthorize_config=${run_dir}/keycloak-reauthorize.curl
relogin_html=${run_dir}/relogin.html

curl_common=(
  --silent --show-error --fail-with-body --insecure
  --resolve "${portal_host}:443:${vip}"
  --resolve "${sso_host}:443:${vip}"
  --cookie "${cookie_jar}" --cookie-jar "${cookie_jar}"
  --connect-timeout 5 --max-time 45
)
write_csrf_token() {
  local source_file=$1 destination_file=$2
  jq -jer '.csrfToken | select(type == "string" and length > 20)' \
    "${source_file}" >"${destination_file}" \
    || die "Auth.js CSRF 응답에 유효한 csrfToken이 없음"
}

assert_recovery_page() {
  local source_file=$1 expected_message=$2 expected_button=$3 hidden_error=$4
  python3 - "${source_file}" "${expected_message}" "${expected_button}" "${hidden_error}" <<'PY'
import pathlib
import sys
from html.parser import HTMLParser

class VisibleText(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hidden = 0
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style", "template"}:
            self.hidden += 1

    def handle_endtag(self, tag):
        if tag in {"script", "style", "template"} and self.hidden:
            self.hidden -= 1

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)

parser = VisibleText()
parser.feed(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
visible = " ".join(" ".join(parser.parts).split())
if sys.argv[2] not in visible or sys.argv[3] not in visible:
    raise SystemExit("authentication recovery copy/button missing")
if sys.argv[4] and sys.argv[4] in visible:
    raise SystemExit("provider error leaked into visible recovery UI")
PY
}

# --- 로그인 전(익명) 게이트 --------------------------------------------------
# (paas) 레이아웃의 requirePaasSession() 이 익명 요청을 어디로 보내는지 확인한다.
# 쿠키를 아직 받기 전이라 이 시점의 요청은 모두 익명이다.
anon_curl=(
  --silent --show-error --fail-with-body --insecure
  --resolve "${portal_host}:443:${vip}"
  --connect-timeout 5 --max-time 20
)
anon_redirect() {
  curl "${anon_curl[@]}" \
    --output /dev/null --write-out '%{http_code} %{redirect_url}' \
    "${portal_origin}${1}"
}

anon_home=$(anon_redirect '/')
[[ ${anon_home} == 3??\ *"/portal" ]] \
  || die "익명 홈(/) 이 /portal 로 가지 않음: ${anon_home}"
ok "익명 홈(/) → /portal 리다이렉트 확인"

anon_my_apps=$(anon_redirect '/my-apps')
[[ ${anon_my_apps} == 3??\ *"/login?callbackUrl=%2Fmy-apps" ]] \
  || die "익명 보호 페이지가 callbackUrl 을 유지한 로그인 화면으로 가지 않음: ${anon_my_apps}"
ok "익명 /my-apps → /login?callbackUrl=%2Fmy-apps 리다이렉트 확인"

curl "${anon_curl[@]}" "${portal_origin}/portal" >"${anon_portal_html}"
grep -q 'Keycloak 로그인' "${anon_portal_html}" \
  || die "익명 /portal 메인에 Keycloak 로그인 버튼이 없음"
ok "익명 /portal 메인 로그인 진입점 확인"

# --- 표시 언어(로케일) ------------------------------------------------------
# 언어는 portal_locale 쿠키로만 갈린다. 쿠키가 없으면 한국어, en 이면 영어이고
# <html lang> 이 함께 바뀌어야 스크린리더/브라우저 번역이 어긋나지 않는다.
grep -q '<html lang="ko"' "${anon_portal_html}" \
  || die "쿠키 없는 요청이 한국어(lang=ko)로 렌더링되지 않음"
ok "기본 로케일 한국어 렌더링 확인"

curl "${anon_curl[@]}" -H 'Cookie: portal_locale=en' \
  "${portal_origin}/portal" >"${anon_portal_en_html}"
grep -q '<html lang="en"' "${anon_portal_en_html}" \
  && grep -q 'Sign in with Keycloak' "${anon_portal_en_html}" \
  && ! grep -q 'Keycloak 로그인' "${anon_portal_en_html}" \
  || die "portal_locale=en 쿠키가 영어 화면으로 이어지지 않음"
ok "portal_locale=en → 영어 렌더링 확인"

# Auth.js의 모든 오류는 기본 오류 화면이 아니라 같은 로그인 복구 화면으로 돌아와야 한다.
auth_error_redirect=$(anon_redirect '/api/auth/error?error=AccessDenied')
[[ ${auth_error_redirect} == 3??\ *"/login?error=AccessDenied" ]] \
  || die "Auth.js error page가 Portal 로그인 화면으로 연결되지 않음: ${auth_error_redirect}"
ok "Auth.js pages.error → /login 연결 확인"

expired_status=$(curl "${anon_curl[@]}" --output "${expired_login_html}" \
  --write-out '%{http_code}' \
  "${portal_origin}/login?error=SessionExpired&callbackUrl=%2Fmy-apps")
[[ ${expired_status} == 200 ]] \
  || die "SessionExpired 로그인 복구 화면이 자동 redirect됨: HTTP ${expired_status}"
assert_recovery_page "${expired_login_html}" \
  '인증 시간이 만료되었습니다. 아래 버튼을 눌러 새로운 로그인을 시작하세요.' \
  '새로 로그인' 'SessionExpired'
ok "SessionExpired 한국어 복구 화면과 사용자 동작 기반 재시도 확인"

expired_en_status=$(curl "${anon_curl[@]}" -H 'Cookie: portal_locale=en' \
  --output "${expired_login_en_html}" --write-out '%{http_code}' \
  "${portal_origin}/login?error=SessionExpired&callbackUrl=%2Fmy-apps")
[[ ${expired_en_status} == 200 ]] \
  || die "영어 로그인 복구 화면이 자동 redirect됨: HTTP ${expired_en_status}"
assert_recovery_page "${expired_login_en_html}" \
  'Your authentication attempt expired. Start a new sign-in below.' \
  'Start a new sign-in' 'SessionExpired'
ok "SessionExpired 영어 복구 화면 확인"

callback_error_status=$(curl "${anon_curl[@]}" --output "${callback_error_html}" \
  --write-out '%{http_code}' \
  "${portal_origin}/login?error=OAuthCallbackError%3Aprovider-detail&callbackUrl=%2Fmy-apps")
[[ ${callback_error_status} == 200 ]] \
  || die "OAuth callback 오류 복구 화면이 자동 redirect됨: HTTP ${callback_error_status}"
assert_recovery_page "${callback_error_html}" \
  '인증 시간이 만료되었습니다. 아래 버튼을 눌러 새로운 로그인을 시작하세요.' \
  '새로 로그인' 'OAuthCallbackError:provider-detail'
ok "OAuth callback 원본 오류를 숨긴 로그인 복구 화면 확인"

curl "${curl_common[@]}" "${portal_origin}/api/auth/csrf" >"${csrf_json}"
write_csrf_token "${csrf_json}" "${csrf_file}"

# 복구 버튼의 서버 액션이 넘기는 authorization parameter와 같은 요청을 두 번 만들어
# state/nonce/PKCE가 오래된 탭의 값으로 재사용되지 않는지 확인한다. 값 자체는 출력하지 않는다.
for destination in "${recovery_signin_json_first}" "${recovery_signin_json_second}"; do
  curl "${curl_common[@]}" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H 'X-Auth-Return-Redirect: 1' \
    --data-urlencode "csrfToken@${csrf_file}" \
    --data-urlencode 'callbackUrl=/my-apps' \
    "${portal_origin}/api/auth/signin/keycloak?prompt=login&ui_locales=en" >"${destination}"
done

python3 - "${recovery_signin_json_first}" "${recovery_signin_json_second}" \
  "${sso_origin}" "${keycloak_realm}" <<'PY'
import json
import pathlib
import sys
import urllib.parse

expected = urllib.parse.urlsplit(sys.argv[3])
expected_path = f"/realms/{sys.argv[4]}/protocol/openid-connect/auth"
requests = []
for source in sys.argv[1:3]:
    payload = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
    parsed = urllib.parse.urlsplit(payload.get("url", ""))
    query = urllib.parse.parse_qs(parsed.query)
    if (parsed.scheme, parsed.netloc, parsed.path) != (expected.scheme, expected.netloc, expected_path):
        raise SystemExit("fresh authentication used an unexpected authorization endpoint")
    if query.get("prompt") != ["login"] or query.get("ui_locales") != ["en"]:
        raise SystemExit("fresh authentication prompt or locale is missing")
    for name in ("state", "nonce", "code_challenge"):
        if not query.get(name, [""])[0]:
            raise SystemExit("fresh authentication validation parameter is missing")
    if query.get("code_challenge_method") != ["S256"]:
        raise SystemExit("fresh authentication PKCE method is not S256")
    if any(name in query for name in ("access_token", "refresh_token", "client_secret", "code")):
        raise SystemExit("authorization URL contains a protected authentication value")
    requests.append(query)

for name in ("state", "nonce", "code_challenge"):
    if requests[0][name][0] == requests[1][name][0]:
        raise SystemExit("fresh authentication reused a validation parameter")
PY
ok "복구 authorization의 prompt=login/영어 locale 및 새 state·nonce·PKCE 확인"

curl "${curl_common[@]}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'X-Auth-Return-Redirect: 1' \
  --data-urlencode "csrfToken@${csrf_file}" \
  --data-urlencode 'callbackUrl=/my-apps' \
  "${portal_origin}/api/auth/signin/keycloak" >"${signin_json}"

python3 - "${signin_json}" "${sso_origin}" "${authorize_config}" "${keycloak_realm}" <<'PY'
import json
import os
import pathlib
import sys
import urllib.parse

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
url = payload.get("url", "")
expected = urllib.parse.urlsplit(sys.argv[2])
parsed = urllib.parse.urlsplit(url)
expected_path = f"/realms/{sys.argv[4]}/protocol/openid-connect/auth"
if (parsed.scheme, parsed.netloc, parsed.path) != (expected.scheme, expected.netloc, expected_path):
    raise SystemExit(
        "unexpected Keycloak authorization endpoint: "
        f"{parsed.scheme}://{parsed.netloc}{parsed.path}"
    )
path = pathlib.Path(sys.argv[3])
path.write_text("url = " + json.dumps(url) + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY

curl "${curl_common[@]}" --proto '=https' --config "${authorize_config}" >"${login_html}"
python3 - "${login_html}" "${sso_origin}" "${login_config}" "${keycloak_realm}" <<'PY'
import json
import os
import pathlib
import sys
import urllib.parse
from html.parser import HTMLParser

class LoginForm(HTMLParser):
    action = None

    def handle_starttag(self, tag, attrs):
        if tag != "form" or self.action is not None:
            return
        values = dict(attrs)
        action = values.get("action", "")
        if values.get("id") == "kc-form-login" or "/login-actions/authenticate" in action:
            self.action = action

parser = LoginForm()
parser.feed(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not parser.action:
    raise SystemExit("Keycloak login form not found")
expected = urllib.parse.urlsplit(sys.argv[2])
parsed = urllib.parse.urlsplit(parser.action)
if (
    (parsed.scheme, parsed.netloc) != (expected.scheme, expected.netloc)
    or not parsed.path.startswith(f"/realms/{sys.argv[4]}/login-actions/authenticate")
):
    raise SystemExit("unexpected Keycloak login form action")
path = pathlib.Path(sys.argv[3])
path.write_text("url = " + json.dumps(parser.action) + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY

login_final_url=$(curl "${curl_common[@]}" --proto '=https' --location --max-redirs 8 \
  --config "${login_config}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "username@${username_file}" \
  --data-urlencode "password@${password_file}" \
  --data-urlencode 'credentialId=' \
  --output "${login_result}" --write-out '%{url_effective}')
[[ ${login_final_url} == "${portal_origin}/my-apps" ]] \
  || die "정상 로그인 후 요청한 내부 callback 경로로 돌아오지 않음"
ok "정상 로그인 후 내부 callbackUrl=/my-apps 복귀 확인"

curl "${curl_common[@]}" "${portal_origin}/api/auth/session" >"${session_json}"
if ! jq -e '
  (.user.id | type == "string" and length > 0) and
  (.user.name | type == "string" and length > 0) and
  (.user.email | type == "string" and contains("@")) and
  (.user.realmRoles | index("platform-admin") != null) and
  (.user.realmRoles | index("viewer") != null) and
  (.user.clientRoles | index("platform-admin") != null) and
  (.user.clientRoles | index("viewer") != null) and
  (.accessTokenExpiresAt | type == "number" and . > 0) and
  ([.. | objects | keys[]] |
    all(. != "accessToken" and . != "refreshToken" and . != "clientSecret"))
' "${session_json}" >/dev/null; then
  missing_claims=$(jq -r '
    [
      if (.user.id | type == "string" and length > 0) then empty else "user.id" end,
      if (.user.name | type == "string" and length > 0) then empty else "user.name" end,
      if (.user.email | type == "string" and contains("@")) then empty else "user.email" end,
      if ((.user.realmRoles // []) | index("platform-admin") != null) then empty
        else "realm:platform-admin" end,
      if ((.user.realmRoles // []) | index("viewer") != null) then empty
        else "realm:viewer" end,
      if ((.user.clientRoles // []) | index("platform-admin") != null) then empty
        else "client:platform-admin" end,
      if ((.user.clientRoles // []) | index("viewer") != null) then empty
        else "client:viewer" end,
      if (.accessTokenExpiresAt | type == "number" and . > 0) then empty
        else "accessTokenExpiresAt" end,
      if ([.. | objects | keys[]] |
        all(. != "accessToken" and . != "refreshToken" and . != "clientSecret")) then empty
        else "browser-secret-field" end
    ] | join(",")
  ' "${session_json}" 2>/dev/null || true)
  die "실제 Keycloak 로그인/세션 role 검증 실패(누락: ${missing_claims:-invalid-session-json})"
fi
ok "실제 Keycloak 로그인과 서버 세션 ID/이름/이메일/realm·client role 확인"
ok "브라우저 세션 응답에 access token/refresh token/client secret 없음"

# 다른 탭에 정상 세션이 남아 있어도 오래된 로그인 탭의 오류 화면을 자동으로 callback에
# 보내면 loop가 생긴다. 오류가 있는 탭은 반드시 사용자의 복구 버튼을 기다려야 한다.
active_recovery_status=$(curl "${curl_common[@]}" \
  --output "${active_session_expired_html}" --write-out '%{http_code}' \
  "${portal_origin}/login?error=SessionExpired&callbackUrl=%2Fmy-apps")
[[ ${active_recovery_status} == 200 ]] \
  || die "기존 세션이 있는 오래된 로그인 탭에서 redirect loop 가능성 감지"
assert_recovery_page "${active_session_expired_html}" \
  '인증 시간이 만료되었습니다. 아래 버튼을 눌러 새로운 로그인을 시작하세요.' \
  '새로 로그인' 'SessionExpired'
ok "중복/오래된 로그인 탭에서 자동 redirect 없이 복구 화면 유지"

curl "${curl_common[@]}" "${portal_origin}/account" >"${account_html}"
grep -q '현재 사용자 정보' "${account_html}" \
  && grep -q 'Realm roles' "${account_html}" \
  && grep -q 'Client roles' "${account_html}" \
  && grep -q 'platform-admin' "${account_html}" \
  && grep -q '로그아웃' "${account_html}" \
  || die "로그인 후 사용자 정보 또는 로그아웃 UI를 찾지 못함"
ok "보호 페이지 사용자 정보와 로그아웃 UI 확인"

# 홈(/)은 세션이 있을 때만 PaaS 대시보드를 렌더링한다(미인증이면 /portal 로 보낸다).
curl "${curl_common[@]}" "${portal_origin}/" >"${home_html}"
grep -q '플랫폼 현황' "${home_html}" \
  && grep -q '빠른 이동' "${home_html}" \
  && grep -q '최근 배포 요청' "${home_html}" \
  && grep -q '내 쿼터 사용량' "${home_html}" \
  && grep -q 'nextjs-authjs-server' "${home_html}" \
  && ! grep -q 'profile.normalized' "${home_html}" \
  || die "로그인 후 Portal 홈 대시보드 marker 또는 API v1 계약 불일치"
ok "로그인 후 Portal 홈 대시보드 진입 확인(기본 한국어)"

# 같은 세션에서 로케일 쿠키만 바꾸면 대시보드도 영어로 렌더링된다.
curl "${curl_common[@]}" -H 'Cookie: portal_locale=en' "${portal_origin}/" >"${home_en_html}"
grep -q 'Platform Status' "${home_en_html}" \
  && grep -q 'Quick Access' "${home_en_html}" \
  && grep -q 'Recent Deployment Requests' "${home_en_html}" \
  && grep -q 'My Quota Usage' "${home_en_html}" \
  || die "portal_locale=en 대시보드 영어 렌더링 실패"
ok "portal_locale=en 대시보드 영어 렌더링 확인"

# 대시보드 배포 요청 테이블은 목데이터가 아니라 Go API(/api/v1/deployment-requests)를 읽는다.
grep -q 'data-source="api"' "${home_html}" \
  || die "대시보드 배포 요청 테이블이 백엔드 API에 연결되지 않음"
ok "대시보드 배포 요청 테이블 백엔드 연동 확인"

# 내 애플리케이션의 Refresh는 실제 client router refresh 버튼이어야 하고, 상세 링크가
# 없더라도 동적 상세 route 자체는 클릭 후 빈 화면이 아니라 명시적인 결과를 렌더링해야 한다.
curl "${curl_common[@]}" "${portal_origin}/my-apps" >"${my_apps_html}"
grep -q '내 애플리케이션' "${my_apps_html}" \
  && grep -q 'aria-label="새로고침"' "${my_apps_html}" \
  || die "내 애플리케이션 또는 Refresh 버튼이 렌더링되지 않음"
ok "내 애플리케이션 Refresh 버튼 렌더링 확인"

curl "${curl_common[@]}" "${portal_origin}/my-apps/acceptance-missing-request" \
  >"${missing_detail_html}"
grep -q '배포 요청 상세' "${missing_detail_html}" \
  && grep -q '상세 정보를 불러오지 못했습니다' "${missing_detail_html}" \
  && grep -q 'aria-label="새로고침"' "${missing_detail_html}" \
  && grep -q 'href="/my-apps"' "${missing_detail_html}" \
  || die "내 애플리케이션 상세 route 또는 Refresh/돌아가기 UI가 렌더링되지 않음"
ok "내 애플리케이션 상세 route와 Refresh/돌아가기 UI 확인"

# Auth.js 기본 signout endpoint는 Portal 세션만 지우며 signOutFromKeycloak 서버 액션을
# 실행하지 않는다. 실제 로그아웃 버튼의 progressive-enhancement form을 제출해야
# Keycloak RP-initiated logout과 브라우저 SSO cookie 제거까지 검증할 수 있다.
python3 - "${account_html}" "${logout_action_field}" <<'PY'
import os
import pathlib
import sys
from html.parser import HTMLParser

class LogoutForms(HTMLParser):
    def __init__(self):
        super().__init__()
        self.current = None
        self.matches = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "form":
            self.current = {
                "action": values.get("action", ""),
                "method": values.get("method", "get").lower(),
                "enctype": values.get("enctype", "").lower(),
                "fields": [],
            }
        elif tag == "input" and self.current is not None:
            name = values.get("name", "")
            if name:
                self.current["fields"].append(name)

    def handle_endtag(self, tag):
        if tag != "form" or self.current is None:
            return
        action_fields = [name for name in self.current["fields"] if name.startswith("$ACTION_ID_")]
        if (
            self.current["action"] == ""
            and self.current["method"] == "post"
            and self.current["enctype"] == "multipart/form-data"
            and len(action_fields) == 1
        ):
            self.matches.append(action_fields[0])
        self.current = None

parser = LogoutForms()
parser.feed(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if len(parser.matches) != 1:
    raise SystemExit("expected exactly one Keycloak logout Server Action form")
path = pathlib.Path(sys.argv[2])
path.write_text(parser.matches[0], encoding="utf-8")
os.chmod(path, 0o600)
PY
logout_field=$(<"${logout_action_field}")
logout_result=$(curl "${curl_common[@]}" --proto '=https' --proto-redir '=https' \
  --location --max-redirs 8 --output "${login_result}" \
  --write-out '%{http_code} %{url_effective}' \
  -H "Origin: ${portal_origin}" --form "${logout_field}=" \
  "${portal_origin}/account")
[[ ${logout_result} == "200 ${portal_origin}/portal" ]] \
  || die "Portal 로그아웃 Server Action의 최종 redirect가 아님: ${logout_result}"

curl "${curl_common[@]}" "${portal_origin}/api/auth/session" >"${signed_out_session}"
jq -e '.user == null' "${signed_out_session}" >/dev/null \
  || die "Auth.js 로그아웃 후에도 사용자 세션이 남아 있음"
ok "Auth.js 로그아웃과 세션 제거 확인"

# 포털 로그아웃은 Keycloak SSO 세션까지 끊어야 한다. 같은 쿠키 자(KEYCLOAK_IDENTITY 보유)로
# 다시 로그인 흐름을 타면, SSO 세션이 살아 있을 때처럼 곧바로 코드가 떨어지면 안 되고
# Keycloak 로그인 폼이 다시 나와야 한다.
curl "${curl_common[@]}" "${portal_origin}/api/auth/csrf" >"${csrf_json}"
write_csrf_token "${csrf_json}" "${csrf_file}"
curl "${curl_common[@]}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'X-Auth-Return-Redirect: 1' \
  --data-urlencode "csrfToken@${csrf_file}" \
  --data-urlencode 'callbackUrl=/' \
  "${portal_origin}/api/auth/signin/keycloak" >"${resignin_json}"
python3 - "${resignin_json}" "${sso_origin}" "${reauthorize_config}" <<'PY'
import json
import os
import pathlib
import sys
import urllib.parse

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
url = payload.get("url", "")
expected = urllib.parse.urlsplit(sys.argv[2])
parsed = urllib.parse.urlsplit(url)
if (parsed.scheme, parsed.netloc) != (expected.scheme, expected.netloc):
    raise SystemExit("unexpected Keycloak authorization endpoint after signout")
path = pathlib.Path(sys.argv[3])
path.write_text("url = " + json.dumps(url) + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY

curl "${curl_common[@]}" --proto '=https' --config "${reauthorize_config}" >"${relogin_html}"
grep -q 'kc-form-login' "${relogin_html}" \
  || die "포털 로그아웃 후에도 Keycloak SSO 세션이 남아 재인증 없이 통과함"
ok "포털 로그아웃 시 Keycloak SSO 세션까지 종료 확인"
