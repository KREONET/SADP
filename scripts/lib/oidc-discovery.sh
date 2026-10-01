#!/usr/bin/env bash
# 외부 OIDC discovery 문서를 기대한 공개 endpoint와 대조하는 공용 함수. source 전용.
#
# 설치 전 site.env 대조(verify-idp-discovery.sh)와 설치 후 Portal acceptance
# (verify-portal-auth.sh)가 같은 규칙을 써야 한다. 한쪽만 issuer를 정규화하면 설치는 통과하고
# 로그인만 깨지는 식으로 두 검사가 서로 다른 결론을 낸다.
#
# 규칙:
# - issuer는 정규화하지 않는다(OIDC Core 정확 일치). discovery URL만 `${issuer%/}`로 만든다.
# - 비교는 JSON 문자열 값의 정확 일치다. 끝 '/' 하나 차이도 불일치다.
# - 값, URL, 응답 본문, curl 오류 원문은 출력하지 않는다. 불일치는 discovery 필드 이름만 알린다.
set -euo pipefail

sadp_oidc_discovery_url() {
  printf '%s/.well-known/openid-configuration' "${1%/}"
}

# 사용: sadp_oidc_discovery_verify <issuer> <authorization> <token> <jwks> <end_session> [proxy]
#   end_session이 비어 있으면 비교하지 않고, discovery만 공개하면 [WARN]을 남긴다.
#   proxy가 비어 있으면 --proxy를 주지 않는다. 호출 환경의 proxy를 따를지는 호출자가 정한다.
# 반환: 0 전부 일치, 1 조회 실패 또는 불일치.
sadp_oidc_discovery_verify() {
  local issuer=$1 authorization=$2 token=$3 jwks=$4 end_session=$5 proxy=${6:-}
  local run_dir body errors status curl_exit=0 cause index
  local -a curl_args fields expected mismatched=()

  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/sadp-idp-discovery.XXXXXX")
  chmod 0700 "${run_dir}"
  body=${run_dir}/body
  errors=${run_dir}/errors
  : >"${body}"
  : >"${errors}"
  chmod 0600 "${body}" "${errors}"

  # 리다이렉트는 따르지 않는다. discovery는 issuer 아래 정확한 경로에서 200이어야 하고,
  # 다른 호스트로 넘어가 받은 문서를 일치로 세면 이 검사의 의미가 사라진다.
  curl_args=(-q --silent --show-error --proto '=https' --tlsv1.2
    --connect-timeout 5 --max-time 20
    --output "${body}" --write-out '%{http_code}')
  [[ -z ${proxy} ]] || curl_args+=(--proxy "${proxy}")
  status=$(curl "${curl_args[@]}" "$(sadp_oidc_discovery_url "${issuer}")" 2>"${errors}") \
    || curl_exit=$?

  if ((curl_exit != 0)); then
    case "${curl_exit}" in
      5) cause="proxy 호스트 DNS 해석 실패(HTTPS_PROXY 확인)" ;;
      6) cause="IdP 호스트 DNS 해석 실패" ;;
      7)
        if [[ -n ${proxy} ]]; then
          cause="proxy 또는 IdP HTTPS 연결 실패"
        else
          cause="IdP HTTPS 연결 실패(폐쇄망이면 site.env HTTPS_PROXY 지정)"
        fi
        ;;
      28) cause="IdP discovery timeout" ;;
      35|51|53|58|59|60|66|77|80|82|83) cause="IdP TLS 인증서/CA 검증 실패" ;;
      56|97)
        if [[ -n ${proxy} ]]; then
          cause="proxy가 IdP 호스트 CONNECT를 거부(Squid allowlist 확인)"
        else
          cause="IdP 응답 수신 실패"
        fi
        ;;
      *) cause="IdP discovery 요청 실패(curl exit=${curl_exit})" ;;
    esac
    rm -rf -- "${run_dir}"
    printf '[FAIL] IdP discovery: %s\n' "${cause}" >&2
    return 1
  fi

  if [[ ${status} != 200 ]]; then
    rm -rf -- "${run_dir}"
    printf '[FAIL] IdP discovery: HTTP status=%s (issuer 경로와 IdP 공개 상태 확인)\n' \
      "${status:-000}" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "${body}" >/dev/null 2>&1; then
    rm -rf -- "${run_dir}"
    printf '[FAIL] IdP discovery: 응답이 JSON 객체가 아님\n' >&2
    return 1
  fi

  fields=(issuer authorization_endpoint token_endpoint jwks_uri)
  expected=("${issuer}" "${authorization}" "${token}" "${jwks}")
  if [[ -n ${end_session} ]]; then
    fields+=(end_session_endpoint)
    expected+=("${end_session}")
  elif jq -e '(.end_session_endpoint | type) == "string" and (.end_session_endpoint | length) > 0' \
      "${body}" >/dev/null 2>&1; then
    printf '[WARN] IdP discovery는 end_session_endpoint를 공개하지만 기대값이 비어 있음(RP-initiated logout 미사용)\n' >&2
  fi
  for index in "${!fields[@]}"; do
    jq -e --arg field "${fields[index]}" --arg value "${expected[index]}" \
      '.[$field] == $value' "${body}" >/dev/null 2>&1 || mismatched+=("${fields[index]}")
  done
  rm -rf -- "${run_dir}"

  if ((${#mismatched[@]})); then
    printf '[FAIL] IdP discovery 불일치 필드: %s\n' "${mismatched[*]}" >&2
    printf '[ACTION] IdP 관리 화면이 아니라 discovery 문서의 값을 끝 %s까지 그대로 복사하라(값은 출력하지 않음)\n' "'/'" >&2
    return 1
  fi
  return 0
}
