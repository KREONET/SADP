#!/usr/bin/env bash
# API key header나 Secret 본문을 읽지 않고 실연결 요청의 Envoy 판정 필드만 추린다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"

usage() {
  cat <<'EOF'
usage: sudo bash ./sadp --inspect-machine-auth-log <exact-user-agent> [--since <duration>]

외부 시험 요청에 고유한 User-Agent를 넣은 뒤 같은 문자열로 호출한다. 출력은 HTTP 판정과
source/routing 필드만 포함하며 request header 전체나 API key 값은 출력하지 않는다.
EOF
}

MARKER=""
SINCE=15m
while (($#)); do
  case "$1" in
    --since)
      shift
      (($#)) || die "--since 값이 필요함"
      SINCE=$1
      ;;
    -h|--help) usage; exit 0 ;;
    --*) die "알 수 없는 인자: $1" ;;
    *)
      [[ -z ${MARKER} ]] || die "User-Agent marker는 하나만 지정"
      MARKER=$1
      ;;
  esac
  shift
done

[[ -n ${MARKER} ]] || { usage; exit 2; }
[[ ${MARKER} =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}$ ]] \
  || die "User-Agent marker는 3~128자의 안전한 ASCII 식별자여야 함"
[[ ${SINCE} =~ ^[1-9][0-9]*[smh]$ ]] || die "--since는 30s, 15m, 2h 형식이어야 함"

require_root
require_command jq
ensure_state_dirs
cd "${TESTBED_ROOT}"

mapfile -t gateway_values < <(python3 - <<'PY'
import yaml
spec = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))["spec"]
print(spec["gateway"]["namespace"])
print(spec["gateway"]["name"])
PY
)
gateway_namespace=${gateway_values[0]}
gateway_name=${gateway_values[1]}
selector="gateway.envoyproxy.io/owning-gateway-namespace=${gateway_namespace},gateway.envoyproxy.io/owning-gateway-name=${gateway_name}"
mapfile -t pods < <(kctl -n "${gateway_namespace}" get pod -l "${selector}" -o name)
((${#pods[@]})) || die "Envoy data-plane Pod를 찾지 못함"

result_file=$(mktemp "${TESTBED_STATE_DIR}/.machine-auth-access-log.XXXXXX")
chmod 0600 "${result_file}"
trap 'rm -f "${result_file}"' EXIT

for pod in "${pods[@]}"; do
  kctl -n "${gateway_namespace}" logs "${pod}" -c envoy --since="${SINCE}" 2>/dev/null |
    jq -Rrc --arg marker "${MARKER}" '
      fromjson?
      | select(."user-agent" == $marker)
      | {
          response_code,
          response_code_details,
          downstream_remote_address,
          "x-forwarded-for": .["x-forwarded-for"],
          ":authority": .[":authority"],
          "x-envoy-origin-path": .["x-envoy-origin-path"],
          "user-agent": .["user-agent"]
        }
    ' >>"${result_file}" || true
done

[[ -s ${result_file} ]] || die "marker와 일치하는 Envoy access log가 없음: ${MARKER}"
cat "${result_file}"
