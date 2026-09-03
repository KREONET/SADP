#!/usr/bin/env bash
# 앱별 OpenBao 정책/OIDC role을 만든다. 외부 IdP 그룹 구성원 추가는 IdP 관리자가 수행한다.
set -euo pipefail
source "$(dirname "$0")/../lib/testbed-common.sh"
source "$(dirname "$0")/../lib/openbao-eso.sh"

APP=""
APP_GROUP=""
OIDC_GROUP=""
APPLY=false
while (($#)); do
  case "$1" in
    --app) APP=${2:?--app 값 필요}; shift ;;
    # 기존 --group은 OIDC group override다. AppGroup 이름으로 재사용하면 기존 자동화가
    # 조용히 다른 group에 묶이므로 새 의미는 별도 인자로만 받는다.
    --app-group) APP_GROUP=${2:?--app-group 값 필요}; shift ;;
    --group) OIDC_GROUP=${2:?--group 값 필요}; shift ;;
    --apply) APPLY=true ;;
    -h|--help)
      echo "usage: sudo bash $0 --app <app-name> [--app-group <group>] [--group <oidc-group>] [--apply]"
      exit 0 ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
  shift
done
require_root
for command in jq python3; do require_command "${command}"; done
[[ ${APP} =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ && ${#APP} -le 40 ]] || die "올바른 app 이름 필요"
[[ ${APP} != portal-lite && ${APP} != secure-demo ]] || die "플랫폼 앱은 이 명령으로 위임할 수 없음"
if [[ -n ${APP_GROUP} ]]; then
  [[ ${APP_GROUP} =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ && ${#APP_GROUP} -le 40 ]] || \
    die "올바른 AppGroup 이름 필요"
fi

cd "${TESTBED_ROOT}"
mapfile -t values < <(python3 - <<'PY'
import re
import yaml

portal = yaml.safe_load(open("apps/portal-lite/values-beta.yaml", encoding="utf-8"))
app = portal["app"]
contract = yaml.safe_load(open("contracts/values-platform-production.yaml", encoding="utf-8"))["platform"]
prefix = str(contract["appGroups"]["namespacePrefix"])
remote_path = str(contract["registry"]["pullSecretRemotePath"])
roles = contract["openbao"]["roles"]
if len(prefix) > 23 or not re.fullmatch(r"[a-z0-9]([-a-z0-9]*)?", prefix):
    raise SystemExit("[FAIL] platform.appGroups.namespacePrefix 형식 오류")
if not re.fullmatch(r"platform/registry/[a-z0-9]([-a-z0-9.]*[a-z0-9])?", remote_path):
    raise SystemExit("[FAIL] platform.registry.pullSecretRemotePath 형식 오류")
for key in ("zoneApp", "groupApp", "groupRegistry"):
    if not re.fullmatch(r"[a-z]([-a-z0-9]*[a-z0-9])?", str(roles.get(key) or "")):
        raise SystemExit(f"[FAIL] platform.openbao.roles.{key} 형식 오류")
print(app["project"])
print(app["environment"])
print(prefix)
print(remote_path)
print(contract["baseDomain"])
print(roles["zoneApp"])
print(roles["groupApp"])
print(roles["groupRegistry"])
print(contract["portal"]["namespace"])
PY
)
PROJECT=${values[0]:?project 계약값 없음}
ENVIRONMENT=${values[1]:?environment 계약값 없음}
NAMESPACE_PREFIX=${values[2]:?AppGroup Namespace prefix 계약값 없음}
REGISTRY_REMOTE_PATH=${values[3]:?registry remote path 계약값 없음}
BASE_DOMAIN=${values[4]:?base domain 계약값 없음}
ZONE_APP_ESO_ROLE=${values[5]:?zone app ESO role 계약값 없음}
GROUP_APP_ESO_ROLE=${values[6]:?group app ESO role 계약값 없음}
GROUP_REGISTRY_ESO_ROLE=${values[7]:?group registry ESO role 계약값 없음}
ZONE_NAMESPACE=${values[8]:?Zone Namespace 계약값 없음}

# Go typedDNSName 및 두 Chart의 typedName과 byte-for-byte 같은 규칙이다. 종류 prefix도
# hash seed에 넣어 서로 다른 리소스 종류가 같은 suffix를 공유하지 않게 한다.
typed_dns_name() {
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib
import sys

prefix, slug, canonical = sys.argv[1:]
suffix = hashlib.sha256(f"{prefix}|{canonical}".encode()).hexdigest()[:10]
room = 63 - len(prefix.encode()) - 11
if room < 1:
    raise SystemExit("[FAIL] typed DNS name prefix가 너무 김")
human = slug.encode()[:room].decode("ascii").rstrip("-")
if not human:
    raise SystemExit("[FAIL] typed DNS name slug가 비어 있음")
print(f"{prefix}{human}-{suffix}")
PY
}

if [[ -n ${APP_GROUP} ]]; then
  CANONICAL_APP="v1/app/${PROJECT}/${ENVIRONMENT}/${APP_GROUP}/${APP}"
  ROLE=$(typed_dns_name "app-role-a-" "${APP_GROUP}-${APP}" "${CANONICAL_APP}")
  ESO_ROLE=${GROUP_APP_ESO_ROLE}
  ESO_SERVICE_ACCOUNT=$(typed_dns_name "eso-sa-a-" "${APP}" "${CANONICAL_APP}")
  APP_NAMESPACE="${NAMESPACE_PREFIX}${APP_GROUP}"
  REGISTRY_ROLE=${GROUP_REGISTRY_ESO_ROLE}
  REGISTRY_SERVICE_ACCOUNT=eso-registry
  : "${OIDC_GROUP:=openbao-${ROLE}}"
else
  ROLE="app-${PROJECT}-${ENVIRONMENT}-${APP}"
  ESO_ROLE=${ZONE_APP_ESO_ROLE}
  ESO_SERVICE_ACCOUNT="eso-${APP}"
  APP_NAMESPACE="${ZONE_NAMESPACE}"
  : "${OIDC_GROUP:=openbao-app-${PROJECT}-${ENVIRONMENT}-${APP}}"
fi
PATH_PREFIX="apps/${PROJECT}/${ENVIRONMENT}/workloads/${APP_NAMESPACE}/${ESO_SERVICE_ACCOUNT}"
[[ ${OIDC_GROUP} =~ ^[A-Za-z0-9._:/-]{1,128}$ ]] || die "OIDC group 이름 형식 오류"

note "외부 IdP 관리자 UI에서 group '${OIDC_GROUP}'을 만들고 승인된 사용자만 구성원으로 추가한다."
note "OpenBao login role: ${ROLE}"
note "ESO Kubernetes auth role: ${ESO_ROLE} (SA ${APP_NAMESPACE}/${ESO_SERVICE_ACCOUNT})"
note "허용 경로: kv/${PATH_PREFIX}"
if [[ -n ${APP_GROUP} ]]; then
  note "AppGroup pull role: ${REGISTRY_ROLE} (SA ${APP_NAMESPACE}/${REGISTRY_SERVICE_ACCOUNT})"
fi
[[ ${APPLY} == true ]] || { note "계획만 출력함. 적용하려면 --apply"; exit 0; }

# policy/role을 쓰기 전에 sealed 상태를 확인해 bao의 503을 일반 write 실패로 숨기지 않는다.
openbao_require_unsealed 2m
INIT_FILE=${TESTBED_STATE_DIR}/openbao-init.json
[[ -s ${INIT_FILE} ]] || die "OpenBao 초기화 파일 없음: ${INIT_FILE}"
jq -e '.root_token | type == "string" and length > 0' "${INIT_FILE}" >/dev/null || \
  die "OpenBao root token을 읽지 못함"
BAO_ADDR=https://openbao.openbao.svc.cluster.local:8200
bao() {
  jq -er '.root_token' "${INIT_FILE}" |
    kctl exec -i -n openbao openbao-0 -- sh -ceu '
      IFS= read -r BAO_TOKEN
      export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
      shift
      exec bao "$@"
    ' sh "${BAO_ADDR}" "$@"
}
bao_input() {
  {
    jq -er '.root_token' "${INIT_FILE}"
    cat
  } | kctl exec -i -n openbao openbao-0 -- sh -ceu '
    IFS= read -r BAO_TOKEN
    export BAO_TOKEN BAO_ADDR="$1" BAO_CACERT=/openbao/tls/ca.crt
    shift
    exec bao "$@"
  ' sh "${BAO_ADDR}" "$@"
}

cat <<HCL | bao_input policy write "${ROLE}" - >/dev/null
path "sys/health" { capabilities = ["read"] }
path "sys/mounts" { capabilities = ["read", "list"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "kv/metadata" { capabilities = ["list"] }
path "kv/metadata/apps" { capabilities = ["list"] }
path "kv/metadata/apps/${PROJECT}" { capabilities = ["list"] }
path "kv/metadata/apps/${PROJECT}/${ENVIRONMENT}" { capabilities = ["list"] }
path "kv/metadata/apps/${PROJECT}/${ENVIRONMENT}/workloads" { capabilities = ["list"] }
path "kv/metadata/apps/${PROJECT}/${ENVIRONMENT}/workloads/${APP_NAMESPACE}" { capabilities = ["list"] }
path "kv/data/${PATH_PREFIX}" { capabilities = ["create", "read", "update", "patch", "delete"] }
path "kv/metadata/${PATH_PREFIX}" { capabilities = ["read", "delete"] }
HCL

# workload/registry ESO role은 bootstrap이 설치한 고정 자원이다. 이 운영 명령이 앱별
# policy/auth role을 다시 만들지 않고 존재만 확인해야 Portal 침해 경계가 되살아나지 않는다.
bao read "auth/kubernetes/role/${ESO_ROLE}" >/dev/null \
  || die "고정 workload ESO role 없음: ${ESO_ROLE} (bootstrap-testbed-services.sh 선행 필요)"
if [[ -n ${APP_GROUP} ]]; then
  bao read "auth/kubernetes/role/${REGISTRY_ROLE}" >/dev/null \
    || die "고정 registry ESO role 없음: ${REGISTRY_ROLE} (bootstrap-testbed-services.sh 선행 필요)"
  bao read "kv/metadata/${REGISTRY_REMOTE_PATH}" >/dev/null \
    || die "registry pull seed 없음: kv/${REGISTRY_REMOTE_PATH} (deploy-testbed-apps.sh 선행 필요)"
fi

jq -n --arg group "${OIDC_GROUP}" --arg policy "${ROLE}" \
  --arg host "openbao.${BASE_DOMAIN}" '{
    role_type:"oidc", user_claim:"preferred_username", groups_claim:"groups",
    bound_audiences:["openbao"], token_policies:[$policy], token_ttl:"1h",
    bound_claims_type:"string", bound_claims:{groups:[$group]},
    allowed_redirect_uris:[
      ("https://" + $host + "/ui/vault/auth/oidc/oidc/callback"),
      "http://localhost:8250/oidc/callback"
    ]}' | bao_input write "auth/oidc/role/${ROLE}" - >/dev/null

ok "앱별 OpenBao policy/role 적용: ${ROLE} (group=${OIDC_GROUP})"
