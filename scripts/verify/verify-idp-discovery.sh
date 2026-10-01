#!/usr/bin/env bash
# site.env의 외부 IdP 공개 endpoint를 실제 OIDC discovery 문서와 대조한다. 읽기 전용이다.
#
# configure-site.py는 외부 호출을 하지 않는다는 원칙을 지키므로 형식·호스트·client ID 오염까지만
# 오프라인으로 거른다. 그 검사를 통과한 오타(경로 오타, 끝 '/' 누락, 다른 application 복사)는
# IdP에 직접 물어봐야만 잡히므로 render 전에 이 단계가 온라인 대조를 맡는다.
#
#   bash ./sadp --verify-idp --env-file /etc/sadp/site.env
#
# 값·응답 본문은 출력하지 않는다. 불일치는 discovery 필드 이름만 알린다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"
source "$(dirname "$0")/../lib/oidc-discovery.sh"

ENV_FILE=

usage() {
  cat <<'EOF'
외부 IdP discovery 대조(읽기 전용)

사용법:
  bash ./sadp --verify-idp --env-file <site.env>

site.env의 HTTPS_PROXY가 있으면 그 proxy만 쓰고, 비어 있으면 직접 연결한다.
호출 셸의 HTTPS_PROXY/ALL_PROXY 환경변수는 쓰지 않는다.
EOF
}

while (($#)); do
  case "$1" in
    --env-file) ENV_FILE=${2:?--env-file 값 필요}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[FAIL] 알 수 없는 인자: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# 기본 경로를 추측하지 않는다. 두 후보가 함께 있으면 어느 쪽이 상류인지 운영자가 정해야 한다.
[[ -n ${ENV_FILE} ]] || die "--env-file 필요(자동 탐색 없음). 후보: environments/site.env, /etc/sadp/site.env"
for command in curl jq python3; do require_command "${command}"; done
cd "${TESTBED_ROOT}"

# 원본 site.env를 source하지 않는다. 오프라인 검증을 통과한 공개값만 shell-quoted로 받는다.
idp_env=$(python3 scripts/site/configure-site.py --env-file "${ENV_FILE}" --print-idp-env) \
  || exit 1
eval "${idp_env}"

# 같은 site.env면 누가 실행해도 같은 경로로 나가야 결과를 믿을 수 있다.
unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy
if [[ -n ${SADP_IDP_HTTPS_PROXY} ]]; then
  note "IdP discovery 조회: site.env HTTPS_PROXY 경유"
else
  note "IdP discovery 조회: 직접 연결(site.env HTTPS_PROXY 비어 있음)"
fi

sadp_oidc_discovery_verify "${OIDC_ISSUER}" "${OIDC_AUTHORIZATION_ENDPOINT}" \
  "${OIDC_TOKEN_ENDPOINT}" "${OIDC_JWKS_URI}" "${OIDC_END_SESSION_ENDPOINT}" \
  "${SADP_IDP_HTTPS_PROXY}" \
  || die "site.env의 외부 IdP endpoint가 discovery 문서와 다름. render 전에 site.env를 고쳐라"

ok "IdP discovery와 site.env의 issuer/authorization/token/jwks${OIDC_END_SESSION_ENDPOINT:+/end_session} 정확 일치"
if [[ ${IDENTITY_SOURCE_PROTOCOL} == saml ]]; then
  note "SAML은 외부 broker가 소유한다. 이 검사는 broker가 공개한 OIDC 표면까지만 확인했다"
fi
