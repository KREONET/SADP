#!/usr/bin/env bash
# D6 인수 확인: Rancher 설치, local 클러스터 등록, 기본 RBAC 골격.
# D6 공동 결과는 "관리자 UI 기본 접속"이다. SSO 연동과 사람 사용자 binding 은 D7 이다.
set -uo pipefail
cd "$(dirname "$0")/../.."
FAIL=0
ok()   { echo "[OK]   $*"; }
bad()  { echo "[FAIL] $*"; FAIL=1; }
skip() { echo "[SKIP] $*"; }

eval "$(python3 - <<'PY'
import yaml
spec = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))["spec"]
gateway, rancher = spec["gateway"], spec["rancher"]
service = next(s for s in spec["platformServices"] if s["name"] == "rancher")
print(f"RANCHER_NS='{rancher['namespace']}'")
print(f"CLUSTER_ID='{rancher['clusterId']}'")
print(f"RANCHER_HOST='{service['host']}'")
print(f"GW_NS='{gateway['namespace']}'")
print(f"ROUTE_NS='{gateway['redirectRouteNamespace']}'")
print(f"ROUTE_LISTENER='{gateway['routeListener']}'")
print(f"VIP='{gateway['vip']}'")
print("PROJECTS='" + " ".join(p["name"] for p in rancher["projects"]) + "'")
print("PROJECT_NS='" + " ".join(
    n for p in rancher["projects"] for n in p.get("namespaces") or []) + "'")
print("PENDING_ROLES='" + " ".join(
    b["role"] for b in rancher["roleBindings"]
    if str(b.get("group") or "").strip().lower() in ("", "pending")) + "'")
PY
)"

echo "== 대상: ${RANCHER_HOST} / cluster ${CLUSTER_ID} / VIP ${VIP} =="

# 1. 설치 상태 -------------------------------------------------------------
if kubectl -n "$RANCHER_NS" rollout status deploy/rancher --timeout=120s >/dev/null 2>&1; then
  ok "Rancher Deployment Ready"
else
  bad "Rancher Deployment 미기동. kubectl -n ${RANCHER_NS} describe deploy rancher"
fi

REPLICAS="$(kubectl -n "$RANCHER_NS" get deploy rancher -o jsonpath='{.spec.replicas}' 2>/dev/null)"
[ "$REPLICAS" = "1" ] \
  && ok "replicas=1 (베타 단일 인스턴스. 계획서 3.4 대로 운영 HA 로 표현하지 않는다)" \
  || skip "replicas=${REPLICAS}. 계약과 다르면 확인 필요"

# ADR 15: Envoy Gateway 가 유일한 외부 진입점이어야 한다.
if kubectl -n "$RANCHER_NS" get ingress 2>/dev/null | grep -q rancher; then
  bad "Rancher Ingress 가 존재한다. ingress.enabled=false 확인(ADR 15 위반)"
else
  ok "Rancher Ingress 없음(Envoy Gateway 단일 진입점 유지)"
fi
if kubectl get ds -n kube-system rke2-ingress-nginx-controller >/dev/null 2>&1; then
  bad "rke2-ingress-nginx 가 살아 있다. ADR 15 절차대로 제거할 것"
else
  ok "rke2-ingress-nginx 없음"
fi

# LoadBalancer 는 Envoy Gateway 만 쓴다(계획서 8장).
LB_OUTSIDE="$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null \
  | tr ' ' '\n' | grep -v "^${GW_NS}/" | grep -v '^$')"
[ -z "$LB_OUTSIDE" ] \
  && ok "LoadBalancer Service 는 Envoy Gateway 전용" \
  || bad "Envoy Gateway 밖의 LoadBalancer: ${LB_OUTSIDE}"

# 2. server-url 과 클러스터 등록 -------------------------------------------
SERVER_URL="$(kubectl get setting.management.cattle.io server-url -o jsonpath='{.value}' 2>/dev/null)"
[ "$SERVER_URL" = "https://${RANCHER_HOST}" ] \
  && ok "server-url = ${SERVER_URL}" \
  || bad "server-url '${SERVER_URL}' != https://${RANCHER_HOST} (agent 연결과 redirect 가 깨진다)"

CLUSTER_STATE="$(kubectl get cluster.management.cattle.io "$CLUSTER_ID" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
if [ "$CLUSTER_STATE" = "True" ]; then
  ok "${CLUSTER_ID} 클러스터 Ready(in-cluster 설치이므로 별도 등록 불필요)"
else
  bad "${CLUSTER_ID} 클러스터 Ready 아님. Rancher/RKE2 지원 매트릭스를 먼저 확인할 것"
fi

# 지원 매트릭스 이탈은 여기서 드러난다(versions.lock.yaml 의 미해결 항목).
K8S_VERSION="$(kubectl version -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null)"
RANCHER_IMAGE="$(kubectl -n "$RANCHER_NS" get deploy rancher \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
echo "참고: Kubernetes ${K8S_VERSION} / Rancher 이미지 ${RANCHER_IMAGE}"
echo "      Rancher 지원 매트릭스에 이 조합이 있는지 확인하고 versions.lock.yaml 주석을 정리할 것"

# 3. 공개 경로 --------------------------------------------------------------
if kubectl -n "$ROUTE_NS" get httproute rancher >/dev/null 2>&1; then
  ACCEPTED="$(kubectl -n "$ROUTE_NS" get httproute rancher \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
  RESOLVED="$(kubectl -n "$ROUTE_NS" get httproute rancher \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null)"
  [ "$ACCEPTED" = "True" ] && ok "rancher HTTPRoute Accepted" || bad "rancher HTTPRoute Accepted 아님"
  [ "$RESOLVED" = "True" ] \
    && ok "rancher HTTPRoute ResolvedRefs(ReferenceGrant 유효)" \
    || bad "ResolvedRefs 아님. ${RANCHER_NS} 의 ReferenceGrant 확인"
else
  bad "${ROUTE_NS} 에 rancher HTTPRoute 가 없다. platform-resources 동기화 확인"
fi

if [ "$VIP" = "pending" ]; then
  skip "VIP 미승인. 외부 접속 확인은 계약 확정 후 재실행"
else
  SCHEME=https; PORT=443
  [ "$ROUTE_LISTENER" = "http" ] && { SCHEME=http; PORT=80; }
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -k --max-time 10 \
    --resolve "${RANCHER_HOST}:${PORT}:${VIP}" "${SCHEME}://${RANCHER_HOST}/" 2>/dev/null)"
  case "$CODE" in
    200|302) ok "VIP 경유 Rancher UI 응답 ${CODE} (${SCHEME})" ;;
    *) bad "VIP 경유 Rancher UI 응답 ${CODE}" ;;
  esac

  # tls=external 이면 Rancher 는 X-Forwarded-Proto 로 원 스킴을 판단한다.
  if [ "$SCHEME" = "https" ]; then
    LOCATION="$(curl -s -o /dev/null -w '%{redirect_url}' -k --max-time 10 \
      --resolve "${RANCHER_HOST}:443:${VIP}" "https://${RANCHER_HOST}/" 2>/dev/null)"
    case "$LOCATION" in
      ""|https://*) ok "redirect 스킴 정상(X-Forwarded-Proto 전달됨)" ;;
      http://*) bad "Rancher 가 http 로 redirect 한다. Gateway 의 X-Forwarded-Proto 확인" ;;
    esac
  fi
fi

# 4. 기본 RBAC -------------------------------------------------------------
for PROJECT in $PROJECTS; do
  if kubectl -n "$CLUSTER_ID" get project.management.cattle.io "$PROJECT" >/dev/null 2>&1; then
    ok "Project ${PROJECT} 존재"
  else
    bad "Project ${PROJECT} 없음. platform-resources 동기화 확인"
  fi
done

for NAMESPACE in $PROJECT_NS; do
  ANNOTATION="$(kubectl get ns "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.field\.cattle\.io/projectId}' 2>/dev/null)"
  [ -n "$ANNOTATION" ] \
    && ok "Namespace ${NAMESPACE} -> ${ANNOTATION}" \
    || bad "Namespace ${NAMESPACE} 가 Project 에 편입되지 않았다"
done

if [ -n "${PENDING_ROLES// /}" ]; then
  skip "RBAC binding 미활성(Rancher principal 대기):${PENDING_ROLES}"
else
  for PROJECT in $PROJECTS; do
    COUNT="$(kubectl -n "$PROJECT" get projectroletemplatebinding.management.cattle.io \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [ "$COUNT" -gt 0 ] \
      && ok "Project ${PROJECT} 에 RBAC binding ${COUNT}건" \
      || bad "Project ${PROJECT} 에 RBAC binding 이 없다"
  done
fi

echo
if [ "$FAIL" -ne 0 ]; then echo "=== D6 검증 실패 ==="; exit 1; fi
echo "=== D6 검증 통과 ==="
