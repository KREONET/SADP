#!/usr/bin/env python3
"""Regression tests for scripts/site/configure-site.py (SC-01..SC-08)."""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys
import tempfile

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
PASSED = 0
FAILED = 0

VALID = """\
SITE_NAME=production
APP_ENVIRONMENT=prod
CLUSTER_NAME=production
BASE_DOMAIN=prod.company.kr
WORKLOAD_NAMESPACE=research-prod
PLATFORM_ROUTE_NAMESPACE=platform-prod
GATEWAY_NAMESPACE=envoy-gateway-system
GATEWAY_NAME=prod-gateway
GATEWAY_PROXY_CONFIG_NAME=prod-envoy-proxy
GATEWAY_ADDRESS_POOL_NAME=prod-envoy-vip
WILDCARD_TLS_SECRET=prod-wildcard-tls
ACME_CLUSTER_ISSUER_NAME=prod-dns01
ACME_ACCOUNT_SECRET_NAME=prod-acme-account-key
PORTAL_HOST=
HELLO_HOST=
SECURE_DEMO_HOST=
RANCHER_HOST=
OPENBAO_HOST=
EXTERNAL_SERVICES=
MACHINE_AUTH_MODE=oidc
MACHINE_AUTH_SERVICES=
MACHINE_AUTH_CLIENTS=
MACHINE_AUTH_ALLOWED_CIDRS=
IDENTITY_SOURCE_PROTOCOL=openid
OIDC_ISSUER=https://idp.company.kr/application/o/sadp
OIDC_AUTHORIZATION_ENDPOINT=https://idp.company.kr/application/o/authorize/
OIDC_TOKEN_ENDPOINT=https://idp.company.kr/application/o/token/
OIDC_JWKS_URI=https://idp.company.kr/application/o/sadp/jwks/
OIDC_END_SESSION_ENDPOINT=
OIDC_GROUPS_CLAIM=groups
OIDC_CLIENT_ID_CLAIM=azp
PORTAL_OIDC_CLIENT_ID=portal-prod
STORAGE_CLASS=local-path
APP_GROUP_VOLUME_SIZE=5Gi
APP_GROUP_MAX_SERVICES=5
FORGEJO_REPO_URL=https://forgejo.company.kr/platform/SADP.git
FORGEJO_REVISION=production
OCI_REGISTRY=registry.company.kr
OCI_PROJECT=platform/sadp
REGISTRY_PULL_SECRET=forgejo-registry-pull
TEST_APP_IMAGE_TAG=1111111111111111111111111111111111111111
PORTAL_IMAGE_TAG=2222222222222222222222222222222222222222
IMAGE_PULL_POLICY=IfNotPresent
CONTROL_PLANE_HOSTNAME=prod-control-plane-1
CONTROL_PLANE_IP=10.20.30.11
WORKER_NODES=prod-worker-1=10.20.30.21,prod-worker-2=10.20.30.22
INTERNAL_INTERFACE=ens192
EXTERNAL_INTERFACE=ens224
NODE_INTERNAL_CIDRS=10.20.30.0/24
POD_CIDRS=10.52.0.0/16
SERVICE_CIDRS=10.53.0.0/16
CLUSTER_DNS_IP=10.53.0.10
KUBERNETES_API_ADDRESSES=10.53.0.1,10.20.30.11
RKE2_SERVER_ENDPOINT=10.20.30.11
INTERNAL_ALLOWED_TCP_PORTS=2379,2380,3128,6443,9345,10250
INTERNAL_ALLOWED_UDP_PORTS=8472
KUBERNETES_API_PORT=6443
RKE2_SUPERVISOR_PORT=9345
ETCD_CLIENT_PORT=2379
ETCD_PEER_PORT=2380
KUBELET_PORT=10250
CANAL_VXLAN_UDP_PORT=8472
PUBLIC_IP=203.0.113.10
PUBLIC_EXPOSURE_MODE=nat
PUBLIC_IP_NODE=
GATEWAY_VIP=10.20.30.200
GATEWAY_ADDRESS_POOL=10.20.30.200-10.20.30.220
PUBLIC_HTTP_PORT=80
PUBLIC_HTTPS_PORT=443
EXTERNAL_ALLOWED_TCP_PORTS=80,443
EXTERNAL_ALLOWED_UDP_PORTS=
ENVOY_HTTPS_TARGET_PORT=10443
SQUID_INTERNAL_IP=10.20.30.11
SQUID_PORT=3128
SQUID_CLIENT_CIDRS=10.20.30.0/24,10.52.0.0/16
EXTRA_PACKAGE_DOMAINS=packages.company.kr
TLS_SOURCE=acme
TLS_ISSUER_MODE=staging
ACME_STAGING_VERIFIED=false
EXISTING_GATEWAY_TLS_READY=false
ACME_EMAIL=platform-ops@company.kr
DNS_PROVIDER=rfc2136
RFC2136_NAMESERVER=192.0.2.53:53
RFC2136_TSIG_KEY_NAME=acme-key.prod.company.kr.
RFC2136_TSIG_ALGORITHM=HMACSHA256
DNS_CREDENTIAL_SECRET_NAME=dns01-rfc2136-tsig
DNS_CREDENTIAL_SECRET_KEY=tsig-secret
DNS_RECURSIVE_NAMESERVERS=10.53.0.10:53
PROVIDED_CERTIFICATE_PATH=wildcard/fullchain.pem
PROVIDED_PRIVATE_KEY_PATH=wildcard/privkey.pem
"""


def run_env(text: str, *, write: bool = False) -> tuple[subprocess.CompletedProcess, pathlib.Path]:
    workspace = pathlib.Path(tempfile.mkdtemp(prefix="configure-site-test-"))
    if write:
        shutil.copytree(
            ROOT,
            workspace,
            dirs_exist_ok=True,
            ignore=shutil.ignore_patterns(
                ".git", ".agents", ".codex", "ADR", "node_modules", ".next", "wildcard", "__pycache__"
            ),
        )
    else:
        (workspace / "scripts" / "site").mkdir(parents=True)
        (workspace / "contracts").mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/site/configure-site.py", workspace / "scripts/site/configure-site.py")
        shutil.copy2(ROOT / "contracts/platform-production.yaml", workspace / "contracts/platform-production.yaml")
        # --check still prepares every target in memory, so copy the read dependencies.
        # scripts/site/templates도 --check에서 읽는 의존성이므로 합성 workspace에 복사한다.
        for relative in ("apps", "argocd", "rke", "platform", "scripts/site/templates"):
            shutil.copytree(
                ROOT / relative,
                workspace / relative,
                ignore=shutil.ignore_patterns("node_modules", ".next", "__pycache__"),
            )

    # 이 테스트는 prod.company.kr라는 합성 사이트를 렌더한다. 운영 Portal이 현재 사이트
    # 도메인으로 만든 AppGroup values/Application까지 복사하면 configure-site 소유 파일은
    # 정상이어도 ci-guard가 타 사이트 host로 판정한다. Portal 런타임 산출물은 합성 입력의
    # 일부가 아니므로 /tmp 복사본에서만 제외하고 빈 생성 위치는 유지한다.
    shutil.rmtree(workspace / "apps/_groups", ignore_errors=True)
    (workspace / "apps/_groups").mkdir(parents=True, exist_ok=True)
    for pattern in ("aa-*.yaml", "ag-*.yaml"):
        for generated_application in (workspace / "argocd/applications").glob(pattern):
            generated_application.unlink()

    env_file = workspace / "site.env"
    env_file.write_text(text, encoding="utf-8")
    command = [sys.executable, "scripts/site/configure-site.py", "--env-file", str(env_file)]
    command.append("--write" if write else "--check")
    result = subprocess.run(command, cwd=workspace, capture_output=True, text=True, check=False)
    return result, workspace


def mutate(text: str, old: str, new: str) -> str:
    if old not in text:
        raise AssertionError(f"test seed not found: {old}")
    return text.replace(old, new, 1)


def case(label: str, text: str, expect_success: bool, verify=None, *, write: bool = False) -> None:
    global PASSED, FAILED
    result, workspace = run_env(text, write=write)
    detail = ""
    try:
        if (result.returncode == 0) != expect_success:
            detail = f"exit={result.returncode}, expected_success={expect_success}"
        elif verify:
            detail = verify(workspace, result) or ""
        if detail:
            FAILED += 1
            print(f"[FAIL] {label}: {detail}")
            output = (result.stdout + result.stderr).strip()
            if output:
                print("       " + output.replace("\n", "\n       "))
        else:
            PASSED += 1
            print(f"[OK]   {label}")
    finally:
        shutil.rmtree(workspace, ignore_errors=True)


# 파생 함수 하나만 확인하면 되는 경우. site.env 를 통째로 돌리면 관련 없는 검증이
# 함께 걸려서 무엇이 깨졌는지 흐려진다.
def load_configure_site():
    import importlib.util

    path = ROOT / "scripts/site/configure-site.py"
    spec = importlib.util.spec_from_file_location("configure_site", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def direct_case(label: str, check) -> None:
    global PASSED, FAILED
    try:
        detail = check() or ""
    except Exception as error:  # noqa: BLE001 - 실패 원인을 그대로 보여 준다
        detail = f"{type(error).__name__}: {error}"
    if detail:
        FAILED += 1
        print(f"[FAIL] {label}: {detail}")
    else:
        PASSED += 1
        print(f"[OK]   {label}")


def verify_generated(workspace: pathlib.Path) -> str:
    contract = yaml.safe_load((workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8"))
    spec = contract["spec"]
    if spec["baseDomain"] != "prod.company.kr":
        return "base domain was not generated"
    if spec["gateway"]["name"] != "prod-gateway":
        return "Gateway name was not generated"
    if spec["gateway"]["allowedRouteNamespaces"] != ["research-prod", "platform-prod"]:
        return "route Namespaces were not generated"
    if spec["gateway"]["wildcardTlsSecret"] != "prod-wildcard-tls":
        return "wildcard Secret name was not generated"
    if spec["tls"]["clusterIssuerName"] != "prod-dns01":
        return "ACME ClusterIssuer name was not generated"
    if spec["tls"]["solver"]["provider"] != "rfc2136":
        return "RFC2136 solver was not selected"
    if spec["tls"]["solver"]["rfc2136"] != {
        "nameserver": "192.0.2.53:53",
        "tsigKeyName": "acme-key.prod.company.kr.",
        "tsigAlgorithm": "HMACSHA256",
    }:
        return "RFC2136 contract mismatch"
    if spec["network"]["defaultDenyNamespaces"] != ["research-prod"]:
        return "default-deny Namespace was not generated"
    interfaces = spec["network"]["interfaces"]
    if (
        interfaces.get("internal") != "ens192"
        or interfaces.get("external") != "ens224"
        or interfaces.get("guarded") != []
    ):
        return "site interface names were not generated into the contract"
    if spec["policy"]["userQuota"]["namespaces"] != ["research-prod"]:
        return "user quota workload Namespace was not generated"
    if spec["public"]["mode"] != "nat" or spec["public"]["ports"] != [80, 443]:
        return "public NAT mode contract mismatch"
    if spec["delivery"] != {
        "provider": "forgejo",
        "repoURL": "https://forgejo.company.kr/platform/SADP.git",
        "revision": "production",
    }:
        return f"Forgejo delivery contract mismatch: {spec.get('delivery')}"
    if spec.get("openbao", {}).get("namespace") != "openbao":
        return "OpenBao CA ConfigMap namespace contract missing"
    if spec.get("registry", {}).get("pullSecretRemotePath") != (
        "platform/registry/forgejo-registry-pull"
    ):
        return "registry pull OpenBao remote path contract mismatch"
    if spec.get("appGroups", {}).get("namespacePrefix") != "app-":
        return "AppGroup Namespace prefix contract mismatch"
    if spec.get("appGroups", {}).get("storage") != {
        "storageClass": "local-path",
        "volumeSize": "5Gi",
        "maxClaims": 5,
        "total": "25Gi",
    }:
        return "AppGroup storage contract mismatch"
    chart_contract = yaml.safe_load(
        (workspace / "contracts/values-platform-production.yaml").read_text(encoding="utf-8")
    )
    if chart_contract.get("platform", {}).get("appGroups", {}).get("namespacePrefix") != "app-":
        return "AppGroup Namespace prefix chart contract mismatch"
    if chart_contract.get("platform", {}).get("appGroups", {}).get("storage", {}).get("total") != "25Gi":
        return "AppGroup storage chart contract mismatch"
    if chart_contract.get("platform", {}).get("rancher", {}).get("workloadProjectId") != (
        "local:proj-research-prod"
    ):
        return "AppGroup Rancher project chart contract mismatch"
    portal = yaml.safe_load((workspace / "apps/portal-lite/values-beta.yaml").read_text(encoding="utf-8"))
    if portal["image"]["repository"] != "registry.company.kr/platform/sadp/portal-lite":
        return "Portal OCI repository mismatch"
    if portal["configuration"]["config"]["PLATFORM_BASE_DOMAIN"] != "prod.company.kr":
        return "Portal runtime base domain missing"
    if "PORTAL_AUTO_APPROVE" in portal["configuration"]["config"]:
        return "Portal global auto approval must not be generated"
    if portal["configuration"]["config"].get("PORTAL_ARGO_NAMESPACE") != "devtroncd":
        return "Portal Argo namespace config missing"
    if portal["configuration"]["config"].get("PORTAL_REGISTRY_PULL_REMOTE_PATH") != (
        "platform/registry/forgejo-registry-pull"
    ):
        return "Portal registry pull OpenBao path config missing"
    if portal["configuration"]["config"].get("PORTAL_APP_GROUP_NAMESPACE_PREFIX") != "app-":
        return "Portal AppGroup Namespace prefix config missing"
    if portal["configuration"]["config"].get("PORTAL_APP_GROUP_VOLUME_SIZE") != "5Gi":
        return "Portal AppGroup volume size config missing"
    if portal["configuration"]["config"].get("PORTAL_APP_GROUP_VOLUME_STORAGE_CLASS") != "local-path":
        return "Portal AppGroup StorageClass config missing"
    if portal["configuration"]["config"].get("PORTAL_APP_GROUP_ARGO_PROJECT") != "app-groups":
        return "Portal AppGroup Argo project config missing"
    if portal.get("portalPipeline", {}).get("argoNamespace") != "devtroncd":
        return "Portal pipeline Argo RBAC namespace missing"
    server = yaml.safe_load((workspace / "rke/control-node/config.yaml").read_text(encoding="utf-8"))
    if "rke2-ingress-nginx" not in (server.get("disable") or []):
        return "RKE2 ingress-nginx disable guard missing"
    if server.get("cluster-cidr") != "10.52.0.0/16":
        return "RKE2 Pod CIDR was not generated from POD_CIDRS"
    if server.get("service-cidr") != "10.53.0.0/16":
        return "RKE2 Service CIDR was not generated from SERVICE_CIDRS"
    if server.get("cluster-dns") != "10.53.0.10":
        return "RKE2 cluster DNS was not generated from CLUSTER_DNS_IP"
    worker = yaml.safe_load((workspace / "rke/worker-node/config.yaml").read_text(encoding="utf-8"))
    if any(key in worker for key in ("cluster-cidr", "service-cidr", "cluster-dns")):
        return "RKE2 server-only network keys leaked into the agent config"
    bootstrap = yaml.safe_load((workspace / "argocd/bootstrap-application.yaml").read_text(encoding="utf-8"))
    if bootstrap["spec"]["source"]["repoURL"] != spec["delivery"]["repoURL"]:
        return "Argo bootstrap repository mismatch"
    if bootstrap["spec"]["source"]["targetRevision"] != "production":
        return "Argo bootstrap revision mismatch"
    portal_application = yaml.safe_load(
        (workspace / "argocd/applications/portal-lite.yaml").read_text(encoding="utf-8")
    )
    if portal_application["spec"]["destination"]["namespace"] != "research-prod":
        return "Argo workload Namespace mismatch"
    portal = yaml.safe_load((workspace / "apps/portal-lite/values-beta.yaml").read_text())
    if portal["configuration"]["config"]["PORTAL_ARGO_PROJECT"] != spec["gateway"]["redirectRouteNamespace"]:
        return "Portal Argo project must follow the site platform Namespace"
    squid = (workspace / "platform/network/squid/squid.conf").read_text(encoding="utf-8")
    provider_domains = (workspace / "platform/network/squid/dns-provider-domains.txt").read_text(encoding="utf-8")
    if any(line.strip() and not line.lstrip().startswith("#") for line in provider_domains.splitlines()):
        return "RFC2136 must not add a DNS API hostname to Squid"
    if "dns_provider_domains" in squid:
        return "RFC2136 must not create a Squid DNS provider ACL"
    if "d5l0dvt14r5h8.cloudfront.net" not in squid:
        return "ECR Public layer CDN missing"
    if "packages.company.kr" not in squid:
        return "extra package hostname missing"
    policies = (workspace / "platform/network/egress-policies.yaml").read_text(encoding="utf-8")
    if "192.0.2.53/32" not in policies:
        return "RFC2136 authoritative DNS egress policy missing"
    tls = workspace / "platform/cert-manager/resources.yaml"
    if not tls.exists() or "prod-wildcard-tls-staging" not in tls.read_text(encoding="utf-8"):
        return "staging wildcard Certificate was not rendered"
    if not (workspace / "platform/network/firewall.env").exists():
        return "firewall contract was not rendered"
    firewall = (workspace / "platform/network/firewall.env").read_text(encoding="utf-8")
    if "EXTERNAL_INTERFACE=ens224" not in firewall:
        return "external interface was not generated into firewall.env"
    install_env = (workspace / "platform/network/site-install.env").read_text(encoding="utf-8")
    if "INTERNAL_INTERFACE=ens192" not in install_env or "EXTERNAL_INTERFACE=ens224" not in install_env:
        return "site interfaces were not generated into site-install.env"
    canal = yaml.safe_load(
        (workspace / "platform/network/rke2-canal-config.yaml").read_text(encoding="utf-8")
    )
    if "iface: ens192" not in canal.get("spec", {}).get("valuesContent", ""):
        return "internal interface was not generated into the RKE2 Canal config"
    identity = spec.get("identityProvider") or {}
    if identity.get("managed") != "external":
        return "identity provider must remain external"
    if identity.get("issuer") != "https://idp.company.kr/application/o/sadp":
        return f"external OIDC issuer mismatch: {identity.get('issuer')}"
    if any(path.is_file() for path in (workspace / "platform/keycloak").rglob("*")):
        return "managed identity-provider manifest was generated"
    quota_documents = [
        item
        for item in yaml.safe_load_all(
            (workspace / "platform/quota/resources.yaml").read_text(encoding="utf-8")
        )
        if item
    ]
    if {item["metadata"]["namespace"] for item in quota_documents} != {"research-prod"}:
        return "quota resources were not rendered into the workload Namespace"
    return ""


def generated(workspace: pathlib.Path, _result: subprocess.CompletedProcess) -> str:
    return verify_generated(workspace)


def generated_custom_workload_namespace(
    workspace: pathlib.Path, _result: subprocess.CompletedProcess
) -> str:
    expected = "team-workloads"
    contract = yaml.safe_load(
        (workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]
    values_contract = yaml.safe_load(
        (workspace / "contracts/values-platform-production.yaml").read_text(encoding="utf-8")
    )["platform"]
    portal = yaml.safe_load(
        (workspace / "apps/portal-lite/values-beta.yaml").read_text(encoding="utf-8")
    )
    application = yaml.safe_load(
        (workspace / "argocd/applications/portal-lite.yaml").read_text(encoding="utf-8")
    )
    reader_docs = [
        item
        for item in yaml.safe_load_all(
            (workspace / "platform/portal/app-group-namespace-reader.yaml").read_text(
                encoding="utf-8"
            )
        )
        if item
    ]
    if contract["network"]["defaultDenyNamespaces"] != [expected]:
        return "custom workload Namespace contract mismatch"
    if values_contract["portal"]["namespace"] != expected:
        return "custom workload Namespace chart contract mismatch"
    if values_contract.get("rancher", {}).get("workloadProjectId") != "local:proj-team-workloads":
        return "custom workload Namespace Rancher project chart contract mismatch"
    remote_path = portal["configuration"]["externalSecrets"][0]["remotePath"]
    expected_path = (
        f"apps/{portal['app']['project']}/{portal['app']['environment']}/portal-lite"
    )
    if remote_path != expected_path:
        return f"Portal legacy OpenBao path mismatch: {remote_path}"
    expected_role = (
        f"eso-{portal['app']['project']}-{portal['app']['environment']}-portal-lite"
    )
    if (portal.get("eso") or {}).get("role") != expected_role:
        return "Portal legacy OpenBao role did not preserve the old project/env formula"
    if application["spec"]["destination"]["namespace"] != expected:
        return "Portal Application custom Namespace mismatch"
    binding = next(item for item in reader_docs if item["kind"] == "ClusterRoleBinding")
    if (binding["subjects"][0].get("namespace") or "") != expected:
        return "Namespace reader Portal subject mismatch"
    return ""


def generated_direct_public(workspace: pathlib.Path, result: subprocess.CompletedProcess) -> str:
    contract = yaml.safe_load((workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8"))
    if contract["spec"]["public"]["mode"] != "direct":
        return "direct public mode was not written to the contract"
    if contract["spec"]["public"].get("nodeName") != "prod-worker-1":
        return "direct public node was not written to the contract"
    documents = [
        item
        for item in yaml.safe_load_all(
            (workspace / "platform/exposure/resources.yaml").read_text(encoding="utf-8")
        )
        if item
    ]
    envoy_proxy = next(item for item in documents if item["kind"] == "EnvoyProxy")
    service = envoy_proxy["spec"]["provider"]["kubernetes"]["envoyService"]
    if service.get("externalTrafficPolicy") != "Local":
        return "direct public Service does not preserve source IP"
    deployment = envoy_proxy["spec"]["provider"]["kubernetes"]["envoyDeployment"]
    if deployment["pod"].get("nodeSelector") != {
        "kubernetes.io/hostname": "prod-worker-1"
    }:
        return "direct public Envoy Pod is not pinned to the public-IP node"
    external_ips = service.get("patch", {}).get("value", {}).get("spec", {}).get("externalIPs")
    if external_ips != ["10.20.30.200", "203.0.113.10"]:
        return f"direct public externalIPs mismatch: {external_ips}"
    return ""


def generated_portal_apex(workspace: pathlib.Path, _result: subprocess.CompletedProcess) -> str:
    portal = yaml.safe_load(
        (workspace / "apps/portal-lite/values-beta.yaml").read_text(encoding="utf-8")
    )
    exposure = portal["exposure"]
    if exposure.get("host") != "prod.company.kr":
        return f"Portal apex host 불일치: {exposure.get('host')}"
    if exposure.get("sectionName") != "apex-http":
        return f"TLS 전 Portal apex listener 불일치: {exposure.get('sectionName')}"
    if portal["configuration"]["config"].get("AUTH_URL") != "https://prod.company.kr":
        return "Portal AUTH_URL이 apex host를 따르지 않는다"
    return ""


case("SC-01 valid Forgejo/OCI site.env check", VALID, True)
case(
    "SC-02 external port expansion rejected",
    mutate(VALID, "EXTERNAL_ALLOWED_TCP_PORTS=80,443", "EXTERNAL_ALLOWED_TCP_PORTS=22,80,443"),
    False,
)
case(
    "SC-03 RKE2 fixed port change rejected",
    mutate(VALID, "RKE2_SUPERVISOR_PORT=9345", "RKE2_SUPERVISOR_PORT=19345"),
    False,
)
case(
    "SC-03b AppGroup services cannot exceed Namespace pod quota",
    mutate(VALID, "APP_GROUP_MAX_SERVICES=5", "APP_GROUP_MAX_SERVICES=6"),
    False,
)
case(
    "SC-06 credential-like env key rejected",
    VALID + "FORGEJO_TOKEN=do-not-store-this-here\n",
    False,
)
case("SC-07 write renders contract/apps/Argo/DNS-01", VALID, True, generated, write=True)
case(
    "SC-07b custom workload Namespace projects through GitOps/OpenBao/RBAC",
    mutate(VALID, "WORKLOAD_NAMESPACE=research-prod", "WORKLOAD_NAMESPACE=team-workloads"),
    True,
    generated_custom_workload_namespace,
    write=True,
)
case(
    "SC-09 Cloudflare provider is rejected",
    mutate(VALID, "DNS_PROVIDER=rfc2136", "DNS_PROVIDER=cloudflare"),
    False,
)
case(
    "SC-12 direct public IP renders Envoy Service externalIPs",
    mutate(
        VALID,
        "PUBLIC_EXPOSURE_MODE=nat\nPUBLIC_IP_NODE=",
        "PUBLIC_EXPOSURE_MODE=direct\nPUBLIC_IP_NODE=prod-worker-1",
    ),
    True,
    generated_direct_public,
    write=True,
)
case(
    "SC-12b direct public mode requires the public-IP node",
    mutate(VALID, "PUBLIC_EXPOSURE_MODE=nat", "PUBLIC_EXPOSURE_MODE=direct"),
    False,
)
case(
    "SC-12c nat mode rejects a stale public-IP node",
    mutate(VALID, "PUBLIC_IP_NODE=", "PUBLIC_IP_NODE=prod-worker-1"),
    False,
)
case(
    "SC-13 Portal만 baseDomain apex listener를 선택",
    mutate(VALID, "PORTAL_HOST=", "PORTAL_HOST=prod.company.kr"),
    True,
    generated_portal_apex,
    write=True,
)

def generated_saml_source(workspace: pathlib.Path, _result) -> str:
    identity = yaml.safe_load(
        (workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]["identityProvider"]
    if identity.get("sourceProtocol") != "saml":
        return f"SAML upstream marker mismatch: {identity.get('sourceProtocol')}"
    if identity.get("issuer") != "https://idp.company.kr/application/o/sadp":
        return "SAML broker의 OIDC issuer가 바뀌었다"
    return ""


case(
    "SC-14 SAML upstream은 외부 broker의 OIDC 표면으로 기록",
    mutate(VALID, "IDENTITY_SOURCE_PROTOCOL=openid", "IDENTITY_SOURCE_PROTOCOL=saml"),
    True,
    generated_saml_source,
    write=True,
)
case(
    "SC-15 알 수 없는 identity source protocol 거부",
    mutate(VALID, "IDENTITY_SOURCE_PROTOCOL=openid", "IDENTITY_SOURCE_PROTOCOL=ldap"),
    False,
)
case(
    "SC-15b OIDC endpoint의 평문 HTTP 거부",
    mutate(
        VALID,
        "OIDC_AUTHORIZATION_ENDPOINT=https://idp.company.kr/application/o/authorize/",
        "OIDC_AUTHORIZATION_ENDPOINT=http://idp.company.kr/application/o/authorize/",
    ),
    False,
)
SYSTEMS_ENTRY = (
    "\nSYSTEMS=analytics=analytics.prod.company.kr\n"
)
SYSTEMS_VALID = VALID + SYSTEMS_ENTRY


def generated_system(workspace: pathlib.Path, _result) -> str:
    contract = yaml.safe_load(
        (workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]
    systems = contract.get("systems") or []
    if len(systems) != 1 or systems[0]["name"] != "analytics":
        return f"spec.systems 이 기대와 다르다: {systems}"
    system = systems[0]
    if system["domain"] != "analytics.prod.company.kr":
        return f"system domain 불일치: {system['domain']}"
    if "keycloak" in system or "identityProvider" in system:
        return "system에 독자 IdP 관리 계약이 생성됨"
    if system["workloadNamespace"] not in (contract["gateway"]["allowedRouteNamespaces"] or []):
        return "system workloadNamespace 가 allowedRouteNamespaces 에 없다"
    if (workspace / "platform/systems/analytics/keycloak.yaml").exists():
        return "system IdP manifest가 생성됨"
    gateway_doc = None
    for item in yaml.safe_load_all(
        (workspace / "platform/exposure/resources.yaml").read_text(encoding="utf-8")
    ):
        if item and item.get("kind") == "Gateway":
            gateway_doc = item
    if gateway_doc is None:
        return "Gateway 문서를 찾지 못함"
    listener_names = {item["name"] for item in gateway_doc["spec"]["listeners"]}
    if "http-analytics" not in listener_names:
        return f"http-analytics listener 가 없다: {listener_names}"
    return ""


case(
    "SC-16 SYSTEMS 선언 시 시스템별 Namespace/Gateway listener 생성",
    SYSTEMS_VALID,
    True,
    generated_system,
    write=True,
)
case(
    "SC-17 baseDomain 밖의 SYSTEMS 도메인 거부",
    mutate(SYSTEMS_VALID, "analytics.prod.company.kr", "analytics.other.example.com"),
    False,
)
case(
    "SC-18 provided TLS_SOURCE 와 SYSTEMS 동시 선언 거부",
    mutate(SYSTEMS_VALID, "TLS_SOURCE=acme", "TLS_SOURCE=provided"),
    False,
)

EXTERNAL_SERVICES_VALID = mutate(
    VALID, "EXTERNAL_SERVICES=", "EXTERNAL_SERVICES=forgejo=10.20.30.25:3000,grafana=10.20.30.26:3000"
)


def generated_external_services(workspace: pathlib.Path, _result) -> str:
    contract = yaml.safe_load(
        (workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]
    entries = {
        str(item.get("name")): item
        for item in contract.get("platformServices") or []
        if (item or {}).get("external")
    }
    if set(entries) != {"forgejo", "grafana"}:
        return f"external platformServices 가 기대와 다르다: {sorted(entries)}"
    forgejo = entries["forgejo"]
    if forgejo["host"] != f"forgejo.{contract['baseDomain']}":
        return f"forgejo host 불일치: {forgejo['host']}"
    if forgejo["external"]["address"] != "10.20.30.25":
        return f"forgejo external address 불일치: {forgejo['external']}"
    documents = [
        item
        for item in yaml.safe_load_all(
            (workspace / "platform/exposure/resources.yaml").read_text(encoding="utf-8")
        )
        if item
    ]

    def find(kind: str, namespace: str):
        return next(
            (
                item
                for item in documents
                if item.get("kind") == kind
                and (item.get("metadata") or {}).get("namespace") == namespace
            ),
            None,
        )

    if find("Service", "grafana") is None:
        return "grafana Service 가 렌더되지 않았다"
    if find("EndpointSlice", "grafana") is None:
        return "grafana EndpointSlice 가 렌더되지 않았다"
    service = find("Service", "grafana")
    if service["spec"].get("selector"):
        return "외부 백엔드 Service 에 selector 가 있으면 안 된다"
    route = next(
        (
            item
            for item in documents
            if item.get("kind") == "HTTPRoute"
            and (item.get("metadata") or {}).get("name") == "grafana"
        ),
        None,
    )
    if route is None:
        return "grafana HTTPRoute 가 렌더되지 않았다"
    return ""


case(
    "SC-19 EXTERNAL_SERVICES 는 Namespace/Service/EndpointSlice/HTTPRoute 를 생성한다",
    EXTERNAL_SERVICES_VALID,
    True,
    generated_external_services,
    write=True,
)
case(
    "SC-20 EXTERNAL_SERVICES 형식 오류 거부",
    mutate(VALID, "EXTERNAL_SERVICES=", "EXTERNAL_SERVICES=forgejo=10.20.30.25"),
    False,
)
case(
    "SC-21 EXTERNAL_SERVICES 가 기존 Namespace 와 충돌하면 거부",
    mutate(VALID, "EXTERNAL_SERVICES=", "EXTERNAL_SERVICES=research-prod=10.20.30.25:3000"),
    False,
)

MACHINE_AUTH_VALID = mutate(
    mutate(
        mutate(VALID, "MACHINE_AUTH_SERVICES=", "MACHINE_AUTH_SERVICES=metrics=monitoring/prometheus:9090"),
        "MACHINE_AUTH_CLIENTS=",
        "MACHINE_AUTH_CLIENTS=grafana-central",
    ),
    "MACHINE_AUTH_ALLOWED_CIDRS=",
    "MACHINE_AUTH_ALLOWED_CIDRS=203.0.113.10/32",
)


def generated_machine_auth(workspace: pathlib.Path, _result) -> str:
    contract = yaml.safe_load(
        (workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]
    entry = next(
        (
            item
            for item in contract.get("platformServices") or []
            if (item or {}).get("machineAuth")
        ),
        None,
    )
    if entry is None:
        return "machineAuth platformServices 가 계약에 없다"
    auth = contract.get("machineAuth") or {}
    if entry["machineAuth"] is not True:
        return "platformServices.machineAuth는 전역 계약을 가리키는 marker여야 한다"
    if auth.get("mode") != "oidc":
        return f"mode 불일치: {auth.get('mode')}"
    if auth["clients"] != ["grafana-central"]:
        return f"clients 불일치: {auth['clients']}"
    if auth["allowedCIDRs"] != ["203.0.113.10/32"]:
        return f"allowedCIDRs 불일치: {auth['allowedCIDRs']}"
    # 계약에 토큰/비밀이 들어가면 안 된다. issuer 와 이름만 남아야 한다.
    serialized = str(auth)
    for forbidden in ("secret", "token", "password"):
        if forbidden in serialized.lower():
            return f"machineAuth 에 '{forbidden}' 이 들어 있다"
    policy = next(
        (
            item
            for item in yaml.safe_load_all(
                (workspace / "platform/exposure/resources.yaml").read_text(encoding="utf-8")
            )
            if item and item.get("kind") == "SecurityPolicy"
        ),
        None,
    )
    if policy is None:
        return "SecurityPolicy 가 렌더되지 않았다"
    authorization = policy["spec"]["authorization"]
    if authorization["defaultAction"] != "Deny":
        return "defaultAction 이 Deny 가 아니다"
    principal = authorization["rules"][0]["principal"]
    if principal["clientCIDRs"] != ["203.0.113.10/32"]:
        return f"clientCIDRs 불일치: {principal['clientCIDRs']}"
    if principal["jwt"]["claims"][0]["name"] != "azp":
        return "azp claim 매칭이 없다"
    if not policy["spec"]["jwt"]["providers"][0]["remoteJWKS"]["uri"].startswith("https://"):
        return "JWKS URI 가 https 가 아니다"
    return ""


case(
    "SC-22 MACHINE_AUTH_SERVICES 는 JWT+CIDR SecurityPolicy 를 생성한다",
    MACHINE_AUTH_VALID,
    True,
    generated_machine_auth,
    write=True,
)
case(
    "SC-23 MACHINE_AUTH 에 0.0.0.0/0 거부",
    mutate(MACHINE_AUTH_VALID, "MACHINE_AUTH_ALLOWED_CIDRS=203.0.113.10/32", "MACHINE_AUTH_ALLOWED_CIDRS=0.0.0.0/0"),
    False,
)
case(
    "SC-24 MACHINE_AUTH client 목록 없이 서비스 선언 거부",
    mutate(MACHINE_AUTH_VALID, "MACHINE_AUTH_CLIENTS=grafana-central", "MACHINE_AUTH_CLIENTS="),
    False,
)

MACHINE_API_KEY_VALID = mutate(
    mutate(
        MACHINE_AUTH_VALID,
        "MACHINE_AUTH_MODE=oidc",
        "MACHINE_AUTH_MODE=api-key",
    ),
    "MACHINE_AUTH_CLIENTS=grafana-central",
    "MACHINE_AUTH_CLIENTS=grafana-central,wazuh-connector",
)


def generated_machine_api_key(workspace: pathlib.Path, _result) -> str:
    contract = yaml.safe_load(
        (workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]
    auth = contract.get("machineAuth") or {}
    if auth.get("mode") != "api-key":
        return f"api-key mode 미반영: {auth.get('mode')!r}"
    if "oidc" in auth:
        return "api-key mode 계약에 machine-auth OIDC 설정이 남았다"
    if set((auth.get("apiKey") or {})) != {
        "header", "remotePathPrefix", "secretStoreName", "esoServiceAccount",
        "esoRole", "credentialSecretPrefix",
    }:
        return f"apiKey 메타데이터 불일치: {auth.get('apiKey')!r}"
    documents = [
        item for item in yaml.safe_load_all(
            (workspace / "platform/exposure/resources.yaml").read_text(encoding="utf-8")
        ) if item
    ]
    policy = next(item for item in documents if item.get("kind") == "SecurityPolicy")
    api_key = policy["spec"].get("apiKeyAuth") or {}
    if policy["spec"].get("jwt"):
        return "api-key mode SecurityPolicy에 JWT가 남았다"
    if api_key.get("extractFrom") != [{"headers": ["X-SADP-API-Key"]}]:
        return f"API key header 불일치: {api_key.get('extractFrom')!r}"
    if api_key.get("sanitize") is not True:
        return "API key header sanitize=true가 아니다"
    names = [item["name"] for item in api_key.get("credentialRefs") or []]
    if names != [
        "machine-auth-grafana-central-api-keys",
        "machine-auth-wazuh-connector-api-keys",
    ]:
        return f"credentialRefs 불일치: {names!r}"
    external_secrets = [item for item in documents if item.get("kind") == "ExternalSecret"]
    if len(external_secrets) != 2:
        return f"machine-auth ExternalSecret 수 불일치: {len(external_secrets)}"
    paths = {
        item["spec"]["dataFrom"][0]["extract"]["key"] for item in external_secrets
    }
    if paths != {
        "platform/machine-auth/grafana-central",
        "platform/machine-auth/wazuh-connector",
    }:
        return f"OpenBao remote path 불일치: {paths!r}"
    if any(item.get("kind") == "Secret" for item in documents):
        return "렌더 결과가 Secret을 직접 만들었다"
    return ""


case(
    "SC-24a api-key 모드는 OpenBao/ESO/APIKeyAuth+CIDR를 렌더한다",
    MACHINE_API_KEY_VALID,
    True,
    generated_machine_api_key,
    write=True,
)
case(
    "SC-24b MACHINE_AUTH_MODE 누락 거부",
    mutate(VALID, "MACHINE_AUTH_MODE=oidc", "MACHINE_AUTH_MODE="),
    False,
)
case(
    "SC-24c 잘못된 MACHINE_AUTH_MODE 거부",
    mutate(VALID, "MACHINE_AUTH_MODE=oidc", "MACHINE_AUTH_MODE=basic"),
    False,
)
case(
    "SC-24d api-key client 목록 누락 거부",
    mutate(MACHINE_API_KEY_VALID, "MACHINE_AUTH_CLIENTS=grafana-central,wazuh-connector", "MACHINE_AUTH_CLIENTS="),
    False,
)
case(
    "SC-24e api-key CIDR 목록 누락 거부",
    mutate(MACHINE_API_KEY_VALID, "MACHINE_AUTH_ALLOWED_CIDRS=203.0.113.10/32", "MACHINE_AUTH_ALLOWED_CIDRS="),
    False,
)

DELEGATED_VALID = mutate(
    mutate(
        VALID,
        "DNS_PROVIDER=rfc2136",
        "DNS_PROVIDER=rfc2136\n"
        "DNS01_MODE=delegated-rfc2136\n"
        "ACME_DELEGATION_TYPE=cname\n"
        "ACME_DELEGATED_ZONE=acme.example.net",
    ),
    # 위임 모드에서는 사업자 권한 DNS 가 아니라 우리 ACME DNS 가 UPDATE 대상이다.
    "RFC2136_NAMESERVER=192.0.2.53:53",
    "RFC2136_NAMESERVER=198.51.100.53:53",
)


def delegated_contract(expected_type: str, expected_zone: str):
    def verify(workspace: pathlib.Path, _result) -> str:
        contract = yaml.safe_load(
            (workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8")
        )
        solver = contract["spec"]["tls"]["solver"]
        if solver.get("dns01Mode") != "delegated-rfc2136":
            return f"dns01Mode 미반영: {solver.get('dns01Mode')!r}"
        delegation = solver.get("delegation") or {}
        if delegation.get("type") != expected_type:
            return f"delegation.type 불일치: {delegation.get('type')!r}"
        if delegation.get("zone") != expected_zone:
            return f"delegation.zone 불일치: {delegation.get('zone')!r}"
        if solver["rfc2136"]["nameserver"] != "198.51.100.53:53":
            return "위임 DNS 가 UPDATE 대상으로 반영되지 않았다"
        return ""

    return verify


case(
    "SC-25 DNS01_MODE 없으면 direct-rfc2136 으로 하위 호환된다",
    VALID,
    True,
    lambda workspace, _result: (
        ""
        if yaml.safe_load(
            (workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8")
        )["spec"]["tls"]["solver"].get("dns01Mode")
        in ("direct-rfc2136", None)
        else "기본값이 direct-rfc2136 이 아니다"
    ),
    write=True,
)
case(
    "SC-26 delegated-rfc2136/cname 은 위임 zone 을 계약으로 렌더한다",
    DELEGATED_VALID,
    True,
    delegated_contract("cname", "acme.example.net"),
    write=True,
)
case(
    "SC-27 delegated-rfc2136/ns 는 _acme-challenge.<BASE_DOMAIN> 만 허용한다",
    mutate(
        mutate(DELEGATED_VALID, "ACME_DELEGATION_TYPE=cname", "ACME_DELEGATION_TYPE=ns"),
        "ACME_DELEGATED_ZONE=acme.example.net",
        "ACME_DELEGATED_ZONE=_acme-challenge.prod.company.kr",
    ),
    True,
    delegated_contract("ns", "_acme-challenge.prod.company.kr"),
    write=True,
)
case(
    "SC-28 delegated-rfc2136/ns 에 임의 zone 을 주면 거부한다",
    mutate(DELEGATED_VALID, "ACME_DELEGATION_TYPE=cname", "ACME_DELEGATION_TYPE=ns"),
    False,
)
case(
    "SC-29 direct-rfc2136 에 위임 값이 남아 있으면 거부한다",
    mutate(DELEGATED_VALID, "DNS01_MODE=delegated-rfc2136", "DNS01_MODE=direct-rfc2136"),
    False,
)
case(
    "SC-30 delegated-rfc2136 인데 위임 zone 이 없으면 거부한다",
    mutate(DELEGATED_VALID, "ACME_DELEGATED_ZONE=acme.example.net", "ACME_DELEGATED_ZONE="),
    False,
)
case(
    "SC-31 위임 zone 이 BASE_DOMAIN 과 같으면 거부한다",
    mutate(
        DELEGATED_VALID,
        "ACME_DELEGATED_ZONE=acme.example.net",
        "ACME_DELEGATED_ZONE=prod.company.kr",
    ),
    False,
)
case(
    "SC-32 알 수 없는 DNS01_MODE 는 거부한다",
    mutate(DELEGATED_VALID, "DNS01_MODE=delegated-rfc2136", "DNS01_MODE=acme-dns"),
    False,
)
# self-check 는 공개 권위 응답을 봐야 하므로 recursive resolver 만 공인 IP 를 허용한다.
case(
    "SC-33 DNS_RECURSIVE_NAMESERVERS 는 권위 서버(공인 IP)를 허용한다",
    mutate(
        VALID,
        "DNS_RECURSIVE_NAMESERVERS=10.53.0.10:53",
        "DNS_RECURSIVE_NAMESERVERS=198.51.100.53:53",
    ),
    True,
)
case(
    "SC-34 CERT_MANAGER_NODE_PLACEMENT 는 계약으로 넘어간다",
    mutate(
        VALID,
        "DNS_RECURSIVE_NAMESERVERS=10.53.0.10:53",
        "DNS_RECURSIVE_NAMESERVERS=10.53.0.10:53\nCERT_MANAGER_NODE_PLACEMENT=control-plane",
    ),
    True,
    lambda workspace, _result: (
        ""
        if yaml.safe_load(
            (workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8")
        )["spec"]["tls"]["certManagerPlacement"]
        == "control-plane"
        else "certManagerPlacement 가 계약에 반영되지 않았다"
    ),
    write=True,
)
case(
    "SC-35 알 수 없는 CERT_MANAGER_NODE_PLACEMENT 는 거부한다",
    mutate(
        VALID,
        "DNS_RECURSIVE_NAMESERVERS=10.53.0.10:53",
        "DNS_RECURSIVE_NAMESERVERS=10.53.0.10:53\nCERT_MANAGER_NODE_PLACEMENT=worker",
    ),
    False,
)
# 반대로 CoreDNS upstream 은 egress 호스트의 내부 주소여야 한다.
case(
    "SC-36 CLUSTER_UPSTREAM_DNS 는 계약으로 넘어간다",
    mutate(
        VALID,
        "CLUSTER_DNS_IP=10.53.0.10",
        "CLUSTER_DNS_IP=10.53.0.10\nCLUSTER_UPSTREAM_DNS=10.20.30.11:53",
    ),
    True,
    lambda workspace, _result: (
        ""
        if yaml.safe_load(
            (workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8")
        )["spec"]["network"]["clusterUpstreamDNS"]
        == "10.20.30.11:53"
        else "clusterUpstreamDNS 가 계약에 반영되지 않았다"
    ),
    write=True,
)
case(
    "SC-37 NODE_INTERNAL_CIDRS 밖의 CLUSTER_UPSTREAM_DNS 는 거부한다",
    mutate(
        VALID,
        "CLUSTER_DNS_IP=10.53.0.10",
        "CLUSTER_DNS_IP=10.53.0.10\nCLUSTER_UPSTREAM_DNS=8.8.8.8:53",
    ),
    False,
)
case(
    "SC-38 CLUSTER_UPSTREAM_DNS 에 port 가 없으면 거부한다",
    mutate(
        VALID,
        "CLUSTER_DNS_IP=10.53.0.10",
        "CLUSTER_DNS_IP=10.53.0.10\nCLUSTER_UPSTREAM_DNS=10.20.30.11",
    ),
    False,
)




# egressMode=web 이 "인터넷"을 뜻하려면 0.0.0.0/0 에서 뺄 대역이 계약에 있어야 한다.
# 상수 목록(RFC1918 등)만 넣으면 노드망이 공인 대역인 사이트에서 관리망이 함께 열린다.
def internal_cidrs_cover_cluster(workspace, _result):
    network = yaml.safe_load(
        (workspace / "contracts/platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]["network"]
    internal = set(network.get("internalCIDRs") or [])
    if not internal:
        return "network.internalCIDRs 가 비어 있다"
    for reserved in ("10.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "192.168.0.0/16"):
        if reserved not in internal:
            return f"예약 대역 {reserved} 가 빠졌다"
    # pod/service/node 는 10.0.0.0/8 안에 있으므로 상위 대역으로 덮인 것이 정상이다.
    for cluster in (*network["podCIDRs"], *network["serviceCIDRs"], *network["nodeInternalCIDRs"]):
        first = cluster.split(".")[0]
        if cluster not in internal and first != "10":
            return f"클러스터 대역 {cluster} 가 빠졌다"
    return ""


case(
    "SC-39 network.internalCIDRs 가 예약 대역과 클러스터 대역을 덮는다",
    VALID,
    True,
    internal_cidrs_cover_cluster,
    write=True,
)
# 노드망이 공인 대역인 사이트(이 테스트베드의 192.42.0.0/28 같은)에서도 그 대역이
# 반드시 제외 목록에 들어가야 한다. env 하나만 바꾸면 다른 검증이 줄줄이 걸리므로
# 파생 함수를 직접 호출해 확인한다.
def check_public_node_range() -> str:
    module = load_configure_site()
    derived = module.internal_egress_cidrs(
        {
            "network": {
                "podCIDRs": ["10.42.0.0/16"],
                "serviceCIDRs": ["10.43.0.0/16"],
                "nodeCIDRs": ["192.42.0.0/28"],
            }
        }
    )
    if "192.42.0.0/28" not in derived:
        return f"공인 노드 대역이 internalCIDRs 에 없다: {derived}"
    # 상위 대역에 이미 포함된 항목은 중복으로 남기지 않는다.
    if "10.42.0.0/16" in derived or "10.43.0.0/16" in derived:
        return f"10.0.0.0/8 에 포함된 대역이 중복으로 남았다: {derived}"
    return ""


direct_case("SC-40 공인 노드 대역도 internalCIDRs 에 들어간다", check_public_node_range)


def check_missing_rancher_project_fails_closed() -> str:
    import copy
    import importlib.util

    path = ROOT / "scripts/lib/contract-values.py"
    spec = importlib.util.spec_from_file_location("contract_values", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    contract = yaml.safe_load(
        (ROOT / "contracts/platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]
    broken = copy.deepcopy(contract)
    broken["rancher"]["projects"] = []
    try:
        module.build(broken)
    except ValueError as error:
        if "Rancher project" not in str(error):
            return f"예상하지 못한 오류: {error}"
        return ""
    return "workload Namespace를 소유한 Rancher project 없이 contract values가 생성됨"


direct_case(
    "SC-41 AppGroup Rancher project 매핑 누락은 contract values 생성에서 거부한다",
    check_missing_rancher_project_fails_closed,
)

case(
    "SC-42 SQUID_CLIENT_CIDRS 에 Pod CIDR이 빠지면 거부한다",
    mutate(
        VALID,
        "SQUID_CLIENT_CIDRS=10.20.30.0/24,10.52.0.0/16",
        "SQUID_CLIENT_CIDRS=10.20.30.0/24",
    ),
    False,
)
case(
    "SC-43 SQUID_CLIENT_CIDRS 에 Node CIDR이 빠지면 거부한다",
    mutate(
        VALID,
        "SQUID_CLIENT_CIDRS=10.20.30.0/24,10.52.0.0/16",
        "SQUID_CLIENT_CIDRS=10.52.0.0/16",
    ),
    False,
)

monitoring_backend_disabled = mutate(
    mutate(
        mutate(
            VALID + "SADP_INSTALL_MONITORING=false\n",
            "MACHINE_AUTH_SERVICES=",
            "MACHINE_AUTH_SERVICES=metrics=monitoring/prometheus-server:80",
        ),
        "MACHINE_AUTH_CLIENTS=",
        "MACHINE_AUTH_CLIENTS=grafana-central",
    ),
    "MACHINE_AUTH_ALLOWED_CIDRS=",
    "MACHINE_AUTH_ALLOWED_CIDRS=192.0.2.40/32",
)
case(
    "SC-44 monitoring 비활성인데 monitoring backend 노출을 요청하면 거부한다",
    monitoring_backend_disabled,
    False,
)
case(
    "SC-45 monitoring 비활성이고 관련 backend가 없으면 허용한다",
    VALID + "SADP_INSTALL_MONITORING=false\n",
    True,
)


worker_assignment = "WORKER_NODES=prod-worker-1=10.20.30.21,prod-worker-2=10.20.30.22"
single = mutate(VALID, worker_assignment, "WORKER_NODES=") + "CLUSTER_MODE=single\n"


def check_single_render(workspace, result):
    contract = yaml.safe_load((workspace / "contracts/platform-production.yaml").read_text())
    assert contract["spec"]["network"]["nodeAddresses"] == ["10.20.30.11"]
    server = yaml.safe_load((workspace / "rke/control-node/config.yaml").read_text())
    assert server["node-taint"] == []
    assert server["token"] == ""
    assert "prod-worker" not in (workspace / "rke/etc/hosts").read_text()
    result = subprocess.run(
        [sys.executable, "scripts/site/configure-site.py", "--env-file", "site.env", "--check-rendered"],
        cwd=workspace, capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


case("SC-46 single 렌더와 재렌더 동기화, 서버 배치 가능", single, True,
     check_single_render, write=True)
case("SC-47 single 서버 빌드 노드 허용", single + "SADP_BUILD_NODE=prod-control-plane-1\n", True)
case("SC-48 single에 worker 입력 거부", VALID + "CLUSTER_MODE=single\n", False)
case("SC-49 multi 빈 worker 거부", mutate(VALID, worker_assignment, "WORKER_NODES="), False)
case("SC-50 잘못된 mode 거부", VALID + "CLUSTER_MODE=ha\n", False)
case("SC-51 multi 서버 빌드 지정 거부", VALID + "SADP_BUILD_NODE=prod-control-plane-1\n", False)


def check_multi_render(expected):
    def verify(workspace, result):
        contract = yaml.safe_load((workspace / "contracts/platform-production.yaml").read_text())
        server = yaml.safe_load((workspace / "rke/control-node/config.yaml").read_text())
        if len(contract["spec"]["network"]["nodeAddresses"]) != expected:
            return "nodeAddresses count mismatch"
        if "node-role.kubernetes.io/control-plane=true:NoSchedule" not in server["node-taint"]:
            return "multi server taint missing"
        return ""
    return verify


for count in (1, 4):
    entries = ",".join(f"prod-worker-{i}=10.20.30.{20+i}" for i in range(1, count+1))
    case(f"SC-multi-1+{count} 워커 수 가변 렌더", mutate(VALID, worker_assignment, "WORKER_NODES=" + entries),
         True, check_multi_render(count+1), write=True)



def provided_path_parity():
    import importlib.util
    configure = load_configure_site()
    spec = importlib.util.spec_from_file_location("provided_exposure", ROOT / "scripts/site/render-exposure.py")
    exposure = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(exposure)
    baseline = dict(line.split("=", 1) for line in VALID.splitlines() if line and not line.startswith("#"))
    baseline["TLS_SOURCE"] = "provided"
    baseline["EXISTING_GATEWAY_TLS_READY"] = "true"
    cases = [
        ("/etc/letsencrypt/live/example.invalid/fullchain.pem", "/etc/letsencrypt/live/example.invalid/privkey.pem", True),
        ("/tmp/../fullchain.pem", "/tmp/privkey.pem", False),
        ("wildcard/fullchain.pem", "wildcard/privkey.pem", True),
        ("wildcard/site/fullchain.PEM", "wildcard/site/privkey.pem", True),
        ("/tmp/fullchain.pem", "wildcard/privkey.pem", True),
        ("wildcard/fullchain.pem", "/tmp/privkey.pem", True),
        ("outside/fullchain.pem", "wildcard/privkey.pem", False),
        ("wildcard/../fullchain.pem", "wildcard/privkey.pem", False),
        ("wildcard", "wildcard/privkey.pem", False),
        ("wildcard/fullchain.crt", "wildcard/privkey.pem", False),
        ("wildcard/fullchain.pem", "wildcard/privkey.key", False),
        ("wildcard/same.pem", "wildcard/same.pem", False),
    ]
    for cert, key, expected in cases:
        values = dict(baseline, PROVIDED_CERTIFICATE_PATH=cert, PROVIDED_PRIVATE_KEY_PATH=key)
        try:
            configure.validate(values)
            accepted = True
        except configure.ConfigError as error:
            accepted = False
            assert "PROVIDED_" in str(error), str(error)
        try:
            exposure.provided_inputs({"tls": {"source": "provided", "provided": {
                "certificatePath": cert, "privateKeyPath": key}}})
            rendered = True
        except ValueError:
            rendered = False
        assert accepted == rendered == expected, (cert, key, accepted, rendered, expected)


direct_case("SC-54 provided PEM 경로는 저장 전 검사와 렌더러의 허용·거부 규칙 일치", provided_path_parity)

case("SC-55 Certbot 절대경로로 생성 및 CI 검증",
     VALID.replace("TLS_SOURCE=acme", "TLS_SOURCE=provided")
          .replace("EXISTING_GATEWAY_TLS_READY=false", "EXISTING_GATEWAY_TLS_READY=true")
          .replace("wildcard/fullchain.pem", "/etc/letsencrypt/live/example.invalid/fullchain.pem")
          .replace("wildcard/privkey.pem", "/etc/letsencrypt/live/example.invalid/privkey.pem"),
     True, write=True)

def check_shared_oidc(workspace, result):
    shared = "Authentik.Shared-Client_123"
    contract = yaml.safe_load((workspace / "contracts/platform-production.yaml").read_text())["spec"]
    assert contract["identityProvider"]["sharedClientID"] == shared
    assert contract["identityProvider"]["portalClientID"] == shared
    portal = yaml.safe_load((workspace / "apps/portal-lite/values-beta.yaml").read_text())
    assert portal["configuration"]["config"]["AUTH_OIDC_ID"] == shared
    namespace = load_configure_site().validate(load_configure_site().parse_env(workspace / "site.env"))["layout"]["workloadNamespace"]
    rendered = subprocess.run(["helm", "template", "secure-demo", "charts/app-profile", "-n", namespace,
                               "-f", "contracts/values-platform-production.yaml",
                               "-f", "apps/secure-demo/values-beta.yaml"],
                              cwd=workspace, capture_output=True, text=True)
    assert rendered.returncode == 0, rendered.stderr
    policies = [doc for doc in yaml.safe_load_all(rendered.stdout) if doc and doc.get("kind") == "SecurityPolicy"]
    assert policies[0]["spec"]["oidc"]["clientID"] == shared
    values = (workspace / "site.env").read_text().replace("OIDC_SHARED_CLIENT_ID=" + shared, "OIDC_SHARED_CLIENT_ID=")
    (workspace / "site.env").write_text(values)
    result = subprocess.run([sys.executable, "scripts/site/configure-site.py", "--env-file", "site.env", "--write"],
                            cwd=workspace, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    identity = yaml.safe_load((workspace / "contracts/platform-production.yaml").read_text())["spec"]["identityProvider"]
    assert "sharedClientID" not in identity and identity["portalClientID"] == "portal-prod"


case("SC-56 공통 OIDC ID 대소문자 보존·Portal·Envoy 동기화 및 앱별 설정 복귀",
     VALID + "OIDC_SHARED_CLIENT_ID=Authentik.Shared-Client_123\n", True, check_shared_oidc, write=True)
case("SC-57 공통 OIDC ID 공백 거부", VALID + "OIDC_SHARED_CLIENT_ID=invalid client\n", False)

print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(FAILED != 0)
