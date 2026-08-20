#!/usr/bin/env bash
# D5 인수 확인: cert-manager, wildcard TLS, HTTP->HTTPS redirect, 공인 DNS, 경계 NAT.
# G2 통과 조건은 "외부망에서 public 앱 HTTPS 200"이다. 마지막 두 항목은 사내망에서
# 실행하면 hairpin NAT 없이는 실패할 수 있으므로 반드시 외부망에서도 한 번 실행한다.
#
# 사용법: bash scripts/verify/verify-d5.sh [<앱 host>]
set -uo pipefail
cd "$(dirname "$0")/../.."
HOST_UNDER_TEST="${1:-}"
FAIL=0
ok()   { echo "[OK]   $*"; }
bad()  { echo "[FAIL] $*"; FAIL=1; }
skip() { echo "[SKIP] $*"; }

eval "$(python3 - <<'PY'
import yaml
spec = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))["spec"]
gateway, tls, public = spec["gateway"], spec["tls"], spec["public"]
network = spec["network"]
mode = tls["issuerMode"]
issuer = tls["clusterIssuerName"] + ("" if mode == "production" else "-staging")
gateway_secret = gateway["wildcardTlsSecret"]
certificate = gateway_secret if mode == "production" else gateway_secret + "-staging"
values = {
    "BASE_DOMAIN": spec["baseDomain"],
    "GW_NS": gateway["namespace"],
    "GW_NAME": gateway["name"],
    "HTTPS_LISTENER": gateway["httpsListener"],
    "ROUTE_LISTENER": gateway["routeListener"],
    "CERTIFICATE": certificate,
    "TLS_SECRET": certificate,
    "VIP": gateway["vip"],
    "CM_NS": tls["certManagerNamespace"],
    "ISSUER": issuer,
    "ISSUER_MODE": mode,
    "DNS01_SECRET": tls["solver"]["credentialSecretName"],
    "RESOLVER": (tls["recursiveNameservers"] or [""])[0].split(":")[0],
    "SQUID_PROXY": "http://{}:{}".format(
        network["squid"]["internalIP"], network["squid"]["port"]
    ),
    "PUBLIC_IP": public["ip"],
}
for key, value in values.items():
    print(f"{key}='{value}'")
PY
)"

APP_HOST="${HOST_UNDER_TEST:-hello.${BASE_DOMAIN}}"
echo "== 대상: ${APP_HOST} / VIP ${VIP} / 공인 IP ${PUBLIC_IP} / issuer ${ISSUER} (${ISSUER_MODE}) =="

# 1. cert-manager -----------------------------------------------------------
if kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1; then
  ok "cert-manager CRD 등록됨"
else
  bad "cert-manager CRD 없음. argocd/applications/cert-manager.yaml 동기화 확인"
fi
if [ "$(kubectl -n "$CM_NS" get deploy -o name 2>/dev/null | wc -l | tr -d ' ')" -ge 3 ]; then
  kubectl -n "$CM_NS" rollout status deploy/cert-manager --timeout=60s >/dev/null 2>&1 \
    && ok "cert-manager controller Ready" || bad "cert-manager controller 미기동"
else
  bad "cert-manager Deployment(controller/webhook/cainjector) 확인 실패"
fi

# DNS-01 자격증명은 부트스트랩 Secret 이므로 Git 이 아니라 클러스터에만 있어야 한다.
if kubectl -n "$CM_NS" get secret "$DNS01_SECRET" >/dev/null 2>&1; then
  ok "DNS-01 자격증명 Secret ${DNS01_SECRET} 존재(값은 출력하지 않는다)"
else
  bad "Secret ${DNS01_SECRET} 없음. platform/README.md 의 부트스트랩 절차 수행"
fi

# split-horizon 우회 인자가 실제 Pod 에 적용됐는지 본다.
if kubectl -n "$CM_NS" get deploy cert-manager -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
     | grep -q -- '--dns01-recursive-nameservers-only'; then
  ok "dns01 recursive nameserver 전용 모드 적용됨"
else
  bad "cert-manager 에 --dns01-recursive-nameservers-only 미적용(내부 DNS 응답으로 self-check 실패)"
fi
CONTROLLER_PROXY="$(kubectl -n "$CM_NS" get deploy cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HTTPS_PROXY")].value}' 2>/dev/null)"
[ "$CONTROLLER_PROXY" = "$SQUID_PROXY" ] \
  && ok "cert-manager controller Squid proxy 적용" \
  || bad "cert-manager HTTPS_PROXY '${CONTROLLER_PROXY}' != '${SQUID_PROXY}'"
for component in cert-manager-webhook cert-manager-cainjector; do
  if kubectl -n "$CM_NS" get deploy "$component" \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HTTPS_PROXY")].value}' \
      2>/dev/null | grep -q .; then
    bad "${component}에 proxy가 적용됨(controller만 허용)"
  else
    ok "${component} proxy 미적용"
  fi
done

# 2. ClusterIssuer 와 Certificate -------------------------------------------
if [ "$(kubectl get clusterissuer "$ISSUER" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; then
  ok "ClusterIssuer ${ISSUER} Ready(ACME 계정 등록 완료)"
else
  bad "ClusterIssuer ${ISSUER} Ready 아님. kubectl describe clusterissuer ${ISSUER}"
fi

if [ "$(kubectl -n "$GW_NS" get certificate "$CERTIFICATE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; then
  ok "Certificate ${CERTIFICATE} Ready"
else
  bad "Certificate ${CERTIFICATE} Ready 아님. kubectl describe certificate -n ${GW_NS} ${CERTIFICATE}"
  kubectl -n "$GW_NS" get challenge 2>/dev/null | head -5
fi

CERT_PEM="$(kubectl -n "$GW_NS" get secret "$TLS_SECRET" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null)"
if [ -n "$CERT_PEM" ]; then
  SANS="$(printf '%s' "$CERT_PEM" | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr -d ' ')"
  echo "$SANS" | grep -q "DNS:\*\.${BASE_DOMAIN}" && ok "SAN 에 *.${BASE_DOMAIN} 포함" \
    || bad "SAN 에 wildcard 없음: ${SANS}"
  echo "$SANS" | grep -q "DNS:${BASE_DOMAIN}" && ok "SAN 에 apex ${BASE_DOMAIN} 포함" \
    || bad "SAN 에 apex 없음(wildcard 는 apex 를 덮지 않는다)"
  ISSUER_CN="$(printf '%s' "$CERT_PEM" | openssl x509 -noout -issuer 2>/dev/null)"
  echo "발급자: ${ISSUER_CN}"
  if [ "$ISSUER_MODE" = "production" ]; then
    echo "$ISSUER_CN" | grep -qi 'staging' \
      && bad "production 모드인데 Gateway Secret의 발급자가 staging임" \
      || ok "production 인증서"
  else
    echo "$ISSUER_CN" | grep -qi 'staging' \
      && ok "staging 인증서(브라우저 신뢰 실패는 정상. production 전환 전 상태)" \
      || skip "staging 모드인데 발급자에 staging 이 없다. 수동 확인 필요"
  fi
else
  bad "Secret ${TLS_SECRET} 에서 tls.crt 를 읽을 수 없다"
fi

if [ "$ISSUER_MODE" = "staging" ]; then
  skip "staging Certificate는 Gateway와 분리됨. production 전환 전 HTTPS/NAT 검증은 수행하지 않음"
  echo
  if [ "$FAIL" -ne 0 ]; then echo "=== D5 staging 검증 실패 ==="; exit 1; fi
  echo "=== D5 staging 검증 통과 ==="
  exit 0
fi

# 3. Gateway HTTPS listener -------------------------------------------------
PROGRAMMED="$(kubectl -n "$GW_NS" get gateway "$GW_NAME" \
  -o jsonpath="{.status.listeners[?(@.name=='${HTTPS_LISTENER}')].conditions[?(@.type=='Programmed')].status}" 2>/dev/null)"
[ "$PROGRAMMED" = "True" ] && ok "Gateway https listener Programmed" \
  || bad "https listener Programmed 아님(certificateRefs 와 Secret Namespace 확인)"

# 4. redirect 와 내부 HTTPS -------------------------------------------------
REDIRECT="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 \
  --resolve "${APP_HOST}:80:${VIP}" "http://${APP_HOST}/" 2>/dev/null)"
case "$REDIRECT" in
  30[128]*https://*) ok "HTTP -> HTTPS redirect 동작: ${REDIRECT}" ;;
  *) bad "redirect 실패: '${REDIRECT}' (http listener 의 redirect HTTPRoute 확인)" ;;
esac

# staging 인증서는 신뢰 체인이 없으므로 내부 검증에서는 -k 로 경로만 확인한다.
INTERNAL="$(curl -s -o /dev/null -w '%{http_code}' -k --max-time 10 \
  --resolve "${APP_HOST}:443:${VIP}" "https://${APP_HOST}/" 2>/dev/null)"
[ "$INTERNAL" = "200" ] && ok "VIP 경유 내부 HTTPS 200" || bad "VIP 경유 내부 HTTPS ${INTERNAL}"

if [ "$ROUTE_LISTENER" != "$HTTPS_LISTENER" ]; then
  skip "routeListener=${ROUTE_LISTENER}. 앱 HTTPRoute 는 아직 http listener 에 붙어 있다"
fi

# 5. 공인 DNS 와 경계 NAT ---------------------------------------------------
if [ "$PUBLIC_IP" = "pending" ]; then
  skip "spec.public.ip 미승인. 공인 DNS/NAT 확인은 승인 후 재실행"
else
  RESOLVED="$(dig +short "@${RESOLVER}" "${APP_HOST}" A 2>/dev/null | tail -1)"
  [ "$RESOLVED" = "$PUBLIC_IP" ] \
    && ok "공인 DNS ${APP_HOST} -> ${PUBLIC_IP}" \
    || bad "공인 DNS 응답 '${RESOLVED}' != ${PUBLIC_IP} (전파 지연 또는 레코드 미등록)"

  EXTERNAL="$(curl -s -o /dev/null -w '%{http_code}' -k --max-time 10 "https://${APP_HOST}/" 2>/dev/null)"
  [ "$EXTERNAL" = "200" ] \
    && ok "공인 경로 HTTPS ${EXTERNAL} (G2 조건)" \
    || bad "공인 경로 HTTPS ${EXTERNAL}. 사내망이면 hairpin NAT 부재일 수 있다. 외부망에서 재확인"

  # 14장: 인터넷 공개 포트는 80/443 뿐이다. 열려서는 안 되는 포트를 표본 확인한다.
  EXPOSED=""
  for PORT in 22 6443 2379 8200 5432; do
    if nc -z -w 3 "$PUBLIC_IP" "$PORT" 2>/dev/null; then
      EXPOSED="${EXPOSED} ${PORT}"
    fi
  done
  [ -n "$EXPOSED" ] \
    && bad "공인 IP 에서 열려 있는 금지 포트:${EXPOSED} (14장 위반)" \
    || ok "공개 금지 포트 표본(22/6443/2379/8200/5432) 모두 닫힘"
fi

echo
if [ "$FAIL" -ne 0 ]; then echo "=== D5 검증 실패 ==="; exit 1; fi
echo "=== D5 검증 통과 ==="
