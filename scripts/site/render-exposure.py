#!/usr/bin/env python3
"""Render D4 exposure and D5 TLS resources from the platform contract.

The Gateway is one resource that carries both the D4 HTTP listener and the D5 HTTPS listener,
so a single renderer owns both. Each output has an independent pending gate:

  platform/exposure/resources.yaml      requires spec.gateway.vip and addressPoolRange
  platform/cert-manager/resources.yaml  requires source=acme and the ACME/solver inputs

The HTTPS listener and the HTTP->HTTPS redirect route are appended when either ACME inputs are
complete or source=provided declares an out-of-band certificate. Provided certificate bytes are
never rendered into Git; scripts/cluster/bootstrap-testbed.sh validates and creates that Secret directly.
"""

from __future__ import annotations

import argparse
import ipaddress
import pathlib
import re
import sys

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT_PATH = ROOT / "contracts" / "platform-production.yaml"
TEMPLATE_DIR = ROOT / "scripts" / "site" / "templates"
EXPOSURE_TEMPLATE = TEMPLATE_DIR / "exposure-resources.yaml.template"
HTTPS_TEMPLATE = TEMPLATE_DIR / "exposure-https.yaml.template"
PLATFORM_SERVICE_TEMPLATE = TEMPLATE_DIR / "exposure-platform-service.yaml.template"
TLS_TEMPLATE = TEMPLATE_DIR / "tls-resources.yaml.template"
EXPOSURE_OUTPUT = ROOT / "platform" / "exposure" / "resources.yaml"
TLS_OUTPUT = ROOT / "platform" / "cert-manager" / "resources.yaml"
# scripts/render-d4.py 시절 산출물. 남으면 platform-resources 가 Gateway 를 두 번 관리한다.
LEGACY_OUTPUTS = (ROOT / "platform" / "exposure" / "d4-resources.yaml",)

PENDING_VALUES = {"", "pending", "replace-me", "tbd", "none"}
SUPPORTED_PROVIDERS = ("rfc2136",)
TLS_SOURCES = ("acme", "provided")
ISSUER_MODES = ("staging", "production")
PUBLIC_MODES = ("nat", "direct")
# DNS-01 은 두 가지로 운용한다. direct 는 BASE_DOMAIN 권한 DNS 를 직접 UPDATE 하고,
# delegated 는 _acme-challenge 만 우리 ACME zone 으로 위임받아 우리 TSIG 로 UPDATE 한다.
DNS01_MODES = ("direct-rfc2136", "delegated-rfc2136")
DELEGATION_TYPES = ("cname", "ns")
EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$")
NAMESERVER_PATTERN = re.compile(r"^(\d{1,3}\.){3}\d{1,3}:\d{1,5}$")
NAME_PATTERN = re.compile(r"^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$")
# _acme-challenge 처럼 밑줄로 시작하는 label 도 zone 이름이 될 수 있다.
DNS_ZONE_PATTERN = re.compile(
    r"^_?[a-z0-9](?:[-a-z0-9]*[a-z0-9])?(?:\._?[a-z0-9](?:[-a-z0-9]*[a-z0-9])?)+\.?$"
)
SOLVER_INDENT = " " * 10


class PendingInput(Exception):
    """An externally approved input has not arrived yet. This is not a failure."""


def load_contract() -> dict:
    contract = yaml.safe_load(CONTRACT_PATH.read_text(encoding="utf-8"))
    if contract.get("kind") != "PlatformContract":
        raise ValueError("contracts/platform-production.yaml kind must be PlatformContract")
    return contract["spec"]


def is_pending(raw_value: object) -> bool:
    return str(raw_value or "").strip().lower() in PENDING_VALUES


def required(mapping: dict, key: str, where: str) -> str:
    value = str(mapping.get(key) or "").strip()
    if is_pending(value):
        raise PendingInput(f"spec.{where}.{key} is pending")
    return value


def required_now(mapping: dict, key: str, where: str) -> str:
    """provider 를 이미 고른 뒤에는 그 provider 의 필드가 비어 있으면 pending 이 아니라 오류다.

    pending 으로 처리하면 산출물만 조용히 사라져서 HTTPS listener 가 없는 이유를 찾기 어렵다.
    """
    value = str(mapping.get(key) or "").strip()
    if is_pending(value):
        raise ValueError(f"spec.{where}.{key} is required once the solver provider is chosen")
    return value


def tls_source(specification: dict) -> str:
    tls = specification.get("tls") or {}
    if not tls:
        raise ValueError("spec.tls is missing")
    source = required(tls, "source", "tls")
    if source not in TLS_SOURCES:
        raise ValueError(f"spec.tls.source must be one of {', '.join(TLS_SOURCES)}")
    return source


def provided_inputs(specification: dict) -> dict[str, str]:
    """Validate safe metadata for an out-of-band wildcard certificate.

    CI clones do not contain ignored private material, so the renderer deliberately does not read
    these files. The operational bootstrap script performs x509/SAN/expiry/key-match checks
    immediately before creating the Kubernetes Secret.
    """
    if tls_source(specification) != "provided":
        raise ValueError("provided certificate inputs require spec.tls.source=provided")
    provided = specification["tls"].get("provided") or {}
    resolved: dict[str, str] = {}
    for key in ("certificatePath", "privateKeyPath"):
        value = required_now(provided, key, "tls.provided")
        path = pathlib.PurePosixPath(value)
        if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "wildcard":
            raise ValueError(f"spec.tls.provided.{key} must be a relative path under wildcard/")
        if path.suffix.lower() != ".pem":
            raise ValueError(f"spec.tls.provided.{key} must name a PEM file")
        resolved[key] = value
    if resolved["certificatePath"] == resolved["privateKeyPath"]:
        raise ValueError("provided certificate and private key paths must be different")
    return resolved


def validate_vip(raw_value: object) -> ipaddress.IPv4Address:
    value = str(raw_value or "").strip()
    if is_pending(value):
        raise PendingInput("spec.gateway.vip is pending")

    address = ipaddress.ip_address(value)
    if not isinstance(address, ipaddress.IPv4Address):
        raise ValueError("spec.gateway.vip must be an IPv4 address")
    if address.is_loopback or address.is_multicast:
        raise ValueError("spec.gateway.vip must be a usable unicast address")

    node_addresses = set()
    hosts_path = ROOT / "rke" / "etc" / "hosts"
    for line in hosts_path.read_text(encoding="utf-8").splitlines():
        content = line.partition("#")[0].strip()
        if content:
            node_addresses.add(content.split()[0])
    if value in node_addresses:
        raise ValueError("spec.gateway.vip conflicts with an RKE2 node address")
    return address


def route_label(gateway: dict) -> tuple[str, str]:
    labels = (gateway.get("allowedRouteSelector") or {}).get("matchLabels") or {}
    if len(labels) != 1:
        raise ValueError(
            "spec.gateway.allowedRouteSelector.matchLabels must hold exactly one label"
        )
    key, value = next(iter(labels.items()))
    return str(key), str(value)


def namespace_project_map(specification: dict, namespaces: list[str]) -> dict[str, str]:
    """[A/D6] Namespace 를 Rancher Project 에 편입하는 field.cattle.io/projectId 값.

    Namespace 객체는 이 렌더러가 소유하므로 annotation 도 여기서 붙인다. render-rancher.py 가
    같은 객체를 또 관리하면 Argo CD 소유권이 충돌한다.
    """
    rancher = specification.get("rancher") or {}
    if not rancher:
        return {}
    cluster_id = str(rancher.get("clusterId") or "").strip()
    if not NAME_PATTERN.match(cluster_id):
        raise ValueError(f"invalid spec.rancher.clusterId: {cluster_id!r}")

    mapping: dict[str, str] = {}
    for project in rancher.get("projects") or []:
        project_name = str(project.get("name") or "").strip()
        if not NAME_PATTERN.match(project_name):
            raise ValueError(f"invalid spec.rancher.projects name: {project_name!r}")
        for namespace in (project or {}).get("namespaces") or []:
            namespace = str(namespace).strip()
            if namespace not in namespaces:
                raise ValueError(
                    f"spec.rancher.projects[{project_name}] lists namespace {namespace!r}, "
                    "which is not in spec.gateway.allowedRouteNamespaces and therefore never "
                    "rendered; it would silently miss its Rancher project annotation"
                )
            if namespace in mapping:
                raise ValueError(f"namespace {namespace!r} is claimed by two Rancher projects")
            mapping[namespace] = f"{cluster_id}:{project_name}"
    return mapping


def route_namespace_documents(
    gateway: dict, label_key: str, label_value: str, projects: dict[str, str]
) -> str:
    namespaces = [str(entry) for entry in gateway.get("allowedRouteNamespaces") or []]
    if not namespaces:
        raise ValueError("spec.gateway.allowedRouteNamespaces must not be empty")
    if gateway["namespace"] in namespaces:
        raise ValueError(
            "spec.gateway.allowedRouteNamespaces must not contain the Gateway namespace; "
            "the envoy-gateway Application already owns it via CreateNamespace"
        )
    documents = []
    for namespace in namespaces:
        if not NAME_PATTERN.match(namespace):
            raise ValueError(f"invalid namespace name: {namespace}")
        document = (
            "apiVersion: v1\n"
            "kind: Namespace\n"
            "metadata:\n"
            f"  name: {namespace}\n"
        )
        if namespace in projects:
            document += (
                "  annotations:\n"
                f"    field.cattle.io/projectId: {projects[namespace]}\n"
            )
        document += "  labels:\n" f"    {label_key}: {label_value}"
        documents.append(document)
    return "\n---\n".join(documents)


def platform_service_documents(specification: dict, replacements: dict[str, str]) -> str:
    """[A/D6] 플랫폼 UI 의 HTTPRoute 와 ReferenceGrant. 사용자 앱은 app-profile chart 가 담당한다."""
    services = specification.get("platformServices") or []
    base_domain = specification["baseDomain"]
    gateway = specification["gateway"]
    template = PLATFORM_SERVICE_TEMPLATE.read_text(encoding="utf-8")
    seen_hosts: set[str] = set()
    documents = []
    for service in services:
        service = service or {}
        name = str(service.get("name") or "").strip()
        host = str(service.get("host") or "").strip()
        namespace = str(service.get("namespace") or "").strip()
        backend_service = str(service.get("service") or name).strip()
        if not NAME_PATTERN.match(name):
            raise ValueError(f"invalid platformServices name: {name!r}")
        if not NAME_PATTERN.match(namespace):
            raise ValueError(f"invalid platformServices namespace for {name}: {namespace!r}")
        if not NAME_PATTERN.match(backend_service):
            raise ValueError(f"invalid platformServices backend service for {name}: {backend_service!r}")
        if not host.endswith(f".{base_domain}"):
            raise ValueError(f"platformServices host must sit under {base_domain}: {host}")
        if host in seen_hosts:
            raise ValueError(f"duplicate platformServices host: {host}")
        seen_hosts.add(host)
        if namespace == gateway["namespace"]:
            raise ValueError(
                f"platformServices {name} must not live in the Gateway namespace; "
                "put the workload in its own namespace"
            )
        port = int(service.get("port") or 0)
        if not 1 <= port <= 65535:
            raise ValueError(f"platformServices port out of range for {name}: {port}")
        machine_auth = service.get("machineAuth") or {}
        if machine_auth:
            # Grafana 같은 기계 클라이언트는 브라우저 OIDC 흐름을 못 탄다. Keycloak
            # client_credentials 로 받은 JWT 를 Bearer 로 보내면 Envoy 가 JWKS 로 검증하고,
            # 출발지 CIDR 까지 함께 확인한다. 토큰 값은 Git 에 들어가지 않는다.
            documents.append(
                machine_auth_document(name, machine_auth, replacements["__REDIRECT_ROUTE_NAMESPACE__"])
            )
        external = service.get("external") or {}
        if external:
            # 다른 VM 에 있는 서비스(Forgejo, Grafana 등)는 클러스터에 워크로드가 없다.
            # Namespace 와 selector 없는 Service, EndpointSlice 를 만들어 주면 위의 HTTPRoute/
            # ReferenceGrant 경로를 그대로 태울 수 있다. 외부 Keycloak 과 같은 방식이다.
            documents.append(external_backend_documents(name, namespace, backend_service, port, external))
        documents.append(
            substitute(
                template,
                {
                    **replacements,
                    "__SERVICE_HOST__": host,
                    "__SERVICE_NAME__": name,
                    "__BACKEND_SERVICE_NAME__": backend_service,
                    "__SERVICE_NAMESPACE__": namespace,
                    "__SERVICE_PORT__": str(port),
                },
            ).rstrip("\n")
        )
    return "\n---\n".join(documents)


def machine_auth_document(name: str, machine_auth: dict, route_namespace: str) -> str:
    """기계 클라이언트 전용 SecurityPolicy. Bearer JWT 검증과 출발지 CIDR 제한을 함께 건다.

    브라우저 로그인을 못 하는 datasource 를 위해 OIDC 대신 JWT provider 를 쓴다. 토큰은
    Keycloak client_credentials 로 발급되므로 client secret 은 OpenBao/Keycloak 에만 있고
    이 저장소에는 issuer 와 허용 client 이름만 남는다.
    """
    issuer = str(machine_auth.get("issuer") or "").strip()
    if not issuer.startswith("https://"):
        raise ValueError(f"platformServices[{name}].machineAuth.issuer must be https: {issuer!r}")
    jwks_uri = str(machine_auth.get("jwksURI") or "").strip()
    if not jwks_uri.startswith("https://"):
        raise ValueError(f"platformServices[{name}].machineAuth.jwksURI must be https")
    claim = str(machine_auth.get("clientClaim") or "azp").strip()
    if not claim:
        raise ValueError(f"platformServices[{name}].machineAuth.clientClaim must not be empty")
    clients = [str(item).strip() for item in machine_auth.get("allowedClients") or []]
    if not clients:
        raise ValueError(
            f"platformServices[{name}].machineAuth.allowedClients must not be empty; "
            "an empty list would let every realm client read this endpoint"
        )
    cidrs = [str(item).strip() for item in machine_auth.get("allowedCIDRs") or []]
    if not cidrs:
        raise ValueError(
            f"platformServices[{name}].machineAuth.allowedCIDRs must not be empty; "
            "these endpoints expose cluster internals and need a source restriction"
        )
    for entry in cidrs:
        try:
            network = ipaddress.ip_network(entry, strict=False)
        except ValueError as error:
            raise ValueError(
                f"platformServices[{name}].machineAuth.allowedCIDRs entry is not a CIDR: {entry}"
            ) from error
        if not isinstance(network, ipaddress.IPv4Network):
            raise ValueError(f"platformServices[{name}].machineAuth.allowedCIDRs must be IPv4")
        if int(network.prefixlen) == 0:
            raise ValueError(
                f"platformServices[{name}].machineAuth.allowedCIDRs must not be 0.0.0.0/0"
            )
    return yaml.safe_dump(
        {
            "apiVersion": "gateway.envoyproxy.io/v1alpha1",
            "kind": "SecurityPolicy",
            "metadata": {"name": f"{name}-machine-auth", "namespace": route_namespace},
            "spec": {
                "targetRefs": [
                    {
                        "group": "gateway.networking.k8s.io",
                        "kind": "HTTPRoute",
                        "name": name,
                    }
                ],
                "jwt": {
                    "providers": [
                        {
                            "name": "keycloak",
                            "issuer": issuer,
                            "remoteJWKS": {"uri": jwks_uri},
                        }
                    ]
                },
                "authorization": {
                    # 허용 목록에 없으면 막는다. 이 엔드포인트는 클러스터 내부가 다 보인다.
                    "defaultAction": "Deny",
                    "rules": [
                        {
                            "name": "allowed-machine-clients",
                            "action": "Allow",
                            "principal": {
                                "clientCIDRs": cidrs,
                                "jwt": {
                                    "provider": "keycloak",
                                    "claims": [
                                        {
                                            "name": claim,
                                            "valueType": "String",
                                            "values": clients,
                                        }
                                    ],
                                },
                            },
                        }
                    ],
                },
            },
        },
        allow_unicode=True,
        sort_keys=False,
    ).rstrip("\n")


def external_backend_documents(
    name: str, namespace: str, backend_service: str, port: int, external: dict
) -> str:
    """다른 VM 의 서비스를 클러스터 안의 Service 이름으로 노출한다."""
    address = str(external.get("address") or "").strip()
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError as error:
        raise ValueError(
            f"platformServices[{name}].external.address must be IPv4: {address!r}"
        ) from error
    if not isinstance(parsed, ipaddress.IPv4Address):
        raise ValueError(f"platformServices[{name}].external.address must be IPv4: {address}")
    target_port = int(external.get("port") or 0)
    if not 1 <= target_port <= 65535:
        raise ValueError(
            f"platformServices[{name}].external.port out of range: {target_port}"
        )
    return "\n---\n".join(
        yaml.safe_dump(document, allow_unicode=True, sort_keys=False).rstrip("\n")
        for document in (
            {
                "apiVersion": "v1",
                "kind": "Namespace",
                "metadata": {
                    "name": namespace,
                    "labels": {"platform.example.io/component": "external-service"},
                },
            },
            {
                "apiVersion": "v1",
                "kind": "Service",
                "metadata": {
                    "name": backend_service,
                    "namespace": namespace,
                    "annotations": {"platform.example.io/backend": "external"},
                },
                # selector 를 두지 않는다. Endpoint 는 아래 EndpointSlice 가 직접 채운다.
                "spec": {
                    "type": "ClusterIP",
                    "ports": [
                        {
                            "name": "http",
                            "port": port,
                            "targetPort": target_port,
                            "protocol": "TCP",
                        }
                    ],
                },
            },
            {
                "apiVersion": "discovery.k8s.io/v1",
                "kind": "EndpointSlice",
                "metadata": {
                    "name": f"{backend_service}-external",
                    "namespace": namespace,
                    "labels": {"kubernetes.io/service-name": backend_service},
                },
                "addressType": "IPv4",
                "ports": [{"name": "http", "port": target_port, "protocol": "TCP"}],
                "endpoints": [{"addresses": [address], "conditions": {"ready": True}}],
            },
        )
    )


def delegation_inputs(specification: dict, solver: dict) -> dict:
    """dns01Mode 와 위임 설정을 확정한다.

    direct 에서는 delegation 값이 남아 있으면 조용히 무시하지 않고 오류로 잡는다.
    남은 값이 다음 모드 전환 때 잘못된 zone 을 UPDATE 하게 만드는 것이 가장 위험하다.
    """
    base_domain = str(specification["baseDomain"]).strip().lower()
    mode = str(solver.get("dns01Mode") or "").strip()
    if is_pending(mode):
        # 계약이 아직 mode 를 갖지 않는 예전 사이트는 기존 동작(직접 UPDATE)이다.
        mode = "direct-rfc2136"
    if mode not in DNS01_MODES:
        raise ValueError(
            f"spec.tls.solver.dns01Mode must be one of {', '.join(DNS01_MODES)}"
        )
    delegation = solver.get("delegation") or {}
    raw_type = str(delegation.get("type") or "").strip().lower()
    raw_zone = str(delegation.get("zone") or "").strip().lower().rstrip(".")

    if mode == "direct-rfc2136":
        for field, value in (("type", raw_type), ("zone", raw_zone)):
            if not is_pending(value):
                raise ValueError(
                    f"spec.tls.solver.delegation.{field} is only valid when "
                    "dns01Mode=delegated-rfc2136"
                )
        return {
            "dns01Mode": mode,
            "delegationType": "",
            "delegatedZone": "",
            "cnameStrategy": "",
        }

    if raw_type not in DELEGATION_TYPES:
        raise ValueError(
            "spec.tls.solver.delegation.type must be one of "
            f"{', '.join(DELEGATION_TYPES)} when dns01Mode=delegated-rfc2136"
        )
    if is_pending(raw_zone):
        raise ValueError(
            "spec.tls.solver.delegation.zone is required when dns01Mode=delegated-rfc2136"
        )
    if not DNS_ZONE_PATTERN.match(raw_zone):
        raise ValueError(
            f"spec.tls.solver.delegation.zone is not a DNS zone name: {raw_zone}"
        )
    if raw_type == "ns":
        # NS 위임은 _acme-challenge 라벨 자체가 별도 zone 이 된다. 다른 이름을 적으면
        # cert-manager 의 SOA 탐색 결과와 어긋나 UPDATE 대상 zone 이 달라진다.
        expected = f"_acme-challenge.{base_domain}"
        if raw_zone != expected:
            raise ValueError(
                "spec.tls.solver.delegation.zone must be "
                f"{expected} when delegation.type=ns"
            )
    elif raw_zone == base_domain:
        raise ValueError(
            "spec.tls.solver.delegation.zone must differ from baseDomain; "
            "delegation exists so the baseDomain zone stays untouched"
        )
    return {
        # 주의: 키 이름은 issuerMode 를 담는 tls_inputs 의 "mode" 와 반드시 달라야 한다.
        # 같으면 resolved.update() 가 ACME issuer 모드를 덮어써 staging/production 이 뒤바뀐다.
        "dns01Mode": mode,
        "delegationType": raw_type,
        "delegatedZone": raw_zone,
        # CNAME 위임에서만 cert-manager 가 CNAME 을 따라가야 위임된 zone 을 UPDATE 한다.
        # NS 위임은 _acme-challenge 가 이미 자체 SOA 를 가지므로 따라갈 CNAME 이 없다.
        "cnameStrategy": "Follow" if raw_type == "cname" else "None",
    }


def tls_inputs(specification: dict) -> dict:
    """Resolve every D5 TLS input. Raises PendingInput while approvals are outstanding."""
    if tls_source(specification) != "acme":
        raise ValueError("ACME inputs require spec.tls.source=acme")
    tls = specification.get("tls") or {}
    if not tls:
        raise ValueError("spec.tls is missing")
    acme = tls.get("acme") or {}
    solver = tls.get("solver") or {}

    email = required(acme, "email", "tls.acme")
    if not EMAIL_PATTERN.match(email):
        raise ValueError(f"spec.tls.acme.email is not an email address: {email}")

    provider = required(solver, "provider", "tls.solver")
    if provider not in SUPPORTED_PROVIDERS:
        raise ValueError(
            f"spec.tls.solver.provider must be one of {', '.join(SUPPORTED_PROVIDERS)}"
        )

    mode = str(tls.get("issuerMode") or "").strip()
    if mode not in ISSUER_MODES:
        raise ValueError(f"spec.tls.issuerMode must be one of {', '.join(ISSUER_MODES)}")

    nameservers = [str(entry).strip() for entry in tls.get("recursiveNameservers") or []]
    if not nameservers:
        raise ValueError("spec.tls.recursiveNameservers must not be empty")
    for entry in nameservers:
        if not NAMESERVER_PATTERN.match(entry):
            raise ValueError(
                f"spec.tls.recursiveNameservers entry must be <ipv4>:<port>: {entry}"
            )

    issuer_name = required(tls, "clusterIssuerName", "tls")
    resolved = {
        "email": email,
        "provider": provider,
        "mode": mode,
        "nameservers": nameservers,
        "issuerName": issuer_name,
        "activeIssuerName": issuer_name if mode == "production" else f"{issuer_name}-staging",
        "stagingServer": required(acme, "stagingServer", "tls.acme"),
        "productionServer": required(acme, "productionServer", "tls.acme"),
        "accountKeySecret": required(acme, "accountKeySecretName", "tls.acme"),
        "credentialSecretName": required(solver, "credentialSecretName", "tls.solver"),
        "credentialSecretKey": required(solver, "credentialSecretKey", "tls.solver"),
        "solver": solver,
    }
    resolved.update(delegation_inputs(specification, solver))
    # provider 별 필드까지 여기서 확정한다. 그래야 부분 입력이 pending 으로 위장하지 않는다.
    resolved["solverBlock"] = solver_block(resolved)
    return resolved


def solver_block(inputs: dict) -> str:
    secret_name = inputs["credentialSecretName"]
    options = inputs["solver"].get("rfc2136") or {}
    nameserver = required_now(options, "nameserver", "tls.solver.rfc2136")
    if not NAMESERVER_PATTERN.match(nameserver):
        raise ValueError("spec.tls.solver.rfc2136.nameserver must be <ipv4>:<port>")
    lines = []
    if inputs.get("cnameStrategy"):
        # cert-manager v1 의 cnameStrategy 는 dns01 바로 아래, provider 블록과 형제다.
        lines.append(f"cnameStrategy: {inputs['cnameStrategy']}")
    lines += [
        "rfc2136:",
        f'  nameserver: "{nameserver}"',
        f"  tsigKeyName: {required_now(options, 'tsigKeyName', 'tls.solver.rfc2136')}",
        f"  tsigAlgorithm: {required_now(options, 'tsigAlgorithm', 'tls.solver.rfc2136')}",
        "  tsigSecretSecretRef:",
        f"    name: {secret_name}",
        f"    key: {inputs['credentialSecretKey']}",
    ]
    return "\n".join(SOLVER_INDENT + line for line in lines)


def substitute(template: str, replacements: dict[str, str]) -> str:
    rendered = template
    for placeholder, value in replacements.items():
        rendered = rendered.replace(placeholder, value)
    unresolved = sorted({part for part in rendered.split() if part.startswith("__")})
    if unresolved:
        raise ValueError(f"unresolved template placeholders: {', '.join(unresolved)}")
    return rendered


def validate_pool_range(raw_value: object, vip: ipaddress.IPv4Address) -> str:
    value = str(raw_value or "").strip()
    if is_pending(value):
        raise PendingInput("spec.gateway.addressPoolRange is pending")
    if "-" not in value:
        raise ValueError("spec.gateway.addressPoolRange must be <start>-<end>")
    start_raw, end_raw = (part.strip() for part in value.split("-", 1))
    start, end = ipaddress.ip_address(start_raw), ipaddress.ip_address(end_raw)
    if not (isinstance(start, ipaddress.IPv4Address) and isinstance(end, ipaddress.IPv4Address)):
        raise ValueError("spec.gateway.addressPoolRange must be IPv4")
    if int(start) > int(end):
        raise ValueError("spec.gateway.addressPoolRange start must be <= end")
    if not (int(start) <= int(vip) <= int(end)):
        raise ValueError("spec.gateway.vip must fall inside spec.gateway.addressPoolRange")

    node_addresses = set()
    hosts_path = ROOT / "rke" / "etc" / "hosts"
    for line in hosts_path.read_text(encoding="utf-8").splitlines():
        content = line.partition("#")[0].strip()
        if content:
            node_addresses.add(content.split()[0])
    overlap = sorted(n for n in node_addresses if int(start) <= int(ipaddress.ip_address(n)) <= int(end))
    if overlap:
        raise ValueError(f"spec.gateway.addressPoolRange overlaps RKE2 node addresses: {overlap}")
    return value


def public_service_config(specification: dict, vip: ipaddress.IPv4Address) -> str:
    public = specification.get("public") or {}
    mode = str(public.get("mode") or "").strip().lower()
    if mode not in PUBLIC_MODES:
        raise ValueError("spec.public.mode must be nat or direct")
    ports = sorted(int(item) for item in public.get("ports") or [])
    if ports != [80, 443]:
        raise ValueError("spec.public.ports must be exactly 80,443")

    try:
        public_ip = ipaddress.ip_address(str(public.get("ip") or ""))
    except ValueError as error:
        raise ValueError("spec.public.ip must be IPv4") from error
    if not isinstance(public_ip, ipaddress.IPv4Address):
        raise ValueError("spec.public.ip must be IPv4")
    if public_ip.is_loopback or public_ip.is_multicast or public_ip.is_unspecified:
        raise ValueError("spec.public.ip must be a usable unicast address")
    if mode == "nat":
        return ""

    external_interface = str(
        ((specification.get("network") or {}).get("interfaces") or {}).get("external") or ""
    ).strip()
    if not external_interface:
        raise ValueError("spec.public.mode=direct requires spec.network.interfaces.external")
    return "\n".join(
        [
            "        # direct mode: the public IP is assigned to the node external interface.",
            "        externalTrafficPolicy: Cluster",
            "        patch:",
            "          type: StrategicMerge",
            "          value:",
            "            spec:",
            "              externalIPs:",
            f"                - {vip}",
            f"                - {public_ip}",
        ]
    )

def render_exposure(specification: dict, tls_ready: bool) -> str:
    gateway = specification["gateway"]
    address = validate_vip(gateway.get("vip"))
    pool_range = validate_pool_range(gateway.get("addressPoolRange"), address)
    label_key, label_value = route_label(gateway)
    redirect_namespace = str(gateway.get("redirectRouteNamespace") or "").strip()
    if redirect_namespace not in [str(x) for x in gateway.get("allowedRouteNamespaces") or []]:
        raise ValueError(
            "spec.gateway.redirectRouteNamespace must be listed in allowedRouteNamespaces"
        )
    if gateway["routeListener"] == gateway["httpsListener"] and not tls_ready:
        raise ValueError(
            "spec.gateway.routeListener points at the HTTPS listener while the TLS inputs are "
            "pending; app HTTPRoutes would attach to a listener that is not rendered"
        )

    replacements = {
        "__ADDRESS_POOL_RANGE__": pool_range,
        "__ADDRESS_POOL_NAME__": gateway["addressPoolName"],
        "__BASE_DOMAIN__": specification["baseDomain"],
        "__GATEWAY_CLASS_NAME__": gateway["className"],
        "__GATEWAY_NAME__": gateway["name"],
        "__GATEWAY_NAMESPACE__": gateway["namespace"],
        "__HTTP_LISTENER_NAME__": gateway["httpListener"],
        "__HTTPS_LISTENER_NAME__": gateway["httpsListener"],
        "__METALLB_VIP__": str(address),
        "__METALLB_VIP_CIDR__": f"{address}/32",
        "__PROXY_CONFIG_NAME__": gateway["proxyConfigName"],
        "__PUBLIC_SERVICE_CONFIG__": public_service_config(specification, address),
        "__REDIRECT_ROUTE_NAMESPACE__": redirect_namespace,
        "__ROUTE_LABEL_KEY__": label_key,
        "__ROUTE_LABEL_VALUE__": label_value,
        "__ROUTE_LISTENER_NAME__": gateway["routeListener"],
        "__WILDCARD_TLS_SECRET__": gateway["wildcardTlsSecret"],
        "__ROUTE_NAMESPACES__": route_namespace_documents(
            gateway,
            label_key,
            label_value,
            namespace_project_map(
                specification, [str(x) for x in gateway.get("allowedRouteNamespaces") or []]
            ),
        ),
    }
    rendered = substitute(EXPOSURE_TEMPLATE.read_text(encoding="utf-8"), replacements)
    rendered = rendered.rstrip("\n") + "\n"
    if tls_ready:
        appended = substitute(HTTPS_TEMPLATE.read_text(encoding="utf-8"), replacements)
        rendered += appended.rstrip("\n") + "\n"
    platform_services = platform_service_documents(specification, replacements)
    if platform_services:
        rendered += "---\n" + platform_services + "\n"
    systems = specification.get("systems") or []
    if systems:
        rendered = append_system_exposure(rendered, specification, tls_ready, label_key, label_value)
    return rendered


def append_system_exposure(
    rendered: str, specification: dict, tls_ready: bool, label_key: str, label_value: str
) -> str:
    """시스템마다 Gateway listener 와 sso HTTPRoute 를 덧붙인다.

    listener 는 기존 beta-gateway 객체 안에 추가한다 — Gateway API 는 하나의 Gateway 에
    여러 hostname/TLS 조합의 listener 를 둘 수 있으므로 새 Gateway 객체가 필요 없다.
    문자열 템플릿으로는 기존 객체 내부에 안전하게 끼워 넣기 어려워 구조화 YAML로 다룬다.
    """
    if tls_source(specification) != "acme":
        raise ValueError("spec.systems requires spec.tls.source=acme")
    documents = [d for d in yaml.safe_load_all(rendered) if d]
    gateway_doc = next(d for d in documents if d.get("kind") == "Gateway")
    listeners = gateway_doc["spec"]["listeners"]
    existing_names = {item["name"] for item in listeners}
    allowed_routes = {
        "namespaces": {
            "from": "Selector",
            "selector": {"matchLabels": {label_key: label_value}},
        },
        "kinds": [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute"}],
    }
    for system in systems_of(specification):
        http_name = system["httpListener"]
        https_name = system["httpsListener"]
        if http_name in existing_names or https_name in existing_names:
            raise ValueError(f"system '{system['name']}' listener name collides with base gateway")
        listeners.append(
            {
                "name": http_name,
                "hostname": f"*.{system['domain']}",
                "protocol": "HTTP",
                "port": 80,
                "allowedRoutes": allowed_routes,
            }
        )
        if tls_ready:
            listeners.append(
                {
                    "name": https_name,
                    "hostname": f"*.{system['domain']}",
                    "protocol": "HTTPS",
                    "port": 443,
                    "tls": {
                        "mode": "Terminate",
                        "certificateRefs": [
                            {"group": "", "kind": "Secret", "name": system["wildcardTlsSecret"]}
                        ],
                    },
                    "allowedRoutes": allowed_routes,
                }
            )
        route_listener = https_name if tls_ready else http_name
        documents.append(
            {
                "apiVersion": "gateway.networking.k8s.io/v1",
                "kind": "HTTPRoute",
                "metadata": {
                    "name": "sso",
                    "namespace": system["workloadNamespace"],
                },
                "spec": {
                    "parentRefs": [
                        {
                            "group": "gateway.networking.k8s.io",
                            "kind": "Gateway",
                            "namespace": gateway_doc["metadata"]["namespace"],
                            "name": gateway_doc["metadata"]["name"],
                            "sectionName": route_listener,
                        }
                    ],
                    "hostnames": [f"sso.{system['domain']}"],
                    "rules": [
                        {
                            "matches": [{"path": {"type": "PathPrefix", "value": "/"}}],
                            "backendRefs": [
                                {
                                    "group": "",
                                    "kind": "Service",
                                    "name": "keycloak",
                                    "port": 8080,
                                }
                            ],
                        }
                    ],
                },
            }
        )
    return "---\n".join(
        yaml.safe_dump(document, allow_unicode=True, sort_keys=False) for document in documents
    )


def systems_of(specification: dict) -> list[dict]:
    systems = specification.get("systems") or []
    names = [str(item.get("name") or "") for item in systems]
    if len(names) != len(set(names)):
        raise ValueError("spec.systems contains duplicate names")
    domains = [str(item.get("domain") or "") for item in systems]
    if len(domains) != len(set(domains)):
        raise ValueError("spec.systems contains duplicate domains")
    base_domain = specification["baseDomain"]
    for item in systems:
        domain = str(item.get("domain") or "")
        if not domain.endswith(f".{base_domain}"):
            raise ValueError(f"spec.systems domain must be a subdomain of baseDomain: {domain}")
    return systems


def render_tls(specification: dict) -> str:
    inputs = tls_inputs(specification)
    gateway = specification["gateway"]
    base_domain = specification["baseDomain"]
    replacements = {
        "__ACCOUNT_KEY_SECRET__": inputs["accountKeySecret"],
        "__ACME_EMAIL__": inputs["email"],
        "__ACME_PRODUCTION_SERVER__": inputs["productionServer"],
        "__ACME_STAGING_SERVER__": inputs["stagingServer"],
        "__ACTIVE_ISSUER_NAME__": inputs["activeIssuerName"],
        "__ACTIVE_CERTIFICATE_NAME__": (
            gateway["wildcardTlsSecret"]
            if inputs["mode"] == "production"
            else f"{gateway['wildcardTlsSecret']}-staging"
        ),
        "__ACTIVE_TLS_SECRET__": (
            gateway["wildcardTlsSecret"]
            if inputs["mode"] == "production"
            else f"{gateway['wildcardTlsSecret']}-staging"
        ),
        "__BASE_DOMAIN__": base_domain,
        "__CREDENTIAL_SECRET_NAME__": inputs["credentialSecretName"],
        # solver selector 는 인증서에 적힌 이름으로 매칭된다. 위임 모드여도 요청 도메인은
        # 여전히 baseDomain 이므로 dnsZones 에 위임 zone 을 적으면 solver 가 선택되지 않는다.
        # (cert-manager DNS01 문서: selector 는 원래 도메인, 자격증명만 위임 zone 쪽)
        "__DNS_ZONE__": base_domain,
        "__GATEWAY_NAMESPACE__": gateway["namespace"],
        "__ISSUER_NAME__": inputs["issuerName"],
        "__SOLVER_BLOCK__": inputs["solverBlock"],
    }
    rendered = substitute(TLS_TEMPLATE.read_text(encoding="utf-8"), replacements)
    systems = specification.get("systems") or []
    if systems:
        # ClusterIssuer 의 solver selector 는 dnsZones=baseDomain 이고 시스템 도메인은 그
        # 서브도메인이므로 cert-manager 가 같은 issuer 로 그대로 매칭한다. 새 issuer가 필요
        # 없고 Certificate 문서만 시스템마다 추가한다.
        for system in systems_of(specification):
            active_name = (
                system["wildcardTlsSecret"]
                if inputs["mode"] == "production"
                else f"{system['wildcardTlsSecret']}-staging"
            )
            rendered += "---\n" + yaml.safe_dump(
                {
                    "apiVersion": "cert-manager.io/v1",
                    "kind": "Certificate",
                    "metadata": {"name": active_name, "namespace": gateway["namespace"]},
                    "spec": {
                        "secretName": active_name,
                        "commonName": f"*.{system['domain']}",
                        "dnsNames": [f"*.{system['domain']}", system["domain"]],
                        "issuerRef": {
                            "group": "cert-manager.io",
                            "kind": "ClusterIssuer",
                            "name": inputs["activeIssuerName"],
                        },
                        "privateKey": {
                            "algorithm": "RSA",
                            "size": 2048,
                            "encoding": "PKCS1",
                            "rotationPolicy": "Always",
                        },
                        "usages": ["digital signature", "key encipherment", "server auth"],
                        "revisionHistoryLimit": 3,
                    },
                },
                allow_unicode=True,
                sort_keys=False,
            )
    return rendered


def write_or_check(path: pathlib.Path, rendered: str, check: bool, label: str) -> tuple[int, str]:
    if check:
        current = path.read_text(encoding="utf-8") if path.exists() else ""
        if current != rendered:
            return 1, f"[FAIL] {path.relative_to(ROOT)} is not synchronized with the contract"
        return 0, f"[OK]   {label} contract and manifest synchronization confirmed"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(rendered, encoding="utf-8")
    return 0, f"[OK]   {path.relative_to(ROOT)} generated"


def handle(path: pathlib.Path, renderer, check: bool, label: str) -> tuple[int, list[str]]:
    try:
        rendered = renderer()
    except PendingInput as error:
        if path.exists():
            return 1, [
                f"[FAIL] {label} manifest is stale: {error}. "
                f"If the value is now known, fill it into contracts/platform-production.yaml and rerun "
                f"this script. If it is still genuinely pending, delete {path.relative_to(ROOT)}."
            ]
        return 0, [f"[WARN] {label} manifest generation skipped: {error}"]
    except (KeyError, ValueError) as error:
        return 1, [f"[FAIL] {label} manifest generation failed: {error}"]
    status, message = write_or_check(path, rendered, check, label)
    return status, [message]


def require_absent(path: pathlib.Path, label: str) -> tuple[int, list[str]]:
    if path.exists():
        return 1, [
            f"[FAIL] {label} manifest must not exist for spec.tls.source=provided: "
            f"delete {path.relative_to(ROOT)} so cert-manager cannot overwrite the provided Secret"
        ]
    return 0, [f"[OK]   {label} manifest intentionally absent (provided certificate mode)"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()

    try:
        specification = load_contract()
    except (KeyError, ValueError) as error:
        print(f"[FAIL] contract load failed: {error}", file=sys.stderr)
        return 1

    failed = 0
    messages: list[str] = []

    for legacy in LEGACY_OUTPUTS:
        if legacy.exists():
            failed = 1
            messages.append(
                f"[FAIL] stale generated file {legacy.relative_to(ROOT)}; "
                "delete it and use platform/exposure/resources.yaml"
            )

    try:
        source = tls_source(specification)
        if source == "acme":
            inputs = tls_inputs(specification)
            # staging은 운영 Gateway Secret과 분리된 probe Certificate만 만든다.
            # 신규 설치는 production Certificate를 선택한 뒤 HTTPS를 활성화한다.
            # 기존 제공 Secret에서 무중단 전환할 때만 명시적 보존 옵션을 허용한다.
            preserve_existing = specification["tls"].get(
                "stagingPreserveExistingGatewaySecret", False
            )
            if not isinstance(preserve_existing, bool):
                raise ValueError(
                    "spec.tls.stagingPreserveExistingGatewaySecret must be boolean"
                )
            if preserve_existing and inputs["mode"] != "staging":
                raise ValueError(
                    "spec.tls.stagingPreserveExistingGatewaySecret is only valid in staging"
                )
            tls_ready = inputs["mode"] == "production" or preserve_existing
        else:
            provided_inputs(specification)
            tls_ready = True
    except PendingInput:
        tls_ready = False
    except (KeyError, ValueError) as error:
        # 계약 자체가 잘못된 경우다. 반쪽 산출물을 남기지 않도록 아무것도 쓰지 않고 멈춘다.
        print(f"[FAIL] D5 TLS contract is invalid: {error}", file=sys.stderr)
        return 1

    if source == "acme":
        status, lines = handle(
            TLS_OUTPUT, lambda: render_tls(specification), arguments.check, "D5 TLS"
        )
    else:
        status, lines = require_absent(TLS_OUTPUT, "D5 TLS")
    failed |= status
    messages += lines

    status, lines = handle(
        EXPOSURE_OUTPUT,
        lambda: render_exposure(specification, tls_ready),
        arguments.check,
        "exposure",
    )
    failed |= status
    messages += lines

    for message in messages:
        print(message, file=sys.stderr if message.startswith("[FAIL]") else sys.stdout)
    return failed


if __name__ == "__main__":
    raise SystemExit(main())
