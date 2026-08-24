#!/usr/bin/env bash
# 금지 입력을 merge 전에 차단한다. 로컬 pre-commit 과 CI 가 같은 스크립트를 쓴다.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

# --- 텍스트 수준 검사 -------------------------------------------------------
echo "==============================="
echo "텍스트 수준 검사"
echo "==============================="

if grep -RInE '^kind:[[:space:]]*Secret[[:space:]]*$' \
     charts/app-profile/templates charts/app-group/templates 2>/dev/null | grep -q .; then
  echo "[FAIL] Chart 가 Kubernetes Secret 을 직접 생성한다. ExternalSecret 만 허용"; FAIL=1
else
  echo "[OK]   Chart 가 Secret 을 직접 생성하지 않음"
fi

# 개발 전용 로그인 우회(lib/require-session.ts 의 devBypassSession)는 next dev 에서만
# 동작하지만, 배포 매니페스트에 환경변수로 들어가면 의도가 남아 위험하다. 배포 표면에
# 이 이름이 보이면 막는다. 구현 파일과 문서에 있는 것은 정상이므로 대상에서 뺀다.
if grep -RInE 'PAAS_DEV_AUTH_BYPASS' apps charts platform argocd contracts rke \
     --include='*.yaml' --include='*.yml' \
     --exclude-dir=node_modules --exclude-dir=.next 2>/dev/null | grep -q .; then
  echo "[FAIL] 개발 전용 인증 우회(PAAS_DEV_AUTH_BYPASS)가 배포 매니페스트에 있다"; FAIL=1
else
  echo "[OK]   배포 매니페스트에 개발용 인증 우회 없음"
fi

# 공개 self-registration을 켜면 익명 사용자가 곧바로 Portal write 권한을 얻는다. 신규
# import는 default group, 기존 연합 사용자는 FORCE mapper로 수렴시키고 Portal client의
# 브라우저 logout 반환 URI도 두 배포 경로에서 함께 유지한다.
if grep -q 'registrationAllowed=false' scripts/cluster/bootstrap-testbed-services.sh \
   && grep -q 'kc update "default-groups/${developer_group_id}"' \
     scripts/cluster/bootstrap-testbed-services.sh \
   && grep -q 'update "default-groups/${developer_group_id}"' \
     platform/keycloak/external/configure-default-developer.sh \
   && grep -q 'oidc-hardcoded-group-idp-mapper' scripts/cluster/bootstrap-testbed-services.sh \
   && grep -q 'oidc-hardcoded-group-idp-mapper' \
     platform/keycloak/external/configure-default-developer.sh \
   && grep -q 'post.logout.redirect.uris' scripts/cluster/bootstrap-testbed-services.sh \
   && grep -q 'post.logout.redirect.uris' \
     platform/keycloak/external/configure-default-developer.sh \
   && grep -q 'idp-auto-link' scripts/cluster/bootstrap-testbed-services.sh \
   && grep -q 'idp-auto-link' \
     platform/keycloak/external/configure-default-developer.sh \
   && grep -q 'firstBrokerLoginFlowAlias' scripts/cluster/bootstrap-testbed-services.sh \
   && grep -q 'firstBrokerLoginFlowAlias' \
     platform/keycloak/external/configure-default-developer.sh \
   && grep -Fq 'STABLE_SAML_USERNAME_TEMPLATE='\''${ATTRIBUTE.http://schemas.goauthentik.io/2021/02/saml/username}'\''' \
     scripts/cluster/bootstrap-testbed-services.sh \
   && grep -Fq 'STABLE_SAML_USERNAME_TEMPLATE='\''${ATTRIBUTE.http://schemas.goauthentik.io/2021/02/saml/username}'\''' \
     platform/keycloak/external/configure-default-developer.sh \
   && grep -q 'saml-username-idp-mapper' scripts/verify/verify-testbed.sh \
   && grep -q 'configure-external-keycloak.sh --apply' \
     scripts/cluster/bootstrap-testbed-services.sh \
   && grep -q 'StrictHostKeyChecking=yes' scripts/cluster/configure-external-keycloak.sh \
   && grep -q 'SADP_NTP_SERVERS' platform/keycloak/external/configure-time-sync.sh \
   && grep -q 'systemd-time-wait-sync.service' platform/keycloak/external/configure-time-sync.sh \
   && grep -q "EXPECTED_NOT_BEFORE='minutes=-5'" scripts/ops/configure-authentik-saml.sh \
   && grep -q "EXPECTED_NOT_ON_OR_AFTER='minutes=5'" scripts/ops/configure-authentik-saml.sh \
   && grep -q '로그인마다 새 SAML Response ID와 Assertion ID 발급' \
     scripts/verify/saml-assertion-contract.py \
   && ! grep -q 'delete.*default-groups' \
     scripts/cluster/bootstrap-testbed-services.sh \
     platform/keycloak/external/configure-default-developer.sh; then
  echo "[OK]   Keycloak LIFE 자동 연결, developer 수렴, Portal SLO와 self-registration 차단 유지"
else
  echo "[FAIL] Keycloak 자동 연결/developer/SLO 또는 self-registration fail-close가 깨짐"; FAIL=1
fi

if grep -RInE '(BEGIN (RSA|EC|OPENSSH|PRIVATE) KEY|hvs\.[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})' \
     --include='*.yaml' --include='*.yml' --include='*.sh' --include='*.md' --include='*.json' \
     --exclude-dir=node_modules --exclude-dir=.next --exclude-dir=.git . 2>/dev/null \
   | grep -v 'scripts/ci-guard.sh' | grep -q .; then
  echo "[FAIL] 자격증명으로 보이는 문자열이 저장소에 있다"; FAIL=1
else
  echo "[OK]   자격증명 패턴 없음"
fi

# 위 패턴 검사는 확장자로 대상을 고른다. environments/bot-token 처럼 확장자가 없고 값만
# 들어 있는 파일은 어떤 include 에도 걸리지 않아 그대로 통과한다. 실제로 40자 토큰이
# 커밋된 적이 있다. environments/ 에는 예시만 커밋한다는 규칙을 파일 목록으로 강제한다.
# .gitignore 는 이미 추적 중인 파일을 막지 못하므로 이 검사가 마지막 방어선이다.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  tracked_env=$(git ls-files 'environments/*' | grep -vE '(\.example|-example)$' || true)
  if [[ -n ${tracked_env} ]]; then
    echo "[FAIL] environments/ 에 예시가 아닌 파일이 추적되고 있다(토큰/사이트 값 유출):"
    echo "${tracked_env}" | sed 's/^/         /'
    echo "         git rm --cached <파일> 로 추적을 끊고, 이미 push 했다면 값을 폐기·재발급한다."
    FAIL=1
  else
    echo "[OK]   environments/ 에 예시 파일만 추적됨"
  fi
fi

# --- YAML 의미 검사 --------------------------------------------------------
python3 - <<'PY' || FAIL=1
import glob, hashlib, ipaddress, pathlib, sys, re, urllib.parse, yaml

fail = 0
def bad(msg):
    global fail
    print("[FAIL] " + msg); fail = 1
def ok(msg):
    print("[OK]   " + msg)

contract = yaml.safe_load(open("contracts/platform-production.yaml", encoding="utf-8"))
base_domain = contract["spec"]["baseDomain"]
allowed_exposure = set(contract["spec"]["policy"]["allowedExposure"])
internal_cidrs = list((contract["spec"].get("network") or {}).get("internalCIDRs") or [])
FORBIDDEN = re.compile(
    r"PASSWORD|PASSWD|TOKEN|SECRET|PRIVATE_KEY|CREDENTIAL|API_KEY|ACCESS_KEY|"
    r"DATABASE_URL|DB_URL|DSN|CONNECTION_STRING|AUTHORIZATION|BEARER",
    re.IGNORECASE,
)
CREDENTIAL_VALUE = re.compile(
    r"://[^/@:]+:[^/@]+@|-----BEGIN (?:RSA )?PRIVATE KEY-----|^hvs\.|^ghp_|^github_pat_|^AKIA",
    re.IGNORECASE,
)

# Next.js route handler 는 'app/api/v1/openapi.yaml/route.ts' 처럼 확장자 모양의 디렉터리를
# 만들고, ui/node_modules 에는 검사 대상이 아닌 서드파티 YAML 이 들어 있다. glob 결과를 그대로
# open() 하면 IsADirectoryError 로 가드 전체가 죽으므로 실제 검사 대상 파일만 남긴다.
SKIP_DIRS = ("node_modules", ".next", ".git")

def yaml_files(*patterns):
    found = []
    for pattern in patterns:
        for f in glob.glob(pattern, recursive=True):
            path = pathlib.Path(f)
            if not path.is_file():
                continue
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            found.append(f)
    return sorted(set(found))

# 1. 저장소에 Secret manifest 금지
secret_docs = []
for f in yaml_files("apps/**/*.yaml", "platform/**/*.yaml",
                    "argocd/**/*.yaml", "policies/**/*.yaml"):
    for doc in yaml.safe_load_all(open(f, encoding="utf-8")):
        if isinstance(doc, dict) and doc.get("kind") == "Secret":
            secret_docs.append(f)
bad("Secret manifest 존재: " + ", ".join(secret_docs)) if secret_docs else ok("Secret manifest 없음")

# 2. versions.lock 무결성(leaf 값만 검사)
def leaves(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from leaves(v, f"{path}.{k}")
    else:
        yield path, node
version_lock = yaml.safe_load(open("versions.lock.yaml", encoding="utf-8"))
lock_items = list(leaves(version_lock))
lock_bad = [p for p, v in lock_items if v in (None, "", "latest")]
lock_pending = [p for p, v in lock_items if v == "pending"]
if lock_bad:
    bad("versions.lock.yaml 빈 값/latest: " + ", ".join(lock_bad) + " (미정이면 문자열 pending 으로 표기)")
else:
    ok("versions.lock.yaml 빈 값 없음")
if lock_pending:
    print("[WARN] versions.lock.yaml 미확정(D5 전 확정 필요): " + ", ".join(lock_pending))

envoy_gateway_version = str(version_lock["platform"]["envoyGateway"])
gateway_api_version = str(version_lock["delivery"]["gatewayApi"])
compatible_gateway_api = {"1.8.3": "v1.5.1"}
expected_gateway_api = compatible_gateway_api.get(envoy_gateway_version)
if expected_gateway_api and gateway_api_version != expected_gateway_api:
    bad(
        f"Envoy Gateway {envoy_gateway_version} requires Gateway API "
        f"{expected_gateway_api}, found {gateway_api_version}"
    )
else:
    ok("Envoy Gateway와 Gateway API 버전 계약 일치")

external_secrets_version = str(version_lock["delivery"]["externalSecrets"])
external_secrets_api = str(version_lock["api"]["externalSecrets"])
compatible_external_secrets_api = {
    "2.8.0": "external-secrets.io/v1",
    "2.9.0": "external-secrets.io/v1",
}
expected_external_secrets_api = compatible_external_secrets_api.get(external_secrets_version)
if expected_external_secrets_api != external_secrets_api:
    bad(
        f"External Secrets {external_secrets_version} does not satisfy the locked API "
        f"{external_secrets_api}; expected {expected_external_secrets_api or 'an explicitly reviewed mapping'}"
    )
else:
    ok("External Secrets chart와 external-secrets.io API 버전 계약 일치")

# 설치 manifest와 컨테이너 빌드 도구도 lock을 소비하는 계약이다. Chart targetRevision만
# 맞고 실제 image가 예전 값이면 fresh 설치와 기존 클러스터 upgrade 결과가 갈라진다.
keycloak_image = f'quay.io/keycloak/keycloak:{version_lock["platform"]["keycloak"]}'
postgresql_image = f'postgres:{version_lock["platform"]["postgresql"]}-bookworm'
local_path_image = (
    "docker.io/rancher/local-path-provisioner:"
    f'v{version_lock["platform"]["localPathProvisioner"]}'
)
versioned_image_files = {
    "scripts/site/templates/keycloak-in-cluster.yaml.template": {keycloak_image, postgresql_image},
    "platform/keycloak/external/docker-compose.yml": {keycloak_image, postgresql_image},
    "docs/examples/local-path-storage.yaml": {local_path_image},
}
# external 배포에서는 이 파일이 Service/EndpointSlice만 가지므로 workload image가 없는 것이 정상이다.
if str((contract["spec"].get("keycloak") or {}).get("deployment") or "in-cluster") == "in-cluster":
    versioned_image_files["platform/keycloak/resources.yaml"] = {keycloak_image, postgresql_image}
image_lock_errors = []
for path, expected_images in versioned_image_files.items():
    text = pathlib.Path(path).read_text(encoding="utf-8")
    missing = sorted(image for image in expected_images if image not in text)
    if missing:
        image_lock_errors.append(f"{path}: {', '.join(missing)}")
openbao_values = yaml.safe_load(
    pathlib.Path("platform/openbao/values-beta.yaml").read_text(encoding="utf-8")
) or {}
openbao_image_tag = str(((openbao_values.get("server") or {}).get("image") or {}).get("tag") or "")
if openbao_image_tag != str(version_lock["platform"]["openbao"]):
    image_lock_errors.append(
        "platform/openbao/values-beta.yaml: "
        f"{openbao_image_tag or 'missing'} != {version_lock['platform']['openbao']}"
    )
portal_dockerfile = pathlib.Path("apps/portal-lite/Dockerfile").read_text(encoding="utf-8")
if f'FROM alpine/helm:{version_lock["delivery"]["helm"]} AS helm' not in portal_dockerfile:
    image_lock_errors.append("apps/portal-lite/Dockerfile: Helm image가 delivery.helm과 불일치")
if image_lock_errors:
    bad("versions.lock.yaml image/tool 계약 불일치: " + "; ".join(image_lock_errors))
else:
    ok("Keycloak/PostgreSQL/OpenBao/Helm/local-path image 버전 계약 일치")

# 3. RKE2 config 에 실제 token 이 들어갔는지
tok_bad = []
for f in yaml_files("rke/**/config*.yaml"):
    doc = yaml.safe_load(open(f, encoding="utf-8")) or {}
    if isinstance(doc, dict) and str(doc.get("token") or "").strip():
        tok_bad.append(f)
bad("RKE2 join token 이 커밋되었다: " + ", ".join(tok_bad)) if tok_bad else ok("RKE2 token 비어 있음")

# 4. 저장소 루트에 적용 대상 아닌 예시 manifest 방치 금지
import os
allowed_root_yaml = {"versions.lock.yaml"}
stray = [f for f in os.listdir(".") if f.endswith((".yaml", ".yml")) and f not in allowed_root_yaml]
bad("루트에 예시 manifest 방치: " + ", ".join(stray) + " (docs/examples 로 이동)") if stray else ok("루트에 잔여 manifest 없음")

# 5. 앱 values 정책
errs = []
for f in yaml_files("apps/*/values-*.yaml", "apps/_groups/*/apps/*/values-*.yaml"):
    v = yaml.safe_load(open(f, encoding="utf-8")) or {}
    app, conf = v.get("app", {}), (v.get("configuration") or {})
    exp, img = (v.get("exposure") or {}), (v.get("image") or {})

    # platform.*는 contract values 파일만 소유한다. 앱 PR이 internalCIDRs/OpenBao/Gateway를
    # 덮어쓰면 승인 도메인과 네트워크·Secret 경계를 우회할 수 있다.
    if "platform" in v:
        errs.append(f"{f}: platform 계약값을 앱 values에서 덮어쓸 수 없음")

    path = pathlib.Path(f)
    if not app.get("group") and path.parts[1] != "_template":
        # 기존 정적 앱은 Git 승격 lane(values-beta)과 런타임 environment(prod)가
        # 의도적으로 다를 수 있다. 물리 K8s identity 충돌을 막는 핵심은 디렉터리와
        # app.name 일치이며, 파일은 위 glob이 values-<lane>.yaml 형식을 보장한다.
        if len(path.parts) != 3 or path.parts[1] != app.get("name"):
            errs.append(f"{f}: 단일 앱 values 경로의 apps/<app>와 app.name이 일치해야 함")
    privileged = bool((v.get("portalPipeline") or {}).get("enabled")) or bool(
        (v.get("openbaoWriter") or {}).get("enabled")
    )
    if privileged and f != "apps/portal-lite/values-beta.yaml":
        errs.append(f"{f}: portalPipeline/openbaoWriter는 portal-lite 생성 values에서만 허용")

    for key, value in (conf.get("config") or {}).items():
        if FORBIDDEN.search(key):
            errs.append(f"{f}: ConfigMap key '{key}' 는 민감값 -> OpenBao 로 이동")
        if CREDENTIAL_VALUE.search(str(value)):
            errs.append(f"{f}: ConfigMap key '{key}' 값은 자격증명/비밀키 형태 -> OpenBao 로 이동")

    # 노출과 인증은 별개 값이다. mode 가 없으면 예전 type 에서 유도한다(하위호환).
    auth = (v.get("authentication") or {})
    legacy = exp.get("type") or ""
    exposure_mode = exp.get("mode") or ""
    auth_mode = auth.get("mode") or ""
    if legacy and legacy not in allowed_exposure:
        errs.append(f"{f}: exposure.type '{legacy}' 허용되지 않음")
    if legacy and exposure_mode and exposure_mode != "external":
        errs.append(f"{f}: exposure.type '{legacy}'의 외부 노출과 exposure.mode '{exposure_mode}'가 충돌")
    legacy_auth = "oidc" if legacy == "oidc" else "none"
    if legacy and auth_mode and auth_mode != legacy_auth:
        errs.append(
            f"{f}: exposure.type '{legacy}'와 authentication.mode '{auth_mode}'가 충돌"
        )
    if not exposure_mode:
        if legacy not in allowed_exposure:
            errs.append(f"{f}: exposure.type '{legacy}' 허용되지 않음")
        exposure_mode = "external"
        auth_mode = auth_mode or ("oidc" if legacy == "oidc" else "none")
    auth_mode = auth_mode or "none"

    if exposure_mode not in ("external", "internal"):
        errs.append(f"{f}: exposure.mode '{exposure_mode}' 는 external 또는 internal 이어야 함")
    if auth_mode not in ("none", "oidc"):
        errs.append(f"{f}: authentication.mode '{auth_mode}' 는 none 또는 oidc 여야 함")
    # SecurityPolicy 는 HTTPRoute 를 대상으로 한다. 내부 전용 앱에는 붙일 대상이 없다.
    if auth_mode == "oidc" and exposure_mode != "external":
        errs.append(f"{f}: authentication.mode=oidc 는 exposure.mode=external 에서만 사용할 수 있음")

    host = exp.get("host") or ""
    if exposure_mode == "external":
        is_portal_apex = (
            f == "apps/portal-lite/values-beta.yaml"
            and app.get("name") == "portal-lite"
            and host == base_domain
        )
        if not host.endswith("." + base_domain) and not is_portal_apex:
            errs.append(f"{f}: host '{host}' 가 승인 도메인 {base_domain} 밖")
        expected_section = f"apex-{contract['spec']['gateway']['routeListener']}"
        if is_portal_apex and exp.get("sectionName") != expected_section:
            errs.append(f"{f}: apex Portal sectionName은 '{expected_section}' 이어야 함")
        if not is_portal_apex and exp.get("sectionName"):
            errs.append(f"{f}: sectionName override는 apex Portal에서만 허용")
    elif host:
        errs.append(f"{f}: exposure.mode=internal 인데 host '{host}' 가 남아 있음")

    # egressMode=web 은 인터넷 TCP 80/443 을 여는 값이다. 사설망 제외 목록이 계약에
    # 없으면 Chart 가 렌더에 실패하므로, 커밋 단계에서 먼저 알려 준다.
    policy = (v.get("networkPolicy") or {})
    egress_mode = policy.get("egressMode") or "custom"
    if egress_mode not in ("blocked", "web", "custom"):
        errs.append(f"{f}: networkPolicy.egressMode '{egress_mode}' 는 blocked, web, custom 중 하나여야 함")
    if egress_mode != "custom" and policy.get("allowedCIDRs"):
        errs.append(f"{f}: networkPolicy.egressMode={egress_mode} 에서는 allowedCIDRs 를 쓸 수 없음")
    if egress_mode == "web" and not internal_cidrs:
        errs.append(f"{f}: egressMode=web 인데 계약 network.internalCIDRs 가 비어 있음(사설망이 함께 열린다)")
    for entry in policy.get("allowedCIDRs") or []:
        if str(entry.get("cidr", "")).endswith("/0"):
            errs.append(f"{f}: allowedCIDRs 에 전체 대역 '{entry.get('cidr')}' 은 허용하지 않음")
    # 앱 이름 selector 는 같은 Namespace 안에서만 뜻이 있다. AppGroup 없이 쓰면
    # 사이트 공용 Zone 의 남의 앱을 여는 규칙이 된다.
    group_peers = (policy.get("allowedApps") or []) + (
        ((policy.get("ingress") or {}).get("allowedApps")) or []
    )
    if group_peers and not app.get("group"):
        errs.append(f"{f}: allowedApps 는 app.group 이 있는 AppGroup 앱에서만 쓸 수 있음")
    for peer in group_peers:
        if str(peer.get("protocol") or "TCP").upper() != "TCP":
            errs.append(f"{f}: allowedApps protocol은 TCP만 허용")
    if app.get("group"):
        if policy.get("enabled") is False:
            errs.append(f"{f}: AppGroup 앱은 networkPolicy.enabled=false를 사용할 수 없음")
        if ((policy.get("ingress") or {}).get("enabled")) is False:
            errs.append(f"{f}: AppGroup 앱은 networkPolicy.ingress.enabled=false를 사용할 수 없음")
        path = pathlib.Path(f)
        # apps/_template은 복사 전 예시라 nested GitOps identity 검사의 대상이 아니다.
        if len(path.parts) < 2 or path.parts[1] != "_template":
            expected_filename = f"values-{app.get('environment')}.yaml"
            if (
                len(path.parts) != 6
                or path.parts[:2] != ("apps", "_groups")
                or path.parts[3] != "apps"
                or path.parts[2] != app.get("group")
                or path.parts[4] != app.get("name")
                or path.name != expected_filename
            ):
                errs.append(
                    f"{f}: AppGroup values 경로는 apps/_groups/<group>/apps/<app>/values-<env>.yaml과 일치해야 함"
                )
    if img.get("tag") in ("latest", "main", "master") or (not img.get("tag") and not img.get("digest")):
        errs.append(f"{f}: image tag/digest 규칙 위반")
    if "type" in (v.get("service") or {}):
        errs.append(f"{f}: service.type 지정 금지 (ClusterIP 고정)")

    namespace = str(((contract["spec"].get("policy") or {}).get("userQuota") or {}).get("namespaces", [""])[0])
    service_account = f"eso-{app.get('name')}"
    expected_role = str(((contract["spec"].get("openbao") or {}).get("roles") or {}).get("zoneApp") or "")
    if app.get("group"):
        namespace = str((contract["spec"].get("appGroups") or {}).get("namespacePrefix") or "") + str(app.get("group"))
        canonical = "v1/app/{}/{}/{}/{}".format(
            app.get("project"), app.get("environment"), app.get("group"), app.get("name")
        )
        prefix = "eso-sa-a-"
        digest = hashlib.sha256(f"{prefix}|{canonical}".encode()).hexdigest()[:10]
        room = 52 - len(prefix)
        service_account = f"{prefix}{str(app.get('name'))[:room].rstrip('-')}-{digest}"
        expected_role = str(((contract["spec"].get("openbao") or {}).get("roles") or {}).get("groupApp") or "")
    canonical_path = "apps/{}/{}/workloads/{}/{}".format(
        app.get("project"), app.get("environment"), namespace, service_account
    )
    external_secrets = conf.get("externalSecrets") or []
    if external_secrets:
        paths = {str(es.get("remotePath") or "") for es in external_secrets}
        legacy_path = "apps/{}/{}/{}".format(
            app.get("project"), app.get("environment"), app.get("name")
        )
        legacy_role = "eso-{}-{}-{}".format(
            app.get("project"), app.get("environment"), app.get("name")
        )
        configured_role = str((v.get("eso") or {}).get("role") or "")
        # 예전 Portal values는 role을 쓰지 않고 당시 Chart 기본 앱별 role을 사용했다.
        actual_role = configured_role or (
            legacy_role if not app.get("group") and paths == {legacy_path} else expected_role
        )
        canonical_pair = actual_role == expected_role and paths == {canonical_path}
        legacy_pair = (
            not app.get("group")
            and actual_role == legacy_role
            and paths == {legacy_path}
        )
        if not (canonical_pair or legacy_pair):
            errs.append(
                f"{f}: ExternalSecret path/role은 canonical '{canonical_path}' + "
                f"'{expected_role}' 또는 단일 앱 legacy '{legacy_path}' + "
                f"'{legacy_role}'의 정확한 한 쌍이어야 함"
            )
    env_owners = {str(key): "ConfigMap" for key in (conf.get("config") or {})}
    for es in external_secrets:
        for bad_field in ("value", "values", "stringData", "data"):
            if bad_field in es:
                errs.append(f"{f}: ExternalSecret 에 실제 값 필드 '{bad_field}' 존재")
        if es.get("inject", True):
            key_map = es.get("targetKeyMap") or {}
            for source_key in es.get("keys") or []:
                target_key = str(key_map.get(source_key) or source_key)
                conflicts = sorted({str(source_key), target_key} & set(env_owners))
                if conflicts:
                    errs.append(
                        f"{f}: env key '{source_key}' 가 {env_owners[conflicts[0]]}와 "
                        f"ExternalSecret/{es.get('name')}에 중복"
                    )
                env_owners[str(source_key)] = f"ExternalSecret/{es.get('name')}"
                env_owners[target_key] = f"ExternalSecret/{es.get('name')}"

if errs:
    for e in errs:
        bad(e)
else:
    ok("앱 values 정책 준수(민감 key/host/노출·인증/네트워크/이미지/OpenBao 경로)")

# AppGroup bootstrap values는 앱 values와 스키마가 다르다. 이 파일도 nested 경로라 위 glob에
# 섞지 않고, 포털이 쓸 수 있는 최소 key만 따로 제한한다. registry/OpenBao 경로를 여기서
# 덮어쓸 수 있으면 사이트 계약의 공통 credential 경계를 우회하게 된다.
group_errs = []
for f in yaml_files("apps/_groups/*/values-*.yaml"):
    v = yaml.safe_load(open(f, encoding="utf-8")) or {}
    unexpected = sorted(set(v) - {"group", "defaultDeny"})
    if unexpected:
        group_errs.append(f"{f}: AppGroup bootstrap에 허용하지 않은 key: {', '.join(unexpected)}")
    group = v.get("group") or {}
    path = pathlib.Path(f)
    if len(path.parts) < 4 or group.get("name") != path.parts[2]:
        group_errs.append(f"{f}: group.name과 apps/_groups/<group> 경로가 다름")
    expected_filename = f"values-{group.get('environment')}.yaml"
    if path.name != expected_filename:
        group_errs.append(f"{f}: group.environment와 values-<env>.yaml 파일명이 다름")
    if (v.get("defaultDeny") or {}) != {"ingress": True, "egress": True}:
        group_errs.append(f"{f}: defaultDeny ingress/egress는 모두 true여야 함")
if group_errs:
    for e in group_errs:
        bad(e)
else:
    ok("AppGroup nested values/Namespace bootstrap 정책 준수")

# AppGroup 앱/Namespace Chart만 ClusterSecretStore를 만들 수 있다. wildcard cluster 권한이나
# 단일 Zone 프로젝트에 같은 권한을 주면 namespaced SecretStore 경계를 넓히게 된다.
projects = {
    doc.get("metadata", {}).get("name"): doc
    for doc in yaml.safe_load_all(open("argocd/appproject.yaml", encoding="utf-8"))
    if isinstance(doc, dict) and doc.get("kind") == "AppProject"
}
app_groups = projects.get("app-groups") or {}
namespace_prefix = str((contract["spec"].get("appGroups") or {}).get("namespacePrefix") or "")
contract_values = yaml.safe_load(open("contracts/values-platform-production.yaml", encoding="utf-8"))
values_prefix = str(
    ((contract_values.get("platform") or {}).get("appGroups") or {}).get("namespacePrefix") or ""
)
portal_values = yaml.safe_load(open("apps/portal-lite/values-beta.yaml", encoding="utf-8"))
portal_prefix = str(
    (((portal_values.get("configuration") or {}).get("config") or {}).get(
        "PORTAL_APP_GROUP_NAMESPACE_PREFIX"
    ) or "")
)
portal_group_project = str(
    (((portal_values.get("configuration") or {}).get("config") or {}).get(
        "PORTAL_APP_GROUP_ARGO_PROJECT"
    ) or "")
)
portal_config = (portal_values.get("configuration") or {}).get("config") or {}
platform_values = contract_values.get("platform") or {}
workload_namespaces = [
    str(item) for item in (((contract["spec"].get("policy") or {}).get("userQuota") or {}).get("namespaces") or [])
]
rancher_contract = contract["spec"].get("rancher") or {}
rancher_cluster_id = str(rancher_contract.get("clusterId") or "")
rancher_matches = [
    str(project.get("name") or "")
    for project in (rancher_contract.get("projects") or [])
    if workload_namespaces
    and workload_namespaces[0] in [str(item) for item in (project.get("namespaces") or [])]
]
expected_rancher_project = (
    f"{rancher_cluster_id}:{rancher_matches[0]}"
    if len(workload_namespaces) == 1
    and rancher_cluster_id
    and len(rancher_matches) == 1
    and rancher_matches[0]
    else ""
)
actual_rancher_project = str((platform_values.get("rancher") or {}).get("workloadProjectId") or "")
if not expected_rancher_project or actual_rancher_project != expected_rancher_project:
    bad(
        "AppGroup Rancher project 계약 불일치: "
        f"workloadNamespaces={workload_namespaces!r}, matches={rancher_matches!r}, "
        f"expected={expected_rancher_project!r}, values={actual_rancher_project!r}"
    )
else:
    ok("AppGroup Rancher project 계약/Chart values 일치")
runtime_projection = {
    "PORTAL_APP_GROUP_NAMESPACE_PREFIX": (platform_values.get("appGroups") or {}).get("namespacePrefix"),
    "PORTAL_APP_GROUP_MAX_SERVICES": str((platform_values.get("appGroups") or {}).get("maxServices") or 0),
    "PORTAL_APP_GROUP_VOLUME_SIZE": ((platform_values.get("appGroups") or {}).get("storage") or {}).get("volumeSize"),
    "PORTAL_APP_GROUP_VOLUME_STORAGE_CLASS": ((platform_values.get("appGroups") or {}).get("storage") or {}).get("storageClass"),
    "PORTAL_APP_IMAGE_PULL_NAME": (platform_values.get("registry") or {}).get("pullSecretName"),
    "PORTAL_REGISTRY_PULL_REMOTE_PATH": (platform_values.get("registry") or {}).get("pullSecretRemotePath"),
    "PORTAL_OPENBAO_ZONE_APP_ROLE": ((platform_values.get("openbao") or {}).get("roles") or {}).get("zoneApp"),
    "PORTAL_OPENBAO_GROUP_APP_ROLE": ((platform_values.get("openbao") or {}).get("roles") or {}).get("groupApp"),
    "PORTAL_OPENBAO_GROUP_REGISTRY_ROLE": ((platform_values.get("openbao") or {}).get("roles") or {}).get("groupRegistry"),
}
runtime_drift = {
    key: (portal_config.get(key), wanted)
    for key, wanted in runtime_projection.items()
    if portal_config.get(key) != wanted
}
if runtime_drift:
    bad(f"Portal runtime/플랫폼 계약 projection 불일치: {runtime_drift}")
else:
    ok("Portal runtime registry/OpenBao/AppGroup 계약 projection 일치")

try:
    namespace_reader = [
        item for item in yaml.safe_load_all(
            open("platform/portal/app-group-namespace-reader.yaml", encoding="utf-8")
        ) if item
    ]
    role, binding = namespace_reader
    assert role["kind"] == "ClusterRole"
    assert role["metadata"]["name"] == "portal-app-group-namespace-reader"
    assert role["rules"] == [{"apiGroups": [""], "resources": ["namespaces"], "verbs": ["get"]}]
    assert binding["kind"] == "ClusterRoleBinding"
    assert binding["roleRef"] == {
        "apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole",
        "name": "portal-app-group-namespace-reader",
    }
    assert binding["subjects"] == [{
        "kind": "ServiceAccount",
        "name": platform_values["portal"]["serviceAccountName"],
        "namespace": platform_values["portal"]["namespace"],
    }]
except (AssertionError, KeyError, TypeError, ValueError, yaml.YAMLError) as error:
    bad(f"Portal AppGroup Namespace reader 최소권한/계약 불일치: {error}")
else:
    ok("Portal AppGroup Namespace reader 최소권한/계약 일치")
destination_namespaces = {
    str(item.get("namespace") or "")
    for item in (app_groups.get("spec", {}).get("destinations") or [])
}
if (
    not namespace_prefix
    or values_prefix != namespace_prefix
    or portal_prefix != namespace_prefix
    or destination_namespaces != {namespace_prefix + "*"}
    or portal_group_project != "app-groups"
):
    bad(
        "AppGroup Namespace prefix 계약 불일치: "
        f"contract={namespace_prefix!r}, values={values_prefix!r}, portal={portal_prefix!r}, "
        f"AppProject={sorted(destination_namespaces)!r}, portalProject={portal_group_project!r}"
    )
else:
    ok("AppGroup Namespace prefix 계약/Portal/AppProject 일치")
cluster_allow = {
    (str(item.get("group", "")), str(item.get("kind", "")))
    for item in (app_groups.get("spec", {}).get("clusterResourceWhitelist") or [])
}
if cluster_allow != {("", "Namespace"), ("external-secrets.io", "ClusterSecretStore")}:
    bad(f"app-groups clusterResourceWhitelist가 최소 권한이 아님: {sorted(cluster_allow)}")
elif any(
    ("external-secrets.io", "ClusterSecretStore") in {
        (str(item.get("group", "")), str(item.get("kind", "")))
        for item in (project.get("spec", {}).get("clusterResourceWhitelist") or [])
    }
    for name, project in projects.items() if name != "app-groups"
):
    bad("AppGroup 외 AppProject가 ClusterSecretStore 생성을 허용함")
else:
    ok("AppGroup ClusterSecretStore AppProject 최소 권한 준수")

# Portal API 문서는 현재 읽기/검증 API와 Forgejo cutover 후 쓰기 API의 기준 계약이다.
try:
    portal_api = yaml.safe_load(open("apps/portal-lite/openapi.yaml", encoding="utf-8"))
    portal_paths = portal_api["paths"]
    portal_components = portal_api["components"]
    assert portal_api["openapi"] == "3.1.1"
    assert "/api/v1/catalog" in portal_paths
    assert "/api/v1/app-profiles/validate" in portal_paths
    create_deployment = portal_paths["/api/v1/deployment-requests"]["post"]
    assert create_deployment["operationId"] == "createDeploymentRequest"
    assert "202" in create_deployment["responses"]
    assert create_deployment["security"] == [{"keycloak": ["deployments:write"]}]
    assert {item["$ref"] for item in create_deployment["parameters"]} >= {
        "#/components/parameters/RequesterHeader",
        "#/components/parameters/OptionalIdempotencyKey",
    }
    validate_group = portal_paths["/api/v1/app-groups/validate"]["post"]
    create_group = portal_paths["/api/v1/app-groups"]["post"]
    assert validate_group["operationId"] == "validateAppGroup"
    assert create_group["operationId"] == "createAppGroup"
    assert "200" in validate_group["responses"] and "202" in create_group["responses"]
    assert {item["$ref"] for item in create_group["parameters"]} >= {
        "#/components/parameters/RequesterHeader",
        "#/components/parameters/IdempotencyKey",
    }
    requester_header = portal_components["parameters"]["RequesterHeader"]
    assert requester_header["in"] == "header" and requester_header["required"] is True
    assert requester_header["x-sadp-injected-by"] == "portal-bff"
    assert portal_components["parameters"]["IdempotencyKey"]["required"] is True
    assert portal_components["securitySchemes"]["keycloak"]["type"] == "oauth2"
    issuer = (contract_values["platform"]["keycloak"]["issuer"]).rstrip("/")
    oauth = portal_components["securitySchemes"]["keycloak"]["flows"]["authorizationCode"]
    assert oauth["authorizationUrl"] == issuer + "/protocol/openid-connect/auth"
    assert oauth["tokenUrl"] == issuer + "/protocol/openid-connect/token"
    assert "forgejoConnected" in portal_components["schemas"]["Catalog"]["required"]
    def resolve(schema):
        # DeploymentRequestInput 처럼 $ref 한 겹으로 감싼 스키마도 계약을 검사한다.
        seen = set()
        while "$ref" in schema:
            ref = schema["$ref"]
            assert ref not in seen, f"순환 $ref: {ref}"
            seen.add(ref)
            node = portal_api
            for part in ref.removeprefix("#/").split("/"):
                node = node[part]
            schema = node
        return schema

    assert resolve(portal_components["schemas"]["DeploymentRequestInput"])["additionalProperties"] is False
    assert resolve(portal_components["schemas"]["AppPeer"])["properties"]["protocol"]["enum"] == ["TCP"]
    assert set(resolve(portal_components["schemas"]["CIDRPeer"])["properties"]["protocol"]["enum"]) == {"TCP", "UDP"}
    normalized_service = resolve(portal_components["schemas"]["NormalizedProfile"])["properties"]["service"]
    assert "internalAddress" in normalized_service["properties"]
    assert "internalAddress" not in normalized_service["required"]
    runtime_update = portal_paths["/api/v1/deployment-requests/{requestID}/runtime-state"]["put"]
    assert runtime_update["operationId"] == "updateDeploymentRuntimeState"
    assert runtime_update["security"] == [{"keycloak": ["deployments:write"]}]
    assert {"202", "500"} <= set(runtime_update["responses"])
    runtime_input = resolve(portal_components["schemas"]["RuntimeStateInput"])
    assert runtime_input["additionalProperties"] is False
    assert set(runtime_input["properties"]["state"]["enum"]) == {"running", "stopped"}
    assert "application/problem+json" in portal_components["responses"]["ValidationError"]["content"]
    response_fields = resolve(portal_components["schemas"]["DeploymentRequest"])["properties"]
    assert {"gitCommitted", "desiredRevision", "applicationSynced", "failedFromState",
            "groupCleanupDecided", "groupCleanupPlanned", "secretWritePending",
            "desiredRuntimeState", "runtimeGeneration", "runtimePullRequest",
            "runtimeSupersededPullRequest", "runtimeDesiredRevision",
            "runtimeApplicationSynced"} <= set(response_fields)
    assert {"stopping", "stopped", "starting"} <= set(response_fields["state"]["enum"])
except (AssertionError, KeyError, TypeError, yaml.YAMLError) as error:
    bad(f"Portal OpenAPI 3.1.1 핵심 계약 오류: {error}")
else:
    ok("Portal OpenAPI 3.1.1 현재/향후 계약 정상")

# 6. 플랫폼 controller는 GitOps child Application으로 선언되어야 한다.
# 문서 중복/최상위 키 중복은 뒤 값이 조용히 이기므로 붙여넣기 실수를 여기서 잡는다.
class StrictLoader(yaml.SafeLoader):
    pass

def _no_duplicate_keys(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                None, None, f"중복 키 '{key}'", key_node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping

StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicate_keys)

application_files = {}
for file in sorted(glob.glob("argocd/applications/*.yaml")):
    try:
        documents = [d for d in yaml.load_all(open(file, encoding="utf-8"), StrictLoader) if d]
    except yaml.YAMLError as error:
        bad(f"{file}: YAML 오류 {error}")
        continue
    if len(documents) != 1:
        bad(f"{file}: child Application 파일은 문서 1개만 담는다 (현재 {len(documents)}개)")
        continue
    application_files[pathlib.Path(file).stem] = documents[0]
if application_files:
    ok("child Application 파일 구조 정상(문서 1개, 중복 키 없음)")

# portal-beta에는 cross-Namespace RBAC과 OpenBao writer를 가진 portal-lite 하나만 들어가야
# 한다. 같은 values/releaseName을 다른 child Application이 다시 렌더하면 두 Argo 앱이
# 동일 Deployment/ServiceAccount를 서로 소유하며 사용자 앱 경계가 무너진다.
portal_contract = (platform_values.get("portal") or {})
portal_application_errors = []
for stem, document in sorted(application_files.items()):
    spec = document.get("spec") or {}
    sources = spec.get("sources") or ([spec.get("source")] if spec.get("source") else [])
    source_text = str(sources)
    claims_portal = (
        spec.get("project") == "portal-beta"
        or "$values/apps/portal-lite/values-beta.yaml" in source_text
        or any(((source or {}).get("helm") or {}).get("releaseName") == "portal-lite" for source in sources)
    )
    if not claims_portal:
        continue
    if stem != "portal-lite":
        portal_application_errors.append(f"{stem}: portal-lite 전용 Application identity 선점")
        continue
    chart_source = next((source for source in sources if (source or {}).get("path") == "charts/app-profile"), None)
    value_files = ((chart_source or {}).get("helm") or {}).get("valueFiles") or []
    if spec.get("project") != "portal-beta":
        portal_application_errors.append("portal-lite: project가 portal-beta가 아님")
    if ((chart_source or {}).get("helm") or {}).get("releaseName") != "portal-lite":
        portal_application_errors.append("portal-lite: Helm releaseName이 portal-lite가 아님")
    if "$values/apps/portal-lite/values-beta.yaml" not in value_files:
        portal_application_errors.append("portal-lite: 전용 values 파일 누락")
    if (spec.get("destination") or {}).get("namespace") != portal_contract.get("namespace"):
        portal_application_errors.append("portal-lite: destination Namespace가 portal 계약과 다름")
if portal_application_errors:
    bad("portal-lite privileged Application 계약 오류: " + "; ".join(portal_application_errors))
else:
    ok("portal-lite privileged Application identity 단일화")

# k8s 1.33+ 는 Deployment/ReplicaSet .status 에 terminatingReplicas 를 넣지만 Devtron 번들
# ArgoCD v2.13 의 스키마에는 없다. 빼먹은 Application 은 sync 도 health 도 정상인데 diff 만
# ComparisonError 로 죽어서 "Unknown" 으로 남는다. 원인 찾기 어려우니 여기서 막는다.
terminating_missing = []
for name, document in sorted(application_files.items()):
    ignored = (document.get("spec") or {}).get("ignoreDifferences") or []
    covered = {
        entry.get("kind") for entry in ignored
        if "terminatingReplicas" in str(entry.get("jqPathExpressions") or "")
    }
    if not {"Deployment", "ReplicaSet"} <= covered:
        terminating_missing.append(name)
if terminating_missing:
    bad("child Application 에 .status.terminatingReplicas ignoreDifferences 누락: "
        + ", ".join(terminating_missing))
else:
    ok("child Application 전부 terminatingReplicas diff 예외 보유")

required_applications = {
    "envoy-gateway", "metallb", "cert-manager", "rancher", "platform-resources",
    "external-secrets", "reloader", "openbao"}
missing_applications = sorted(required_applications - set(application_files))
if missing_applications:
    bad("GitOps child Application 누락: " + ", ".join(missing_applications))
else:
    ok("플랫폼 controller GitOps child Application 존재")

def chart_source(application):
    spec = (application or {}).get("spec") or {}
    for source in spec.get("sources") or []:
        if source.get("chart"):
            return source
    return spec.get("source") or {}

controller_chart_locks = {
    "external-secrets": version_lock["delivery"]["externalSecrets"],
    "reloader": version_lock["delivery"]["reloader"],
    "openbao": version_lock["platform"]["openbaoChart"],
}
controller_chart_errors = []
for name, locked in controller_chart_locks.items():
    source = chart_source(application_files.get(name))
    if str(source.get("targetRevision") or "") != str(locked):
        controller_chart_errors.append(
            f"{name}={source.get('targetRevision') or 'missing'} (lock={locked})"
        )
if controller_chart_errors:
    bad("controller Helm chart와 versions.lock.yaml 불일치: " + "; ".join(controller_chart_errors))
else:
    ok("External Secrets/Reloader/OpenBao chart 버전 계약 일치")

platform_resources = application_files.get("platform-resources") or {}
platform_directory = (
    platform_resources.get("spec", {}).get("source", {}).get("directory", {})
)
platform_excludes = str(platform_directory.get("exclude") or "")
required_value_excludes = {
    "external-secrets/values-beta.yaml",
    "openbao/values-beta.yaml",
    "reloader/values-beta.yaml",
}
excluded_paths = {
    item.strip()
    for item in platform_excludes.strip("{}").split(",")
    if item.strip()
}
if platform_directory.get("recurse") is not True:
    bad("platform-resources는 platform/ 하위 manifest를 재귀 탐색해야 한다")
elif not required_value_excludes.issubset(excluded_paths):
    bad(
        "platform-resources directory.exclude에 비-manifest Helm values 누락: "
        + ", ".join(sorted(required_value_excludes - excluded_paths))
    )
else:
    ok("platform-resources가 Helm values YAML을 manifest 적용 대상에서 제외")

hello_application = application_files.get("hello") or {}
hello_sync_options = hello_application.get("spec", {}).get("syncPolicy", {}).get("syncOptions", [])
if "SkipDryRunOnMissingResource=true" not in hello_sync_options:
    bad("Devtron-managed hello Application에 CRD 등록 지연 대응 옵션 누락")
else:
    ok("Devtron-managed hello Application 소유권과 CRD 지연 대응 유지")

envoy_application = application_files.get("envoy-gateway") or {}
envoy_source = envoy_application.get("spec", {}).get("source", {})
if str(envoy_source.get("targetRevision")) != f"v{envoy_gateway_version}":
    bad("Envoy Gateway Application 버전이 versions.lock.yaml과 불일치")
else:
    ok("Envoy Gateway Application 버전 계약 일치")

metallb_application = application_files.get("metallb") or {}
metallb_source = metallb_application.get("spec", {}).get("source", {})
if str(metallb_source.get("targetRevision")) != str(version_lock["platform"]["metallb"]):
    bad("MetalLB Application 버전이 versions.lock.yaml과 불일치")
else:
    ok("MetalLB Application 버전 계약 일치")

cert_manager_application = application_files.get("cert-manager") or {}
cert_manager_source = cert_manager_application.get("spec", {}).get("source", {})
cert_manager_version = str(version_lock["platform"]["certManager"])
if str(cert_manager_source.get("targetRevision")) != f"v{cert_manager_version}":
    bad("cert-manager Application 버전이 versions.lock.yaml과 불일치")
else:
    ok("cert-manager Application 버전 계약 일치")

# 모니터링 스택은 외부 Grafana 가 읽어갈 백엔드다. 차트 버전이 versions.lock.yaml 과
# 어긋나면 이미지 목록(platform/monitoring/images.txt)도 같이 어긋나 워커에서 pull 이 막힌다.
monitoring_ok = True
for component in ("prometheus", "loki", "alloy"):
    locked = version_lock["platform"].get(component)
    if locked is None:
        bad(f"versions.lock.yaml 에 platform.{component} 이 없다")
        monitoring_ok = False
        continue
    application = application_files.get(component) or {}
    if not application:
        bad(f"argocd/applications/{component}.yaml 이 없다")
        monitoring_ok = False
        continue
    source = application.get("spec", {}).get("source", {})
    if str(source.get("targetRevision")) != str(locked):
        bad(f"{component} Application 버전이 versions.lock.yaml 과 불일치")
        monitoring_ok = False
    if component == "loki" and str(source.get("repoURL")) != "https://grafana-community.github.io/helm-charts":
        bad("Loki OSS Application은 grafana-community Helm 저장소를 사용해야 한다")
        monitoring_ok = False
    if str(source.get("helm", {}).get("valuesObject", {}) and "ok") != "ok":
        bad(f"{component} Application 에 valuesObject 가 비어 있다")
        monitoring_ok = False
if monitoring_ok:
    ok("모니터링 스택(Prometheus/Loki/Alloy) Application 버전 계약 일치")

# 이미지 목록에 digest 고정 참조가 있으면 sync-external-images.sh 로 옮길 때 해석되지 않는다.
monitoring_images_path = pathlib.Path("platform/monitoring/images.txt")
if not monitoring_images_path.exists():
    bad("platform/monitoring/images.txt 가 없다(워커는 registry 에서 이미지를 받지 못한다)")
else:
    digest_pinned = []
    listed = []
    for line in monitoring_images_path.read_text(encoding="utf-8").splitlines():
        entry = line.split("#", 1)[0].strip()
        if not entry:
            continue
        listed.append(entry)
        if "@sha256:" in entry:
            digest_pinned.append(entry)
    if digest_pinned:
        bad("platform/monitoring/images.txt 에 digest 고정 참조가 있다: " + ", ".join(digest_pinned))
    elif not listed:
        bad("platform/monitoring/images.txt 에 이미지가 없다")
    else:
        ok(f"모니터링 이미지 목록 {len(listed)}개(digest 고정 없음)")

# 7. D5 TLS 계약 검사
tls = contract["spec"].get("tls") or {}
public = contract["spec"].get("public") or {}
gateway = contract["spec"]["gateway"]
status = contract.get("status") or {}
PENDING = {"", "pending", "replace-me", "tbd", "none"}

def pending(value):
    return str(value or "").strip().lower() in PENDING

if not tls:
    bad("contracts/platform-production.yaml 에 spec.tls 가 없다(D5 필수)")
else:
    source = str(tls.get("source") or "").strip()
    if source not in ("acme", "provided"):
        bad("spec.tls.source 는 acme 또는 provided 이어야 한다")
    if not gateway.get("wildcardTlsSecret"):
        bad("spec.gateway.wildcardTlsSecret 이 비어 있다")
    if source == "acme":
        provider = str((tls.get("solver") or {}).get("provider") or "").strip()
        if not pending(provider) and provider != "rfc2136":
            bad(f"spec.tls.solver.provider '{provider}' 는 지원 대상이 아니다")
        if str(tls.get("issuerMode") or "") not in ("staging", "production"):
            bad("spec.tls.issuerMode 는 staging 또는 production 이어야 한다")
        preserve_existing = tls.get("stagingPreserveExistingGatewaySecret", False)
        if not isinstance(preserve_existing, bool):
            bad("spec.tls.stagingPreserveExistingGatewaySecret 는 boolean 이어야 한다")
        elif preserve_existing:
            if str(tls.get("issuerMode")) != "staging":
                bad("기존 Gateway Secret 보존 옵션은 issuerMode=staging 에서만 허용")
            if str(status.get("wildcardTls")) != "ready":
                bad("기존 Gateway Secret 보존 옵션에는 status.wildcardTls=ready 가 필요")
            if gateway.get("routeListener") != gateway.get("httpsListener"):
                bad("기존 Gateway Secret 보존 옵션에는 routeListener=https 가 필요")
        # 이름만 적는 필드에 값이 들어오는 것을 막는다(계획서 2.6 부트스트랩 Secret).
        solver = tls.get("solver") or {}
        for field in ("credentialSecret", "credentialSecretValue", "apiToken", "token", "tsigSecret"):
            if field in solver:
                bad(f"spec.tls.solver.{field} 금지. Secret 이름만 적는다")
        secret_name = str(solver.get("credentialSecretName") or "")
        if secret_name and not re.fullmatch(r"[a-z0-9]([-a-z0-9.]*[a-z0-9])?", secret_name):
            bad(f"spec.tls.solver.credentialSecretName '{secret_name}' 이 Kubernetes 이름 규칙 위반")

        # cert-manager Application 의 dns01 resolver 가 계약과 같아야 한다.
        contract_resolvers = [str(x).strip() for x in tls.get("recursiveNameservers") or []]
        extra_args = ((cert_manager_source.get("helm") or {}).get("valuesObject") or {}).get("extraArgs") or []
        application_resolvers = []
        resolver_only = False
        for argument in extra_args:
            if str(argument).startswith("--dns01-recursive-nameservers="):
                application_resolvers = str(argument).split("=", 1)[1].split(",")
            if str(argument).strip() == "--dns01-recursive-nameservers-only":
                resolver_only = True
        if application_resolvers != contract_resolvers:
            bad("cert-manager Application 의 --dns01-recursive-nameservers 가 "
                "spec.tls.recursiveNameservers 와 불일치")
        elif not resolver_only:
            bad("cert-manager Application 에 --dns01-recursive-nameservers-only 누락 "
                "(split-horizon DNS 로 self-check 가 실패한다)")
        else:
            ok("cert-manager dns01 resolver 가 계약과 일치")
    elif source == "provided":
        provided = tls.get("provided") or {}
        provided_paths = []
        for field in ("certificatePath", "privateKeyPath"):
            value = str(provided.get(field) or "")
            path = pathlib.PurePosixPath(value)
            if (not value or path.is_absolute() or ".." in path.parts
                    or not path.parts or path.parts[0] != "wildcard" or path.suffix.lower() != ".pem"):
                bad(f"spec.tls.provided.{field} 는 wildcard/ 아래 상대 PEM 경로여야 한다")
            provided_paths.append(value)
        if len(set(provided_paths)) != 2:
            bad("provided 인증서와 private key 경로가 같을 수 없다")

        wildcard_owners = []
        for file in yaml_files("platform/**/*.yaml"):
            for document in yaml.safe_load_all(open(file, encoding="utf-8")):
                if (isinstance(document, dict) and document.get("kind") == "Certificate"
                        and (document.get("spec") or {}).get("secretName") == gateway.get("wildcardTlsSecret")):
                    wildcard_owners.append(file)
        if wildcard_owners:
            bad("provided wildcard Secret을 덮어쓰는 cert-manager Certificate 존재: "
                + ", ".join(sorted(set(wildcard_owners))))
        else:
            ok("provided wildcard 인증서 경로/소유권 계약 정상")

# redirect HTTPRoute Namespace 는 허용 목록 안에 있어야 하고 Gateway Namespace 는 아니어야 한다.
route_namespaces = [str(x) for x in gateway.get("allowedRouteNamespaces") or []]
redirect_namespace = str(gateway.get("redirectRouteNamespace") or "")
if redirect_namespace not in route_namespaces:
    bad("spec.gateway.redirectRouteNamespace 가 allowedRouteNamespaces 에 없다")
elif gateway["namespace"] in route_namespaces:
    bad("allowedRouteNamespaces 에 Gateway Namespace 를 넣으면 소유권이 충돌한다")
else:
    ok("redirect HTTPRoute Namespace 계약 정상")

# wildcardTls 가 ready 면 앱 HTTPRoute 는 https listener 에 붙어야 한다(G2 조건).
if str(status.get("wildcardTls")) == "ready" and gateway["routeListener"] != gateway["httpsListener"]:
    bad("status.wildcardTls=ready 인데 routeListener 가 아직 http 다. "
        "https 로 바꾸고 scripts/lib/contract-values.py 를 재실행하라")
elif str(status.get("wildcardTls")) == "ready":
    ok("wildcardTls ready 이며 앱 HTTPRoute 가 https listener 를 참조")

# 공개 방식은 경계 NAT 또는 노드 공인 NIC 직접 노출이며 포트는 80/443뿐이다.
public_mode = str(public.get("mode") or "")
public_ports = sorted(int(p) for p in public.get("ports") or [])
if public_mode not in ("nat", "direct"):
    bad("spec.public.mode 는 nat 또는 direct 이어야 한다")
if public_ports != [80, 443]:
    bad(f"spec.public.ports {public_ports} 는 80/443 만 허용한다")
else:
    ok(f"공개 {public_mode} 포트 80/443 유지")
if public_mode == "direct":
    external_interface = str(
        ((contract["spec"].get("network") or {}).get("interfaces") or {}).get("external") or ""
    )
    if not external_interface:
        bad("spec.public.mode=direct 인데 network.interfaces.external 이 비어 있다")
    try:
        public_ip = str(ipaddress.IPv4Address(str(public.get("ip") or "")))
    except ipaddress.AddressValueError:
        bad("spec.public.mode=direct 인데 public.ip 가 유효한 IPv4가 아니다")
    else:
        if public_ip == str(gateway.get("vip") or ""):
            bad("direct public IP는 이미 NIC에 할당된 주소이므로 MetalLB VIP와 같을 수 없다")

# Envoy Gateway가 유일한 80/443 진입점이어야 한다. RKE2 기본 ingress는 hostPort를 선점해
# 공인 IP 요청에 fake certificate/404를 반환하므로 사이트 템플릿에서도 반드시 끈다.
rke_server = yaml.safe_load(open("rke/control-node/config.yaml", encoding="utf-8")) or {}
disabled_addons = rke_server.get("disable") or []
if isinstance(disabled_addons, str):
    disabled_addons = [disabled_addons]
if "rke2-ingress-nginx" not in disabled_addons:
    bad("rke/control-node/config.yaml 에 rke2-ingress-nginx disable 누락(공인 80/443 충돌)")
else:
    ok("RKE2 기본 ingress 비활성 계약 유지")

# Keycloak은 in-cluster 배포와 외부 VM 중 하나만 선택한다. 어느 쪽이든 sso host와 issuer는
# 같고 외부 진입점은 Envoy Gateway 하나다. 달라지는 것은 keycloak Service의 backend 뿐이다.
# 시스템마다 독자 Keycloak을 가지므로 같은 검사를 전역/시스템 공통으로 쓴다.
systems = contract["spec"].get("systems") or []


def check_keycloak_deployment(label, keycloak, manifest_path):
    mode = str(keycloak.get("deployment") or "in-cluster")
    placement = str(keycloak.get("nodePlacement") or "any")
    external = keycloak.get("external") or {}
    if not manifest_path.exists():
        bad(f"{label}: {manifest_path} 가 없다")
        return
    documents = [
        item for item in yaml.safe_load_all(manifest_path.read_text(encoding="utf-8")) if item
    ]
    kinds = [str(item.get("kind")) for item in documents]
    if mode not in ("in-cluster", "external"):
        bad(f"{label}: keycloak.deployment 값이 올바르지 않다: {mode}")
    elif placement not in ("any", "control-plane"):
        bad(f"{label}: keycloak.nodePlacement 값이 올바르지 않다: {placement}")
    elif mode == "external":
        if placement != "any":
            bad(f"{label}: external 모드는 keycloak.nodePlacement=any 여야 한다")
            return
        external_address = str(external.get("address") or "")
        try:
            ipaddress.IPv4Address(external_address)
        except ValueError:
            bad(f"{label}: deployment=external 인데 keycloak.external.address 가 IPv4가 아니다")
            return
        workloads = [kind for kind in kinds if kind in ("Deployment", "StatefulSet")]
        if workloads:
            bad(f"{label}: external 모드인데 클러스터 Keycloak 워크로드가 남아 있다: {workloads}")
        elif "EndpointSlice" not in kinds:
            bad(f"{label}: external 모드인데 keycloak EndpointSlice 가 없다")
        else:
            slice_document = next(item for item in documents if item.get("kind") == "EndpointSlice")
            rendered = [
                str(value)
                for endpoint in slice_document.get("endpoints") or []
                for value in endpoint.get("addresses") or []
            ]
            if rendered != [external_address]:
                bad(f"{label}: keycloak EndpointSlice 주소가 계약과 다르다: {rendered}")
            else:
                ok(f"{label}: Keycloak external 배포 계약과 EndpointSlice 일치")
    else:
        if external.get("address"):
            bad(f"{label}: in-cluster 모드인데 keycloak.external.address 가 채워져 있다")
        elif "Deployment" not in kinds or "StatefulSet" not in kinds:
            bad(f"{label}: in-cluster 모드인데 Keycloak/PostgreSQL 워크로드가 없다")
        else:
            workloads = [
                item for item in documents
                if item.get("kind") in ("Deployment", "StatefulSet")
            ]
            placement_errors = []
            for workload in workloads:
                workload_name = str((workload.get("metadata") or {}).get("name") or "")
                pod_spec = (((workload.get("spec") or {}).get("template") or {}).get("spec") or {})
                selector = pod_spec.get("nodeSelector") or {}
                tolerations = pod_spec.get("tolerations") or []
                has_critical = any(
                    item.get("key") == "CriticalAddonsOnly"
                    and item.get("operator") == "Equal"
                    and str(item.get("value") or "").lower() == "true"
                    and item.get("effect") == "NoExecute"
                    for item in tolerations
                )
                has_control = any(
                    item.get("key") == "node-role.kubernetes.io/control-plane"
                    and item.get("operator") == "Equal"
                    and str(item.get("value") or "").lower() == "true"
                    and item.get("effect") == "NoSchedule"
                    for item in tolerations
                )
                pinned = (
                    str(selector.get("node-role.kubernetes.io/control-plane") or "").lower()
                    == "true"
                    and has_critical
                    and has_control
                )
                if placement == "control-plane" and not pinned:
                    placement_errors.append(workload_name)
                if placement == "any" and (
                    "node-role.kubernetes.io/control-plane" in selector
                    or has_critical
                    or has_control
                ):
                    placement_errors.append(workload_name)
            if placement_errors:
                bad(
                    f"{label}: nodePlacement={placement} 와 워크로드 scheduling 불일치: "
                    + ", ".join(placement_errors)
                )
            else:
                ok(f"{label}: Keycloak in-cluster nodePlacement={placement} 계약 유지")


check_keycloak_deployment(
    "keycloak", contract["spec"].get("keycloak") or {}, pathlib.Path("platform/keycloak/resources.yaml")
)

# 상위 SAML IdP 의 metadata/SSO host 는 Keycloak 이 server-side 로 나가므로
# squid identityProviderDomains 에 열려 있어야 한다. URL 만 바꾸고 egress 를
# 빼먹으면 로그인이 조용히 깨지므로 여기서 같이 막는다.
identity_provider = (contract["spec"].get("keycloak") or {}).get("identityProvider") or {}
if identity_provider:
    keycloak = contract["spec"].get("keycloak") or {}
    issuer = str(keycloak.get("issuer") or "").rstrip("/")
    saml_sp_entity_id = str(keycloak.get("samlSpEntityId") or "")
    if saml_sp_entity_id not in {issuer, f"{issuer}/"}:
        bad(
            "keycloak.samlSpEntityId 는 issuer와 같고 외부 IdP가 요구하는 경우에만 "
            "끝 슬래시 하나를 가져야 한다"
        )
    else:
        ok("keycloak.samlSpEntityId: SAML Audience 문자열 계약 확인")
    idp_domains = [
        str(item).strip()
        for item in ((contract["spec"].get("network") or {}).get("squid") or {}).get(
            "identityProviderDomains"
        )
        or []
    ]
    for field in ("metadataDescriptorUrl", "singleSignOnServiceUrl"):
        url = str(identity_provider.get(field) or "").strip()
        if not url:
            continue
        host = urllib.parse.urlparse(url).hostname or ""
        allowed = any(
            host == domain.lstrip(".") or host.endswith(domain)
            if domain.startswith(".")
            else host == domain
            for domain in idp_domains
        )
        if not allowed:
            bad(
                f"keycloak.identityProvider.{field} host '{host}' 가 "
                f"network.squid.identityProviderDomains 에 없다(로그인 egress 차단)"
            )
        else:
            ok(f"keycloak.identityProvider.{field}: squid egress 허용 확인")

# 시스템 도메인은 baseDomain 의 형제 서브도메인이어야 공유 RFC2136 zone/TSIG 로 발급 가능하다.
# 이름/도메인/Namespace 중복도 여기서 다시 확인한다(계약을 수동으로 고칠 가능성이 있어서다).
systems_seen_names: set[str] = set()
systems_seen_domains: set[str] = set()
systems_seen_namespaces: set[str] = set()
for system in systems:
    system_name = str(system.get("name") or "")
    domain = str(system.get("domain") or "")
    namespace = str(system.get("workloadNamespace") or "")
    label = f"system '{system_name}'"
    if system_name in systems_seen_names:
        bad(f"spec.systems 에 이름이 중복됨: {system_name}")
    systems_seen_names.add(system_name)
    if domain in systems_seen_domains:
        bad(f"spec.systems 에 도메인이 중복됨: {domain}")
    systems_seen_domains.add(domain)
    if namespace in systems_seen_namespaces:
        bad(f"spec.systems 에 Namespace 가 중복됨: {namespace}")
    systems_seen_namespaces.add(namespace)
    if not domain.endswith(f".{base_domain}"):
        bad(f"{label}: domain 이 baseDomain 의 서브도메인이 아니다: {domain}")
    if namespace not in (contract["spec"]["gateway"].get("allowedRouteNamespaces") or []):
        bad(f"{label}: workloadNamespace 가 gateway.allowedRouteNamespaces 에 없다")
    check_keycloak_deployment(
        label,
        system.get("keycloak") or {},
        pathlib.Path("platform/systems") / system_name / "keycloak.yaml",
    )
if systems:
    if str((contract["spec"].get("tls") or {}).get("source") or "") != "acme":
        bad("spec.systems 가 있는데 spec.tls.source 가 acme 가 아니다(형제 서브도메인 발급 불가)")
    else:
        ok(f"시스템 {len(systems)}개 도메인/Namespace/Keycloak 계약 정상")

# NMS는 비활성, 전용 망/포트, API 호출 중 하나만 선택한다.
nms = (contract["spec"].get("network") or {}).get("nms") or {}
nms_mode = str(nms.get("mode") or "")
if nms_mode not in ("disabled", "network", "api"):
    bad("spec.network.nms.mode 는 disabled, network 또는 api 이어야 한다")
else:
    common_values = (
        bool(nms.get("allowedApps")),
        bool(str(nms.get("destinationCIDR") or "")),
        1 <= int(nms.get("port") or 0) <= 65535,
    )
    common_populated = any(common_values)
    common_complete = all(common_values)
    network_values = tuple(
        bool(str(nms.get(key) or ""))
        for key in ("gatewayInternalIP", "interface", "gatewayIP", "nextHop")
    )
    network_populated = any(network_values)
    network_complete = all(network_values)
    api_populated = bool(str(nms.get("apiBaseURL") or ""))
    if nms_mode == "disabled" and (common_populated or network_populated or api_populated):
        bad("NMS disabled 모드에 활성 모드 필드가 남아 있다")
    elif nms_mode == "network" and (not common_complete or not network_complete or api_populated):
        bad("NMS network 모드는 목적지/port/전용망 필드만 완전하게 입력해야 한다")
    elif nms_mode == "api" and (not common_complete or network_populated or not api_populated):
        bad("NMS api 모드는 목적지/port/apiBaseURL만 입력하고 전용망 필드를 비워야 한다")
    else:
        ok(f"NMS 모드 계약 정상({nms_mode})")

# 공인 DNS 레코드는 baseDomain 과 시스템 도메인을 벗어날 수 없고, 각 도메인의 wildcard 와
# apex 를 모두 덮어야 한다. 시스템 도메인은 baseDomain 의 서브도메인이므로 같은 zone/TSIG 로
# 발급되지만, A 레코드 자체는 각 도메인 이름으로 별도로 있어야 한다.
allowed_domains = {base_domain, *(str(item.get("domain") or "") for item in systems)}
expected_records = {name for domain in allowed_domains for name in (domain, f"*.{domain}")}
record_names = {str((r or {}).get("name") or "") for r in public.get("records") or []}
if record_names:
    outside = sorted(n for n in record_names if n not in expected_records)
    if outside:
        bad("spec.public.records 가 승인 도메인 밖: " + ", ".join(outside))
    elif record_names != expected_records:
        bad("spec.public.records 는 baseDomain/시스템 도메인마다 wildcard 와 apex 를 "
            "모두 포함해야 한다 (wildcard 는 apex 를 덮지 않는다)")
    else:
        ok("공인 DNS 레코드가 baseDomain/시스템 도메인마다 wildcard 와 apex 를 모두 포함")

# 8. D6 Rancher 계약 검사
rancher = contract["spec"].get("rancher") or {}
platform_services = contract["spec"].get("platformServices") or []
service_hosts = {}
for entry in platform_services:
    entry = entry or {}
    name, host = str(entry.get("name") or ""), str(entry.get("host") or "")
    service_hosts[name] = host
    if not host.endswith("." + base_domain):
        bad(f"spec.platformServices[{name}].host '{host}' 가 승인 도메인 {base_domain} 밖")
    if str(entry.get("namespace") or "") == gateway["namespace"]:
        bad(f"spec.platformServices[{name}] 은 Gateway Namespace 에 둘 수 없다")
    # 다른 VM 의 서비스는 EndpointSlice 가 유일한 연결 고리다. 주소가 틀리면 조용히 503 이 된다.
    external_backend = entry.get("external") or {}
    if external_backend:
        try:
            ipaddress.IPv4Address(str(external_backend.get("address") or ""))
        except ValueError:
            bad(f"spec.platformServices[{name}].external.address 가 IPv4 가 아니다")
        external_port = int(external_backend.get("port") or 0)
        if not 1 <= external_port <= 65535:
            bad(f"spec.platformServices[{name}].external.port 가 범위를 벗어났다")
if len(set(service_hosts.values())) != len(service_hosts):
    bad("spec.platformServices 에 중복 host 가 있다")
elif service_hosts:
    ok("플랫폼 UI host 가 승인 도메인 안에 있음")

# 외부 백엔드는 Namespace/Service/EndpointSlice 가 계약과 함께 렌더돼야 한다.
external_entries = [e for e in platform_services if (e or {}).get("external")]
if external_entries:
    exposure_documents = [
        item
        for item in yaml.safe_load_all(
            open("platform/exposure/resources.yaml", encoding="utf-8")
        )
        if item
    ]
    external_ok = True
    for entry in external_entries:
        name = str(entry.get("name") or "")
        namespace = str(entry.get("namespace") or "")
        backend = str(entry.get("service") or name)
        expected_address = str((entry.get("external") or {}).get("address") or "")
        slice_document = next(
            (
                item
                for item in exposure_documents
                if item.get("kind") == "EndpointSlice"
                and (item.get("metadata") or {}).get("namespace") == namespace
                and (item.get("metadata") or {}).get("labels", {}).get(
                    "kubernetes.io/service-name"
                )
                == backend
            ),
            None,
        )
        if slice_document is None:
            bad(f"외부 서비스 '{name}' 의 EndpointSlice 가 렌더되지 않았다")
            external_ok = False
            continue
        rendered = [
            str(value)
            for endpoint in slice_document.get("endpoints") or []
            for value in endpoint.get("addresses") or []
        ]
        if rendered != [expected_address]:
            bad(f"외부 서비스 '{name}' EndpointSlice 주소가 계약과 다르다: {rendered}")
            external_ok = False
    if external_ok:
        ok(f"외부 백엔드 서비스 {len(external_entries)}개 계약과 EndpointSlice 일치")

rancher_application = application_files.get("rancher") or {}
rancher_source = rancher_application.get("spec", {}).get("source", {})
rancher_values = (rancher_source.get("helm") or {}).get("valuesObject") or {}
if str(rancher_source.get("targetRevision")).lstrip("v") != str(version_lock["platform"]["rancher"]).lstrip("v"):
    bad("Rancher Application 버전이 versions.lock.yaml과 불일치")
else:
    ok("Rancher Application 버전 계약 일치")

# ADR 15: 외부 진입점은 Envoy Gateway 하나다. Rancher 가 자체 Ingress 를 만들면 정책이 우회된다.
if (rancher_values.get("ingress") or {}).get("enabled") is not False:
    bad("Rancher Application 에 ingress.enabled=false 가 없다(ADR 15 단일 진입점 위반)")
elif str(rancher_values.get("tls")) != "external":
    bad("Rancher Application 은 tls=external 이어야 한다(Gateway 에서 TLS 종료)")
else:
    ok("Rancher 가 Envoy Gateway 단일 진입점을 사용")

# hostname 은 계약의 platformServices 와 같아야 한다.
if "rancher" not in service_hosts:
    bad("spec.platformServices 에 rancher 항목이 없다(D6 공개 경로 누락)")
elif str(rancher_values.get("hostname")) != service_hosts["rancher"]:
    bad(f"Rancher Application hostname '{rancher_values.get('hostname')}' 이 "
        f"spec.platformServices[rancher].host '{service_hosts['rancher']}' 와 불일치")
else:
    ok("Rancher hostname 이 계약과 일치")

# 부트스트랩 자격증명은 Git 에 넣지 않는다(계획서 2.6).
for forbidden in ("bootstrapPassword", "letsEncrypt", "privateCA"):
    if forbidden in rancher_values:
        bad(f"Rancher Application 에 {forbidden} 금지. bootstrap-secret 은 클러스터에서 읽는다")

# 역할 모델은 계획서 7.2 를 벗어날 수 없다.
KNOWN_ROLES = {"platform-admin", "app-admin", "developer", "viewer"}
known_projects = {str((p or {}).get("name") or "") for p in rancher.get("projects") or []}
declared_roles = []
for binding in rancher.get("roleBindings") or []:
    binding = binding or {}
    role = str(binding.get("role") or "")
    declared_roles.append(role)
    if role not in KNOWN_ROLES:
        bad(f"spec.rancher.roleBindings role '{role}' 은 계획서 7.2 역할이 아니다")
    if str(binding.get("scope")) == "project":
        for target in binding.get("projects") or []:
            if str(target) not in known_projects:
                bad(f"spec.rancher.roleBindings[{role}] 이 없는 Project '{target}' 을 참조한다")
    # group 에 사람 계정이나 자격증명이 들어오는 것을 막는다.
    if "user" in binding or "password" in binding:
        bad(f"spec.rancher.roleBindings[{role}] 에 개별 사용자/비밀번호 금지. group 만 사용한다")
if declared_roles and len(set(declared_roles)) != len(declared_roles):
    bad("spec.rancher.roleBindings 에 중복 역할이 있다")
elif set(declared_roles) == KNOWN_ROLES:
    ok("Rancher 역할 모델이 계획서 7.2 와 일치")
elif declared_roles:
    bad("spec.rancher.roleBindings 는 계획서 7.2 의 4개 역할을 모두 선언해야 한다: "
        + ", ".join(sorted(KNOWN_ROLES - set(declared_roles))) + " 누락")

# Rancher Project 의 Namespace 는 렌더 대상이어야 하고, Project 이름은 워크로드 Namespace 와
# 겹치면 안 된다(Rancher 가 같은 이름의 backing Namespace 를 만든다).
for project in rancher.get("projects") or []:
    project = project or {}
    if str(project.get("name") or "") in route_namespaces:
        bad(f"spec.rancher.projects '{project.get('name')}' 이 워크로드 Namespace 와 겹친다. "
            "proj- 접두사 등으로 분리하고 displayName 을 쓰라")
    for namespace in project.get("namespaces") or []:
        if str(namespace) not in route_namespaces:
            bad(f"spec.rancher.projects[{project.get('name')}] 의 Namespace '{namespace}' 가 "
                "allowedRouteNamespaces 에 없어 렌더되지 않는다")

# rancherRbac 이 ready 면 모든 역할의 group 이 채워져 있어야 한다.
pending_groups = sorted(
    str((b or {}).get("role") or "") for b in rancher.get("roleBindings") or []
    if pending((b or {}).get("group"))
)
if str(status.get("rancherRbac")) == "ready" and pending_groups:
    bad("status.rancherRbac=ready 인데 group 미확정 역할이 있다: " + ", ".join(pending_groups))
elif pending_groups:
    print("[WARN] Keycloak group 미확정(D7 에 활성화): " + ", ".join(pending_groups))
else:
    ok("Rancher RBAC group 이 모두 확정됨")

sys.exit(fail)
PY

# --- 계약 <-> 생성 values 동기화 -------------------------------------------
python3 scripts/tests/portal-ui-build-env-test.py || FAIL=1
python3 scripts/lib/contract-values.py --check || FAIL=1
python3 scripts/site/render-exposure.py --check || FAIL=1
python3 scripts/site/render-network.py --check || FAIL=1
python3 scripts/site/render-rancher.py --check || FAIL=1
# 계약의 사용자 상한이 포털 서버 검증(quota.go)과 어긋나면 여기서 걸린다.
python3 scripts/site/render-quota.py --check || FAIL=1

if [ "$FAIL" -ne 0 ]; then echo "=== ci-guard 실패 ==="; exit 1; fi
echo "=== ci-guard 통과 ==="
