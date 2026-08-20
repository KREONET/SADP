#!/usr/bin/env bash
# Forgejo 봇 토큰 회전.
#
# 왜 반자동인가:
#   Forgejo(15.0.6+gitea-1.22.0)의 토큰 생성/삭제 API
#   (POST|DELETE /api/v1/users/{user}/tokens)는 "비밀번호 basic-auth"만 허용한다.
#   토큰을 password 자리에 넣으면 401 {"message":"auth method not allowed"} 로 거부된다.
#   따라서 새 토큰 발급과 구 토큰 폐기는 사람이 해야 하고,
#   이 스크립트는 그 앞뒤(주입/검증/전환)를 전부 자동화한다.
#
# 사용법:
#   1) Forgejo UI에서 새 토큰 2개 발급 (아래 "발급 방법" 참고)
#   2) sudo bash scripts/ops/rotate-forgejo-token.sh \
#        --write-token-file /path/write.txt \
#        --read-token-file  /path/read.txt
#   3) 스크립트가 OK를 내면 UI에서 구 토큰 삭제
#
# 발급 방법 (site.env의 SADP_ARGO_REPO_USERNAME 계정으로 로그인):
#   Settings > Applications > Generate New Token
#     - 이름 portal-lite-write / 스코프 write:repository  (포털이 PR 생성)
#     - 이름 argocd-read      / 스코프 read:repository   (ArgoCD가 clone)
#   ※ 두 토큰 모두 admin 스코프를 절대 주지 말 것.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
mapfile -t repository_values < <(python3 - "${ROOT}/contracts/platform-production.yaml" <<'PY'
import sys
from urllib.parse import urlsplit
import yaml

url = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["spec"]["delivery"]["repoURL"]
parsed = urlsplit(url)
parts = parsed.path.strip("/").removesuffix(".git").split("/")
if parsed.scheme != "https" or not parsed.hostname or len(parts) != 2:
    raise SystemExit("[FAIL] token 회전은 https://host/owner/repo GitOps URL만 지원")
print(f"https://{parsed.netloc}")
print("/".join(parts))
PY
)
FORGEJO_BASE_URL=${FORGEJO_BASE_URL:-${repository_values[0]}}
BOT_USER=${BOT_USER:-sadp-installer}
REPO_PATH=${REPO_PATH:-${repository_values[1]}}
CREDENTIAL_DIR=${CREDENTIAL_DIR:-/var/lib/sadp/credentials}
ARGOCD_NAMESPACE=${ARGOCD_NAMESPACE:-devtroncd}
ARGOCD_REPO_SECRET=${ARGOCD_REPO_SECRET:-sadp-repo}
KUBECONFIG_PATH=${KUBECONFIG_PATH:-/etc/rancher/rke2/rke2.yaml}
KUBECTL_BIN=${KUBECTL_BIN:-/var/lib/rancher/rke2/bin/kubectl}

# 기본값을 beta 로 박아 두면 WORKLOAD_NAMESPACE 를 바꾼 사이트에서 없는 Namespace 를
# 보고 토큰 회전이 실패한다. 계약이 default-deny egress 를 거는 Namespace 를 쓴다.
PORTAL_NAMESPACE=${PORTAL_NAMESPACE:-$(python3 - "${ROOT}/contracts/platform-production.yaml" <<'PY'
import sys

import yaml

document = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
namespaces = ((document.get("spec") or {}).get("network") or {}).get("defaultDenyNamespaces") or []
if len(namespaces) != 1:
    raise SystemExit("[FAIL] network.defaultDenyNamespaces 가 정확히 하나여야 한다")
print(namespaces[0])
PY
)}
[[ -n ${PORTAL_NAMESPACE} ]] || { printf '[FAIL] PORTAL_NAMESPACE 를 정하지 못함\n' >&2; exit 1; }

WRITE_TOKEN_FILE=""
READ_TOKEN_FILE=""
DRY_RUN=false

die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
ok() { printf '[OK] %s\n' "$*"; }
note() { printf '[..] %s\n' "$*"; }

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (($#)); do
  case $1 in
    --write-token-file) WRITE_TOKEN_FILE=${2:?--write-token-file 값 필요}; shift ;;
    --read-token-file) READ_TOKEN_FILE=${2:?--read-token-file 값 필요}; shift ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

[[ ${EUID} -eq 0 ]] || die "root 권한 필요 (sudo)"
[[ -n ${WRITE_TOKEN_FILE} ]] || die "--write-token-file 필요"
[[ -r ${WRITE_TOKEN_FILE} ]] || die "읽을 수 없음: ${WRITE_TOKEN_FILE}"
: "${READ_TOKEN_FILE:=${WRITE_TOKEN_FILE}}"
[[ -r ${READ_TOKEN_FILE} ]] || die "읽을 수 없음: ${READ_TOKEN_FILE}"

WRITE_TOKEN=$(tr -d ' \t\r\n' <"${WRITE_TOKEN_FILE}")
READ_TOKEN=$(tr -d ' \t\r\n' <"${READ_TOKEN_FILE}")
[[ ${#WRITE_TOKEN} -ge 40 ]] || die "write 토큰이 짧다(형식 확인)"
[[ ${#READ_TOKEN} -ge 40 ]] || die "read 토큰이 짧다(형식 확인)"

OLD_TOKEN=""
[[ -r ${CREDENTIAL_DIR}/forgejo-bot-token ]] &&
  OLD_TOKEN=$(tr -d ' \t\r\n' <"${CREDENTIAL_DIR}/forgejo-bot-token")
[[ ${WRITE_TOKEN} != "${OLD_TOKEN}" ]] || die "새 토큰이 기존 토큰과 동일하다 — 회전이 아니다"

BODY_FILE=$(mktemp); chmod 600 "${BODY_FILE}"
trap 'rm -f "${BODY_FILE}"' EXIT
HTTP_CODE=000

# api <token> <method> <path>
#   HTTP_CODE 전역과 ${BODY_FILE} 에 결과를 남긴다.
#   주의: 명령치환($(...))으로 호출하면 서브셸이라 HTTP_CODE가 전파되지 않는다.
#         반드시 `api ...` 로 호출하고 본문은 api_body 로 읽어라.
api() {
  local token=$1 method=$2 path=$3
  HTTP_CODE=$(curl -sS -o "${BODY_FILE}" -w '%{http_code}' \
    -X "${method}" -H "Authorization: token ${token}" \
    "${FORGEJO_BASE_URL}/api/v1${path}") || die "API 호출 실패: ${path}"
}
api_body() { cat "${BODY_FILE}"; }

# ---- 1. 새 토큰 신원/권한 검증 -------------------------------------------
note "새 토큰 신원 확인"
api "${WRITE_TOKEN}" GET /user
[[ ${HTTP_CODE} == 200 ]] || die "write 토큰이 유효하지 않다 (HTTP ${HTTP_CODE})"
login=$(api_body | python3 -c 'import sys,json;print(json.load(sys.stdin)["login"])')
[[ ${login} == "${BOT_USER}" ]] || die "write 토큰 소유자가 ${BOT_USER}가 아니라 ${login}"
ok "write 토큰 소유자=${login}"

note "최소권한 확인: admin API가 막혀 있어야 한다"
api "${WRITE_TOKEN}" GET "/admin/users?limit=1"
[[ ${HTTP_CODE} == 403 || ${HTTP_CODE} == 404 ]] ||
  die "write 토큰이 admin API에 접근 가능(HTTP ${HTTP_CODE}). admin 스코프를 빼고 재발급하라"
ok "write 토큰에 admin 스코프 없음"

note "저장소 push 권한 확인"
api "${WRITE_TOKEN}" GET "/repos/${REPO_PATH}"
[[ ${HTTP_CODE} == 200 ]] || die "write 토큰으로 ${REPO_PATH} 접근 불가 (HTTP ${HTTP_CODE})"
api_body | python3 -c '
import sys,json
p=json.load(sys.stdin).get("permissions",{})
sys.exit(0 if p.get("push") else 1)' || die "write 토큰에 push 권한이 없다"
ok "write 토큰 push 권한 확인"


note "read 토큰 확인"
api "${READ_TOKEN}" GET "/repos/${REPO_PATH}"
[[ ${HTTP_CODE} == 200 ]] || die "read 토큰으로 ${REPO_PATH} 접근 불가 (HTTP ${HTTP_CODE})"
api "${READ_TOKEN}" GET "/admin/users?limit=1"
[[ ${HTTP_CODE} == 403 || ${HTTP_CODE} == 404 ]] ||
  die "read 토큰이 admin API에 접근 가능. 재발급하라"
ok "read 토큰 확인"

if [[ ${DRY_RUN} == true ]]; then
  ok "dry-run: 검증만 수행하고 종료"
  exit 0
fi

# ---- 2. 자격증명 파일 교체 (구 토큰 백업) --------------------------------
install -d -m 700 "${CREDENTIAL_DIR}"
if [[ -n ${OLD_TOKEN} ]]; then
  printf '%s\n' "${OLD_TOKEN}" >"${CREDENTIAL_DIR}/forgejo-bot-token.revoked-$(date +%Y%m%d%H%M%S)"
  chmod 600 "${CREDENTIAL_DIR}"/forgejo-bot-token.revoked-*
fi
printf '%s\n' "${WRITE_TOKEN}" >"${CREDENTIAL_DIR}/forgejo-bot-token"
printf '%s\n' "${READ_TOKEN}" >"${CREDENTIAL_DIR}/forgejo-argocd-token"
chmod 600 "${CREDENTIAL_DIR}/forgejo-bot-token" "${CREDENTIAL_DIR}/forgejo-argocd-token"
ok "자격증명 파일 갱신 (구 토큰은 .revoked-* 로 백업)"

# ---- 3. 포털 백엔드(OpenBao 경유) 주입 -----------------------------------
note "OpenBao에 포털 토큰 주입"
bash "${ROOT}/scripts/cluster/install-portal-backend.sh" --token-only \
  --forgejo-token-file "${CREDENTIAL_DIR}/forgejo-bot-token" ||
  die "install-portal-backend.sh --token-only 실패"
ok "포털 토큰 주입 완료"

# ---- 4. ArgoCD repo secret 교체 (읽기 전용 토큰) -------------------------
export KUBECONFIG=${KUBECONFIG_PATH}
note "ArgoCD repo secret 교체"
"${KUBECTL_BIN}" -n "${ARGOCD_NAMESPACE}" patch secret "${ARGOCD_REPO_SECRET}" \
  --type merge -p "{\"stringData\":{\"password\":\"${READ_TOKEN}\"}}" >/dev/null ||
  die "ArgoCD repo secret 패치 실패"
"${KUBECTL_BIN}" -n "${ARGOCD_NAMESPACE}" rollout restart deploy/argocd-repo-server >/dev/null
"${KUBECTL_BIN}" -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-repo-server --timeout=180s
ok "ArgoCD repo secret 교체 + repo-server 재기동"

# ---- 5. ExternalSecret 강제 동기화 후 포털 재기동 -------------------------
note "portal-lite-auth ExternalSecret 강제 동기화"
"${KUBECTL_BIN}" -n "${PORTAL_NAMESPACE}" annotate externalsecret portal-lite-auth \
  force-sync="$(date +%s)" --overwrite >/dev/null || die "ExternalSecret 강제 동기화 실패"
for _ in $(seq 1 30); do
  phase=$("${KUBECTL_BIN}" -n "${PORTAL_NAMESPACE}" get externalsecret portal-lite-auth \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ ${phase} == True ]] && break
  sleep 2
done
[[ ${phase:-} == True ]] || die "portal-lite-auth ExternalSecret 가 Ready 가 아니다"
ok "ExternalSecret 동기화 완료"

note "포털 재기동"
"${KUBECTL_BIN}" -n "${PORTAL_NAMESPACE}" rollout restart deploy/portal-lite >/dev/null
"${KUBECTL_BIN}" -n "${PORTAL_NAMESPACE}" rollout status deploy/portal-lite --timeout=180s

note "검증: 구 토큰은 더 이상 쓰이지 않아야 한다"
for ns_secret in "${ARGOCD_NAMESPACE}/${ARGOCD_REPO_SECRET}" "${PORTAL_NAMESPACE}/portal-lite-auth"; do
  ns=${ns_secret%%/*}; name=${ns_secret##*/}
  if [[ -n ${OLD_TOKEN} ]] && "${KUBECTL_BIN}" -n "${ns}" get secret "${name}" -o json |
      OLD_TOKEN="${OLD_TOKEN}" python3 -c '
import sys, json, base64, os
d = json.load(sys.stdin).get("data", {})
old = os.environ["OLD_TOKEN"]
sys.exit(0 if any(base64.b64decode(v).decode("utf-8", "ignore").strip() == old
                  for v in d.values()) else 1)'; then
    die "${ns_secret} 에 아직 구 토큰이 남아 있다"
  fi
done
ok "클러스터 시크릿에 구 토큰 없음"

cat <<EOF

[남은 수동 단계 — 반드시 수행]
  Forgejo UI (${BOT_USER} 계정) > Settings > Applications 에서
  구 토큰 'RKE2-Bot-Token' (끝 8자리 ${OLD_TOKEN: -8}) 를 삭제하라.
  API로는 삭제할 수 없다(비밀번호 basic-auth 전용).
  삭제 후 확인:
    curl -s -u ${BOT_USER}:<새토큰> ${FORGEJO_BASE_URL}/api/v1/users/${BOT_USER}/tokens
EOF
ok "회전 완료 (구 토큰 폐기만 남음)"
