#!/usr/bin/env bash
# Chart 회귀 시험: 정상 profile 은 통과, 금지 profile 은 반드시 실패해야 한다.
set -uo pipefail
cd "$(dirname "$0")/../.."
# helm template 회귀는 클러스터를 읽지 않는다. root 셸의 RKE2 KUBECONFIG를 상속하면
# 불필요한 파일 권한 경고가 반복되어 실제 렌더 실패가 묻힌다.
unset KUBECONFIG
# 실행 파일 부재를 금지 profile의 정상 거부로 세지 않도록 먼저 확인한다.
command -v helm >/dev/null 2>&1 || { echo "[FAIL] helm이 필요합니다"; exit 1; }
CONTRACT=contracts/values-platform-production.yaml
PASS=0; FAILED=0
readarray -t SITE_VALUES < <(python3 - <<'PY'
import yaml

spec = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))["spec"]
app = yaml.safe_load(open("apps/hello/values-beta.yaml", encoding="utf-8"))["app"]
print(spec["environment"])
print(spec["gateway"]["vip"])
print(spec["gateway"]["name"])
print(app["project"])
print(spec["baseDomain"])
namespaces = (spec.get("network") or {}).get("defaultDenyNamespaces") or []
print(str(namespaces[0]) if len(namespaces) == 1 else "")
storage = (spec.get("appGroups") or {}).get("storage") or {}
print(str(storage.get("volumeSize") or ""))
print(str(storage.get("storageClass") or ""))
PY
)
APP_ENV=${SITE_VALUES[0]}
GATEWAY_VIP=${SITE_VALUES[1]}
GATEWAY_NAME=${SITE_VALUES[2]}
APP_PROJECT=${SITE_VALUES[3]}
BASE_DOMAIN=${SITE_VALUES[4]}
PORTAL_NAMESPACE=${SITE_VALUES[5]}
APP_GROUP_VOLUME_SIZE=${SITE_VALUES[6]}
APP_GROUP_STORAGE_CLASS=${SITE_VALUES[7]}
# cluster-scoped/ESO 이름은 project/environment를 포함한 canonical tuple의 hash다.
# 사이트 계약을 바꿔도 research/beta 시절 golden suffix를 기대하지 않도록 Chart/Go와 같은
# prefix|canonical 공식을 시험 입력에도 적용한다.
readarray -t APP_GROUP_TYPED_NAMES < <(python3 - "$APP_PROJECT" "$APP_ENV" <<'PY'
import hashlib
import sys

project, environment = sys.argv[1:]

def typed_name(prefix, slug, canonical):
    suffix = hashlib.sha256(f"{prefix}|{canonical}".encode()).hexdigest()[:10]
    room = 52 - len(prefix)
    normalized_slug = slug[:room].strip("-")
    return f"{prefix}{normalized_slug}-{suffix}"

print(typed_name(
    "css-g-",
    "mobility-platform",
    f"v1/group/{project}/{environment}/mobility-platform",
))
print(typed_name(
    "eso-sa-a-",
    "api",
    f"v1/app/{project}/{environment}/mobility-platform/api",
))
PY
)
APP_GROUP_PULL_STORE=${APP_GROUP_TYPED_NAMES[0]}
APP_GROUP_API_ESO_SA=${APP_GROUP_TYPED_NAMES[1]}
# 금지 profile도 계약값이 바뀌면 계속 다른 용량을 요청해야 한다.
INVALID_APP_GROUP_VOLUME_SIZE=10Gi
if [[ "$APP_GROUP_VOLUME_SIZE" == "$INVALID_APP_GROUP_VOLUME_SIZE" ]]; then
  INVALID_APP_GROUP_VOLUME_SIZE=11Gi
fi
t_ok()  { if helm template "$1" charts/app-profile -n "$PORTAL_NAMESPACE" -f $CONTRACT -f "$2" >/dev/null 2>&1; then echo "[OK]   $3"; PASS=$((PASS+1)); else echo "[FAIL] $3 (통과해야 하는데 실패)"; FAILED=$((FAILED+1)); fi; }
t_group_ok() { if helm template "$1" charts/app-profile -n "app-$1" -f $CONTRACT -f "$2" >/dev/null 2>&1; then echo "[OK]   $3"; PASS=$((PASS+1)); else echo "[FAIL] $3 (통과해야 하는데 실패)"; FAILED=$((FAILED+1)); fi; }
t_bad() { if helm template "$1" charts/app-profile -n "$PORTAL_NAMESPACE" -f $CONTRACT -f "$2" >/dev/null 2>&1; then echo "[FAIL] $3 (실패해야 하는데 통과)"; FAILED=$((FAILED+1)); else echo "[OK]   $3"; PASS=$((PASS+1)); fi; }
t_group_bad() { if helm template "$1" charts/app-profile -n "app-$1" -f $CONTRACT -f "$2" >/dev/null 2>&1; then echo "[FAIL] $3 (실패해야 하는데 통과)"; FAILED=$((FAILED+1)); else echo "[OK]   $3"; PASS=$((PASS+1)); fi; }
echo "==============================="
echo "설정파일 (yaml) 파일 체크"
echo "==============================="

t_ok  hello       apps/hello/values-beta.yaml             "external+none 정상 profile"
t_ok  secure-demo apps/secure-demo/values-beta.yaml       "external+oidc 정상 profile"
t_ok  sample-public apps/_template/values-public.yaml     "public 배포 템플릿"
t_ok  sample-sso    apps/_template/values-sso.yaml        "SSO 필수 배포 템플릿"
t_group_ok sample-stack apps/_template/values-internal.yaml "내부 전용 배포 템플릿"
t_ok  portal-lite   apps/portal-lite/values-beta.yaml     "Portal egress 정책"

# 일반 앱은 서버가 내려준 코드의 브라우저 통신도 제한한다. Portal은 요청별 nonce를
# 만드는 자체 CSP가 있으므로 Gateway의 정적 CSP로 덮어쓰지 않는다.
hello_render=$(helm template hello charts/app-profile -n "$PORTAL_NAMESPACE" \
  -f "$CONTRACT" -f apps/hello/values-beta.yaml)
if grep -q 'type: ResponseHeaderModifier' <<<"$hello_render" \
  && grep -q "connect-src 'self'" <<<"$hello_render" \
  && grep -q 'name: Cache-Control' <<<"$hello_render" \
  && grep -q 'name: X-Content-Type-Options' <<<"$hello_render"; then
  echo "[OK]   일반 외부 앱 브라우저 응답 보안 헤더"
  PASS=$((PASS+1))
else
  echo "[FAIL] 일반 외부 앱 브라우저 응답 보안 헤더 누락"
  FAILED=$((FAILED+1))
fi
portal_render=$(helm template portal-lite charts/app-profile -n "$PORTAL_NAMESPACE" \
  -f "$CONTRACT" -f apps/portal-lite/values-beta.yaml)
if ! grep -q 'type: ResponseHeaderModifier' <<<"$portal_render"; then
  echo "[OK]   Portal 자체 nonce CSP 보존"
  PASS=$((PASS+1))
else
  echo "[FAIL] Gateway 정적 CSP가 Portal 자체 nonce CSP를 덮음"
  FAILED=$((FAILED+1))
fi

TMP=$(mktemp -d)
sed -E 's/^  tag: .*/  tag: latest/'                      apps/hello/values-beta.yaml > $TMP/latest.yaml
sed 's/^service:/service:\n  type: NodePort/'             apps/hello/values-beta.yaml > $TMP/nodeport.yaml
sed "/^    APP_ENV:/a\\    DB_PASSWORD: \"p@ss\"" apps/hello/values-beta.yaml > $TMP/plainsecret.yaml
sed 's/^  host: .*/  host: hello.evil.com/'              apps/hello/values-beta.yaml > $TMP/badhost.yaml
sed "s/^  host: .*/  host: ${BASE_DOMAIN}/"              apps/hello/values-beta.yaml > $TMP/app-apex.yaml
# exposure.type 은 폐기했지만 예전 values 를 읽을 수 있어야 한다. 그때도 허용 목록 밖 값은 막는다.
sed 's/^  mode: external/  type: office-oidc/'            apps/hello/values-beta.yaml > $TMP/officeoidc.yaml
sed "s|apps/${APP_PROJECT}/${APP_ENV}/secure-demo|apps/${APP_PROJECT}/invalid/secure-demo|" apps/secure-demo/values-beta.yaml > $TMP/crosspath.yaml
cp apps/hello/values-beta.yaml $TMP/app-owned-csp.yaml
cat >>$TMP/app-owned-csp.yaml <<'EOF'
responseSecurity:
  mode: application
EOF

t_bad hello       $TMP/latest.yaml      "latest 태그 거부"
t_bad hello       $TMP/nodeport.yaml    "NodePort 거부"
t_bad hello       $TMP/plainsecret.yaml "ConfigMap 평문 Secret 거부"
t_bad hello       $TMP/badhost.yaml     "허용 외 host 거부"
t_bad hello       $TMP/app-apex.yaml    "일반 앱의 baseDomain apex 점유 거부"
t_bad hello       $TMP/officeoidc.yaml  "office-oidc 거부"
t_bad secure-demo $TMP/crosspath.yaml   "환경 교차 경로 거부"
t_bad hello       $TMP/app-owned-csp.yaml "일반 앱의 응답 보안 헤더 비활성화 거부"

# workload identity 도입 전에 Portal이 만든 단일 앱은 exact 앱 경로와 exact 앱별 role을
# 함께 썼다. 기존 릴리스를 재렌더할 수 있어야 하지만 두 계약을 섞거나 AppGroup에 재사용하면
# 고정 role의 범위를 우회할 수 있으므로 실패해야 한다.
python3 - "apps/_template/values-sso.yaml" "$TMP/legacy-single.yaml" \
  "$APP_PROJECT" "$APP_ENV" "$PORTAL_NAMESPACE" "$BASE_DOMAIN" <<'PY'
import sys, yaml

source, output, project, environment, namespace, base_domain = sys.argv[1:]
values = yaml.safe_load(open(source, encoding="utf-8"))
values["app"].update(name="legacy-single", project=project, environment=environment)
values["image"]["repository"] = "registry.example/legacy-single"
values["exposure"]["host"] = f"legacy-single.{base_domain}"
values["oidc"]["allowedGroups"] = ["legacy-single-user"]
secret = values["configuration"]["externalSecrets"][0]
secret["secretStore"] = "openbao-legacy-single"
secret["remotePath"] = f"apps/{project}/{environment}/legacy-single"
values["eso"].pop("role", None)
open(output, "w", encoding="utf-8").write(yaml.safe_dump(values, sort_keys=False))
PY
t_ok legacy-single "$TMP/legacy-single.yaml" "기존 단일 앱 생략 role + exact OpenBao path 호환"
t_bad other-release "$TMP/legacy-single.yaml" "legacy OpenBao contract의 release identity 고정"
if helm template legacy-single charts/app-profile -n other-namespace -f "$CONTRACT" \
  -f "$TMP/legacy-single.yaml" >/dev/null 2>&1; then
  echo "[FAIL] legacy OpenBao contract가 다른 Namespace에 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   legacy OpenBao contract의 workload Namespace 고정"; PASS=$((PASS+1))
fi
helm template legacy-single charts/app-profile -n team-workloads -f "$CONTRACT" \
  -f "$TMP/legacy-single.yaml" --set-string platform.portal.namespace=team-workloads \
  > "$TMP/legacy-custom-namespace-rendered.yaml"
if python3 - "$TMP/legacy-custom-namespace-rendered.yaml" \
  "eso-${APP_PROJECT}-${APP_ENV}-legacy-single" <<'PY'
import sys, yaml

documents = [doc for doc in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if doc]
store = next(doc for doc in documents if doc.get("kind") == "SecretStore")
role = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]["role"]
if role != sys.argv[2]:
    raise SystemExit(f"legacy role={role!r}, expected={sys.argv[2]!r}")
PY
then
  echo "[OK]   기존 생략 role은 workload Namespace가 아니라 project/env 공식 유지"; PASS=$((PASS+1))
else
  echo "[FAIL] 기존 생략 role 공식이 workload Namespace에 종속"; FAILED=$((FAILED+1))
fi
cp "$TMP/legacy-single.yaml" "$TMP/legacy-path-fixed-role.yaml"
sed -i '/^eso:/a\  role: portal-zone-app-eso' "$TMP/legacy-path-fixed-role.yaml"
t_bad legacy-single "$TMP/legacy-path-fixed-role.yaml" "legacy path + fixed role 혼용 거부"
cp "$TMP/legacy-single.yaml" "$TMP/canonical-path-legacy-role.yaml"
sed -i "s|apps/${APP_PROJECT}/${APP_ENV}/legacy-single|apps/${APP_PROJECT}/${APP_ENV}/workloads/${PORTAL_NAMESPACE}/eso-legacy-single|" \
  "$TMP/canonical-path-legacy-role.yaml"
sed -i "/^eso:/a\\  role: eso-${APP_PROJECT}-${APP_ENV}-legacy-single" \
  "$TMP/canonical-path-legacy-role.yaml"
t_bad legacy-single "$TMP/canonical-path-legacy-role.yaml" "canonical path + legacy role 혼용 거부"

# 고정 shared ESO role에서는 ServiceAccount identity가 곧 읽을 KV 경로다. 단일 앱이
# 다른 플랫폼 앱의 SA/SecretStore/path를 한꺼번에 가리켜도 Chart가 마지막 경계에서 막는다.
sed 's/openbao-secure-demo/openbao-portal-lite/g; s/eso-secure-demo/eso-portal-lite/g' \
  apps/secure-demo/values-beta.yaml > $TMP/cross-app-secret.yaml
sed -i '/^eso:/a\  serviceAccountName: eso-portal-lite' $TMP/cross-app-secret.yaml
t_bad secure-demo $TMP/cross-app-secret.yaml "다른 앱 ESO ServiceAccount/SecretStore 경로 거부"

cp apps/hello/values-beta.yaml $TMP/privileged-app.yaml
cat >> $TMP/privileged-app.yaml <<'YAML'
rbac:
  enabled: true
openbaoWriter:
  enabled: true
portalPipeline:
  enabled: true
  argoNamespace: devtroncd
YAML
t_bad hello $TMP/privileged-app.yaml "일반 앱 portalPipeline/OpenBao writer 권한 거부"

# --- 노출과 인증이 서로 독립인지 -------------------------------------------
# 예전 values(exposure.type)가 그대로 동작해야 한다. 이 호환이 깨지면 아직 마이그레이션
# 하지 않은 사이트의 앱이 인증 없이 열리거나 반대로 통째로 막힌다.
sed 's/^  mode: external/  type: oidc/' apps/secure-demo/values-beta.yaml \
  | sed '/^authentication:/,+1d' > $TMP/legacy-oidc.yaml
if helm template secure-demo charts/app-profile -n "$PORTAL_NAMESPACE" -f $CONTRACT -f $TMP/legacy-oidc.yaml 2>/dev/null \
   | grep -q '^kind: SecurityPolicy$'; then
  echo "[OK]   예전 exposure.type=oidc 가 계속 SSO 를 강제"; PASS=$((PASS+1))
else
  echo "[FAIL] 예전 exposure.type=oidc 하위호환 깨짐"; FAILED=$((FAILED+1))
fi

# internal + oidc 는 붙일 HTTPRoute 가 없다. 조용히 인증 없이 열리면 안 되므로 렌더를 막는다.
# t_bad 는 helm 실행 실패도 "거부"로 세므로 프로세스 치환 대신 실제 파일을 쓴다.
sed 's/^  mode: none/  mode: oidc/' apps/_template/values-internal.yaml > $TMP/internal-oidc.yaml
t_group_bad sample-stack $TMP/internal-oidc.yaml "internal + oidc 거부"

# legacy type과 새 축을 같이 쓰는 migration values는 의미가 정확히 같을 때만 받는다.
# 새 값을 조용히 우선하면 type=oidc가 보장하던 SSO를 해제할 수 있다.
cp apps/hello/values-beta.yaml $TMP/conflict-legacy-oidc-none.yaml
sed -i '/^exposure:/a\  type: oidc' $TMP/conflict-legacy-oidc-none.yaml
t_bad hello $TMP/conflict-legacy-oidc-none.yaml "legacy oidc + none 충돌 거부"

cp apps/secure-demo/values-beta.yaml $TMP/conflict-legacy-public-oidc.yaml
sed -i '/^exposure:/a\  type: public' $TMP/conflict-legacy-public-oidc.yaml
t_bad secure-demo $TMP/conflict-legacy-public-oidc.yaml "legacy public + oidc 충돌 거부"

cp apps/hello/values-beta.yaml $TMP/conflict-legacy-public-internal.yaml
sed -i '/^exposure:/a\  type: public' $TMP/conflict-legacy-public-internal.yaml
sed -i 's/^  mode: external/  mode: internal/' $TMP/conflict-legacy-public-internal.yaml
sed -i 's/^  host: .*/  host: ""/' $TMP/conflict-legacy-public-internal.yaml
t_bad hello $TMP/conflict-legacy-public-internal.yaml "legacy 외부 노출 + internal 충돌 거부"

helm template sample-internal charts/app-profile -n app-sample-stack -f $CONTRACT \
  -f apps/_template/values-internal.yaml >$TMP/internal.yaml
if ! grep -q '^kind: HTTPRoute$' $TMP/internal.yaml \
   && ! grep -q '^kind: SecurityPolicy$' $TMP/internal.yaml \
   && grep -q '^kind: Service$' $TMP/internal.yaml; then
  echo "[OK]   내부 전용 앱은 Service 만 만들고 외부 경로가 없다"; PASS=$((PASS+1))
else
  echo "[FAIL] 내부 전용 앱에 외부 경로가 생겼다"; FAILED=$((FAILED+1))
fi

# ports/expose가 없는 Compose worker는 거짓 Service/TCP probe를 만들지 않는다. egress
# NetworkPolicy와 Deployment는 남아 DNS·명시 연결/인터넷 정책을 계속 적용한다.
helm template sample-stack charts/app-profile -n app-sample-stack -f $CONTRACT \
  -f apps/_template/values-internal.yaml \
  --set service.enabled=false --set service.port=0 --set service.probe.type=none \
  --set 'networkPolicy.ingress.allowedApps=null' >$TMP/worker.yaml
if python3 - "$TMP/worker.yaml" <<'PY'
import sys, yaml
docs = [doc for doc in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if doc]
kinds = [doc["kind"] for doc in docs]
if "Deployment" not in kinds or "NetworkPolicy" not in kinds:
    raise SystemExit("worker Deployment/egress policy 누락")
if any(kind in {"Service", "HTTPRoute", "SecurityPolicy"} for kind in kinds):
    raise SystemExit(f"worker에 포트 기반 리소스가 생김: {kinds}")
policies = [doc for doc in docs if doc["kind"] == "NetworkPolicy"]
ingress = next((doc for doc in policies if doc["spec"].get("policyTypes") == ["Ingress"]), None)
if ingress is None or ingress["spec"].get("policyTypes") != ["Ingress"] or ingress["spec"].get("ingress") != []:
    raise SystemExit(f"worker 앱별 default-deny ingress 누락: {ingress}")
container = next(doc for doc in docs if doc["kind"] == "Deployment")["spec"]["template"]["spec"]["containers"][0]
if "ports" in container or "readinessProbe" in container or "livenessProbe" in container:
    raise SystemExit("worker에 거짓 port/probe가 생김")
PY
then
  echo "[OK]   포트 없는 worker는 Service/HTTPRoute/probe 없이 배포"; PASS=$((PASS+1))
else
  echo "[FAIL] 포트 없는 worker 렌더 불일치"; FAILED=$((FAILED+1))
fi

# Compose named volume은 계약 size/Class의 RWO PVC 하나이며 postgres 승인 경로의
# emptyDir를 대체한다. 같은 이름의 두 volume을 겹쳐 mount하지 않는다.
helm template sample-stack charts/app-profile -n app-sample-stack -f $CONTRACT \
  -f apps/_template/values-internal.yaml --set podSecurity.profile=postgres \
  --set persistence.enabled=true --set persistence.accessMode=ReadWriteOnce \
  --set persistence.size="$APP_GROUP_VOLUME_SIZE" \
  --set persistence.storageClass="$APP_GROUP_STORAGE_CLASS" \
  --set persistence.mountPath=/var/lib/postgresql/data --set persistence.keepOnDelete=false \
  >$TMP/persistent-postgres.yaml
if python3 - "$TMP/persistent-postgres.yaml" "$APP_GROUP_VOLUME_SIZE" "$APP_GROUP_STORAGE_CLASS" <<'PY'
import sys, yaml
docs = [doc for doc in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if doc]
expected_size, expected_storage_class = sys.argv[2:4]
pvc = next(doc for doc in docs if doc["kind"] == "PersistentVolumeClaim")
if pvc["spec"]["accessModes"] != ["ReadWriteOnce"] or pvc["spec"]["resources"]["requests"]["storage"] != expected_size:
    raise SystemExit(f"PVC 계약 불일치: {pvc['spec']}")
if pvc["spec"].get("storageClassName") != expected_storage_class:
    raise SystemExit("PVC StorageClass 계약 불일치")
deployment = next(doc for doc in docs if doc["kind"] == "Deployment")
container = deployment["spec"]["template"]["spec"]["containers"][0]
mounts = [item for item in container["volumeMounts"] if item["mountPath"] == "/var/lib/postgresql/data"]
if mounts != [{"name": "data", "mountPath": "/var/lib/postgresql/data"}]:
    raise SystemExit(f"postgres PVC mount 중복/누락: {mounts}")
if any(item["name"] == "postgres-data" for item in deployment["spec"]["template"]["spec"]["volumes"]):
    raise SystemExit("PVC와 postgres-data emptyDir가 동시에 생성됨")
PY
then
  echo "[OK]   Compose named volume은 계약 고정 RWO PVC로 렌더"; PASS=$((PASS+1))
else
  echo "[FAIL] Compose named volume PVC 렌더 불일치"; FAILED=$((FAILED+1))
fi

if helm template sample-stack charts/app-profile -n app-sample-stack -f $CONTRACT \
     -f apps/_template/values-internal.yaml --set persistence.enabled=true \
     --set persistence.size="$INVALID_APP_GROUP_VOLUME_SIZE" \
     --set persistence.storageClass="$APP_GROUP_STORAGE_CLASS" \
     --set persistence.keepOnDelete=false >/dev/null 2>&1; then
  echo "[FAIL] 계약 밖 PVC 크기가 통과함"; FAILED=$((FAILED+1))
else
  echo "[OK]   AppGroup PVC size/StorageClass 계약 우회 거부"; PASS=$((PASS+1))
fi

# AppGroup이 아닌 internal 앱도 ClusterIP는 다른 Namespace에서 호출할 수 있으므로 ingress
# policy가 필요하다. 다만 기존 Zone 내부 앱끼리는 하위호환상 같은 Namespace 전체를 연다.
sed 's/^  mode: external/  mode: internal/; s/^  host: .*/  host: ""/' \
  apps/hello/values-beta.yaml >$TMP/single-internal.yaml
helm template single-internal charts/app-profile -n research-prod -f $CONTRACT \
  -f $TMP/single-internal.yaml >$TMP/single-internal-rendered.yaml
if python3 - "$TMP/single-internal-rendered.yaml" <<'PY'
import sys, yaml

documents = [doc for doc in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if doc]
policies = [doc for doc in documents if doc["kind"] == "NetworkPolicy" and doc["metadata"]["name"].endswith("-ingress")]
if len(policies) != 1:
    raise SystemExit(f"internal 단일 앱 ingress policy 수가 다르다: {len(policies)}")
rules = policies[0]["spec"].get("ingress") or []
if len(rules) != 1:
    raise SystemExit(f"internal 단일 앱 ingress 규칙이 과도하다: {rules}")
rule = rules[0]
if rule.get("ports") != [{"protocol": "TCP", "port": 8080}]:
    raise SystemExit(f"internal 단일 앱 포트가 다르다: {rule.get('ports')}")
if rule.get("from") != [{
    "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "research-prod"}},
    "podSelector": {},
}]:
    raise SystemExit(f"internal 단일 앱 peer가 동일 Namespace로 제한되지 않았다: {rule.get('from')}")
if any(doc["kind"] in {"HTTPRoute", "SecurityPolicy"} for doc in documents):
    raise SystemExit("internal 단일 앱에 외부 경로가 생겼다")
PY
then
  echo "[OK]   internal 단일 앱은 같은 Namespace에서만 Service 포트 접근 허용"; PASS=$((PASS+1))
else
  echo "[FAIL] internal 단일 앱 ingress Namespace 경계 불일치"; FAILED=$((FAILED+1))
fi
if helm template single-internal charts/app-profile -n research-prod -f $CONTRACT \
     -f $TMP/single-internal.yaml --set networkPolicy.ingress.enabled=false >/dev/null 2>&1; then
  echo "[FAIL] internal 단일 앱 ingress 정책 비활성화가 통과함"; FAILED=$((FAILED+1))
else
  echo "[OK]   internal 단일 앱 ingress 정책 비활성화 거부"; PASS=$((PASS+1))
fi
if helm template single-internal charts/app-profile -n research-prod -f $CONTRACT \
     -f $TMP/single-internal.yaml --set networkPolicy.enabled=false >/dev/null 2>&1; then
  echo "[FAIL] internal 단일 앱 NetworkPolicy 전체 비활성화가 통과함"; FAILED=$((FAILED+1))
else
  echo "[OK]   internal 단일 앱 NetworkPolicy 전체 비활성화 거부"; PASS=$((PASS+1))
fi

# --- egressMode ------------------------------------------------------------
readarray -t INTERNAL_CIDRS < <(python3 - <<'PY'
import yaml

spec = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))["spec"]
for item in spec["network"].get("internalCIDRs") or []:
    print(item)
PY
)
# blocked: DNS 만. 인터넷도, 다른 어떤 CIDR 도 없어야 한다.
helm template hello charts/app-profile -f $CONTRACT -f apps/hello/values-beta.yaml >$TMP/blocked.yaml
if ! grep -q 'cidr: 0.0.0.0/0' $TMP/blocked.yaml \
   && grep -q 'egress-mode: "blocked"' $TMP/blocked.yaml \
   && grep -q 'port: 53' $TMP/blocked.yaml; then
  echo "[OK]   egressMode=blocked 는 DNS 만 허용"; PASS=$((PASS+1))
else
  echo "[FAIL] egressMode=blocked 정책 불일치"; FAILED=$((FAILED+1))
fi

# web: 인터넷 TCP 80/443 만. 사설망/클러스터 대역은 ipBlock.except 로 빠져야 한다.
helm template hello charts/app-profile -f $CONTRACT -f apps/hello/values-beta.yaml \
  --set networkPolicy.egressMode=web >$TMP/web.yaml
web_ok=true
grep -q 'cidr: 0.0.0.0/0' $TMP/web.yaml || web_ok=false
python3 - "$TMP/web.yaml" "${INTERNAL_CIDRS[@]}" <<'PY' || web_ok=false
import sys, yaml

path, expected = sys.argv[1], sys.argv[2:]
policy = next(
    doc for doc in yaml.safe_load_all(open(path, encoding="utf-8"))
    if doc and doc.get("kind") == "NetworkPolicy" and doc["metadata"]["name"].endswith("-egress")
)
internet = [
    rule for rule in policy["spec"]["egress"]
    if any((peer.get("ipBlock") or {}).get("cidr") == "0.0.0.0/0" for peer in rule.get("to") or [])
]
if len(internet) != 1:
    raise SystemExit(f"인터넷 규칙이 {len(internet)}개")
rule = internet[0]
ports = {(item["protocol"], item["port"]) for item in rule["ports"]}
if ports != {("TCP", 80), ("TCP", 443)}:
    raise SystemExit(f"허용 포트가 TCP 80/443 이 아니다: {sorted(ports)}")
except_list = rule["to"][0]["ipBlock"].get("except") or []
if sorted(except_list) != sorted(expected):
    raise SystemExit(f"except 목록이 계약과 다르다: {except_list}")
# 인터넷 규칙 말고 다른 곳에서 0.0.0.0/0 이 열리면 안 된다.
for other in policy["spec"]["egress"]:
    if other is rule:
        continue
    for peer in other.get("to") or []:
        if (peer.get("ipBlock") or {}).get("cidr", "").endswith("/0"):
            raise SystemExit("다른 규칙에서 전체 대역이 열렸다")
PY
if [[ ${web_ok} == true ]]; then
  echo "[OK]   egressMode=web 은 인터넷 TCP 80/443 만 열고 사설망을 제외"; PASS=$((PASS+1))
else
  echo "[FAIL] egressMode=web 정책 불일치"; FAILED=$((FAILED+1))
fi

# web 모드에서 계약값이 비면 사설망까지 열리므로 렌더가 실패해야 한다.
if helm template hello charts/app-profile -f $CONTRACT -f apps/hello/values-beta.yaml \
     --set networkPolicy.egressMode=web --set 'platform.network.internalCIDRs=null' >/dev/null 2>&1; then
  echo "[FAIL] internalCIDRs 없이 web 모드가 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   internalCIDRs 없는 web 모드 거부"; PASS=$((PASS+1))
fi

# custom 이 아닌 모드에서 CIDR 직접 지정은 막는다.
if helm template hello charts/app-profile -f $CONTRACT -f apps/hello/values-beta.yaml \
     --set networkPolicy.egressMode=blocked \
     --set 'networkPolicy.allowedCIDRs[0].cidr=203.0.113.10/32' \
     --set 'networkPolicy.allowedCIDRs[0].port=443' >/dev/null 2>&1; then
  echo "[FAIL] blocked 모드에서 allowedCIDRs 가 통과함"; FAILED=$((FAILED+1))
else
  echo "[OK]   blocked/web 모드의 allowedCIDRs 거부"; PASS=$((PASS+1))
fi

# API/ci-guard만 믿지 않고 Helm도 전체 인터넷 CIDR과 단일 Zone allowedApps 우회를 막는다.
if helm template hello charts/app-profile -f $CONTRACT -f apps/hello/values-beta.yaml \
     --set networkPolicy.egressMode=custom \
     --set-string 'networkPolicy.allowedCIDRs[0].cidr=0.0.0.0/0' \
     --set-string 'networkPolicy.allowedCIDRs[0].protocol=TCP' \
     --set 'networkPolicy.allowedCIDRs[0].port=22' >/dev/null 2>&1; then
  echo "[FAIL] custom 전체 인터넷 CIDR이 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   custom 전체 인터넷 CIDR 거부"; PASS=$((PASS+1))
fi
if helm template hello charts/app-profile -f $CONTRACT -f apps/hello/values-beta.yaml \
     --set-string 'networkPolicy.allowedApps[0].app=api' \
     --set 'networkPolicy.allowedApps[0].port=8080' >/dev/null 2>&1; then
  echo "[FAIL] 단일 Zone 앱에서 allowedApps가 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   allowedApps는 AppGroup에서만 허용"; PASS=$((PASS+1))
fi

# --- AppGroup 다중 앱 -------------------------------------------------------
helm template mobility-platform charts/app-group -n app-mobility-platform -f $CONTRACT \
  --set group.name=mobility-platform --set group.project=${APP_PROJECT} \
  --set group.environment=${APP_ENV} >$TMP/group.yaml
if python3 - "$TMP/group.yaml" "$APP_GROUP_PULL_STORE" <<'PY'
import sys, yaml

documents = [doc for doc in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if doc]
expected_store = sys.argv[2]
kinds = {doc["kind"] for doc in documents}
required = {"Namespace", "NetworkPolicy", "ResourceQuota", "LimitRange", "Role", "RoleBinding"}
missing = required - kinds
if missing:
    raise SystemExit(f"AppGroup Namespace bootstrap 누락: {sorted(missing)}")
namespace = next(doc for doc in documents if doc["kind"] == "Namespace")
if namespace["metadata"]["labels"].get("platform.example.io/route") != "allowed":
    raise SystemExit("Gateway allowedRoutes label 이 없다")
if namespace["metadata"]["labels"].get("platform.example.io/app-group") != "true":
    raise SystemExit("고정 OpenBao AppGroup role이 선택할 불변 label 이 없다")
platform = yaml.safe_load(
    open("contracts/values-platform-production.yaml", encoding="utf-8")
)["platform"]
if namespace["metadata"].get("annotations", {}).get("field.cattle.io/projectId") != \
        platform["rancher"]["workloadProjectId"]:
    raise SystemExit("AppGroup Namespace Rancher project annotation이 계약값과 다르다")
denies = {
    doc["metadata"]["name"]: doc["spec"]["policyTypes"]
    for doc in documents if doc["kind"] == "NetworkPolicy"
}
if denies.get("default-deny-ingress") != ["Ingress"] or denies.get("default-deny-egress") != ["Egress"]:
    raise SystemExit(f"기본 차단 정책이 없다: {denies}")
quota = next(doc for doc in documents if doc["kind"] == "ResourceQuota")
contract_pods = platform["quota"]["maxReplicas"]
if int(quota["spec"]["hard"].get("pods", 0)) != int(contract_pods):
    raise SystemExit("AppGroup Pod quota가 API/플랫폼 maxReplicas 계약과 다르다")
storage = platform["appGroups"]["storage"]
if int(quota["spec"]["hard"].get("persistentvolumeclaims", 0)) != int(storage["maxClaims"]):
    raise SystemExit("AppGroup PVC count quota가 계약과 다르다")
if quota["spec"]["hard"].get("requests.storage") != storage["total"]:
    raise SystemExit("AppGroup requests.storage quota가 계약과 다르다")
store = next((doc for doc in documents if doc["kind"] == "ClusterSecretStore"), None)
pull = next((doc for doc in documents if doc["kind"] == "ExternalSecret"), None)
if not store or not pull:
    raise SystemExit("registry pull Secret의 OpenBao -> ESO 리소스가 없다")
if store["metadata"].get("namespace"):
    raise SystemExit("ClusterSecretStore에 metadata.namespace가 있으면 안 된다")
if store["spec"].get("conditions") != [{"namespaces": ["app-mobility-platform"]}]:
    raise SystemExit(f"ClusterSecretStore Namespace 조건이 다르다: {store['spec'].get('conditions')}")
vault = store["spec"]["provider"]["vault"]
if vault["caProvider"].get("namespace") != "openbao":
    raise SystemExit("OpenBao CA ConfigMap Namespace가 계약값이 아니다")
sa_ref = vault["auth"]["kubernetes"]["serviceAccountRef"]
if sa_ref.get("namespace") != "app-mobility-platform":
    raise SystemExit("ESO ServiceAccountRef가 AppGroup Namespace에 묶이지 않았다")
if pull["spec"]["secretStoreRef"].get("kind") != "ClusterSecretStore":
    raise SystemExit("registry ExternalSecret이 ClusterSecretStore를 참조하지 않는다")
if store["metadata"]["name"] != expected_store:
    raise SystemExit(f"registry ClusterSecretStore typed-name golden 불일치: {store['metadata']['name']}")
service_account = next(doc for doc in documents if doc["kind"] == "ServiceAccount")
if service_account["metadata"]["name"] != "eso-registry":
    raise SystemExit(f"registry ESO ServiceAccount typed-name golden 불일치: {service_account['metadata']['name']}")
PY
then
  echo "[OK]   AppGroup Namespace 가 quota/기본차단/route label 과 함께 생성"; PASS=$((PASS+1))
else
  echo "[FAIL] AppGroup Namespace bootstrap 불일치"; FAILED=$((FAILED+1))
fi
if helm template mobility-platform charts/app-group -n other-mobility-platform -f $CONTRACT \
  --set group.name=mobility-platform --set group.project=${APP_PROJECT} \
  --set group.environment=${APP_ENV} --set group.namespacePrefix=other- >/dev/null 2>&1; then
  echo "[FAIL] AppGroup Namespace prefix 계약 우회가 통과함"; FAILED=$((FAILED+1))
else
  echo "[OK]   AppGroup Namespace prefix 계약 우회 거부"; PASS=$((PASS+1))
fi
if helm template mobility-platform charts/app-group -n other-mobility-platform -f $CONTRACT \
  --set group.name=mobility-platform --set group.project=${APP_PROJECT} \
  --set group.environment=${APP_ENV} --set group.namespace=other-mobility-platform >/dev/null 2>&1; then
  echo "[FAIL] AppGroup explicit Namespace 계약 우회가 통과함"; FAILED=$((FAILED+1))
else
  echo "[OK]   AppGroup explicit Namespace 계약 우회 거부"; PASS=$((PASS+1))
fi
if helm template mobility-platform charts/app-group -n app-mobility-platform -f $CONTRACT \
  --set group.name=mobility-platform --set group.project=${APP_PROJECT} \
  --set group.environment=${APP_ENV} --set-string platform.rancher.workloadProjectId= \
  >/dev/null 2>&1; then
  echo "[FAIL] Rancher project 없는 AppGroup Namespace가 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   Rancher project 없는 AppGroup Namespace 거부"; PASS=$((PASS+1))
fi
if helm template mobility-platform charts/app-group -n app-mobility-platform -f $CONTRACT \
  --set group.name=mobility-platform --set group.project=${APP_PROJECT} \
  --set group.environment=${APP_ENV} --set quota.pods=8 >/dev/null 2>&1; then
  echo "[FAIL] 계약과 다른 AppGroup Pod quota가 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   AppGroup Pod quota/API 상한 불일치 거부"; PASS=$((PASS+1))
fi

# 비 HTTP Compose 서비스는 TCP probe를 쓸 수 있고, probe를 제공하지 못하는 앱은 명시적으로
# 생략할 수 있다. 기존 values는 기본 HTTP /healthz를 유지한다.
helm template probe-tcp charts/app-profile -f $CONTRACT -f apps/hello/values-beta.yaml \
  --set service.probe.type=tcp >$TMP/probe-tcp.yaml
helm template probe-none charts/app-profile -f $CONTRACT -f apps/hello/values-beta.yaml \
  --set service.probe.type=none >$TMP/probe-none.yaml
if grep -q 'tcpSocket:' $TMP/probe-tcp.yaml && ! grep -q 'httpGet:' $TMP/probe-tcp.yaml \
   && ! grep -q 'readinessProbe:' $TMP/probe-none.yaml \
   && ! grep -q 'livenessProbe:' $TMP/probe-none.yaml; then
  echo "[OK]   HTTP/TCP/none probe profile 분리"; PASS=$((PASS+1))
else
  echo "[FAIL] probe profile 렌더 불일치"; FAILED=$((FAILED+1))
fi

# DB/cache 지원은 raw hostPath나 임의 mount가 아니라 고정 preset으로만 연다. root filesystem,
# seccomp, capability 방어선은 기존 Deployment securityContext에 그대로 남아야 한다.
helm template preset-postgres charts/app-profile -f $CONTRACT -f apps/hello/values-beta.yaml \
  --set podSecurity.profile=postgres --set service.probe.type=tcp >$TMP/preset-postgres.yaml
helm template preset-redis charts/app-profile -f $CONTRACT -f apps/hello/values-beta.yaml \
  --set podSecurity.profile=redis --set service.probe.type=tcp >$TMP/preset-redis.yaml
if grep -q 'runAsUser: 999' $TMP/preset-postgres.yaml \
   && grep -q 'mountPath: /var/lib/postgresql/data' $TMP/preset-postgres.yaml \
   && grep -q 'mountPath: /var/run/postgresql' $TMP/preset-postgres.yaml \
   && grep -q 'mountPath: /data' $TMP/preset-redis.yaml \
   && grep -q 'readOnlyRootFilesystem: true' $TMP/preset-postgres.yaml \
   && grep -q 'drop: \["ALL"\]' $TMP/preset-postgres.yaml; then
  echo "[OK]   postgres/redis 제한 preset과 기존 보안 context 유지"; PASS=$((PASS+1))
else
  echo "[FAIL] postgres/redis preset 렌더 불일치"; FAILED=$((FAILED+1))
fi

# 같은 AppGroup 안에서 선언한 연결만 열려야 한다.
cat > $TMP/group-api.yaml <<EOF
app:
  name: api
  group: mobility-platform
  project: ${APP_PROJECT}
  environment: ${APP_ENV}
image:
  repository: forgejo.example.invalid/api
  tag: '0000000000000000000000000000000000000000'
service:
  port: 8080
exposure:
  enabled: true
  mode: internal
  host: ''
authentication:
  mode: none
networkPolicy:
  egressMode: web
  allowedApps:
  - app: postgres
    port: 5432
  ingress:
    allowedApps:
    - app: frontend
      port: 8080
configuration:
  externalSecrets:
    - name: app-env
      secretStore: openbao-api
      remotePath: apps/${APP_PROJECT}/${APP_ENV}/workloads/app-mobility-platform/${APP_GROUP_API_ESO_SA}
      inject: true
      keys:
        - API_TOKEN
eso:
  createSecretStore: true
EOF
python3 - "$TMP/group-api.yaml" "$TMP/group-legacy-secret.yaml" \
  "$APP_PROJECT" "$APP_ENV" <<'PY'
import sys, yaml

source, output, project, environment = sys.argv[1:]
values = yaml.safe_load(open(source, encoding="utf-8"))
values["configuration"]["externalSecrets"][0]["remotePath"] = \
    f"apps/{project}/{environment}/api"
values.setdefault("eso", {})["role"] = "eso-app-mobility-platform-api"
open(output, "w", encoding="utf-8").write(yaml.safe_dump(values, sort_keys=False))
PY
t_group_bad mobility-platform "$TMP/group-legacy-secret.yaml" "AppGroup legacy OpenBao path/role 거부"
# app-profile의 Service/Deployment와 Compose 입력은 TCP만 지원한다. allowedCIDRs의 UDP는
# 계속 허용하지만 앱 이름 연결만 UDP로 열어 지원되는 것처럼 보이게 해서는 안 된다.
if helm template api charts/app-profile -n app-mobility-platform -f $CONTRACT \
     -f $TMP/group-api.yaml --set-string 'networkPolicy.allowedApps[0].protocol=UDP' \
     >/dev/null 2>&1; then
  echo "[FAIL] AppGroup egress allowedApps UDP가 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   AppGroup egress allowedApps는 TCP만 허용"; PASS=$((PASS+1))
fi
if helm template api charts/app-profile -n app-mobility-platform -f $CONTRACT \
     -f $TMP/group-api.yaml --set-string 'networkPolicy.ingress.allowedApps[0].protocol=UDP' \
     >/dev/null 2>&1; then
  echo "[FAIL] AppGroup ingress allowedApps UDP가 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   AppGroup ingress allowedApps는 TCP만 허용"; PASS=$((PASS+1))
fi
helm template api charts/app-profile -n app-mobility-platform -f $CONTRACT -f $TMP/group-api.yaml \
  >$TMP/group-api-rendered.yaml
if helm template api charts/app-profile -n research-prod -f $CONTRACT -f $TMP/group-api.yaml \
     >/dev/null 2>&1; then
  echo "[FAIL] AppGroup 앱이 계약 밖 Namespace에 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   AppGroup 앱 Release.Namespace 계약 강제"; PASS=$((PASS+1))
fi
if python3 - "$TMP/group-api-rendered.yaml" "$APP_PROJECT" "$APP_ENV" <<'PY'
import sys, yaml

documents = [doc for doc in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if doc]
project, environment = sys.argv[2:]
policies = {doc["metadata"]["name"]: doc for doc in documents if doc["kind"] == "NetworkPolicy"}
egress_policy = next(doc for doc in policies.values() if doc["spec"]["policyTypes"] == ["Egress"])
ingress_policy = next(doc for doc in policies.values() if doc["spec"]["policyTypes"] == ["Ingress"])
if not egress_policy["metadata"]["name"].startswith("np-e-api-"):
    raise SystemExit(f"egress typed name이 아니다: {egress_policy['metadata']['name']}")
if not ingress_policy["metadata"]["name"].startswith("np-i-api-"):
    raise SystemExit(f"ingress typed name이 아니다: {ingress_policy['metadata']['name']}")
egress = egress_policy["spec"]["egress"]
ingress = ingress_policy["spec"]["ingress"]

def app_peers(rules, key):
    found = set()
    for rule in rules:
        for peer in rule.get(key) or []:
            selector = (peer.get("podSelector") or {}).get("matchLabels") or {}
            name = selector.get("app.kubernetes.io/name")
            # namespaceSelector 가 붙으면 다른 AppGroup 으로 나갈 수 있다는 뜻이다.
            if name and "namespaceSelector" not in peer:
                found.add((name, rule["ports"][0]["port"]))
    return found

if app_peers(egress, "to") != {("postgres", 5432)}:
    raise SystemExit(f"egress 앱 연결이 다르다: {app_peers(egress, 'to')}")
if app_peers(ingress, "from") != {("frontend", 8080)}:
    raise SystemExit(f"ingress 앱 연결이 다르다: {app_peers(ingress, 'from')}")
if any("redis" in str(rule) for rule in egress):
    raise SystemExit("선언하지 않은 앱이 열렸다")
stores = [doc for doc in documents if doc["kind"] == "ClusterSecretStore"]
secrets = [doc for doc in documents if doc["kind"] == "ExternalSecret"]
if len(stores) != 1 or len(secrets) != 1:
    raise SystemExit("그룹 앱 ClusterSecretStore/ExternalSecret이 한 벌이 아니다")
store = stores[0]
if store["spec"].get("conditions") != [{"namespaces": ["app-mobility-platform"]}]:
    raise SystemExit("그룹 앱 ClusterSecretStore가 Namespace 하나에 묶이지 않았다")
vault = store["spec"]["provider"]["vault"]
if vault["caProvider"].get("namespace") != "openbao":
    raise SystemExit("그룹 앱 OpenBao CA Namespace가 계약과 다르다")
if vault["auth"]["kubernetes"]["serviceAccountRef"].get("namespace") != "app-mobility-platform":
    raise SystemExit("그룹 앱 ESO ServiceAccount Namespace가 다르다")
service_account = next(doc for doc in documents if doc["kind"] == "ServiceAccount")
expected_path = f"apps/{project}/{environment}/workloads/app-mobility-platform/{service_account['metadata']['name']}"
if secrets[0]["spec"]["data"][0]["remoteRef"]["key"] != expected_path:
    raise SystemExit("그룹 앱 OpenBao 경로가 Namespace/ServiceAccount identity와 다르다")
PY
then
  echo "[OK]   AppGroup 앱은 선언한 연결만 열린다"; PASS=$((PASS+1))
else
  echo "[FAIL] AppGroup 앱 사이 정책 불일치"; FAILED=$((FAILED+1))
fi

# app 이름이 default-deny여도 Namespace baseline NetworkPolicy 이름을 덮어쓸 수 없다.
sed \
  -e 's/name: api/name: default-deny/' \
  "$TMP/group-api.yaml" >"$TMP/group-default-deny.yaml"
if helm template default-deny charts/app-profile -n app-mobility-platform -f $CONTRACT \
     -f "$TMP/group-default-deny.yaml" --set-json 'configuration.externalSecrets=[]' \
     --set eso.createSecretStore=false >"$TMP/group-default-deny-rendered.yaml" \
   && python3 - "$TMP/group-default-deny-rendered.yaml" <<'PY'
import sys, yaml

documents = [doc for doc in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if doc]
names = {
    doc["metadata"]["name"]
    for doc in documents if doc.get("kind") == "NetworkPolicy"
}
if "default-deny-ingress" in names or "default-deny-egress" in names:
    raise SystemExit(f"앱 NetworkPolicy가 Namespace baseline 이름을 사용한다: {names}")
if not any(name.startswith("np-i-default-deny-") for name in names) or \
   not any(name.startswith("np-e-default-deny-") for name in names):
    raise SystemExit(f"typed NetworkPolicy 이름이 없다: {names}")
PY
then
  echo "[OK]   default-deny 앱 이름은 Namespace baseline 정책을 덮지 않는다"; PASS=$((PASS+1))
else
  echo "[FAIL] default-deny 앱 NetworkPolicy 이름 충돌"; FAILED=$((FAILED+1))
fi

# '-' 단순 연결로는 (group=x-app-y, app=z)와 (group=x, app=y-app-z)가 같다.
# Chart의 cluster-scoped store와 ESO SA/NetworkPolicy는 canonical tuple hash로 분리돼야 한다.
python3 - "$TMP/group-api.yaml" "$TMP/collision-a.yaml" "$TMP/collision-b.yaml" \
  "$APP_PROJECT" "$APP_ENV" <<'PY'
import sys, yaml

source, out_a, out_b, project, environment = sys.argv[1:]
base = yaml.safe_load(open(source, encoding="utf-8"))
for output, group, app in ((out_a, "x-app-y", "z"), (out_b, "x", "y-app-z")):
    values = yaml.safe_load(yaml.safe_dump(base))
    values["app"].update(name=app, group=group, project=project, environment=environment)
    values["networkPolicy"]["allowedApps"] = []
    values["networkPolicy"]["ingress"]["allowedApps"] = []
    canonical = f"v1/app/{project}/{environment}/{group}/{app}"
    suffix = __import__("hashlib").sha256(f"eso-sa-a-|{canonical}".encode()).hexdigest()[:10]
    sa = f"eso-sa-a-{app[:43].rstrip('-')}-{suffix}"
    values["configuration"]["externalSecrets"][0]["remotePath"] = \
        f"apps/{project}/{environment}/workloads/app-{group}/{sa}"
    open(output, "w", encoding="utf-8").write(yaml.safe_dump(values, sort_keys=False))
PY
if helm template z charts/app-profile -n app-x-app-y -f $CONTRACT -f "$TMP/collision-a.yaml" \
     >"$TMP/collision-a-rendered.yaml" \
   && helm template y-app-z charts/app-profile -n app-x -f $CONTRACT -f "$TMP/collision-b.yaml" \
     >"$TMP/collision-b-rendered.yaml" \
   && python3 - "$TMP/collision-a-rendered.yaml" "$TMP/collision-b-rendered.yaml" <<'PY'
import re, sys, yaml

def typed_names(path):
    documents = [doc for doc in yaml.safe_load_all(open(path, encoding="utf-8")) if doc]
    return {
        doc["metadata"]["name"]
        for doc in documents
        if doc.get("kind") in {"NetworkPolicy", "ClusterSecretStore", "ServiceAccount"}
    }

first, second = map(typed_names, sys.argv[1:])
if first & second:
    raise SystemExit(f"서로 다른 tuple의 보조 리소스 이름 충돌: {first & second}")
dns_label = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
if any(len(name) > 63 or not dns_label.fullmatch(name) for name in first | second):
    raise SystemExit(f"typed name이 DNS label이 아님: {first | second}")
PY
then
  echo "[OK]   AppGroup tuple 분할이 달라도 typed 보조 리소스는 충돌하지 않는다"; PASS=$((PASS+1))
else
  echo "[FAIL] AppGroup typed 보조 리소스 tuple 충돌"; FAILED=$((FAILED+1))
fi

# CSS slug 절단점이 연속 '-' 위에 걸려도 hash 앞 이름은 '-'로 끝나지 않아야 한다.
python3 - "$TMP/group-api.yaml" "$TMP/collision-trim.yaml" "$APP_PROJECT" "$APP_ENV" <<'PY'
import sys, yaml

source, output, project, environment = sys.argv[1:]
values = yaml.safe_load(open(source, encoding="utf-8"))
group, app = "g" * 40, "aa---b"
values["app"].update(name=app, group=group, project=project, environment=environment)
values["networkPolicy"]["allowedApps"] = []
values["networkPolicy"]["ingress"]["allowedApps"] = []
canonical = f"v1/app/{project}/{environment}/{group}/{app}"
suffix = __import__("hashlib").sha256(f"eso-sa-a-|{canonical}".encode()).hexdigest()[:10]
sa = f"eso-sa-a-{app[:43].rstrip('-')}-{suffix}"
values["configuration"]["externalSecrets"][0]["remotePath"] = \
    f"apps/{project}/{environment}/workloads/app-{group}/{sa}"
open(output, "w", encoding="utf-8").write(yaml.safe_dump(values, sort_keys=False))
PY
if helm template aa---b charts/app-profile -n "app-$(printf 'g%.0s' {1..40})" \
     -f $CONTRACT -f "$TMP/collision-trim.yaml" >"$TMP/collision-trim-rendered.yaml" \
   && python3 - "$TMP/collision-trim-rendered.yaml" <<'PY'
import re, sys, yaml

stores = [doc for doc in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if doc and doc.get("kind") == "ClusterSecretStore"]
name = stores[0]["metadata"]["name"]
if "--" in name or not re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", name):
    raise SystemExit(f"연속 dash 절단 결과가 DNS label이 아님: {name}")
PY
then
  echo "[OK]   typed name 연속 dash 절단은 DNS label을 유지"; PASS=$((PASS+1))
else
  echo "[FAIL] typed name 연속 dash 절단 불일치"; FAILED=$((FAILED+1))
fi

# AppGroup의 ingress policy를 끄면 Namespace default-deny에서 Gateway와 선언한 앱 모두
# 닿지 못한다. API를 우회한 values도 Chart가 마지막 방어선에서 막아야 한다.
if helm template api charts/app-profile -n app-mobility-platform -f $CONTRACT \
  -f $TMP/group-api.yaml --set networkPolicy.ingress.enabled=false >/dev/null 2>&1; then
  echo "[FAIL] AppGroup ingress.enabled=false가 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   AppGroup ingress.enabled=false 거부"; PASS=$((PASS+1))
fi

# ConfigMap과 OpenBao Secret에 같은 key가 있으면 envFrom 순서에 의존하지 않고 거부한다.
if helm template hello charts/app-profile -f $CONTRACT -f apps/hello/values-beta.yaml \
  --set-string 'configuration.externalSecrets[0].name=duplicate' \
  --set-string 'configuration.externalSecrets[0].secretStore=openbao-hello' \
  --set-string "configuration.externalSecrets[0].remotePath=apps/${APP_PROJECT}/${APP_ENV}/workloads/${APP_PROJECT}-${APP_ENV}/eso-hello" \
  --set-string 'configuration.externalSecrets[0].keys[0]=APP_ENV' >/dev/null 2>&1; then
  echo "[FAIL] ConfigMap/OpenBao env key 중복 거부"; FAILED=$((FAILED+1))
else
  echo "[OK]   ConfigMap/OpenBao env key 중복 거부"; PASS=$((PASS+1))
fi

helm template sample-public charts/app-profile -f $CONTRACT \
  -f apps/_template/values-public.yaml >$TMP/public.yaml
helm template sample-sso charts/app-profile -f $CONTRACT \
  -f apps/_template/values-sso.yaml >$TMP/sso.yaml
if grep -q '^kind: SecurityPolicy$' $TMP/public.yaml; then
  echo "[FAIL] public 템플릿이 SSO SecurityPolicy를 생성함"; FAILED=$((FAILED+1))
else
  echo "[OK]   public 템플릿은 로그인 없이 접근"; PASS=$((PASS+1))
fi
if grep -q '^kind: ExternalSecret$' $TMP/public.yaml; then
  echo "[FAIL] Secret 없는 public 템플릿이 ExternalSecret을 생성함"; FAILED=$((FAILED+1))
else
  echo "[OK]   Secret 없는 public 템플릿은 OIDC/OpenBao 리소스 불필요"; PASS=$((PASS+1))
fi
if grep -q '^kind: SecurityPolicy$' $TMP/sso.yaml \
   && grep -q '^kind: ExternalSecret$' $TMP/sso.yaml \
   && grep -q "clientID: \"sample-sso-${APP_ENV}\"" $TMP/sso.yaml; then
  echo "[OK]   SSO 템플릿은 외부 OIDC 인증을 강제"; PASS=$((PASS+1))
else
  echo "[FAIL] 템플릿의 OIDC 리소스 누락"; FAILED=$((FAILED+1))
fi
if helm template sample-sso charts/app-profile -f $CONTRACT \
     -f apps/_template/values-sso.yaml --set 'configuration.externalSecrets=null' >/dev/null 2>&1; then
  echo "[FAIL] OIDC ExternalSecret 없는 앱이 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   OIDC ExternalSecret 누락 거부"; PASS=$((PASS+1))
fi
for invalid_oidc in \
  'oidc.callbackPath=/wrong/callback' \
  'configuration.externalSecrets[0].inject=true' \
  'configuration.externalSecrets[0].targetKeyMap.OIDC_CLIENT_SECRET=wrong-key'; do
  if helm template sample-sso charts/app-profile -f $CONTRACT \
       -f apps/_template/values-sso.yaml --set-string "$invalid_oidc" >/dev/null 2>&1; then
    echo "[FAIL] 잘못된 OIDC 계약이 렌더됨: $invalid_oidc"; FAILED=$((FAILED+1))
  else
    echo "[OK]   잘못된 OIDC 계약 거부: $invalid_oidc"; PASS=$((PASS+1))
  fi
done
if helm template sample-sso charts/app-profile -f $CONTRACT \
     -f apps/_template/values-sso.yaml --set authentication.mode=none >/dev/null 2>&1; then
  echo "[FAIL] authentication=none 앱에 OIDC ExternalSecret이 남음"; FAILED=$((FAILED+1))
else
  echo "[OK]   authentication=none의 OIDC ExternalSecret 거부"; PASS=$((PASS+1))
fi

python3 - apps/_template/values-public.yaml "$TMP/public-runtime-secret.yaml" \
  "$APP_PROJECT" "$APP_ENV" "$PORTAL_NAMESPACE" <<'PY'
import sys, yaml

source, output, project, environment, namespace = sys.argv[1:]
values = yaml.safe_load(open(source, encoding="utf-8"))
values["configuration"]["externalSecrets"] = [{
    "name": "runtime",
    "secretStore": "openbao-sample-public",
    "remotePath": f"apps/{project}/{environment}/workloads/{namespace}/eso-sample-public",
    "keys": ["API_TOKEN"],
}]
values["eso"] = {"createSecretStore": True, "role": "portal-zone-app-eso"}
open(output, "w", encoding="utf-8").write(yaml.safe_dump(values, sort_keys=False))
PY
if helm template sample-public charts/app-profile -n "$PORTAL_NAMESPACE" -f $CONTRACT \
     -f "$TMP/public-runtime-secret.yaml" >"$TMP/public-runtime-secret-rendered.yaml" \
   && grep -q '^kind: ExternalSecret$' "$TMP/public-runtime-secret-rendered.yaml"; then
  echo "[OK]   runtime Secret 앱은 canonical OpenBao ExternalSecret 생성"; PASS=$((PASS+1))
else
  echo "[FAIL] runtime Secret 앱의 ExternalSecret 계약 누락"; FAILED=$((FAILED+1))
fi
# clientSecretName을 바꾸면 SecurityPolicy 참조만 바뀌고 ESO target은 예전 이름에 남는
# 반쪽 override가 되어 로그인이 시작되지 않는다. 기본/사용자 지정 이름을 함께 대조한다.
helm template sample-sso-custom charts/app-profile -f $CONTRACT \
  -f apps/_template/values-sso.yaml \
  --set-string oidc.clientSecretName=custom-oidc-client >$TMP/sso-custom-secret.yaml
if python3 - "$TMP/sso.yaml" "$TMP/sso-custom-secret.yaml" <<'PY'
import sys, yaml

for path, expected in zip(sys.argv[1:], ("sample-sso-oidc-client", "custom-oidc-client")):
    documents = [doc for doc in yaml.safe_load_all(open(path, encoding="utf-8")) if doc]
    policy = next(doc for doc in documents if doc["kind"] == "SecurityPolicy")
    oidc_secret = next(
        doc for doc in documents
        if doc["kind"] == "ExternalSecret"
        and any(item["remoteRef"]["property"] == "OIDC_CLIENT_SECRET"
                for item in doc["spec"]["data"])
    )
    referenced = policy["spec"]["oidc"]["clientSecret"]["name"]
    target = oidc_secret["spec"]["target"]["name"]
    if referenced != expected or target != expected:
        raise SystemExit(
            f"OIDC client Secret 이름 불일치: expected={expected}, "
            f"SecurityPolicy={referenced}, ExternalSecret target={target}"
        )
PY
then
  echo "[OK]   OIDC client Secret 기본/사용자 지정 이름 일치"; PASS=$((PASS+1))
else
  echo "[FAIL] OIDC client Secret 이름 불일치"; FAILED=$((FAILED+1))
fi
# 외부 IdP 로그인이 성공해도 승인 그룹이 아니면 통과하면 안 된다. 앱이 선언한 그룹만
# Allow 되는지 본다.
if grep -q 'defaultAction: Deny' $TMP/sso.yaml \
   && grep -q 'provider: external-oidc' $TMP/sso.yaml \
   && grep -q '"sample-sso-user"' $TMP/sso.yaml; then
  echo "[OK]   SSO 템플릿은 허용 그룹만 통과시킨다"; PASS=$((PASS+1))
else
  echo "[FAIL] SSO 그룹 인가 규칙 누락"; FAILED=$((FAILED+1))
fi
if helm template sample-sso charts/app-profile -f $CONTRACT \
     -f apps/_template/values-sso.yaml --set 'oidc.allowedGroups=null' >/dev/null 2>&1; then
  echo "[FAIL] allowedGroups 없는 OIDC 앱이 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   allowedGroups 없는 OIDC 앱 거부"; PASS=$((PASS+1))
fi
if helm template sample-sso-off charts/app-profile -f $CONTRACT \
     -f apps/_template/values-sso.yaml --set replicaCount=0 --set exposure.enabled=false \
     --set 'oidc.allowedGroups=null' >/dev/null 2>&1; then
  echo "[FAIL] 노출 중지 상태에서 allowedGroups 없는 OIDC 앱이 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   노출 중지 상태도 OIDC allowedGroups 누락 거부"; PASS=$((PASS+1))
fi
if helm template invalid-stop-route charts/app-profile -f $CONTRACT \
     -f apps/_template/values-public.yaml --set replicaCount=0 >/dev/null 2>&1; then
  echo "[FAIL] replica 0인데 외부 Route가 켜진 앱이 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   replica 0/외부 Route 활성 불일치 거부"; PASS=$((PASS+1))
fi
if helm template invalid-route-only-stop charts/app-profile -f $CONTRACT \
     -f apps/_template/values-public.yaml --set exposure.enabled=false >/dev/null 2>&1; then
  echo "[FAIL] 실행 Pod를 둔 채 외부 Route만 중지한 앱이 렌더됨"; FAILED=$((FAILED+1))
else
  echo "[OK]   외부 Route 비활성/replica 양수 불일치 거부"; PASS=$((PASS+1))
fi
if helm template sample-sso charts/app-profile -f $CONTRACT \
     -f apps/_template/values-sso.yaml \
     --set 'oidc.allowedGroups[0]=bad group' >/dev/null 2>&1; then
  echo "[FAIL] 잘못된 그룹 이름이 통과함"; FAILED=$((FAILED+1))
else
  echo "[OK]   잘못된 그룹 이름 거부"; PASS=$((PASS+1))
fi
readarray -t GROUP_TYPED_NAMES < <(python3 - "${APP_PROJECT}" "${APP_ENV}" <<'PY'
import hashlib, sys

project, environment = sys.argv[1:]
canonical = f"v1/app/{project}/{environment}/mobility-platform/api"
def typed(prefix, slug):
    digest = hashlib.sha256(f"{prefix}|{canonical}".encode()).hexdigest()[:10]
    return f"{prefix}{slug[:52-len(prefix)].rstrip('-')}-{digest}"
print(typed("ga-", "api-mobility-platform"))
print(typed("oc-a-", f"mobility-platform-api-{environment}"))
print(typed("og-a-", "mobility-platform-api-user"))
print(typed("css-a-", "mobility-platform-api"))
print(typed("eso-sa-a-", "api"))
print(typed("np-i-", "api"))
print(typed("np-e-", "api"))
PY
)
GROUP_APP_HOST=${GROUP_TYPED_NAMES[0]}.${BASE_DOMAIN}
GROUP_OIDC_CLIENT=${GROUP_TYPED_NAMES[1]}
GROUP_ALLOWED_GROUP=${GROUP_TYPED_NAMES[2]}
GROUP_SECRET_STORE=${GROUP_TYPED_NAMES[3]}
GROUP_ESO_SA=${GROUP_TYPED_NAMES[4]}
GROUP_INGRESS_NP=${GROUP_TYPED_NAMES[5]}
GROUP_EGRESS_NP=${GROUP_TYPED_NAMES[6]}
helm template group-sso charts/app-profile -n app-mobility-platform -f $CONTRACT \
  -f apps/_template/values-sso.yaml \
  --set app.name=api --set app.group=mobility-platform \
  --set app.environment=${APP_ENV} \
  --set-string eso.role=portal-group-app-eso \
  --set-string "exposure.host=${GROUP_APP_HOST}" \
  --set-string "configuration.externalSecrets[0].remotePath=apps/${APP_PROJECT}/${APP_ENV}/workloads/app-mobility-platform/${GROUP_ESO_SA}" \
  --set-string "oidc.allowedGroups[0]=${GROUP_ALLOWED_GROUP}" >$TMP/group-sso.yaml
if grep -q "clientID: \"${GROUP_OIDC_CLIENT}\"" $TMP/group-sso.yaml \
   && grep -q "name: ${GROUP_SECRET_STORE}" $TMP/group-sso.yaml \
   && grep -q "name: ${GROUP_ESO_SA}" $TMP/group-sso.yaml \
   && grep -q "name: ${GROUP_INGRESS_NP}" $TMP/group-sso.yaml \
   && grep -q "name: ${GROUP_EGRESS_NP}" $TMP/group-sso.yaml \
   && grep -q 'namespace: app-mobility-platform' $TMP/group-sso.yaml; then
  echo "[OK]   AppGroup OIDC client/ESO 식별자가 group 경계를 포함"; PASS=$((PASS+1))
else
  echo "[FAIL] AppGroup OIDC client/ESO 식별자 불일치"; FAILED=$((FAILED+1))
fi
# 볼륨 제약을 제거해도 Portal의 프로세스 로컬 정합성 경계는 남아야 한다.
for storage_override in persistence.enabled=false persistence.accessMode=ReadWriteOncePod; do
  if helm template portal-lite charts/app-profile -n "$PORTAL_NAMESPACE" -f $CONTRACT \
    -f apps/portal-lite/values-beta.yaml --set replicaCount=2 --set "$storage_override" \
    >"$TMP/portal-concurrency.yaml" 2>"$TMP/portal-concurrency.err"; then
    echo "[FAIL] Portal 다중 프로세스를 허용함 ($storage_override)"; FAILED=$((FAILED+1))
  elif grep -q 'portal-lite 정합성은 단일 프로세스' "$TMP/portal-concurrency.err"; then
    echo "[OK]   Portal 저장소와 무관한 replica 가드 ($storage_override)"; PASS=$((PASS+1))
  else
    echo "[FAIL] Portal 정합성 가드 이외의 오류 ($storage_override)"; FAILED=$((FAILED+1))
  fi
  if helm template portal-lite charts/app-profile -n "$PORTAL_NAMESPACE" -f $CONTRACT \
    -f apps/portal-lite/values-beta.yaml --set replicaCount=1 --set "$storage_override" \
    >"$TMP/portal-single.yaml" && grep -q 'type: Recreate' "$TMP/portal-single.yaml"; then
    echo "[OK]   Portal 단일 프로세스 롤아웃 ($storage_override)"; PASS=$((PASS+1))
  else
    echo "[FAIL] Portal 단일 프로세스 롤아웃 ($storage_override)"; FAILED=$((FAILED+1))
  fi
done

helm template portal-lite charts/app-profile -n "$PORTAL_NAMESPACE" -f $CONTRACT \
  -f apps/portal-lite/values-beta.yaml --set replicaCount=0 --set exposure.enabled=false \
  >$TMP/portal-off.yaml
if ! grep -q '^kind: HTTPRoute$' $TMP/portal-off.yaml \
   && grep -q 'replicas: 0' $TMP/portal-off.yaml; then
  echo "[OK]   Portal OFF는 replicas=0이며 외부 Route 없음"; PASS=$((PASS+1))
else
  echo "[FAIL] Portal OFF 렌더 불일치"; FAILED=$((FAILED+1))
fi

helm template portal-lite charts/app-profile -n "$PORTAL_NAMESPACE" -f $CONTRACT \
  -f apps/portal-lite/values-beta.yaml >$TMP/portal.yaml
if grep -q '^kind: NetworkPolicy$' $TMP/portal.yaml \
   && grep -q "cidr: \"${GATEWAY_VIP}/32\"" $TMP/portal.yaml \
   && grep -q "gateway.envoyproxy.io/owning-gateway-name: ${GATEWAY_NAME}" $TMP/portal.yaml; then
  echo "[OK]   Portal 기본 egress 정책 일치"; PASS=$((PASS+1))
else
  echo "[FAIL] Portal egress 정책 불일치"; FAILED=$((FAILED+1))
fi
# 모든 오브젝트는 metadata.namespace 를 명시해야 한다.
# kubectl/argocd 의 기본 Namespace 나 helm -n 생략에 따라 배포 대상이 바뀌면 안 된다.
# Role/RoleBinding 만 rbacNamespaces 로 다른 Namespace 를 가질 수 있다.
NS_CHECK=render-ns-check
helm template portal-lite charts/app-profile -f $CONTRACT \
  -f apps/portal-lite/values-beta.yaml -n "$PORTAL_NAMESPACE" >$TMP/ns-portal.yaml
helm template sample-sso charts/app-profile -f $CONTRACT \
  -f apps/_template/values-sso.yaml -n $NS_CHECK >$TMP/ns-sso.yaml
if python3 - "$TMP/ns-portal.yaml" "$PORTAL_NAMESPACE" "$TMP/ns-sso.yaml" "$NS_CHECK" <<'PY'
import sys, yaml

problems = []
for path, expected in zip(sys.argv[1::2], sys.argv[2::2]):
    with open(path, encoding="utf-8") as handle:
        for doc in yaml.safe_load_all(handle):
            if not doc:
                continue
            kind = doc.get("kind")
            meta = doc.get("metadata") or {}
            name = meta.get("name")
            namespace = meta.get("namespace")
            if not namespace:
                problems.append(f"{kind}/{name} 에 metadata.namespace 가 없음")
            elif namespace != expected and kind not in ("Role", "RoleBinding"):
                problems.append(f"{kind}/{name} 의 Namespace 가 {namespace} 기대 {expected}")
for problem in problems:
    print(problem, file=sys.stderr)
sys.exit(1 if problems else 0)
PY
then
  echo "[OK]   모든 오브젝트가 Namespace 를 명시"; PASS=$((PASS+1))
else
  echo "[FAIL] Namespace 미명시 오브젝트 존재"; FAILED=$((FAILED+1))
fi

rm -rf $TMP
echo "통과 $PASS / 실패 $FAILED" ; [ $FAILED -eq 0 ]
