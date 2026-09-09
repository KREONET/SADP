#!/usr/bin/env python3
"""Validate a non-secret site.env and render one deployable repository checkout.

The default mode is read-only. ``--write`` is deliberately explicit: it updates the
environment contract, app values, Argo CD repository endpoints, RKE2 templates and
their generated manifests. Git/OCI credentials and DNS API token values are never
accepted by this file; only approved Kubernetes Secret names may be configured.
"""

from __future__ import annotations

import argparse
import copy
import ipaddress
import pathlib
import re
import shlex
import subprocess
import sys
from urllib.parse import urlsplit

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT_PATH = ROOT / "contracts" / "platform-production.yaml"
ENV_KEY = re.compile(r"^[A-Z][A-Z0-9_]*$")
KUBE_NAME = re.compile(r"^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$")
DNS_NAME = re.compile(
    r"^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?(?:\.[a-z0-9](?:[-a-z0-9]*[a-z0-9])?)+$"
)
INTERFACE = re.compile(r"^[A-Za-z0-9_.:-]{1,15}$")
IMAGE_TAG = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
REVISION = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
REGISTRY = re.compile(r"^[a-zA-Z0-9.-]+(?::[0-9]{1,5})?$")
REGISTRY_PATH = re.compile(r"^[a-z0-9](?:[a-z0-9._/-]*[a-z0-9])?$")
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$")
TSIG_KEY_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*\.?$")

SUPPORTED_DNS_PROVIDERS = {"rfc2136"}
SUPPORTED_TSIG_ALGORITHMS = {"HMACMD5", "HMACSHA1", "HMACSHA256", "HMACSHA512"}
SUPPORTED_DNS01_MODES = {"direct-rfc2136", "delegated-rfc2136"}
SUPPORTED_DELEGATION_TYPES = {"cname", "ns"}
# direct-rfc2136 은 Pod 가 권위 서버로 raw DNS UPDATE 를 보낸다. Squid 로는 대신할 수
# 없으므로 egress 가 gateway 노드에만 있는 사이트에서는 controller 를 그 노드에 고정한다.
SUPPORTED_CERT_MANAGER_PLACEMENTS = {"any", "control-plane"}
SUPPORTED_IDENTITY_SOURCE_PROTOCOLS = {"openid", "saml"}
SUPPORTED_MACHINE_AUTH_MODES = {"oidc", "api-key"}
MACHINE_AUTH_API_KEY_HEADER = "X-SADP-API-Key"
MACHINE_AUTH_REMOTE_PATH_PREFIX = "platform/machine-auth"
MACHINE_AUTH_SECRET_STORE = "machine-auth-openbao"
MACHINE_AUTH_ESO_SERVICE_ACCOUNT = "eso-machine-auth"
MACHINE_AUTH_ESO_ROLE = "machine-auth-eso"
MACHINE_AUTH_SECRET_PREFIX = "machine-auth-"
# _acme-challenge 처럼 밑줄로 시작하는 label 도 위임 zone 이름이 될 수 있다.
DNS_ZONE = re.compile(
    r"^_?[a-z0-9](?:[-a-z0-9]*[a-z0-9])?(?:\._?[a-z0-9](?:[-a-z0-9]*[a-z0-9])?)+$"
)
KNOWN_APPS = {"hello", "secure-demo", "portal-lite"}

# Squid 기본 allowlist는 어느 사이트에서도 같은 공개 패키지 공급자만 담는다. 예전에는
# 기존 계약의 목록에 새 값을 append해서, 한 번 들어간 기관 전용 Registry/IdP 도메인이
# 다른 사이트를 렌더한 뒤에도 남았다. 외부 배포에서는 그 흔적 자체가 정보 유출이므로
# 사이트 입력과 무관한 기본값을 코드에서 매번 다시 만든다.
DEFAULT_PACKAGE_DOMAINS = (
    ".docker.io",
    "production.cloudflare.docker.com",
    "production.cloudfront.docker.com",
    "registry.npmjs.org",
    "registry.yarnpkg.com",
    "pypi.org",
    "files.pythonhosted.org",
    "archive.ubuntu.com",
    "security.ubuntu.com",
    "ports.ubuntu.com",
    "ftp.kaist.ac.kr",
    "dl-cdn.alpinelinux.org",
    "repo.zabbix.com",
    "nodejs.org",
    "github.com",
    "codeload.github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
    "charts.external-secrets.io",
    "external-secrets.io",
    "stakater.github.io",
    "openbao.github.io",
    "charts.jetstack.io",
    "grafana.github.io",
    "prometheus-community.github.io",
    "metallb.github.io",
    "releases.rancher.com",
    "helm.devtron.ai",
    "quay.io",
    "cdn01.quay.io",
    "cdn02.quay.io",
    "helm.elastic.co",
    "kubernetes.github.io",
    "fluent.github.io",
    "kubernetes-sigs.github.io",
    "repo.broadcom.com",
    "charts.bitnami.com",
    "kedacore.github.io",
    "opencost.github.io",
    "nvidia.github.io",
    "vmware-tanzu.github.io",
    "cdn03.quay.io",
    "raw.githubusercontent.com",
    "public.ecr.aws",
    "ghcr.io",
    "pkg-containers.githubusercontent.com",
    "registry.k8s.io",
    ".gcr.io",
    "storage.googleapis.com",
    "asia-northeast2-docker.pkg.dev",
    "prod-registry-k8s-io-ap-northeast-1.s3.dualstack.ap-northeast-1.amazonaws.com",
)

# 앱 NetworkPolicy 의 egressMode=web 은 "인터넷 TCP 80/443" 을 뜻한다. 0.0.0.0/0 을 그대로
# 열면 사설망과 클러스터 내부까지 같이 열리므로 ipBlock.except 로 뺄 대역을 계약이 정한다.
# RFC1918/loopback/link-local/CGNAT 는 어느 사이트에서나 같지만, 이 테스트베드처럼
# 노드망이 공인 대역(192.42.0.0/28)인 사이트가 있으므로 pod/service/node 대역을 반드시
# 함께 넣는다. 상수만 믿으면 "사설망 제외"가 조용히 새는 사이트가 생긴다.
RESERVED_EGRESS_CIDRS = (
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.168.0.0/16",
)

# portal-lite 백엔드가 상태 프로브로 EndpointSlice를 읽는 플랫폼 Namespace.
# 이름은 platform/ 차트가 설치하는 고정값이라 site.env로 바꾸지 않는다.
PORTAL_PLATFORM_NAMESPACES = {
    "PORTAL_RANCHER_NAMESPACE": "cattle-system",
    "PORTAL_OPENBAO_NAMESPACE": "openbao",
}
# AppGroup Namespace는 현재 플랫폼 전체에서 `app-<group>` 계약을 쓴다. site.env 입력으로
# 임의 변경을 허용하면 Argo AppProject destination과 Portal/Chart가 동시에 어긋나므로,
# 확장 입력을 설계하기 전까지 생성 계약의 고정값으로 둔다.
APP_GROUP_NAMESPACE_PREFIX = "app-"
OPENBAO_ESO_ROLES = {
    "zoneApp": "portal-zone-app-eso",
    "groupApp": "portal-group-app-eso",
    "groupRegistry": "portal-group-registry-eso",
}
# https://host/owner/repo(.git) 형태만 Forgejo REST API 좌표로 환산할 수 있다.
FORGEJO_HTTPS_URL = re.compile(
    r"^https://([A-Za-z0-9._-]+(?::[0-9]{1,5})?)/([A-Za-z0-9][A-Za-z0-9._-]{0,62})/"
    r"([A-Za-z0-9][A-Za-z0-9._-]{0,62}?)(?:\.git)?/?$"
)
MUTABLE_IMAGE_TAGS = {"latest", "main", "master", "stable"}
ALLOWED_SECRET_METADATA_KEYS = {
    "ACME_ACCOUNT_SECRET_NAME",
    "DNS_CREDENTIAL_SECRET_NAME",
    "DNS_CREDENTIAL_SECRET_KEY",
    "REGISTRY_PULL_SECRET",
    "PROVIDED_PRIVATE_KEY_PATH",
    "WILDCARD_TLS_SECRET",
    "SADP_ARGO_REPO_TOKEN_FILE",
    "SADP_DNS_TSIG_SECRET_FILE",
    # OAuth 표준 endpoint 이름에 TOKEN이 들어가지만 값은 공개 URL이다.
    "OIDC_TOKEN_ENDPOINT",
}
SENSITIVE_KEY = re.compile(r"PASSWORD|TOKEN|PRIVATE_KEY|CREDENTIAL|API_KEY|SECRET")
SENSITIVE_VALUE = re.compile(
    r"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY|hvs\.[A-Za-z0-9]{20,}|"
    r"ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}"
)

KNOWN_KEYS = {
    "SITE_NAME", "APP_ENVIRONMENT", "CLUSTER_NAME", "BASE_DOMAIN", "APP_PROJECT",
    "WORKLOAD_NAMESPACE", "PLATFORM_ROUTE_NAMESPACE", "GATEWAY_NAMESPACE",
    "GATEWAY_NAME", "GATEWAY_PROXY_CONFIG_NAME", "GATEWAY_ADDRESS_POOL_NAME",
    "WILDCARD_TLS_SECRET", "ACME_CLUSTER_ISSUER_NAME", "ACME_ACCOUNT_SECRET_NAME",
    "PORTAL_HOST", "HELLO_HOST", "SECURE_DEMO_HOST",
    "RANCHER_HOST", "OPENBAO_HOST", "SYSTEMS", "EXTERNAL_SERVICES",
    "MACHINE_AUTH_MODE", "MACHINE_AUTH_SERVICES", "MACHINE_AUTH_CLIENTS",
    "MACHINE_AUTH_ALLOWED_CIDRS",
    "IDENTITY_SOURCE_PROTOCOL", "OIDC_ISSUER", "OIDC_AUTHORIZATION_ENDPOINT",
    "OIDC_TOKEN_ENDPOINT", "OIDC_JWKS_URI", "OIDC_END_SESSION_ENDPOINT",
    "OIDC_GROUPS_CLAIM", "OIDC_CLIENT_ID_CLAIM", "PORTAL_OIDC_CLIENT_ID",
    "STORAGE_CLASS", "APP_GROUP_VOLUME_SIZE", "APP_GROUP_MAX_SERVICES", "FORGEJO_REPO_URL",
    "FORGEJO_REVISION", "OCI_REGISTRY", "OCI_PROJECT", "REGISTRY_PULL_SECRET",
    "TEST_APP_IMAGE_TAG", "PORTAL_IMAGE_TAG", "IMAGE_PULL_POLICY",
    "CONTROL_PLANE_HOSTNAME", "CONTROL_PLANE_IP", "WORKER_NODES",
    "INTERNAL_INTERFACE", "EXTERNAL_INTERFACE", "GUARDED_INTERFACES",
    "NODE_INTERNAL_CIDRS",
    "POD_CIDRS", "SERVICE_CIDRS", "CLUSTER_DNS_IP",
    "KUBERNETES_API_ADDRESSES", "RKE2_SERVER_ENDPOINT",
    "INTERNAL_ALLOWED_TCP_PORTS", "INTERNAL_ALLOWED_UDP_PORTS",
    "CLUSTER_UPSTREAM_DNS",
    "KUBERNETES_API_PORT", "RKE2_SUPERVISOR_PORT", "ETCD_CLIENT_PORT",
    "ETCD_PEER_PORT", "KUBELET_PORT", "CANAL_VXLAN_UDP_PORT", "PUBLIC_IP",
    "PUBLIC_EXPOSURE_MODE", "PUBLIC_IP_NODE",
    "GATEWAY_VIP", "GATEWAY_ADDRESS_POOL", "PUBLIC_HTTP_PORT",
    "PUBLIC_HTTPS_PORT", "EXTERNAL_ALLOWED_TCP_PORTS",
    "EXTERNAL_ALLOWED_UDP_PORTS", "ENVOY_HTTPS_TARGET_PORT",
    "SQUID_INTERNAL_IP", "SQUID_PORT", "SQUID_CLIENT_CIDRS",
    "EXTRA_PACKAGE_DOMAINS", "TLS_SOURCE", "TLS_ISSUER_MODE",
    "ACME_STAGING_VERIFIED", "EXISTING_GATEWAY_TLS_READY", "ACME_EMAIL",
    "DNS_PROVIDER", "DNS01_MODE", "ACME_DELEGATION_TYPE", "ACME_DELEGATED_ZONE",
    "RFC2136_NAMESERVER", "RFC2136_TSIG_KEY_NAME",
    "RFC2136_TSIG_ALGORITHM", "DNS_CREDENTIAL_SECRET_NAME",
    "DNS_CREDENTIAL_SECRET_KEY", "DNS_RECURSIVE_NAMESERVERS",
    "CERT_MANAGER_NODE_PLACEMENT",
    "PROVIDED_CERTIFICATE_PATH", "PROVIDED_PRIVATE_KEY_PATH",
    "SADP_INSTALL_GITOPS", "SADP_ARGO_REPO_USERNAME", "SADP_ARGO_REPO_TOKEN_FILE",
    "SADP_DNS_TSIG_SECRET_FILE", "SADP_INSTALL_MONITORING", "SADP_BUILD_IMAGES", "SADP_BUILD_NODE",
    "SADP_DEPLOY_APPS", "SADP_REGISTRY_PULL_DOCKERCONFIG",
    "SADP_REGISTRY_PUSH_DOCKERCONFIG", "SADP_RUN_VERIFY",
}


class ConfigError(ValueError):
    """A site.env value is missing, unsafe or internally inconsistent."""


def parse_env(path: pathlib.Path) -> dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ConfigError(f"cannot read env file: {error}") from error
    if len(text.encode("utf-8")) > 64 * 1024:
        raise ConfigError("env file exceeds 64 KiB")

    result: dict[str, str] = {}
    for line_number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        key, separator, value = line.partition("=")
        key = key.strip()
        if not separator or not ENV_KEY.fullmatch(key):
            raise ConfigError(f"line {line_number}: expected UPPER_CASE_KEY=value")
        if key in result:
            raise ConfigError(f"line {line_number}: duplicate key {key}")
        value = value.strip()
        if value[:1] in {"'", '"'}:
            if len(value) < 2 or value[-1] != value[0]:
                raise ConfigError(f"line {line_number}: unterminated quote for {key}")
            value = value[1:-1]
        if any(marker in value for marker in ("$(", "`", "${")):
            raise ConfigError(f"line {line_number}: shell interpolation is forbidden for {key}")
        if "\x00" in value or "\n" in value or "\r" in value:
            raise ConfigError(f"line {line_number}: control character in {key}")
        if len(value) > 2048:
            raise ConfigError(f"line {line_number}: value too long for {key}")
        result[key] = value

    unknown = sorted(set(result) - KNOWN_KEYS)
    if unknown:
        raise ConfigError("unknown env keys: " + ", ".join(unknown))
    for key, value in result.items():
        if SENSITIVE_KEY.search(key) and key not in ALLOWED_SECRET_METADATA_KEYS:
            raise ConfigError(
                f"{key} looks like secret material; site.env accepts Secret names/keys only"
            )
        if SENSITIVE_VALUE.search(value):
            raise ConfigError(f"{key} contains credential-like material")
    return result


def required(values: dict[str, str], key: str) -> str:
    value = values.get(key, "").strip()
    if not value:
        raise ConfigError(f"{key} is required")
    if "CHANGE_ME" in value.upper():
        raise ConfigError(f"{key} still contains CHANGE_ME")
    return value


def optional(values: dict[str, str], key: str) -> str:
    value = values.get(key, "").strip()
    if value and "CHANGE_ME" in value.upper():
        raise ConfigError(f"{key} still contains CHANGE_ME")
    return value


def boolean(values: dict[str, str], key: str, default: bool = False) -> bool:
    raw = values.get(key, "true" if default else "false").strip().lower()
    if raw not in {"true", "false"}:
        raise ConfigError(f"{key} must be true or false")
    return raw == "true"


def csv(values: dict[str, str], key: str, *, required_value: bool = False) -> list[str]:
    raw = required(values, key) if required_value else optional(values, key)
    if not raw:
        return []
    items = [item.strip() for item in raw.split(",")]
    if any(not item for item in items):
        raise ConfigError(f"{key} contains an empty item")
    if len(items) != len(set(items)):
        raise ConfigError(f"{key} contains duplicate items")
    return items


def port(raw: str, where: str) -> int:
    try:
        value = int(raw)
    except ValueError as error:
        raise ConfigError(f"{where} must be an integer port") from error
    if not 1 <= value <= 65535:
        raise ConfigError(f"{where} must be in 1..65535")
    return value


def positive_int(raw: str, where: str, maximum: int) -> int:
    try:
        value = int(raw)
    except ValueError as error:
        raise ConfigError(f"{where} must be an integer") from error
    if not 1 <= value <= maximum:
        raise ConfigError(f"{where} must be in 1..{maximum}")
    return value


def storage_quantity(raw: str, where: str) -> tuple[int, str]:
    match = re.fullmatch(r"([1-9][0-9]*)(Mi|Gi|Ti)", raw)
    if not match:
        raise ConfigError(f"{where} must be a positive integer Mi/Gi/Ti quantity")
    amount = int(match.group(1))
    if amount > 1024:
        raise ConfigError(f"{where} is too large")
    return amount, match.group(2)


def ports(values: dict[str, str], key: str) -> set[int]:
    return {port(item, key) for item in csv(values, key)}


def ipv4(raw: str, where: str, *, private: bool = False) -> ipaddress.IPv4Address:
    try:
        value = ipaddress.ip_address(raw)
    except ValueError as error:
        raise ConfigError(f"{where} must be an IPv4 address") from error
    if not isinstance(value, ipaddress.IPv4Address):
        raise ConfigError(f"{where} must be an IPv4 address")
    if value.is_loopback or value.is_multicast or value.is_unspecified:
        raise ConfigError(f"{where} is not a usable unicast IPv4 address")
    if private and not value.is_private:
        raise ConfigError(f"{where} must be a private/internal IPv4 address")
    return value


def cidr(raw: str, where: str) -> ipaddress.IPv4Network:
    try:
        value = ipaddress.ip_network(raw, strict=True)
    except ValueError as error:
        raise ConfigError(f"{where} must be a canonical IPv4 CIDR") from error
    if not isinstance(value, ipaddress.IPv4Network) or value.prefixlen == 0:
        raise ConfigError(f"{where} must be a non-default IPv4 CIDR")
    return value


def cidrs(values: dict[str, str], key: str) -> list[ipaddress.IPv4Network]:
    return [cidr(item, key) for item in csv(values, key, required_value=True)]


def dns_name(raw: str, where: str) -> str:
    value = raw.strip().lower().rstrip(".")
    if not DNS_NAME.fullmatch(value) or len(value) > 253:
        raise ConfigError(f"{where} must be a lower-case DNS hostname")
    return value


def kube_name(raw: str, where: str) -> str:
    value = raw.strip().lower()
    if not KUBE_NAME.fullmatch(value) or len(value) > 63:
        raise ConfigError(f"{where} must be a Kubernetes/DNS label")
    return value


def parse_identity_provider(values: dict[str, str]) -> dict[str, str]:
    """외부 IdP의 공개 OIDC 소비 계약만 받는다.

    sourceProtocol=saml은 외부 브로커의 상류 연결 방식이다. Portal, Envoy Gateway,
    OpenBao는 SAML을 직접 처리하지 않으므로 두 경우 모두 브로커가 공개한 OIDC endpoint가
    필요하다. 저장소는 IdP, realm, client, 사용자 또는 그룹을 생성하지 않는다.
    """
    source_protocol = required(values, "IDENTITY_SOURCE_PROTOCOL").lower()
    if source_protocol not in SUPPORTED_IDENTITY_SOURCE_PROTOCOLS:
        raise ConfigError("IDENTITY_SOURCE_PROTOCOL must be openid or saml")
    issuer = https_url(required(values, "OIDC_ISSUER"), "OIDC_ISSUER").rstrip("/")
    authorization = https_url(
        required(values, "OIDC_AUTHORIZATION_ENDPOINT"), "OIDC_AUTHORIZATION_ENDPOINT"
    )
    token = https_url(required(values, "OIDC_TOKEN_ENDPOINT"), "OIDC_TOKEN_ENDPOINT")
    jwks = https_url(required(values, "OIDC_JWKS_URI"), "OIDC_JWKS_URI")
    end_session_raw = optional(values, "OIDC_END_SESSION_ENDPOINT")
    end_session = (
        https_url(end_session_raw, "OIDC_END_SESSION_ENDPOINT") if end_session_raw else ""
    )
    groups_claim = optional(values, "OIDC_GROUPS_CLAIM") or "groups"
    client_id_claim = optional(values, "OIDC_CLIENT_ID_CLAIM") or "azp"
    for name, value in (("OIDC_GROUPS_CLAIM", groups_claim), ("OIDC_CLIENT_ID_CLAIM", client_id_claim)):
        if not re.fullmatch(r"[A-Za-z0-9._/-]{1,128}", value):
            raise ConfigError(f"{name} has an invalid claim name")
    return {
        "managed": "external",
        "sourceProtocol": source_protocol,
        "issuer": issuer,
        "authorizationEndpoint": authorization,
        "tokenEndpoint": token,
        "jwksURI": jwks,
        "endSessionEndpoint": end_session,
        "groupsClaim": groups_claim,
        "clientIDClaim": client_id_claim,
        "portalClientID": kube_name(
            required(values, "PORTAL_OIDC_CLIENT_ID"), "PORTAL_OIDC_CLIENT_ID"
        ),
    }


def parse_machine_auth(
    values: dict[str, str], base_domain: str, identity_provider: dict[str, str]
) -> dict:
    """기계 인증의 전역 모드와 노출 서비스를 실제 값 없는 계약으로 바꾼다.

    oidc는 외부 IdP의 client_credentials JWT를 검증한다. api-key는 클라이언트 이름과
    OpenBao/ESO가 사용할 경로·Secret 이름만 계약에 두며 실제 키는 절대 받지 않는다.
    """
    mode = required(values, "MACHINE_AUTH_MODE").lower()
    if mode not in SUPPORTED_MACHINE_AUTH_MODES:
        raise ConfigError("MACHINE_AUTH_MODE must be oidc or api-key")
    entries = csv(values, "MACHINE_AUTH_SERVICES")
    clients = csv(values, "MACHINE_AUTH_CLIENTS")
    cidrs = csv(values, "MACHINE_AUTH_ALLOWED_CIDRS")
    if mode == "api-key" and not clients:
        raise ConfigError("MACHINE_AUTH_MODE=api-key requires MACHINE_AUTH_CLIENTS")
    if mode == "api-key" and not cidrs:
        raise ConfigError("MACHINE_AUTH_MODE=api-key requires MACHINE_AUTH_ALLOWED_CIDRS")
    if entries and not clients:
        raise ConfigError("MACHINE_AUTH_SERVICES requires MACHINE_AUTH_CLIENTS")
    if entries and not cidrs:
        raise ConfigError(
            "MACHINE_AUTH_SERVICES requires MACHINE_AUTH_ALLOWED_CIDRS; these endpoints "
            "expose cluster internals"
        )
    if not entries and mode == "oidc" and (clients or cidrs):
        raise ConfigError(
            "MACHINE_AUTH_CLIENTS and MACHINE_AUTH_ALLOWED_CIDRS require "
            "MACHINE_AUTH_SERVICES in oidc mode"
        )
    for entry in cidrs:
        try:
            network = ipaddress.ip_network(entry, strict=False)
        except ValueError as error:
            raise ConfigError(f"MACHINE_AUTH_ALLOWED_CIDRS entry is not a CIDR: {entry}") from error
        if not isinstance(network, ipaddress.IPv4Network):
            raise ConfigError("MACHINE_AUTH_ALLOWED_CIDRS must be IPv4")
        if int(network.prefixlen) == 0:
            raise ConfigError("MACHINE_AUTH_ALLOWED_CIDRS must not be 0.0.0.0/0")
    for client in clients:
        kube_name(client, f"MACHINE_AUTH_CLIENTS entry '{client}'")
        if len(f"{MACHINE_AUTH_SECRET_PREFIX}{client}-api-keys") > 63:
            raise ConfigError(
                f"MACHINE_AUTH_CLIENTS entry '{client}' is too long for the derived Secret name"
            )

    if len(clients) != len(set(clients)):
        raise ConfigError("MACHINE_AUTH_CLIENTS contains duplicate names")

    services: list[dict] = []
    for entry in entries:
        name_part, separator, target = entry.partition("=")
        if not separator:
            raise ConfigError(
                f"MACHINE_AUTH_SERVICES entry must be <name>=<namespace>/<service>:<port>: {entry}"
            )
        name = kube_name(name_part, f"MACHINE_AUTH_SERVICES name '{name_part}'")
        if len(f"{name}-machine-auth") > 63:
            raise ConfigError(
                f"MACHINE_AUTH_SERVICES name '{name}' is too long for the SecurityPolicy name"
            )
        namespace_part, slash, rest = target.partition("/")
        if not slash:
            raise ConfigError(
                f"MACHINE_AUTH_SERVICES entry must be <name>=<namespace>/<service>:<port>: {entry}"
            )
        namespace = kube_name(namespace_part, f"MACHINE_AUTH_SERVICES namespace for '{name}'")
        service_part, colon, port_text = rest.rpartition(":")
        if not colon:
            raise ConfigError(
                f"MACHINE_AUTH_SERVICES entry must be <name>=<namespace>/<service>:<port>: {entry}"
            )
        backend = kube_name(service_part, f"MACHINE_AUTH_SERVICES service for '{name}'")
        service_port = port(port_text, f"MACHINE_AUTH_SERVICES port for '{name}'")
        services.append(
            {
                "name": name,
                "host": f"{name}.{base_domain}",
                "namespace": namespace,
                "service": backend,
                "port": service_port,
                "machineAuth": True,
            }
        )
    names = [item["name"] for item in services]
    if len(names) != len(set(names)):
        raise ConfigError("MACHINE_AUTH_SERVICES contains duplicate names")
    result = {
        "mode": mode,
        "clients": clients,
        "allowedCIDRs": cidrs,
    }
    if mode == "oidc":
        result["oidc"] = {
            "issuer": identity_provider["issuer"],
            "jwksURI": identity_provider["jwksURI"],
            "clientClaim": identity_provider["clientIDClaim"],
        }
    else:
        result["apiKey"] = {
            "header": MACHINE_AUTH_API_KEY_HEADER,
            "remotePathPrefix": MACHINE_AUTH_REMOTE_PATH_PREFIX,
            "secretStoreName": MACHINE_AUTH_SECRET_STORE,
            "esoServiceAccount": MACHINE_AUTH_ESO_SERVICE_ACCOUNT,
            "esoRole": MACHINE_AUTH_ESO_ROLE,
            "credentialSecretPrefix": MACHINE_AUTH_SECRET_PREFIX,
        }
    result["services"] = services
    return result


def parse_external_services(
    values: dict[str, str], base_domain: str, reserved_namespaces: set[str]
) -> list[dict]:
    """`EXTERNAL_SERVICES=<name>=<ipv4>:<port>,...` 를 외부 백엔드 목록으로 바꾼다.

    다른 VM 에서 도는 Forgejo, Grafana 같은 서비스를 Envoy Gateway 뒤에 붙인다. 클러스터에는
    워크로드 없이 Namespace/Service/EndpointSlice 만 생기고, 공개 host 와 wildcard 인증서는
    기존 platformServices 경로를 그대로 쓴다.
    """
    entries = csv(values, "EXTERNAL_SERVICES")
    if not entries:
        return []
    services: list[dict] = []
    reserved = set(reserved_namespaces)
    for entry in entries:
        name_part, separator, target = entry.partition("=")
        if not separator:
            raise ConfigError(f"EXTERNAL_SERVICES entry must be <name>=<ipv4>:<port>: {entry}")
        name = kube_name(name_part, f"EXTERNAL_SERVICES name '{name_part}'")
        address_text, colon, port_text = target.rpartition(":")
        if not colon:
            raise ConfigError(f"EXTERNAL_SERVICES entry must be <name>=<ipv4>:<port>: {entry}")
        address = str(ipv4(address_text, f"EXTERNAL_SERVICES address for '{name}'"))
        service_port = port(port_text, f"EXTERNAL_SERVICES port for '{name}'")
        if name in reserved:
            raise ConfigError(
                f"EXTERNAL_SERVICES namespace '{name}' collides with an existing namespace"
            )
        reserved.add(name)
        services.append(
            {
                "name": name,
                "host": f"{name}.{base_domain}",
                "namespace": name,
                "address": address,
                "port": service_port,
            }
        )
    names = [item["name"] for item in services]
    if len(names) != len(set(names)):
        raise ConfigError("EXTERNAL_SERVICES contains duplicate names")
    return services


def parse_systems(
    values: dict[str, str],
    environment: str,
    base_domain: str,
    reserved_namespaces: set[str],
) -> list[dict]:
    """`SYSTEMS=<name>=<domain>,...` 를 시스템 목록으로 바꾼다.

    시스템마다 전용 Namespace, Rancher Project, 도메인, wildcard 인증서를 가진다.
    인증은 사이트의 외부 IdP 계약을 공유한다. 도메인은 baseDomain 의 형제 서브도메인
    이어야 한다 — 그래야 이미 승인된 RFC2136 zone/TSIG 하나로 모든 시스템의 wildcard 를
    발급할 수 있다.
    """
    entries = csv(values, "SYSTEMS")
    if not entries:
        return []
    systems: list[dict] = []
    reserved = set(reserved_namespaces)
    for entry in entries:
        name, separator, domain = entry.partition("=")
        if not separator:
            raise ConfigError(f"SYSTEMS entry must be <name>=<domain>: {entry}")
        system_name = kube_name(name, f"SYSTEMS name '{name}'")
        system_domain = dns_name(domain, f"SYSTEMS domain for '{system_name}'")
        if not system_domain.endswith(f".{base_domain}"):
            raise ConfigError(
                f"SYSTEMS domain for '{system_name}' must be a subdomain of BASE_DOMAIN "
                "so the existing RFC2136 zone/TSIG can issue its wildcard"
            )
        namespace = kube_name(
            f"{system_name}-{environment}", f"derived namespace for '{system_name}'"
        )
        if namespace in reserved:
            raise ConfigError(
                f"SYSTEMS namespace '{namespace}' collides with an existing namespace"
            )
        reserved.add(namespace)

        systems.append(
            {
                "name": system_name,
                "domain": system_domain,
                "workloadNamespace": namespace,
                "project": kube_name(f"proj-{namespace}", "derived system project"),
                "wildcardTlsSecret": kube_name(
                    f"{system_name}-wildcard-tls", "derived system TLS secret"
                ),
                "httpListener": f"http-{system_name}",
                "httpsListener": f"https-{system_name}",
            }
        )
    names = [item["name"] for item in systems]
    if len(names) != len(set(names)):
        raise ConfigError("SYSTEMS contains duplicate system names")
    domains = [item["domain"] for item in systems]
    if len(domains) != len(set(domains)):
        raise ConfigError("SYSTEMS contains duplicate domains")
    return systems




def interface(raw: str, where: str) -> str:
    if not INTERFACE.fullmatch(raw):
        raise ConfigError(f"{where} is not a valid Linux interface name")
    return raw


def endpoint_host(values: dict[str, str], key: str, label: str, base_domain: str) -> str:
    configured = optional(values, key)
    host = dns_name(configured or f"{label}.{base_domain}", key)
    if host != base_domain and not host.endswith(f".{base_domain}"):
        raise ConfigError(f"{key} must be inside BASE_DOMAIN")
    return host


def validate_git_url(raw: str) -> str:
    if raw.startswith("git@") and ":" in raw:
        if any(character.isspace() for character in raw):
            raise ConfigError("FORGEJO_REPO_URL contains whitespace")
        return raw
    parsed = urlsplit(raw)
    if parsed.scheme not in {"https", "ssh"} or not parsed.hostname:
        raise ConfigError("FORGEJO_REPO_URL must use https://, ssh:// or git@host:path")
    if parsed.username or parsed.password:
        raise ConfigError("FORGEJO_REPO_URL must not embed credentials")
    if parsed.query or parsed.fragment:
        raise ConfigError("FORGEJO_REPO_URL must not contain query/fragment")
    return raw


def https_url(raw: str, where: str) -> str:
    parsed = urlsplit(raw)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ConfigError(f"{where} must be an HTTPS URL")
    if parsed.username or parsed.password or parsed.fragment:
        raise ConfigError(f"{where} must not contain credentials or a fragment")
    if any(character.isspace() for character in raw):
        raise ConfigError(f"{where} must not contain whitespace")
    return raw


def safe_absolute_path(raw: str, where: str) -> str:
    """Validate a root-owned input path without reading the referenced secret file."""
    if not raw.startswith("/") or not re.fullmatch(r"/[A-Za-z0-9._/-]+", raw):
        raise ConfigError(f"{where} must be a safe absolute path")
    parts = pathlib.PurePosixPath(raw).parts
    if ".." in parts or raw == "/" or "//" in raw:
        raise ConfigError(f"{where} must identify one file below an absolute directory")
    return raw


def forgejo_api_coordinates(raw: str) -> dict[str, str] | None:
    """https 원격 주소를 Forgejo REST API 좌표로 환산한다. ssh/git@ 주소는 None."""
    match = FORGEJO_HTTPS_URL.fullmatch(raw.strip())
    if match is None:
        return None
    host, owner, repo = match.groups()
    if repo in {".", ".."} or owner in {".", ".."}:
        return None
    return {"baseURL": f"https://{host}", "owner": owner, "repo": repo}


def parse_workers(raw: str, networks: list[ipaddress.IPv4Network]) -> list[tuple[str, str]]:
    result: list[tuple[str, str]] = []
    for item in [entry.strip() for entry in raw.split(",") if entry.strip()]:
        name, separator, address_raw = item.partition("=")
        if not separator:
            raise ConfigError("WORKER_NODES must be hostname=IPv4 entries")
        name = kube_name(name, "WORKER_NODES hostname")
        address = ipv4(address_raw, "WORKER_NODES address")
        if not any(address in network for network in networks):
            raise ConfigError(f"worker {address} is outside NODE_INTERNAL_CIDRS")
        result.append((name, str(address)))
    if not result:
        raise ConfigError("WORKER_NODES must contain at least one worker")
    if len({name for name, _ in result}) != len(result):
        raise ConfigError("WORKER_NODES contains duplicate hostnames")
    if len({address for _, address in result}) != len(result):
        raise ConfigError("WORKER_NODES contains duplicate addresses")
    return result


def validate(values: dict[str, str]) -> dict:
    site_name = kube_name(required(values, "SITE_NAME"), "SITE_NAME")
    environment = required(values, "APP_ENVIRONMENT")
    if environment not in {"dev", "beta", "prod"}:
        raise ConfigError("APP_ENVIRONMENT must be dev, beta or prod")
    cluster_name = kube_name(required(values, "CLUSTER_NAME"), "CLUSTER_NAME")
    base_domain = dns_name(required(values, "BASE_DOMAIN"), "BASE_DOMAIN")
    if base_domain == "example.com" or base_domain.endswith(".example.com"):
        raise ConfigError("BASE_DOMAIN is still an example domain")
    app_project = kube_name(optional(values, "APP_PROJECT") or "research", "APP_PROJECT")

    workload_namespace = kube_name(
        required(values, "WORKLOAD_NAMESPACE"), "WORKLOAD_NAMESPACE"
    )
    platform_namespace = kube_name(
        required(values, "PLATFORM_ROUTE_NAMESPACE"), "PLATFORM_ROUTE_NAMESPACE"
    )
    gateway_namespace = kube_name(
        required(values, "GATEWAY_NAMESPACE"), "GATEWAY_NAMESPACE"
    )
    if len({workload_namespace, platform_namespace, gateway_namespace}) != 3:
        raise ConfigError(
            "WORKLOAD_NAMESPACE, PLATFORM_ROUTE_NAMESPACE and GATEWAY_NAMESPACE must differ"
        )
    workload_project = kube_name(f"proj-{workload_namespace}", "derived workload project")
    platform_project = kube_name(f"proj-{platform_namespace}", "derived platform project")
    gateway_name = kube_name(required(values, "GATEWAY_NAME"), "GATEWAY_NAME")
    gateway_proxy = kube_name(
        required(values, "GATEWAY_PROXY_CONFIG_NAME"), "GATEWAY_PROXY_CONFIG_NAME"
    )
    gateway_pool_name = kube_name(
        required(values, "GATEWAY_ADDRESS_POOL_NAME"), "GATEWAY_ADDRESS_POOL_NAME"
    )
    wildcard_secret = kube_name(
        required(values, "WILDCARD_TLS_SECRET"), "WILDCARD_TLS_SECRET"
    )
    acme_issuer = kube_name(
        required(values, "ACME_CLUSTER_ISSUER_NAME"), "ACME_CLUSTER_ISSUER_NAME"
    )
    acme_account_secret = kube_name(
        required(values, "ACME_ACCOUNT_SECRET_NAME"), "ACME_ACCOUNT_SECRET_NAME"
    )

    hosts = {
        "portal": endpoint_host(values, "PORTAL_HOST", "portal", base_domain),
        "hello": endpoint_host(values, "HELLO_HOST", "hello", base_domain),
        "secure-demo": endpoint_host(
            values, "SECURE_DEMO_HOST", "secure-demo", base_domain
        ),
        "rancher": endpoint_host(values, "RANCHER_HOST", "rancher", base_domain),
        "openbao": endpoint_host(values, "OPENBAO_HOST", "openbao", base_domain),
    }
    if len(set(hosts.values())) != len(hosts):
        raise ConfigError("public service hostnames must be unique")

    node_networks = cidrs(values, "NODE_INTERNAL_CIDRS")
    pod_networks = cidrs(values, "POD_CIDRS")
    service_networks = cidrs(values, "SERVICE_CIDRS")
    all_networks = [("node", item) for item in node_networks]
    all_networks += [("pod", item) for item in pod_networks]
    all_networks += [("service", item) for item in service_networks]
    for index, (left_name, left) in enumerate(all_networks):
        for right_name, right in all_networks[index + 1 :]:
            if left.overlaps(right):
                raise ConfigError(
                    f"{left_name} CIDR {left} overlaps {right_name} CIDR {right}"
                )

    control_ip = ipv4(required(values, "CONTROL_PLANE_IP"), "CONTROL_PLANE_IP")
    if not any(control_ip in network for network in node_networks):
        raise ConfigError("CONTROL_PLANE_IP is outside NODE_INTERNAL_CIDRS")
    control_hostname = kube_name(
        required(values, "CONTROL_PLANE_HOSTNAME"), "CONTROL_PLANE_HOSTNAME"
    )
    workers = parse_workers(required(values, "WORKER_NODES"), node_networks)
    if control_hostname in {name for name, _ in workers}:
        raise ConfigError("control-plane and worker hostnames must be unique")
    if str(control_ip) in {address for _, address in workers}:
        raise ConfigError("control-plane and worker addresses must be unique")

    cluster_dns = ipv4(required(values, "CLUSTER_DNS_IP"), "CLUSTER_DNS_IP", private=True)
    if not any(cluster_dns in network for network in service_networks):
        raise ConfigError("CLUSTER_DNS_IP must be inside SERVICE_CIDRS")
    # 비워 두면 CoreDNS 는 노드의 /etc/resolv.conf 를 그대로 쓴다. 워커에 외부 egress 가
    # 없는 사이트에서는 노드가 못 가는 resolver 가 적혀 있어 외부 이름이 전부 SERVFAIL 이
    # 되므로, 워커에서 닿는 forwarder 를 여기에 적는다.
    upstream_dns_raw = optional(values, "CLUSTER_UPSTREAM_DNS")
    upstream_dns = ""
    if upstream_dns_raw:
        address_raw, separator, port_raw = upstream_dns_raw.rpartition(":")
        if not separator:
            raise ConfigError("CLUSTER_UPSTREAM_DNS must be IPv4:port")
        # egress 호스트의 내부 주소여야 한다. 워커에서 못 가는 주소를 적으면 고치려던
        # SERVFAIL 이 그대로 남는다. 내부망이 공인 대역인 사이트도 있으므로 RFC1918 여부가
        # 아니라 NODE_INTERNAL_CIDRS 소속으로 판정한다(SQUID_INTERNAL_IP 와 같은 규칙).
        upstream_ip = ipv4(address_raw, "CLUSTER_UPSTREAM_DNS")
        if not any(upstream_ip in network for network in node_networks):
            raise ConfigError("CLUSTER_UPSTREAM_DNS must be inside NODE_INTERNAL_CIDRS")
        port(port_raw, "CLUSTER_UPSTREAM_DNS")
        upstream_dns = upstream_dns_raw
    api_addresses = [
        ipv4(item, "KUBERNETES_API_ADDRESSES")
        for item in csv(values, "KUBERNETES_API_ADDRESSES", required_value=True)
    ]
    rke2_endpoint = ipv4(
        required(values, "RKE2_SERVER_ENDPOINT"), "RKE2_SERVER_ENDPOINT"
    )
    if not any(rke2_endpoint in network for network in node_networks):
        raise ConfigError("RKE2_SERVER_ENDPOINT must be inside NODE_INTERNAL_CIDRS")

    gateway_vip = ipv4(required(values, "GATEWAY_VIP"), "GATEWAY_VIP")
    pool_raw = required(values, "GATEWAY_ADDRESS_POOL")
    pool_start_raw, separator, pool_end_raw = pool_raw.partition("-")
    if not separator:
        raise ConfigError("GATEWAY_ADDRESS_POOL must be startIPv4-endIPv4")
    pool_start = ipv4(pool_start_raw.strip(), "GATEWAY_ADDRESS_POOL start")
    pool_end = ipv4(pool_end_raw.strip(), "GATEWAY_ADDRESS_POOL end")
    if int(pool_start) > int(pool_end) or not int(pool_start) <= int(gateway_vip) <= int(pool_end):
        raise ConfigError("GATEWAY_ADDRESS_POOL must contain GATEWAY_VIP")
    if not any(gateway_vip in network for network in node_networks):
        raise ConfigError("GATEWAY_VIP must be inside NODE_INTERNAL_CIDRS")
    node_addresses = {str(control_ip), *(address for _, address in workers)}
    if str(gateway_vip) in node_addresses:
        raise ConfigError("GATEWAY_VIP conflicts with a node address")
    if any(int(pool_start) <= int(ipaddress.ip_address(item)) <= int(pool_end) for item in node_addresses):
        raise ConfigError("GATEWAY_ADDRESS_POOL overlaps a node address")

    squid_ip = ipv4(required(values, "SQUID_INTERNAL_IP"), "SQUID_INTERNAL_IP")
    if not any(squid_ip in network for network in node_networks):
        raise ConfigError("SQUID_INTERNAL_IP must be inside NODE_INTERNAL_CIDRS")
    squid_port = port(required(values, "SQUID_PORT"), "SQUID_PORT")
    squid_clients = [cidr(item, "SQUID_CLIENT_CIDRS") for item in csv(values, "SQUID_CLIENT_CIDRS", required_value=True)]
    # Squid 는 요청 출발지가 이 목록에 들어올 때만 CONNECT 를 허용한다. 노드에서 실행한
    # curl 만 통과하고 Pod 원본 주소는 403 이 되는 구성을 입력 단계에서 막는다.
    for source_name, source_networks in (
        ("NODE_INTERNAL_CIDRS", node_networks),
        ("POD_CIDRS", pod_networks),
    ):
        for source_network in source_networks:
            if not any(source_network.subnet_of(client) for client in squid_clients):
                raise ConfigError(
                    f"SQUID_CLIENT_CIDRS must cover every {source_name} entry"
                )

    fixed_ports = {
        "KUBERNETES_API_PORT": 6443,
        "RKE2_SUPERVISOR_PORT": 9345,
        "ETCD_CLIENT_PORT": 2379,
        "ETCD_PEER_PORT": 2380,
        "KUBELET_PORT": 10250,
        "CANAL_VXLAN_UDP_PORT": 8472,
        "PUBLIC_HTTP_PORT": 80,
        "PUBLIC_HTTPS_PORT": 443,
    }
    parsed_fixed = {key: port(required(values, key), key) for key in fixed_ports}
    changed = [key for key, expected in fixed_ports.items() if parsed_fixed[key] != expected]
    if changed:
        raise ConfigError(
            "this repository fixes reviewed RKE2/public ports; unexpected values: "
            + ", ".join(changed)
        )
    internal_tcp = ports(values, "INTERNAL_ALLOWED_TCP_PORTS")
    expected_internal_tcp = {2379, 2380, 6443, 9345, 10250, squid_port}
    if internal_tcp != expected_internal_tcp:
        raise ConfigError(
            "INTERNAL_ALLOWED_TCP_PORTS must be exactly "
            + ",".join(str(item) for item in sorted(expected_internal_tcp))
        )
    if ports(values, "INTERNAL_ALLOWED_UDP_PORTS") != {8472}:
        raise ConfigError("INTERNAL_ALLOWED_UDP_PORTS must be exactly 8472")
    if ports(values, "EXTERNAL_ALLOWED_TCP_PORTS") != {80, 443}:
        raise ConfigError("EXTERNAL_ALLOWED_TCP_PORTS must be exactly 80,443")
    if ports(values, "EXTERNAL_ALLOWED_UDP_PORTS"):
        raise ConfigError("EXTERNAL_ALLOWED_UDP_PORTS must stay empty")

    internal_interface = interface(required(values, "INTERNAL_INTERFACE"), "INTERNAL_INTERFACE")
    external_interface = interface(required(values, "EXTERNAL_INTERFACE"), "EXTERNAL_INTERFACE")
    if internal_interface == external_interface:
        raise ConfigError("INTERNAL_INTERFACE and EXTERNAL_INTERFACE must differ")

    # 계약상 역할이 없더라도 공인 주소를 받을 수 있는 NIC은 관리 포트를 막아야 한다.
    # 계약에 없으면 guard 재설치 때 보호가 조용히 빠지므로 별도 목록으로 보존한다.
    guarded_interfaces: list[str] = []
    for item in (values.get("GUARDED_INTERFACES") or "").split(","):
        name = item.strip()
        if not name:
            continue
        guarded_interfaces.append(interface(name, "GUARDED_INTERFACES"))
    if len(guarded_interfaces) != len(set(guarded_interfaces)):
        raise ConfigError("GUARDED_INTERFACES must not repeat a name")
    if internal_interface in guarded_interfaces:
        raise ConfigError("GUARDED_INTERFACES must not contain INTERNAL_INTERFACE")
    if external_interface in guarded_interfaces:
        raise ConfigError("GUARDED_INTERFACES must not contain EXTERNAL_INTERFACE")

    forgejo_url = validate_git_url(required(values, "FORGEJO_REPO_URL"))
    forgejo_revision = required(values, "FORGEJO_REVISION")
    if not REVISION.fullmatch(forgejo_revision) or ".." in forgejo_revision:
        raise ConfigError("FORGEJO_REVISION contains unsafe characters")
    registry = required(values, "OCI_REGISTRY").lower()
    if not REGISTRY.fullmatch(registry) or "://" in registry:
        raise ConfigError("OCI_REGISTRY must be hostname[:port] without a URL scheme")
    registry_project = required(values, "OCI_PROJECT").strip("/").lower()
    if not REGISTRY_PATH.fullmatch(registry_project) or ".." in registry_project:
        raise ConfigError("OCI_PROJECT must be a lower-case OCI path")
    pull_secret = kube_name(required(values, "REGISTRY_PULL_SECRET"), "REGISTRY_PULL_SECRET")
    image_tags = {
        "test-app": required(values, "TEST_APP_IMAGE_TAG"),
        "portal-lite": required(values, "PORTAL_IMAGE_TAG"),
    }
    for name, tag in image_tags.items():
        if not IMAGE_TAG.fullmatch(tag) or tag.lower() in MUTABLE_IMAGE_TAGS:
            raise ConfigError(f"{name} image tag must be immutable and must not be latest/main")
    pull_policy = required(values, "IMAGE_PULL_POLICY")
    if pull_policy not in {"IfNotPresent", "Always"}:
        raise ConfigError("IMAGE_PULL_POLICY must be IfNotPresent or Always for Registry images")

    tls_source = required(values, "TLS_SOURCE")
    if tls_source not in {"acme", "provided"}:
        raise ConfigError("TLS_SOURCE must be acme or provided")
    issuer_mode = required(values, "TLS_ISSUER_MODE")
    if issuer_mode not in {"staging", "production"}:
        raise ConfigError("TLS_ISSUER_MODE must be staging or production")
    staging_verified = boolean(values, "ACME_STAGING_VERIFIED")
    existing_tls = boolean(values, "EXISTING_GATEWAY_TLS_READY")
    if tls_source == "acme" and issuer_mode == "production" and not staging_verified:
        raise ConfigError("TLS_ISSUER_MODE=production requires ACME_STAGING_VERIFIED=true")
    provider = optional(values, "DNS_PROVIDER")
    rfc2136 = {"nameserver": "", "tsigKeyName": "", "tsigAlgorithm": "HMACSHA256"}
    dns01_mode = optional(values, "DNS01_MODE") or "direct-rfc2136"
    delegation = {"type": "", "zone": ""}
    recursive_nameservers = csv(values, "DNS_RECURSIVE_NAMESERVERS", required_value=True)
    for item in recursive_nameservers:
        address_raw, separator, port_raw = item.rpartition(":")
        if not separator:
            raise ConfigError("DNS_RECURSIVE_NAMESERVERS entries must be IPv4:port")
        # self-check 는 공개 권위 응답을 그대로 봐야 한다. 내부 recursive 가 공개 답을
        # 못 돌려주는 사이트에서는 권위 서버(공인 IP)를 직접 지정한다.
        ipv4(address_raw, "DNS_RECURSIVE_NAMESERVERS")
        port(port_raw, "DNS_RECURSIVE_NAMESERVERS")
    cert_manager_placement = (
        optional(values, "CERT_MANAGER_NODE_PLACEMENT") or "any"
    )
    if cert_manager_placement not in SUPPORTED_CERT_MANAGER_PLACEMENTS:
        raise ConfigError(
            "CERT_MANAGER_NODE_PLACEMENT must be any or control-plane"
        )
    if tls_source == "acme":
        if provider not in SUPPORTED_DNS_PROVIDERS:
            raise ConfigError(
                "DNS_PROVIDER must be rfc2136; Let's Encrypt does not update DNS records"
            )
        email = required(values, "ACME_EMAIL")
        if not EMAIL.fullmatch(email):
            raise ConfigError("ACME_EMAIL is invalid")
        kube_name(required(values, "DNS_CREDENTIAL_SECRET_NAME"), "DNS_CREDENTIAL_SECRET_NAME")
        kube_name(required(values, "DNS_CREDENTIAL_SECRET_KEY"), "DNS_CREDENTIAL_SECRET_KEY")
        nameserver_raw = required(values, "RFC2136_NAMESERVER")
        nameserver_ip_raw, separator, nameserver_port_raw = nameserver_raw.rpartition(":")
        if not separator:
            raise ConfigError("RFC2136_NAMESERVER must be IPv4:port")
        nameserver_ip = ipv4(nameserver_ip_raw, "RFC2136_NAMESERVER")
        nameserver_port = port(nameserver_port_raw, "RFC2136_NAMESERVER")
        tsig_key_name = required(values, "RFC2136_TSIG_KEY_NAME")
        if len(tsig_key_name) > 254 or not TSIG_KEY_NAME.fullmatch(tsig_key_name):
            raise ConfigError("RFC2136_TSIG_KEY_NAME must be a DNS/TSIG key name")
        tsig_algorithm = required(values, "RFC2136_TSIG_ALGORITHM").upper()
        if tsig_algorithm not in SUPPORTED_TSIG_ALGORITHMS:
            raise ConfigError(
                "RFC2136_TSIG_ALGORITHM must be HMACMD5, HMACSHA1, "
                "HMACSHA256 or HMACSHA512"
            )
        rfc2136 = {
            "nameserver": f"{nameserver_ip}:{nameserver_port}",
            "tsigKeyName": tsig_key_name,
            "tsigAlgorithm": tsig_algorithm,
        }
        if dns01_mode not in SUPPORTED_DNS01_MODES:
            raise ConfigError("DNS01_MODE must be direct-rfc2136 or delegated-rfc2136")
        delegation_type = optional(values, "ACME_DELEGATION_TYPE").lower()
        delegated_zone = optional(values, "ACME_DELEGATED_ZONE").strip().rstrip(".").lower()
        if dns01_mode == "direct-rfc2136":
            # 남겨 둔 위임 값이 다음 전환 때 엉뚱한 zone 을 UPDATE 하게 만드는 것을 막는다.
            for key, value in (
                ("ACME_DELEGATION_TYPE", delegation_type),
                ("ACME_DELEGATED_ZONE", delegated_zone),
            ):
                if value:
                    raise ConfigError(
                        f"{key} is only valid when DNS01_MODE=delegated-rfc2136"
                    )
        else:
            if delegation_type not in SUPPORTED_DELEGATION_TYPES:
                raise ConfigError(
                    "ACME_DELEGATION_TYPE must be cname or ns when "
                    "DNS01_MODE=delegated-rfc2136"
                )
            if not delegated_zone:
                raise ConfigError(
                    "ACME_DELEGATED_ZONE is required when DNS01_MODE=delegated-rfc2136"
                )
            if not DNS_ZONE.fullmatch(delegated_zone) or len(delegated_zone) > 253:
                raise ConfigError("ACME_DELEGATED_ZONE must be a DNS zone name")
            if delegation_type == "ns":
                # NS 위임에서는 _acme-challenge 라벨 자체가 위임된 zone 의 apex 다.
                expected = f"_acme-challenge.{base_domain}"
                if delegated_zone != expected:
                    raise ConfigError(
                        f"ACME_DELEGATED_ZONE must be {expected} when "
                        "ACME_DELEGATION_TYPE=ns"
                    )
            elif delegated_zone == base_domain:
                raise ConfigError(
                    "ACME_DELEGATED_ZONE must differ from BASE_DOMAIN; the point of "
                    "delegation is that the BASE_DOMAIN zone is never updated"
                )
            delegation = {"type": delegation_type, "zone": delegated_zone}
    else:
        dns01_mode = ""
        if not existing_tls:
            raise ConfigError("TLS_SOURCE=provided requires EXISTING_GATEWAY_TLS_READY=true")
        email = optional(values, "ACME_EMAIL")

    public_ip = ipv4(required(values, "PUBLIC_IP"), "PUBLIC_IP")
    public_mode = required(values, "PUBLIC_EXPOSURE_MODE").lower()
    if public_mode not in {"nat", "direct"}:
        raise ConfigError("PUBLIC_EXPOSURE_MODE must be nat or direct")
    public_ip_node = optional(values, "PUBLIC_IP_NODE")
    if public_mode == "direct":
        public_ip_node = kube_name(
            required(values, "PUBLIC_IP_NODE"), "PUBLIC_IP_NODE"
        )
        known_nodes = {control_hostname, *(name for name, _ in workers)}
        if public_ip_node not in known_nodes:
            raise ConfigError("PUBLIC_IP_NODE must name CONTROL_PLANE_HOSTNAME or a WORKER_NODES host")
    elif public_ip_node:
        raise ConfigError("PUBLIC_IP_NODE is only valid when PUBLIC_EXPOSURE_MODE=direct")
    extra_packages = [dns_name(item, "EXTRA_PACKAGE_DOMAINS") for item in csv(values, "EXTRA_PACKAGE_DOMAINS")]
    storage_class = kube_name(required(values, "STORAGE_CLASS"), "STORAGE_CLASS")
    app_group_volume_amount, app_group_volume_unit = storage_quantity(
        required(values, "APP_GROUP_VOLUME_SIZE"), "APP_GROUP_VOLUME_SIZE"
    )
    app_group_max_services = positive_int(
        required(values, "APP_GROUP_MAX_SERVICES"), "APP_GROUP_MAX_SERVICES", 20
    )
    identity_provider = parse_identity_provider(values)
    install_gitops = boolean(values, "SADP_INSTALL_GITOPS", default=False)
    argo_username = optional(values, "SADP_ARGO_REPO_USERNAME")
    argo_token_file = optional(values, "SADP_ARGO_REPO_TOKEN_FILE")
    if install_gitops:
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", argo_username):
            raise ConfigError(
                "SADP_ARGO_REPO_USERNAME is required and must contain only letters, digits, ._-"
            )
        argo_token_file = safe_absolute_path(
            required(values, "SADP_ARGO_REPO_TOKEN_FILE"), "SADP_ARGO_REPO_TOKEN_FILE"
        )
    elif argo_token_file:
        argo_token_file = safe_absolute_path(
            argo_token_file, "SADP_ARGO_REPO_TOKEN_FILE"
        )

    dns_tsig_secret_file = optional(values, "SADP_DNS_TSIG_SECRET_FILE")
    if dns_tsig_secret_file:
        dns_tsig_secret_file = safe_absolute_path(
            dns_tsig_secret_file, "SADP_DNS_TSIG_SECRET_FILE"
        )
    install_monitoring = boolean(values, "SADP_INSTALL_MONITORING", default=True)
    build_images = boolean(values, "SADP_BUILD_IMAGES", default=True)
    build_node = optional(values, "SADP_BUILD_NODE")
    if build_node:
        build_node = kube_name(build_node, "SADP_BUILD_NODE")
        worker_names = {name for name, _ in workers}
        if build_node not in worker_names:
            raise ConfigError("SADP_BUILD_NODE must name one entry in WORKER_NODES")
    deploy_apps = boolean(values, "SADP_DEPLOY_APPS", default=False)
    pull_dockerconfig = optional(values, "SADP_REGISTRY_PULL_DOCKERCONFIG")
    push_dockerconfig = optional(values, "SADP_REGISTRY_PUSH_DOCKERCONFIG")
    if deploy_apps:
        pull_dockerconfig = safe_absolute_path(
            required(values, "SADP_REGISTRY_PULL_DOCKERCONFIG"),
            "SADP_REGISTRY_PULL_DOCKERCONFIG",
        )
        push_dockerconfig = safe_absolute_path(
            required(values, "SADP_REGISTRY_PUSH_DOCKERCONFIG"),
            "SADP_REGISTRY_PUSH_DOCKERCONFIG",
        )
        if pull_dockerconfig == push_dockerconfig:
            raise ConfigError("registry pull and push Docker config paths must differ")
    else:
        if pull_dockerconfig:
            pull_dockerconfig = safe_absolute_path(
                pull_dockerconfig, "SADP_REGISTRY_PULL_DOCKERCONFIG"
            )
        if push_dockerconfig:
            push_dockerconfig = safe_absolute_path(
                push_dockerconfig, "SADP_REGISTRY_PUSH_DOCKERCONFIG"
            )
    run_verify = boolean(values, "SADP_RUN_VERIFY", default=True)
    systems = parse_systems(values, environment, base_domain, {
        workload_namespace, platform_namespace, gateway_namespace,
    })
    machine_auth = parse_machine_auth(values, base_domain, identity_provider)
    if not install_monitoring and any(
        service["namespace"] == "monitoring"
        for service in machine_auth.get("services") or []
    ):
        raise ConfigError(
            "monitoring backend exposure requires SADP_INSTALL_MONITORING=true; "
            "enable it or remove the backend input and render again"
        )
    external_services = parse_external_services(
        values,
        base_domain,
        {
            workload_namespace,
            platform_namespace,
            gateway_namespace,
            *(item["workloadNamespace"] for item in systems),
        },
    )
    if systems and tls_source != "acme":
        # 형제 서브도메인 wildcard 는 공유 RFC2136 zone/TSIG 로 자동 발급해야 유지 가능하다.
        # provided 모드는 시스템마다 별도 PEM 을 수동 공급해야 하는데 그 경로는 아직 없다.
        raise ConfigError("SYSTEMS requires TLS_SOURCE=acme")

    return {
        "siteName": site_name,
        "environment": environment,
        "clusterName": cluster_name,
        "baseDomain": base_domain,
        "appProject": app_project,
        "layout": {
            "workloadNamespace": workload_namespace,
            "platformNamespace": platform_namespace,
            "gatewayNamespace": gateway_namespace,
            "gatewayName": gateway_name,
            "gatewayProxyConfigName": gateway_proxy,
            "gatewayAddressPoolName": gateway_pool_name,
            "workloadProject": workload_project,
            "platformProject": platform_project,
        },
        "systems": systems,
        "externalServices": external_services,
        "machineAuth": machine_auth,
        "hosts": hosts,
        "storageClass": storage_class,
        "appGroups": {
            "namespacePrefix": APP_GROUP_NAMESPACE_PREFIX,
            "maxServices": app_group_max_services,
            "storage": {
                "storageClass": storage_class,
                "volumeSize": f"{app_group_volume_amount}{app_group_volume_unit}",
                "maxClaims": app_group_max_services,
                "total": f"{app_group_volume_amount * app_group_max_services}{app_group_volume_unit}",
            },
        },
        "forgejo": {
            "repoURL": forgejo_url,
            "revision": forgejo_revision,
            "api": forgejo_api_coordinates(forgejo_url),
        },
        "registry": {
            "host": registry,
            "project": registry_project,
            "pullSecret": pull_secret,
            "tags": image_tags,
            "pullPolicy": pull_policy,
        },
        "nodes": {
            "controlHostname": control_hostname,
            "controlIP": str(control_ip),
            "workers": workers,
            "rke2Endpoint": str(rke2_endpoint),
        },
        "interfaces": {
            "internal": internal_interface,
            "external": external_interface,
            "guarded": guarded_interfaces,
        },
        "network": {
            "nodeCIDRs": [str(item) for item in node_networks],
            "podCIDRs": [str(item) for item in pod_networks],
            "serviceCIDRs": [str(item) for item in service_networks],
            "clusterDNS": str(cluster_dns),
            "clusterUpstreamDNS": upstream_dns,
            "apiAddresses": [str(item) for item in api_addresses],
            "gatewayVIP": str(gateway_vip),
            "gatewayPool": f"{pool_start}-{pool_end}",
            "publicIP": str(public_ip),
            "publicMode": public_mode,
            "publicIPNode": public_ip_node,
            "envoyTargetPort": port(
                required(values, "ENVOY_HTTPS_TARGET_PORT"), "ENVOY_HTTPS_TARGET_PORT"
            ),
            "squidIP": str(squid_ip),
            "squidPort": squid_port,
            "squidClients": [str(item) for item in squid_clients],
            "extraPackages": extra_packages,
            "ports": {
                "internalTCP": sorted(internal_tcp),
                "internalUDP": [8472],
                "externalTCP": [80, 443],
                "externalUDP": [],
            },
        },
        "tls": {
            "source": tls_source,
            "issuerMode": issuer_mode,
            "stagingVerified": staging_verified,
            "existingReady": existing_tls,
            "email": email,
            "provider": provider,
            "providerEndpoints": [],
            "rfc2136": rfc2136,
            "dns01Mode": dns01_mode,
            "delegation": delegation,
            "credentialSecretName": optional(values, "DNS_CREDENTIAL_SECRET_NAME"),
            "credentialSecretKey": optional(values, "DNS_CREDENTIAL_SECRET_KEY"),
            "wildcardSecret": wildcard_secret,
            "clusterIssuerName": acme_issuer,
            "accountKeySecretName": acme_account_secret,
            "recursiveNameservers": recursive_nameservers,
            "certManagerPlacement": cert_manager_placement,
            "providedCertificatePath": required(values, "PROVIDED_CERTIFICATE_PATH"),
            "providedPrivateKeyPath": required(values, "PROVIDED_PRIVATE_KEY_PATH"),
        },
        "identityProvider": identity_provider,
        "installer": {
            "gitops": install_gitops,
            "argoRepoUsername": argo_username,
            "argoRepoTokenFile": argo_token_file,
            "dnsTsigSecretFile": dns_tsig_secret_file,
            "installMonitoring": install_monitoring,
            "buildImages": build_images,
            "buildNode": build_node,
            "deployApps": deploy_apps,
            "registryPullDockerconfig": pull_dockerconfig,
            "registryPushDockerconfig": push_dockerconfig,
            "runVerify": run_verify,
        },
    }


def internal_egress_cidrs(cfg: dict) -> list[str]:
    """egressMode=web 의 ipBlock.except 목록. 상위 대역에 이미 포함된 항목은 뺀다."""
    candidates = {
        ipaddress.ip_network(item)
        for item in (
            *RESERVED_EGRESS_CIDRS,
            *cfg["network"]["podCIDRs"],
            *cfg["network"]["serviceCIDRs"],
            *cfg["network"]["nodeCIDRs"],
        )
    }
    kept: list[ipaddress.IPv4Network] = []
    for network in sorted(candidates, key=lambda item: (item.network_address, item.prefixlen)):
        if any(network.subnet_of(existing) for existing in kept):
            continue
        kept.append(network)
    return [str(item) for item in kept]


def build_contract(base: dict, cfg: dict) -> dict:
    document = copy.deepcopy(base)
    document.setdefault("metadata", {})["name"] = cfg["siteName"]
    spec = document["spec"]
    status = document.setdefault("status", {})
    max_group_services = int(cfg["appGroups"]["maxServices"])
    max_group_pods = int((spec.get("policy", {}).get("userQuota") or {}).get("maxReplicas") or 0)
    if max_group_pods < 1 or max_group_services > max_group_pods:
        raise ConfigError(
            "APP_GROUP_MAX_SERVICES must not exceed spec.policy.userQuota.maxReplicas"
        )
    spec["environment"] = cfg["environment"]
    spec["baseDomain"] = cfg["baseDomain"]
    spec["cluster"]["name"] = cfg["clusterName"]
    spec["cluster"]["storageClass"] = cfg["storageClass"]
    spec["monitoring"] = {"enabled": cfg["installer"]["installMonitoring"]}

    gateway = spec["gateway"]
    old_workload_namespace = str(gateway["allowedRouteNamespaces"][0])
    old_platform_namespace = str(gateway["redirectRouteNamespace"])
    gateway["namespace"] = cfg["layout"]["gatewayNamespace"]
    gateway["name"] = cfg["layout"]["gatewayName"]
    gateway["proxyConfigName"] = cfg["layout"]["gatewayProxyConfigName"]
    gateway["addressPoolName"] = cfg["layout"]["gatewayAddressPoolName"]
    # 시스템별 Namespace 도 Gateway 가 Route 를 받아들일 대상에 포함한다.
    gateway["allowedRouteNamespaces"] = [
        cfg["layout"]["workloadNamespace"],
        *(item["workloadNamespace"] for item in cfg["systems"]),
        cfg["layout"]["platformNamespace"],
    ]
    gateway["redirectRouteNamespace"] = cfg["layout"]["platformNamespace"]
    gateway["wildcardTlsSecret"] = cfg["tls"]["wildcardSecret"]
    gateway["vip"] = cfg["network"]["gatewayVIP"]
    gateway["addressPoolRange"] = cfg["network"]["gatewayPool"]
    gateway["routeListener"] = (
        gateway["httpsListener"] if cfg["tls"]["existingReady"] else gateway["httpListener"]
    )

    tls = spec["tls"]
    tls["source"] = cfg["tls"]["source"]
    tls["issuerMode"] = cfg["tls"]["issuerMode"]
    tls["clusterIssuerName"] = cfg["tls"]["clusterIssuerName"]
    tls["acme"]["accountKeySecretName"] = cfg["tls"]["accountKeySecretName"]
    tls["recursiveNameservers"] = cfg["tls"]["recursiveNameservers"]
    tls["certManagerPlacement"] = cfg["tls"]["certManagerPlacement"]
    tls["provided"] = {
        "certificatePath": cfg["tls"]["providedCertificatePath"],
        "privateKeyPath": cfg["tls"]["providedPrivateKeyPath"],
    }
    tls["acme"]["email"] = cfg["tls"]["email"]
    tls["solver"]["provider"] = (
        cfg["tls"]["provider"] if cfg["tls"]["source"] == "acme" else "pending"
    )
    tls["solver"]["credentialSecretName"] = cfg["tls"]["credentialSecretName"]
    tls["solver"]["credentialSecretKey"] = cfg["tls"]["credentialSecretKey"]
    tls["solver"]["rfc2136"] = copy.deepcopy(cfg["tls"]["rfc2136"])
    tls["solver"]["dns01Mode"] = cfg["tls"]["dns01Mode"] or "pending"
    if cfg["tls"]["delegation"]["type"]:
        tls["solver"]["delegation"] = copy.deepcopy(cfg["tls"]["delegation"])
    else:
        # direct 모드로 되돌아왔을 때 이전 위임 zone 이 계약에 남으면, 렌더러가
        # 엉뚱한 zone 을 UPDATE 대상으로 삼는다. 반드시 지운다.
        tls["solver"].pop("delegation", None)
    tls["solver"].pop("route53", None)
    preserve = (
        cfg["tls"]["source"] == "acme"
        and cfg["tls"]["issuerMode"] == "staging"
        and cfg["tls"]["existingReady"]
    )
    if preserve:
        tls["stagingPreserveExistingGatewaySecret"] = True
    else:
        tls.pop("stagingPreserveExistingGatewaySecret", None)

    network = spec["network"]
    network["podCIDRs"] = cfg["network"]["podCIDRs"]
    network["serviceCIDRs"] = cfg["network"]["serviceCIDRs"]
    network["nodeInternalCIDRs"] = cfg["network"]["nodeCIDRs"]
    network["internalCIDRs"] = internal_egress_cidrs(cfg)
    network["clusterDNS"] = cfg["network"]["clusterDNS"]
    network["clusterUpstreamDNS"] = cfg["network"]["clusterUpstreamDNS"]
    network["kubernetesAPIAddresses"] = cfg["network"]["apiAddresses"]
    network["nodeAddresses"] = [
        cfg["nodes"]["controlIP"],
        *(address for _, address in cfg["nodes"]["workers"]),
    ]
    network["interfaces"] = cfg["interfaces"]
    network["allowedPorts"] = cfg["network"]["ports"]
    network["defaultDenyNamespaces"] = [cfg["layout"]["workloadNamespace"]]
    squid = network["squid"]
    squid["internalIP"] = cfg["network"]["squidIP"]
    squid["port"] = cfg["network"]["squidPort"]
    squid["clientCIDRs"] = cfg["network"]["squidClients"]
    squid["packageDomains"] = list(
        dict.fromkeys([*DEFAULT_PACKAGE_DOMAINS, *cfg["network"]["extraPackages"]])
    )
    # IdP host도 site.env에서 매번 다시 파생한다. 이전 기관의 로그인 도메인이 새
    # 사이트 allowlist에 남으면 불필요한 egress와 내부 정보 노출이 동시에 생긴다.
    squid["identityProviderDomains"] = list(
        dict.fromkeys(
            urlsplit(url).hostname or ""
            for url in (
                cfg["identityProvider"]["issuer"],
                cfg["identityProvider"]["authorizationEndpoint"],
                cfg["identityProvider"]["tokenEndpoint"],
                cfg["identityProvider"]["jwksURI"],
                cfg["identityProvider"].get("endSessionEndpoint", ""),
            )
            if url
        )
    )
    squid["dnsProviderEndpoints"] = (
        cfg["tls"]["providerEndpoints"] if cfg["tls"]["source"] == "acme" else []
    )
    # 현재 사용자 앱은 사이트당 단일 workload Namespace를 공유한다. Gateway/Rancher만
    # 새 Namespace로 바꾸고 quota 대상이 이전 사이트 값에 남으면 render-quota가 실패하고,
    # 더 나쁘게는 오래된 Namespace에만 제한이 걸릴 수 있으므로 같은 계약 변경에 묶는다.
    spec["policy"]["userQuota"]["namespaces"] = [cfg["layout"]["workloadNamespace"]]

    spec["public"]["mode"] = cfg["network"]["publicMode"]
    spec["public"]["ip"] = cfg["network"]["publicIP"]
    if cfg["network"]["publicMode"] == "direct":
        spec["public"]["nodeName"] = cfg["network"]["publicIPNode"]
    else:
        spec["public"].pop("nodeName", None)
    spec["public"]["ports"] = [80, 443]
    spec["public"].pop("natPorts", None)
    spec["public"]["hairpinNat"] = (
        "required" if cfg["network"]["publicMode"] == "nat" else "not-required"
    )
    spec["public"]["records"] = [
        {"name": f"*.{cfg['baseDomain']}", "type": "A"},
        {"name": cfg["baseDomain"], "type": "A"},
        *(
            record
            for item in cfg["systems"]
            for record in (
                {"name": f"*.{item['domain']}", "type": "A"},
                {"name": item["domain"], "type": "A"},
            )
        ),
    ]
    for service in spec.get("platformServices") or []:
        if service.get("name") in cfg["hosts"]:
            service["host"] = cfg["hosts"][service["name"]]
    # 다른 VM 에 있는 서비스(Forgejo, Grafana 등)는 계약이 매번 새로 만든다. 이전 실행에서
    # 남은 항목을 지우고 다시 넣어야 EXTERNAL_SERVICES 에서 뺀 서비스가 사라진다.
    spec["platformServices"] = [
        service
        for service in spec.get("platformServices") or []
        if (service or {}).get("name") != "sso"
        and not (service or {}).get("external")
        and not (service or {}).get("machineAuth")
    ]
    spec["machineAuth"] = copy.deepcopy(cfg["machineAuth"])
    spec["machineAuth"].pop("services", None)
    for entry in cfg["machineAuth"]["services"]:
        spec["platformServices"].append(copy.deepcopy(entry))
    for entry in cfg["externalServices"]:
        spec["platformServices"].append(
            {
                "name": entry["name"],
                "host": entry["host"],
                "namespace": entry["namespace"],
                "service": entry["name"],
                "port": entry["port"],
                "external": {"address": entry["address"], "port": entry["port"]},
            }
        )

    rancher = spec.get("rancher") or {}
    project_replacements: dict[str, str] = {}
    for project in rancher.get("projects") or []:
        namespaces = [str(item) for item in project.get("namespaces") or []]
        if old_workload_namespace in namespaces:
            project_replacements[str(project.get("name") or "")] = cfg["layout"][
                "workloadProject"
            ]
            project["name"] = cfg["layout"]["workloadProject"]
            project["displayName"] = cfg["layout"]["workloadNamespace"]
            project["namespaces"] = [cfg["layout"]["workloadNamespace"]]
        elif old_platform_namespace in namespaces:
            project_replacements[str(project.get("name") or "")] = cfg["layout"][
                "platformProject"
            ]
            project["name"] = cfg["layout"]["platformProject"]
            project["displayName"] = cfg["layout"]["platformNamespace"]
            project["namespaces"] = [cfg["layout"]["platformNamespace"]]
    for binding in rancher.get("roleBindings") or []:
        binding["projects"] = [
            project_replacements.get(str(name), str(name))
            for name in binding.get("projects") or []
        ]
    # 시스템마다 자체 Project 로 격리한다. 워크로드 Project 와 같은 성격이라 role binding은
    # 시스템 앱에 붙는 그룹이 정해지면 별도로 추가한다(D7 이전에는 계약이 비워둔다).
    existing_project_names = {str(p.get("name") or "") for p in rancher.get("projects") or []}
    for item in cfg["systems"]:
        if item["project"] not in existing_project_names:
            rancher.setdefault("projects", []).append(
                {
                    "name": item["project"],
                    "displayName": item["workloadNamespace"],
                    "description": f"{item['name']} 시스템 전용 워크로드",
                    "namespaces": [item["workloadNamespace"]],
                }
            )
    spec["systems"] = [
        {
            "name": item["name"],
            "domain": item["domain"],
            "workloadNamespace": item["workloadNamespace"],
            "project": item["project"],
            "wildcardTlsSecret": item["wildcardTlsSecret"],
            "httpListener": item["httpListener"],
            "httpsListener": item["httpsListener"],
        }
        for item in cfg["systems"]
    ]
    spec.pop("keycloak", None)
    spec["identityProvider"] = copy.deepcopy(cfg["identityProvider"])
    # AppGroup의 ClusterSecretStore는 namespaced SecretStore와 달리 CA ConfigMap의
    # Namespace를 명시해야 한다. 이 값도 계약을 거쳐 Chart로 보내 하드코딩을 피한다.
    spec["openbao"]["namespace"] = PORTAL_PLATFORM_NAMESPACES["PORTAL_OPENBAO_NAMESPACE"]
    # 포털은 이 고정 role을 읽고 사용할 뿐 policy/auth role을 동적으로 만들지 않는다.
    # 이름을 사이트 입력으로 열면 Chart/bootstrap/Portal 사이 계약이 다시 갈라진다.
    spec["openbao"]["roles"] = copy.deepcopy(OPENBAO_ESO_ROLES)
    spec["registry"] = {
        "url": cfg["registry"]["host"],
        "project": cfg["registry"]["project"],
        "pullSecretName": cfg["registry"]["pullSecret"],
        # 경로는 비밀값이 아니라 공통 registry credential의 OpenBao 좌표다. 그룹 values나
        # 사용자 입력으로 바꾸지 않고 사이트 계약이 하나의 exact 경로만 허용한다.
        "pullSecretRemotePath": f"platform/registry/{cfg['registry']['pullSecret']}",
    }
    spec["appGroups"] = copy.deepcopy(cfg["appGroups"])
    spec["delivery"] = {
        "provider": "forgejo",
        "repoURL": cfg["forgejo"]["repoURL"],
        "revision": cfg["forgejo"]["revision"],
    }
    spec["policy"]["allowedHosts"] = f"*.{cfg['baseDomain']}"
    status["wildcardTls"] = "ready" if cfg["tls"]["existingReady"] else "pending"
    status.pop("natAndPublicDns", None)
    status["publicExposureAndDns"] = "pending"
    return document


def yaml_text(document: object, header: str = "") -> str:
    return header + yaml.safe_dump(document, allow_unicode=True, sort_keys=False)


def portal_forgejo_reach(cfg: dict) -> tuple[str, int, str]:
    """Forgejo API 주소에 어떤 경로로 나가는지 판정한다.

    반환값은 (kind, port, host)이며 kind는 다음 셋 중 하나다.
      - "direct":  URL host가 IP 리터럴 → 그 주소로 직접 egress
      - "gateway": host가 baseDomain 하위 → split DNS로 Gateway VIP:443에 모임
      - "proxy":   그 외 외부 인터넷 → Squid를 통해서만 나갈 수 있음
    """
    api = cfg["forgejo"].get("api")
    if not api:
        return ("none", 0, "")
    host_port = api["baseURL"].removeprefix("https://")
    host, separator, port_text = host_port.rpartition(":")
    if separator and port_text.isdigit():
        service_port = int(port_text)
    else:
        host, service_port = host_port, 443
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        return ("direct", service_port, host)
    if host == cfg["baseDomain"] or host.endswith(f".{cfg['baseDomain']}"):
        return ("gateway", 443, host)
    return ("proxy", service_port, host)


def portal_forgejo_egress(cfg: dict) -> list[dict]:
    """Forgejo PR 생성에 필요한 egress 규칙. 없으면 빈 목록."""
    kind, service_port, host = portal_forgejo_reach(cfg)
    if kind == "direct":
        return [{"cidr": f"{host}/32", "protocol": "TCP", "port": service_port}]
    if kind == "proxy":
        # 폐쇄망에서 외부 Forgejo로 가는 유일한 통로는 Squid다.
        return [
            {
                "cidr": f"{cfg['network']['squidIP']}/32",
                "protocol": "TCP",
                "port": cfg["network"]["squidPort"],
            }
        ]
    return []


def portal_forgejo_config(config: dict, cfg: dict) -> None:
    """Go API가 읽는 FORGEJO_* 설정을 채운다. 토큰은 ExternalSecret으로만 들어간다."""
    keys = (
        "FORGEJO_BASE_URL",
        "FORGEJO_OWNER",
        "FORGEJO_REPO",
        "FORGEJO_TARGET_BRANCH",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "NO_PROXY",
    )
    api = cfg["forgejo"].get("api")
    if not api:
        # https 원격이 아니면 API 좌표를 만들 수 없다. 값을 비워 두면 Go API가
        # cutover 전까지 503 forgejo_not_configured로 응답한다.
        for key in keys:
            config.pop(key, None)
        return
    config["FORGEJO_BASE_URL"] = api["baseURL"]
    config["FORGEJO_OWNER"] = api["owner"]
    config["FORGEJO_REPO"] = api["repo"]
    config["FORGEJO_TARGET_BRANCH"] = cfg["forgejo"]["revision"]

    kind, _, _ = portal_forgejo_reach(cfg)
    if kind != "proxy":
        for key in ("HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"):
            config.pop(key, None)
        return
    proxy = f"http://{cfg['network']['squidIP']}:{cfg['network']['squidPort']}"
    config["HTTP_PROXY"] = proxy
    config["HTTPS_PROXY"] = proxy
    # 클러스터 내부와 사이트 대역은 프록시를 타면 안 된다.
    config["NO_PROXY"] = ",".join(
        dict.fromkeys(
            [
                "localhost",
                "127.0.0.1",
                ".svc",
                ".cluster.local",
                f".{cfg['baseDomain']}",
                *cfg["network"]["serviceCIDRs"],
                *cfg["network"]["podCIDRs"],
                *cfg["network"]["nodeCIDRs"],
                cfg["network"]["gatewayVIP"],
                *cfg["network"]["apiAddresses"],
            ]
        )
    )


def app_values(
    path: pathlib.Path,
    cfg: dict,
    app_name: str,
    host: str,
    image_name: str,
    route_listener: str,
) -> str:
    document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    app = document.setdefault("app", {})
    app["project"] = cfg["appProject"]
    app["environment"] = cfg["environment"]
    image = document.setdefault("image", {})
    image["repository"] = (
        f"{cfg['registry']['host']}/{cfg['registry']['project']}/{image_name}"
    )
    image["tag"] = cfg["registry"]["tags"][image_name]
    image["digest"] = ""
    image["pullPolicy"] = cfg["registry"]["pullPolicy"]
    document["imagePullSecrets"] = [cfg["registry"]["pullSecret"]]
    exposure = document.setdefault("exposure", {})
    exposure["host"] = host
    if app_name == "portal-lite" and host == cfg["baseDomain"]:
        # Gateway wildcard listener는 baseDomain 자체를 받지 못한다. Portal에만 열어 둔
        # 정확한 hostname listener를 선택하고, 서브도메인으로 돌아가면 override를 지운다.
        exposure["sectionName"] = f"apex-{route_listener}"
    else:
        exposure.pop("sectionName", None)
    configuration = document.setdefault("configuration", {})
    configuration.setdefault("config", {})["APP_ENV"] = cfg["environment"]
    # 이 두 정적 앱은 기존 설치가 이미 쓰는 앱별 OpenBao 경로/role을 유지한다.
    # 신규 Portal 앱과 AppGroup만 아래의 fixed templated role + workload identity 경로를 쓴다.
    legacy_static_eso = app_name in {"portal-lite", "secure-demo"}
    if legacy_static_eso:
        expected_path = f"apps/{app.get('project')}/{cfg['environment']}/{app_name}"
    else:
        expected_path = (
            f"apps/{app.get('project')}/{cfg['environment']}/workloads/"
            f"{cfg['layout']['workloadNamespace']}/eso-{app_name}"
        )
    for external_secret in configuration.get("externalSecrets") or []:
        external_secret["remotePath"] = expected_path
    if configuration.get("externalSecrets"):
        document.setdefault("eso", {})["role"] = (
            f"eso-{app.get('project')}-{cfg['environment']}-{app_name}"
            if legacy_static_eso
            else OPENBAO_ESO_ROLES["zoneApp"]
        )

    policy = document.setdefault("networkPolicy", {})

    if app_name == "portal-lite":
        config = configuration["config"]
        config["PLATFORM_BASE_DOMAIN"] = cfg["baseDomain"]
        config.pop("AUTH_KEYCLOAK_ID", None)
        config.pop("AUTH_KEYCLOAK_ISSUER", None)
        config["AUTH_OIDC_ID"] = cfg["identityProvider"]["portalClientID"]
        config["AUTH_OIDC_ISSUER"] = cfg["identityProvider"]["issuer"]
        config["AUTH_OIDC_TOKEN_ENDPOINT"] = cfg["identityProvider"]["tokenEndpoint"]
        config["AUTH_OIDC_END_SESSION_ENDPOINT"] = cfg["identityProvider"]["endSessionEndpoint"]
        config["AUTH_OIDC_GROUPS_CLAIM"] = cfg["identityProvider"]["groupsClaim"]
        config["AUTH_URL"] = f"https://{cfg['hosts']['portal']}"

        # 신청 이력 PVC. Go API의 PORTAL_STATE_DIR과 마운트 경로는 항상 같아야 한다.
        persistence = document.setdefault("persistence", {})
        persistence["enabled"] = True
        persistence["storageClass"] = cfg["storageClass"]
        mount_path = str(persistence.setdefault("mountPath", "/data"))
        config["PORTAL_STATE_DIR"] = mount_path
        config["PORTAL_OCI_REGISTRY_BASE"] = (
            f"{cfg['registry']['host']}/{cfg['registry']['project']}"
        )

        # 카탈로그 상태 프로브가 읽는 Namespace = RBAC RoleBinding 대상. 둘이 어긋나면
        # 프로브가 403을 받고 카탈로그가 통째로 degraded로 표시된다.
        workload_namespace = cfg["layout"]["workloadNamespace"]
        config["PORTAL_WORKLOAD_NAMESPACE"] = workload_namespace
        config["PORTAL_ZONE_ID"] = workload_namespace
        config["PORTAL_ZONE_LABEL"] = f"{cfg['siteName']} Zone"
        # 전역 자동 승인은 승인 증거 없이 재시작 뒤 진행될 수 있으므로 생성물에서도 제거한다.
        # 예외는 Portal 관리자 화면에서 사용자별 durable 정책으로만 관리한다.
        config.pop("PORTAL_AUTO_APPROVE", None)
        config["PORTAL_BUILD_NAMESPACE"] = workload_namespace
        config["PORTAL_APP_IMAGE_PULL_NAME"] = cfg["registry"]["pullSecret"]
        config["PORTAL_REGISTRY_PULL_REMOTE_PATH"] = (
            f"platform/registry/{cfg['registry']['pullSecret']}"
        )
        config["PORTAL_APP_GROUP_NAMESPACE_PREFIX"] = APP_GROUP_NAMESPACE_PREFIX
        config["PORTAL_APP_GROUP_MAX_SERVICES"] = str(cfg["appGroups"]["maxServices"])
        config["PORTAL_APP_GROUP_VOLUME_SIZE"] = cfg["appGroups"]["storage"]["volumeSize"]
        config["PORTAL_APP_GROUP_VOLUME_STORAGE_CLASS"] = cfg["appGroups"]["storage"]["storageClass"]
        config["PORTAL_APP_GROUP_ARGO_PROJECT"] = "app-groups"
        config["PORTAL_ARGO_NAMESPACE"] = "devtroncd"
        # Rancher workloadProject와 Argo CD AppProject는 별도 객체다.
        config["PORTAL_ARGO_PROJECT"] = "platform-prod"
        config["PORTAL_ARGO_BOOTSTRAP_APPLICATION"] = "platform-bootstrap"
        config.update(PORTAL_PLATFORM_NAMESPACES)
        config["PORTAL_OPENBAO_ADDR"] = "https://openbao.openbao.svc.cluster.local:8200"
        config["PORTAL_OPENBAO_CACERT"] = "/var/run/openbao/ca.crt"
        config["PORTAL_OPENBAO_JWT_PATH"] = "/var/run/openbao/token"
        config["PORTAL_OPENBAO_WRITER_ROLE"] = "portal-app-secret-writer"
        config["PORTAL_OPENBAO_ZONE_APP_ROLE"] = OPENBAO_ESO_ROLES["zoneApp"]
        config["PORTAL_OPENBAO_GROUP_APP_ROLE"] = OPENBAO_ESO_ROLES["groupApp"]
        config["PORTAL_OPENBAO_GROUP_REGISTRY_ROLE"] = OPENBAO_ESO_ROLES[
            "groupRegistry"
        ]
        rbac = document.setdefault("rbac", {})
        rbac["enabled"] = True
        rbac["namespaces"] = list(
            dict.fromkeys([workload_namespace, *PORTAL_PLATFORM_NAMESPACES.values()])
        )
        document["openbaoWriter"] = {
            "enabled": True,
            "audience": "vault",
            "tokenExpirationSeconds": 3600,
            "mountPath": "/var/run/openbao",
            "caConfigMap": "openbao-ca",
        }
        pipeline = document.setdefault("portalPipeline", {})
        pipeline["enabled"] = True
        pipeline["argoNamespace"] = config["PORTAL_ARGO_NAMESPACE"]
        pipeline.pop("namespace", None)

        allowed_pods = policy.get("allowedPods") or []
        openbao_peer = {
            "namespace": "openbao",
            "podLabels": {"app.kubernetes.io/name": "openbao", "component": "server"},
            "protocol": "TCP",
            "port": 8200,
        }
        if not any(peer.get("namespace") == "openbao" for peer in allowed_pods):
            allowed_pods.insert(0, openbao_peer)
        policy["allowedPods"] = allowed_pods
        for peer in allowed_pods:
            labels = peer.get("podLabels") or {}
            if "gateway.envoyproxy.io/owning-gateway-name" in labels:
                labels["gateway.envoyproxy.io/owning-gateway-name"] = cfg["layout"][
                    "gatewayName"
                ]
                peer["port"] = cfg["network"]["envoyTargetPort"]
        # egress 허용 목록. split DNS 때문에 공개 host는 전부 Gateway VIP:443으로 모인다.
        allowed_cidrs = [
            {"cidr": f"{cfg['network']['gatewayVIP']}/32", "protocol": "TCP", "port": 443}
        ]
        # 카탈로그 상태 프로브가 쓰는 kube-apiserver. Service ClusterIP는 kube-proxy가 DNAT한
        # 뒤 Canal이 정책을 평가하므로 노드 주소:6443도 함께 열어야 한다.
        service_networks = [
            ipaddress.ip_network(item) for item in cfg["network"]["serviceCIDRs"]
        ]
        for address in cfg["network"]["apiAddresses"]:
            in_service_cidr = any(
                ipaddress.ip_address(address) in network for network in service_networks
            )
            allowed_cidrs.append(
                {
                    "cidr": f"{address}/32",
                    "protocol": "TCP",
                    "port": 443 if in_service_cidr else 6443,
                }
            )
        for entry in portal_forgejo_egress(cfg):
            if entry not in allowed_cidrs:
                allowed_cidrs.append(entry)
        policy["allowedCIDRs"] = allowed_cidrs

        portal_forgejo_config(config, cfg)
        auth_secret = next(
            (item for item in configuration.get("externalSecrets") or [] if item.get("name") == "auth"),
            None,
        )
        if auth_secret:
            keys = [
                item
                for item in auth_secret.get("keys") or []
                if item not in {"FORGEJO_BOT_TOKEN", "AUTH_KEYCLOAK_SECRET", "AUTH_OIDC_SECRET"}
            ]
            keys.append("AUTH_OIDC_SECRET")
            if cfg["forgejo"].get("api"):
                # 봇 토큰은 OpenBao에만 있고 values/Git에는 키 이름만 남는다.
                keys.append("FORGEJO_BOT_TOKEN")
            auth_secret["keys"] = list(dict.fromkeys(keys))
    return yaml_text(document, "# Generated by scripts/site/configure-site.py. Review and commit.\n")


def template_values(path: pathlib.Path, cfg: dict, app_name: str, exposure: str) -> str:
    document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    document["app"]["project"] = cfg["appProject"]
    document["app"]["environment"] = cfg["environment"]
    document["image"]["repository"] = (
        f"{cfg['registry']['host']}/{cfg['registry']['project']}/{app_name}"
    )
    document["image"]["tag"] = "0" * 40
    document["image"]["digest"] = ""
    document["image"]["pullPolicy"] = cfg["registry"]["pullPolicy"]
    # 템플릿 image는 플랫폼 Registry를 전제로 한다. 사용자가 Docker credential을 values에
    # 넣지 않고 Namespace의 ESO 동기화 pull Secret만 쓰도록 명시한다.
    document["image"]["usePullSecret"] = True
    document["imagePullSecrets"] = [cfg["registry"]["pullSecret"]]
    # 내부 전용 앱은 외부 도메인을 갖지 않는다. host 를 채우면 Chart 가 렌더를 거부한다.
    if document["exposure"].get("mode") == "internal":
        document["exposure"]["host"] = ""
    else:
        document["exposure"]["host"] = f"{app_name}.{cfg['baseDomain']}"
    document["configuration"]["config"]["APP_ENV"] = cfg["environment"]
    expected_path = (
        f"apps/{document['app']['project']}/{cfg['environment']}/workloads/"
        f"{cfg['layout']['workloadNamespace']}/eso-{app_name}"
    )
    authentication = document.setdefault("authentication", {})
    configuration = document.setdefault("configuration", {})
    eso = document.setdefault("eso", {})
    if exposure == "oidc":
        authentication["mode"] = "oidc"
        configuration["externalSecrets"] = [
            {
                "name": "oidc-client",
                "secretStore": f"openbao-{app_name}",
                "remotePath": expected_path,
                "inject": False,
                "keys": ["OIDC_CLIENT_SECRET"],
                "targetKeyMap": {"OIDC_CLIENT_SECRET": "client-secret"},
            }
        ]
        eso["createSecretStore"] = True
        eso["role"] = OPENBAO_ESO_ROLES["zoneApp"]
        oidc = document.setdefault("oidc", {})
        oidc["clientSecretName"] = ""
        oidc["callbackPath"] = "/oauth2/callback"
        oidc.setdefault("logoutPath", "/logout")
        oidc["allowedGroups"] = oidc.get("allowedGroups") or [f"{app_name}-user"]
    else:
        # 인증과 runtime Secret이 모두 없는 기본 템플릿은 외부 IdP/OpenBao를 전혀 요구하지
        # 않는다. runtime Secret이 실제로 필요한 앱만 이 목록과 canonical path를 추가한다.
        authentication["mode"] = "none"
        configuration["externalSecrets"] = []
        eso["createSecretStore"] = False
        eso.pop("role", None)
        document.pop("oidc", None)
    return yaml_text(
        document,
        f"# Generated {exposure} app example; copy to a new values file before editing.\n",
    )


def replace_strings(value: object, replacements: dict[str, str]) -> object:
    if isinstance(value, dict):
        return {key: replace_strings(item, replacements) for key, item in value.items()}
    if isinstance(value, list):
        return [replace_strings(item, replacements) for item in value]
    if isinstance(value, str):
        result = value
        for old, new in replacements.items():
            result = result.replace(old, new)
        return result
    return value


def argocd_updates(cfg: dict, old_contract: dict) -> dict[pathlib.Path, str]:
    bootstrap = yaml.safe_load((ROOT / "argocd/bootstrap-application.yaml").read_text(encoding="utf-8"))
    old_repo = bootstrap["spec"]["source"]["repoURL"]
    old_spec = old_contract["spec"]
    old_gateway = old_spec["gateway"]
    old_workload_namespace = str(old_gateway["allowedRouteNamespaces"][0])
    old_platform_namespace = str(old_gateway["redirectRouteNamespace"])
    exact_replacements = {
        old_workload_namespace: cfg["layout"]["workloadNamespace"],
        old_platform_namespace: cfg["layout"]["platformNamespace"],
        str(old_gateway["namespace"]): cfg["layout"]["gatewayNamespace"],
    }
    for project in (old_spec.get("rancher") or {}).get("projects") or []:
        namespaces = [str(item) for item in project.get("namespaces") or []]
        if old_workload_namespace in namespaces:
            exact_replacements[str(project.get("name") or "")] = cfg["layout"][
                "workloadProject"
            ]
        elif old_platform_namespace in namespaces:
            exact_replacements[str(project.get("name") or "")] = cfg["layout"][
                "platformProject"
            ]
    old_domain = old_spec["baseDomain"]
    updates: dict[pathlib.Path, str] = {}
    for path in sorted((ROOT / "argocd").glob("**/*.yaml")):
        documents = [item for item in yaml.safe_load_all(path.read_text(encoding="utf-8")) if item]

        def transform(value: object) -> object:
            if isinstance(value, dict):
                self_repository = value.get("repoURL") == old_repo
                result = {key: transform(item) for key, item in value.items()}
                if self_repository:
                    result["repoURL"] = cfg["forgejo"]["repoURL"]
                    if "targetRevision" in result:
                        result["targetRevision"] = cfg["forgejo"]["revision"]
                return result
            if isinstance(value, list):
                return [transform(item) for item in value]
            if isinstance(value, str):
                updated = value.replace(old_repo, cfg["forgejo"]["repoURL"]).replace(
                    old_domain, cfg["baseDomain"]
                )
                return exact_replacements.get(updated, updated)
            return value

        transformed = [transform(item) for item in documents]
        if len(transformed) == 1:
            updates[path] = yaml_text(transformed[0])
        else:
            updates[path] = "---\n".join(
                yaml.safe_dump(item, allow_unicode=True, sort_keys=False) for item in transformed
            )
    return updates


def rke_updates(cfg: dict) -> dict[pathlib.Path, str]:
    server_path = ROOT / "rke/control-node/config.yaml"
    server = yaml.safe_load(server_path.read_text(encoding="utf-8")) or {}
    server["token"] = ""
    server["node-ip"] = cfg["nodes"]["controlIP"]
    server["advertise-address"] = cfg["nodes"]["controlIP"]
    server["bind-address"] = cfg["nodes"]["controlIP"]
    # 계약만 바뀌고 RKE2가 기본 CIDR을 계속 쓰면 CNI·NetworkPolicy·CoreDNS가 서로 다른
    # 대역을 믿게 된다. site.env의 네트워크 입력을 최초 server 설정에도 같은 값으로 고정한다.
    server["cluster-cidr"] = ",".join(cfg["network"]["podCIDRs"])
    server["service-cidr"] = ",".join(cfg["network"]["serviceCIDRs"])
    server["cluster-dns"] = cfg["network"]["clusterDNS"]
    disabled_addons = server.get("disable") or []
    if isinstance(disabled_addons, str):
        disabled_addons = [disabled_addons]
    server["disable"] = list(dict.fromkeys([*disabled_addons, "rke2-ingress-nginx"]))
    server["tls-san"] = list(
        dict.fromkeys(
            [
                cfg["nodes"]["controlHostname"],
                cfg["nodes"]["controlIP"],
                cfg["nodes"]["rke2Endpoint"],
                "127.0.0.1",
            ]
        )
    )
    worker_path = ROOT / "rke/worker-node/config.yaml"
    worker = yaml.safe_load(worker_path.read_text(encoding="utf-8")) or {}
    worker["token"] = ""
    worker["server"] = (
        f"https://{cfg['nodes']['rke2Endpoint']}:9345"
    )
    hosts = [
        "# Generated by scripts/site/configure-site.py. RKE2 join tokens never belong here.",
        f"{cfg['nodes']['controlIP']} {cfg['nodes']['controlHostname']}",
        *(f"{address} {name}" for name, address in cfg["nodes"]["workers"]),
        "",
    ]
    canal_path = ROOT / "platform/network/rke2-canal-config.yaml"
    canal = yaml.safe_load(canal_path.read_text(encoding="utf-8")) or {}
    content = str(canal.get("spec", {}).get("valuesContent") or "")
    content = re.sub(
        r"(?m)^(\s*iface:\s*).+$",
        rf"\g<1>{cfg['interfaces']['internal']}",
        content,
    )
    canal.setdefault("spec", {})["valuesContent"] = content
    return {
        server_path: yaml_text(server, "# Generated site RKE2 server template; token stays empty.\n"),
        worker_path: yaml_text(worker, "# Generated site RKE2 agent template; token stays empty.\n"),
        ROOT / "rke/etc/hosts": "\n".join(hosts),
        canal_path: yaml_text(canal, "# Generated by scripts/site/configure-site.py.\n"),
    }


def runtime_updates(cfg: dict, old_contract: dict) -> dict[pathlib.Path, str]:
    old_domain = old_contract["spec"]["baseDomain"]
    updates: dict[pathlib.Path, str] = {}
    openapi_path = ROOT / "apps/portal-lite/backend/openapi.yaml"
    openapi = yaml.safe_load(openapi_path.read_text(encoding="utf-8"))
    openapi = replace_strings(
        openapi,
        {
            old_domain: cfg["baseDomain"],
            str(old_contract["spec"].get("environment") or "beta"): cfg["environment"],
        },
    )
    oauth_flow = openapi["components"]["securitySchemes"]["oidc"]["flows"][
        "authorizationCode"
    ]
    oauth_flow["authorizationUrl"] = cfg["identityProvider"]["authorizationEndpoint"]
    oauth_flow["tokenUrl"] = cfg["identityProvider"]["tokenEndpoint"]
    updates[openapi_path] = yaml_text(openapi)

    openbao_values_path = ROOT / "platform/openbao/values-beta.yaml"
    openbao_values = yaml.safe_load(openbao_values_path.read_text(encoding="utf-8")) or {}
    server = openbao_values.setdefault("server", {})
    server.setdefault("dataStorage", {})["storageClass"] = cfg["storageClass"]
    server.setdefault("auditStorage", {})["storageClass"] = cfg["storageClass"]
    updates[openbao_values_path] = yaml_text(openbao_values)
    return updates


def install_env(cfg: dict) -> str:
    values = {
        "SITE_NAME": cfg["siteName"],
        "APP_ENVIRONMENT": cfg["environment"],
        "BASE_DOMAIN": cfg["baseDomain"],
        "WORKLOAD_NAMESPACE": cfg["layout"]["workloadNamespace"],
        "PLATFORM_ROUTE_NAMESPACE": cfg["layout"]["platformNamespace"],
        "GATEWAY_NAMESPACE": cfg["layout"]["gatewayNamespace"],
        "GATEWAY_NAME": cfg["layout"]["gatewayName"],
        "WILDCARD_TLS_SECRET": cfg["tls"]["wildcardSecret"],
        "ACME_CLUSTER_ISSUER_NAME": cfg["tls"]["clusterIssuerName"],
        "INTERNAL_INTERFACE": cfg["interfaces"]["internal"],
        "EXTERNAL_INTERFACE": cfg["interfaces"]["external"],
        "GUARDED_INTERFACES": ",".join(cfg["interfaces"].get("guarded") or []),
        "CONTROL_PLANE_HOSTNAME": cfg["nodes"]["controlHostname"],
        "CONTROL_PLANE_IP": cfg["nodes"]["controlIP"],
        "WORKER_NODES": ",".join(
            f"{name}={address}" for name, address in cfg["nodes"]["workers"]
        ),
        "RKE2_SERVER_ENDPOINT": cfg["nodes"]["rke2Endpoint"],
        "SERVICE_CIDR": cfg["network"]["serviceCIDRs"][0],
        "CLUSTER_UPSTREAM_DNS": cfg["network"]["clusterUpstreamDNS"],
        "SQUID_INTERNAL_IP": cfg["network"]["squidIP"],
        "INTERNAL_ALLOWED_TCP_PORTS": ",".join(map(str, cfg["network"]["ports"]["internalTCP"])),
        "INTERNAL_ALLOWED_UDP_PORTS": ",".join(map(str, cfg["network"]["ports"]["internalUDP"])),
        "EXTERNAL_ALLOWED_TCP_PORTS": "80,443",
        "PUBLIC_EXPOSURE_MODE": cfg["network"]["publicMode"],
        "PUBLIC_IP": cfg["network"]["publicIP"],
        "PUBLIC_IP_NODE": cfg["network"]["publicIPNode"],
        "FORGEJO_REPO_URL": cfg["forgejo"]["repoURL"],
        "FORGEJO_REVISION": cfg["forgejo"]["revision"],
        "OCI_REGISTRY": cfg["registry"]["host"],
        "REGISTRY_PULL_SECRET": cfg["registry"]["pullSecret"],
        "TLS_SOURCE": cfg["tls"]["source"],
        "EXISTING_GATEWAY_TLS_READY": str(cfg["tls"]["existingReady"]).lower(),
        "OIDC_ISSUER": cfg["identityProvider"]["issuer"],
        "DNS_CREDENTIAL_SECRET_NAME": cfg["tls"]["credentialSecretName"],
        "DNS_CREDENTIAL_SECRET_KEY": cfg["tls"]["credentialSecretKey"],
        "SADP_INSTALL_GITOPS": str(cfg["installer"]["gitops"]).lower(),
        "SADP_ARGO_REPO_USERNAME": cfg["installer"]["argoRepoUsername"],
        "SADP_ARGO_REPO_TOKEN_FILE": cfg["installer"]["argoRepoTokenFile"],
        "SADP_DNS_TSIG_SECRET_FILE": cfg["installer"]["dnsTsigSecretFile"],
        "SADP_INSTALL_MONITORING": str(cfg["installer"]["installMonitoring"]).lower(),
        "SADP_BUILD_IMAGES": str(cfg["installer"]["buildImages"]).lower(),
        "SADP_BUILD_NODE": cfg["installer"]["buildNode"],
        "SADP_DEPLOY_APPS": str(cfg["installer"]["deployApps"]).lower(),
        "SADP_REGISTRY_PULL_DOCKERCONFIG": cfg["installer"]["registryPullDockerconfig"],
        "SADP_REGISTRY_PUSH_DOCKERCONFIG": cfg["installer"]["registryPushDockerconfig"],
        "SADP_RUN_VERIFY": str(cfg["installer"]["runVerify"]).lower(),
    }
    return (
        "# Generated by scripts/site/configure-site.py. Contains no credentials.\n"
        + "\n".join(f"{key}={shlex.quote(str(value))}" for key, value in values.items())
        + "\n"
    )


def portal_namespace_reader(cfg: dict) -> str:
    documents = [
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "ClusterRole",
            "metadata": {"name": "portal-app-group-namespace-reader"},
            "rules": [
                {
                    "apiGroups": [""],
                    "resources": ["namespaces"],
                    "verbs": ["get"],
                }
            ],
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "ClusterRoleBinding",
            "metadata": {"name": "portal-app-group-namespace-reader"},
            "roleRef": {
                "apiGroup": "rbac.authorization.k8s.io",
                "kind": "ClusterRole",
                "name": "portal-app-group-namespace-reader",
            },
            "subjects": [
                {
                    "kind": "ServiceAccount",
                    "name": "portal-lite",
                    "namespace": cfg["layout"]["workloadNamespace"],
                }
            ],
        },
    ]
    return "# Generated by scripts/site/configure-site.py. Do not edit directly.\n" + "---\n".join(
        yaml.safe_dump(item, allow_unicode=True, sort_keys=False) for item in documents
    )


def prepare_updates(cfg: dict, contract: dict) -> dict[pathlib.Path, str]:
    old_domain = contract["spec"]["baseDomain"]
    rendered_contract = build_contract(contract, cfg)
    route_listener = rendered_contract["spec"]["gateway"]["routeListener"]
    updates = {
        CONTRACT_PATH: yaml_text(
            rendered_contract,
            "# Generated by scripts/site/configure-site.py from a validated non-secret site.env.\n",
        ),
        ROOT / "apps/hello/values-beta.yaml": app_values(
            ROOT / "apps/hello/values-beta.yaml", cfg, "hello", cfg["hosts"]["hello"], "test-app",
            route_listener,
        ),
        ROOT / "apps/secure-demo/values-beta.yaml": app_values(
            ROOT / "apps/secure-demo/values-beta.yaml",
            cfg,
            "secure-demo",
            cfg["hosts"]["secure-demo"],
            "test-app",
            route_listener,
        ),
        ROOT / "apps/portal-lite/values-beta.yaml": app_values(
            ROOT / "apps/portal-lite/values-beta.yaml",
            cfg,
            "portal-lite",
            cfg["hosts"]["portal"],
            "portal-lite",
            route_listener,
        ),
        ROOT / "apps/_template/values-public.yaml": template_values(
            ROOT / "apps/_template/values-public.yaml", cfg, "sample-public", "public"
        ),
        ROOT / "apps/_template/values-sso.yaml": template_values(
            ROOT / "apps/_template/values-sso.yaml", cfg, "sample-sso", "oidc"
        ),
        ROOT / "apps/_template/values-internal.yaml": template_values(
            ROOT / "apps/_template/values-internal.yaml", cfg, "sample-internal", "internal"
        ),
        ROOT / "platform/network/site-install.env": install_env(cfg),
        ROOT / "platform/portal/app-group-namespace-reader.yaml": portal_namespace_reader(cfg),
    }
    updates.update(argocd_updates(cfg, contract))
    updates.update(rke_updates(cfg))
    updates.update(runtime_updates(cfg, contract))
    return updates


GENERATED_PATHS = (
    ROOT / "contracts/values-platform-production.yaml",
    ROOT / "platform/exposure/resources.yaml",
    ROOT / "platform/cert-manager/resources.yaml",
    ROOT / "platform/rancher/resources.yaml",
    ROOT / "platform/network/squid/squid.conf",
    ROOT / "platform/network/squid/dns-provider-domains.txt",
    ROOT / "platform/network/proxy.env",
    ROOT / "platform/network/firewall.env",
    ROOT / "platform/network/egress-policies.yaml",
    ROOT / "platform/dns/rke2-coredns-config.yaml",
    ROOT / "argocd/applications/cert-manager.yaml",
    ROOT / "platform/quota/resources.yaml",
)


def git_dirty() -> list[str]:
    if not (ROOT / ".git").exists():
        return []
    result = subprocess.run(
        ["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True, check=False
    )
    if result.returncode:
        raise ConfigError("git status failed")
    return [line for line in result.stdout.splitlines() if line]


def write_transaction(updates: dict[pathlib.Path, str], cfg: dict) -> None:
    paths = set(updates) | set(GENERATED_PATHS)
    snapshots = {path: path.read_bytes() if path.exists() else None for path in paths}
    try:
        for path, content in updates.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        if cfg["tls"]["source"] == "provided":
            tls_output = ROOT / "platform/cert-manager/resources.yaml"
            if tls_output.exists():
                tls_output.unlink()
        commands = (
            [sys.executable, "scripts/lib/contract-values.py"],
            [sys.executable, "scripts/site/render-exposure.py"],
            [sys.executable, "scripts/site/render-network.py"],
            [sys.executable, "scripts/site/render-rancher.py"],
            [sys.executable, "scripts/site/render-quota.py"],
            ["bash", "scripts/tests/render-test.sh"],
            ["bash", "scripts/ci-guard.sh"],
        )
        for command in commands:
            result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False)
            if result.stdout:
                print(result.stdout, end="")
            if result.returncode:
                if result.stderr:
                    print(result.stderr, file=sys.stderr, end="")
                raise ConfigError("generated repository validation failed: " + " ".join(command))
    except Exception:
        for path, content in snapshots.items():
            if content is None:
                if path.exists():
                    path.unlink()
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
        raise


def check_rendered(updates: dict[pathlib.Path, str]) -> None:
    stale = [
        path.relative_to(ROOT)
        for path, content in updates.items()
        if path not in GENERATED_PATHS
        and (not path.exists() or path.read_text(encoding="utf-8") != content)
    ]
    if stale:
        raise ConfigError(
            "site.env and repository outputs differ; run --write and publish the reviewed change: "
            + ", ".join(map(str, stale[:12]))
            + (" ..." if len(stale) > 12 else "")
        )
    commands = (
        [sys.executable, "scripts/lib/contract-values.py", "--check"],
        [sys.executable, "scripts/site/render-exposure.py", "--check"],
        [sys.executable, "scripts/site/render-network.py", "--check"],
        [sys.executable, "scripts/site/render-rancher.py", "--check"],
        [sys.executable, "scripts/site/render-quota.py", "--check"],
    )
    for command in commands:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False)
        if result.stdout:
            print(result.stdout, end="")
        if result.returncode:
            if result.stderr:
                print(result.stderr, file=sys.stderr, end="")
            raise ConfigError("generated repository check failed: " + " ".join(command))


def summary(cfg: dict) -> None:
    print(f"[OK] site={cfg['siteName']} environment={cfg['environment']} domain={cfg['baseDomain']}")
    print(
        "[OK] network="
        f"internal:{cfg['interfaces']['internal']} "
        f"external:{cfg['interfaces']['external']} "
        f"public-ports:{','.join(map(str, cfg['network']['ports']['externalTCP']))}"
    )
    print(
        f"[OK] forgejo={cfg['forgejo']['repoURL']} revision={cfg['forgejo']['revision']} "
        f"registry={cfg['registry']['host']}/{cfg['registry']['project']}"
    )
    print(
        f"[OK] machine-auth mode={cfg['machineAuth']['mode']} "
        f"clients={len(cfg['machineAuth']['clients'])} "
        f"services={len(cfg['machineAuth']['services'])}"
    )
    api = cfg["forgejo"].get("api")
    if api:
        kind, service_port, host = portal_forgejo_reach(cfg)
        portal_project = str(
            (
                yaml.safe_load(
                    (ROOT / "apps/portal-lite/values-beta.yaml").read_text(encoding="utf-8")
                )
                or {}
            ).get("app", {}).get("project", "<project>")
        )
        route = {
            "direct": f"직접 {host}:{service_port}",
            "gateway": f"split DNS → Gateway VIP {cfg['network']['gatewayVIP']}:443",
            "proxy": f"Squid {cfg['network']['squidIP']}:{cfg['network']['squidPort']}",
        }[kind]
        print(
            f"[OK] portal-lite forgejo API={api['baseURL']} {api['owner']}/{api['repo']} "
            f"egress={route} (FORGEJO_BOT_TOKEN은 OpenBao "
            f"apps/{portal_project}/{cfg['environment']}/portal-lite 에 넣어야 한다)"
        )
    else:
        print(
            "[WARN] FORGEJO_REPO_URL이 https://host/owner/repo 형태가 아니라 portal-lite "
            "배포 신청 API가 503(forgejo_not_configured)으로 남는다"
        )
    print("[OK] no credential values accepted or generated")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", required=True, type=pathlib.Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="validate only (default)")
    mode.add_argument(
        "--check-rendered",
        action="store_true",
        help="validate and require every repository output to match site.env",
    )
    mode.add_argument("--write", action="store_true", help="write and render repository files")
    parser.add_argument(
        "--allow-dirty",
        action="store_true",
        help="allow --write in a dirty worktree after the operator reviewed existing changes",
    )
    parser.add_argument(
        "--print-install-env",
        action="store_true",
        help="print validated, shell-quoted non-secret installer inputs",
    )
    args = parser.parse_args()
    try:
        values = parse_env(args.env_file)
        cfg = validate(values)
        if args.print_install_env:
            print(install_env(cfg), end="")
            return 0
        contract = yaml.safe_load(CONTRACT_PATH.read_text(encoding="utf-8"))
        if not isinstance(contract, dict) or contract.get("kind") != "PlatformContract":
            raise ConfigError("contracts/platform-production.yaml is not a PlatformContract")
        updates = prepare_updates(cfg, contract)
        summary(cfg)
        print(f"[OK] planned files={len(updates)} plus {len(GENERATED_PATHS)} renderer outputs")
        if args.check_rendered:
            check_rendered(updates)
            print("[OK] site.env and all rendered repository outputs are synchronized")
            return 0
        if not args.write:
            print("[INFO] validation only; use --write after reviewing this summary")
            return 0
        # --allow-dirty는 기존 변경을 검토했다는 명시적 승인이다. Git metadata를 일부러
        # 숨기는 배포 bundle에서도 같은 플래그로 렌더할 수 있어야 한다.
        dirty = [] if args.allow_dirty else git_dirty()
        if dirty and not args.allow_dirty:
            raise ConfigError(
                "worktree is dirty; preserve/review changes first or explicitly pass --allow-dirty"
            )
        write_transaction(updates, cfg)
        print("[OK] site configuration written and renderer/CI guard validation passed")
        print("[INFO] no kubectl apply, Helm upgrade, service restart or external API call was run")
        return 0
    except (ConfigError, KeyError, TypeError, yaml.YAMLError, OSError) as error:
        print(f"[FAIL] site configuration: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
