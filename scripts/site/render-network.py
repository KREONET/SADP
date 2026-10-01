#!/usr/bin/env python3
"""Render Squid, cert-manager egress and CoreDNS inputs from the platform contract."""

from __future__ import annotations

import argparse
import ipaddress
import pathlib
import re
import shlex
import sys

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT = ROOT / "contracts" / "platform-production.yaml"
OUTPUTS = {
    "squid": ROOT / "platform" / "network" / "squid" / "squid.conf",
    "provider_domains": ROOT / "platform" / "network" / "squid" / "dns-provider-domains.txt",
    "proxy_env": ROOT / "platform" / "network" / "proxy.env",
    "openbao_proxy": ROOT / "platform" / "openbao" / "proxy-values.yaml",
    "firewall_env": ROOT / "platform" / "network" / "firewall.env",
    "policies": ROOT / "platform" / "network" / "egress-policies.yaml",
    "coredns": ROOT / "platform" / "dns" / "rke2-coredns-config.yaml",
    "cert_manager_application": ROOT / "argocd" / "applications" / "cert-manager.yaml",
    # relay를 끈 계약에서는 만들지 않고, 남아 있으면 지운다(--check는 잔존을 실패로 본다).
    "idp_relay": ROOT / "platform" / "network" / "idp-relay" / "haproxy.cfg",
}
DOMAIN = re.compile(r"^\.?[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?$")
INTERFACE = re.compile(r"^[A-Za-z0-9_.:-]+$")
KUBE_NAME = re.compile(r"^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$")
CERT_MANAGER_PLACEMENTS = {"any", "control-plane"}
CONTROL_PLANE_LABEL = "node-role.kubernetes.io/control-plane"


def load() -> dict:
    document = yaml.safe_load(CONTRACT.read_text(encoding="utf-8"))
    return document["spec"]


def address(value: object, where: str) -> ipaddress.IPv4Address:
    try:
        parsed = ipaddress.ip_address(str(value or ""))
    except ValueError as error:
        raise ValueError(f"{where} must be IPv4") from error
    if not isinstance(parsed, ipaddress.IPv4Address):
        raise ValueError(f"{where} must be IPv4")
    return parsed


def network(value: object, where: str) -> ipaddress.IPv4Network:
    try:
        parsed = ipaddress.ip_network(str(value or ""), strict=True)
    except ValueError as error:
        raise ValueError(f"{where} must be IPv4 CIDR") from error
    if not isinstance(parsed, ipaddress.IPv4Network):
        raise ValueError(f"{where} must be IPv4 CIDR")
    return parsed


def valid_port(value: object, where: str) -> int:
    parsed = int(value or 0)
    if not 1 <= parsed <= 65535:
        raise ValueError(f"{where} must be in 1..65535")
    return parsed


def domains(values: object, where: str) -> list[str]:
    result = []
    for raw in values or []:
        value = str(raw).strip().lower()
        if not DOMAIN.fullmatch(value) or "://" in value or "/" in value:
            raise ValueError(f"{where} contains invalid hostname: {value!r}")
        result.append(value)
    if len(result) != len(set(result)):
        raise ValueError(f"{where} contains duplicate hostnames")
    return result


def settings(spec: dict) -> dict:
    net = spec.get("network") or {}
    squid = net.get("squid") or {}
    pod_cidrs = [network(item, "network.podCIDRs") for item in net.get("podCIDRs") or []]
    service_cidrs = [
        network(item, "network.serviceCIDRs") for item in net.get("serviceCIDRs") or []
    ]
    node_cidrs = [
        network(item, "network.nodeInternalCIDRs")
        for item in net.get("nodeInternalCIDRs") or []
    ]
    if not pod_cidrs or not service_cidrs or not node_cidrs:
        raise ValueError("network pod/service/node CIDR lists must not be empty")

    upstream_dns = str(net.get("clusterUpstreamDNS") or "").strip()
    if upstream_dns:
        host, separator, raw_port = upstream_dns.rpartition(":")
        if not separator:
            raise ValueError("network.clusterUpstreamDNS must be <IPv4>:<port>")
        address(host, "network.clusterUpstreamDNS")
        valid_port(raw_port, "network.clusterUpstreamDNS")
    cluster_dns = address(net.get("clusterDNS"), "network.clusterDNS")
    if not any(cluster_dns in item for item in service_cidrs):
        raise ValueError("network.clusterDNS must be inside a service CIDR")

    squid_ip = address(squid.get("internalIP"), "network.squid.internalIP")
    if not any(squid_ip in item for item in node_cidrs):
        raise ValueError("network.squid.internalIP must be inside a node internal CIDR")

    api_addresses = [
        address(item, "network.kubernetesAPIAddresses")
        for item in net.get("kubernetesAPIAddresses") or []
    ]
    if not api_addresses:
        raise ValueError("network.kubernetesAPIAddresses must not be empty")

    client_cidrs = [
        network(item, "network.squid.clientCIDRs") for item in squid.get("clientCIDRs") or []
    ]
    if not client_cidrs:
        raise ValueError("network.squid.clientCIDRs must not be empty")
    # site.env 없이 계약을 직접 관리하는 사이트도 같은 fail-closed 검증을 받아야 한다.
    # 노드 curl 이 성공해도 Pod CIDR 이 빠지면 cert-manager CONNECT 는 403 으로 거부된다.
    for source_name, source_networks in (
        ("network.nodeInternalCIDRs", node_cidrs),
        ("network.podCIDRs", pod_cidrs),
    ):
        for source_network in source_networks:
            if not any(source_network.subnet_of(client) for client in client_cidrs):
                raise ValueError(
                    "network.squid.clientCIDRs must cover every " + source_name + " entry"
                )

    interfaces = net.get("interfaces") or {}
    if not isinstance(interfaces.get("workersInternalOnly", False), bool):
        raise ValueError("network.interfaces.workersInternalOnly must be boolean")
    internal_interface = str(interfaces.get("internal") or "").strip()
    external_interface = str(interfaces.get("external") or "").strip()
    if not internal_interface or not INTERFACE.fullmatch(internal_interface):
        raise ValueError("network.interfaces.internal is invalid")
    if external_interface and not INTERFACE.fullmatch(external_interface):
        raise ValueError("network.interfaces.external is invalid")
    populated_interfaces = [item for item in (internal_interface, external_interface) if item]
    if len(populated_interfaces) != len(set(populated_interfaces)):
        raise ValueError("network internal/external interfaces must be distinct")

    # 계약상 역할이 없더라도 공인 주소를 받을 수 있는 NIC은 관리 포트를 막아야 한다.
    # 그런 NIC이 계약에 없으면
    # guard 재설치(--apply 는 체인을 flush 한다) 때 조용히 보호가 빠진다.
    guarded_interfaces = [str(item).strip() for item in (interfaces.get("guarded") or [])]
    guarded_interfaces = [item for item in guarded_interfaces if item]
    for value in guarded_interfaces:
        if not INTERFACE.fullmatch(value):
            raise ValueError("network.interfaces.guarded contains an invalid name")
    if len(guarded_interfaces) != len(set(guarded_interfaces)):
        raise ValueError("network.interfaces.guarded must not repeat a name")
    # 내부망 NIC 을 막으면 etcd/apiserver/kubelet 이 끊겨 클러스터가 죽는다.
    if internal_interface in guarded_interfaces:
        raise ValueError("network.interfaces.guarded must not contain the internal interface")
    already_guarded = {external_interface} if external_interface else set()
    if already_guarded & set(guarded_interfaces):
        raise ValueError("network.interfaces.guarded must list only additional interfaces")

    allowed_ports = net.get("allowedPorts") or {}
    port_sets: dict[str, list[int]] = {}
    for key in ("internalTCP", "internalUDP", "externalTCP", "externalUDP"):
        parsed = [valid_port(item, f"network.allowedPorts.{key}") for item in allowed_ports.get(key) or []]
        if len(parsed) != len(set(parsed)):
            raise ValueError(f"network.allowedPorts.{key} contains duplicate ports")
        port_sets[key] = sorted(parsed)
    squid_port = valid_port(squid.get("port"), "network.squid.port")
    expected_internal_tcp = sorted({2379, 2380, squid_port, 6443, 9345, 10250})
    if port_sets["internalTCP"] != expected_internal_tcp:
        raise ValueError(
            "network.allowedPorts.internalTCP must be exactly "
            + ",".join(map(str, expected_internal_tcp))
        )
    if port_sets["internalUDP"] != [8472]:
        raise ValueError("network.allowedPorts.internalUDP must be exactly 8472 for Canal VXLAN")
    if port_sets["externalTCP"] != [80, 443] or port_sets["externalUDP"]:
        raise ValueError("network.allowedPorts external service ports must be TCP 80,443 only")

    deny_namespaces = [str(item).strip() for item in net.get("defaultDenyNamespaces") or []]
    if not deny_namespaces:
        raise ValueError("network.defaultDenyNamespaces must not be empty")
    if len(deny_namespaces) != len(set(deny_namespaces)):
        raise ValueError("network.defaultDenyNamespaces contains duplicates")
    if any(not KUBE_NAME.fullmatch(item) for item in deny_namespaces):
        raise ValueError("network.defaultDenyNamespaces contains an invalid namespace")

    package_domains = domains(squid.get("packageDomains"), "network.squid.packageDomains")
    if not package_domains:
        raise ValueError("network.squid.packageDomains must not be empty")

    idp_domains = domains(
        squid.get("identityProviderDomains"), "network.squid.identityProviderDomains"
    )
    overlap = sorted(set(idp_domains) & set(package_domains))
    if overlap:
        raise ValueError(
            "network.squid.identityProviderDomains overlaps packageDomains: "
            + ", ".join(overlap)
        )

    idp_relay = idp_relay_settings(net, idp_domains, node_cidrs, squid_ip)

    tls = spec.get("tls") or {}
    recursive_nameservers = [
        str(item).strip() for item in tls.get("recursiveNameservers") or []
    ]
    if not recursive_nameservers:
        raise ValueError("tls.recursiveNameservers must not be empty")
    for index, item in enumerate(recursive_nameservers):
        host, separator, raw_port = item.rpartition(":")
        if not separator:
            raise ValueError(
                f"tls.recursiveNameservers[{index}] must be <IPv4>:<port>"
            )
        address(host, f"tls.recursiveNameservers[{index}]")
        valid_port(raw_port, f"tls.recursiveNameservers[{index}]")

    cert_manager_placement = str(tls.get("certManagerPlacement") or "any").strip()
    if cert_manager_placement not in CERT_MANAGER_PLACEMENTS:
        raise ValueError("tls.certManagerPlacement must be any or control-plane")

    provider_domains = domains(
        squid.get("dnsProviderEndpoints"), "network.squid.dnsProviderEndpoints"
    )
    if provider_domains:
        raise ValueError(
            "network.squid.dnsProviderEndpoints must stay empty; "
            "RFC2136 DNS UPDATE does not use Squid"
        )
    solver = tls.get("solver") or {}
    provider = str(solver.get("provider") or "").strip()
    rfc2136_update = None
    if tls.get("source") == "acme" and provider == "rfc2136":
        nameserver = str((solver.get("rfc2136") or {}).get("nameserver") or "").strip()
        host, separator, raw_port = nameserver.rpartition(":")
        if not separator:
            raise ValueError("tls.solver.rfc2136.nameserver must be <IPv4>:<port>")
        rfc2136_update = {
            "address": address(host, "tls.solver.rfc2136.nameserver"),
            "port": valid_port(raw_port, "tls.solver.rfc2136.nameserver"),
        }
    elif tls.get("source") == "acme" and provider not in ("", "pending"):
        raise ValueError("tls.solver.provider must be rfc2136")

    return {
        "spec": spec,
        "pod_cidrs": pod_cidrs,
        "service_cidrs": service_cidrs,
        "node_cidrs": node_cidrs,
        "cluster_dns": cluster_dns,
        "upstream_dns": upstream_dns,
        "api_addresses": api_addresses,
        "squid_ip": squid_ip,
        "squid_port": squid_port,
        "client_cidrs": client_cidrs,
        "package_domains": package_domains,
        "idp_domains": idp_domains,
        "idp_relay": idp_relay,
        "provider_domains": provider_domains,
        "rfc2136_update": rfc2136_update,
        "recursive_nameservers": recursive_nameservers,
        "cert_manager_placement": cert_manager_placement,
        "interfaces": {
            "internal": internal_interface,
            "external": external_interface,
            "guarded": guarded_interfaces,
        },
        "allowed_ports": port_sets,
        "deny_namespaces": deny_namespaces,
    }


def idp_relay_settings(
    net: dict,
    idp_domains: list[str],
    node_cidrs: list[ipaddress.IPv4Network],
    squid_ip: ipaddress.IPv4Address,
) -> dict | None:
    """network.identityProviderRelay를 검증한다. 끄거나 없으면 None.

    Envoy Gateway controller/data plane은 HTTPS_PROXY를 쓰지 않아 외부 route 없는 worker에서
    IdP에 닿지 못한다. relay는 egress 호스트에서 SNI만 보고 TCP를 넘기며 TLS를 풀지 않는다.
    CoreDNS hosts는 정확한 호스트만 적을 수 있으므로 suffix(.example.org) 항목은 받지 않는다.
    """
    relay = net.get("identityProviderRelay") or {}
    enabled = relay.get("enabled", False)
    if not isinstance(enabled, bool):
        raise ValueError("network.identityProviderRelay.enabled must be boolean")
    if not enabled:
        return None
    relay_ip = address(relay.get("address"), "network.identityProviderRelay.address")
    if not any(relay_ip in item for item in node_cidrs):
        raise ValueError("network.identityProviderRelay.address must be inside a node internal CIDR")
    # 외부 route가 있는 곳은 Squid egress 호스트뿐이다. 다른 노드에 두면 relay도 IdP에 못 닿는다.
    if relay_ip != squid_ip:
        raise ValueError("network.identityProviderRelay.address must be the Squid egress host")
    relay_port = valid_port(relay.get("port"), "network.identityProviderRelay.port")
    if relay_port != 443:
        raise ValueError("network.identityProviderRelay.port must be 443 (clients dial the IdP host:443)")
    if not idp_domains:
        raise ValueError("network.identityProviderRelay needs network.squid.identityProviderDomains")
    wildcard = [item for item in idp_domains if item.startswith(".")]
    if wildcard:
        raise ValueError(
            "network.identityProviderRelay cannot relay suffix IdP domains: " + ", ".join(wildcard)
        )
    return {"address": relay_ip, "port": relay_port, "hosts": list(idp_domains)}


def render_idp_relay(cfg: dict) -> str:
    relay = cfg["idp_relay"]
    lines = [
        "# Generated by scripts/site/render-network.py. Do not edit.",
        "# 외부 IdP SNI relay. TLS를 종단하지 않고 ClientHello의 SNI가 계약 IdP 호스트와",
        "# 정확히 같을 때만 같은 호스트의 443으로 TCP를 넘긴다. 다른 SNI는 backend 없이 끊는다.",
        "# 내부 IP에만 bind해 공인 NIC으로 열린 relay가 되지 않게 한다.",
        "global",
        "    log /dev/log local0",
        "    chroot /var/lib/haproxy",
        "    maxconn 2048",
        "    user haproxy",
        "    group haproxy",
        "",
        # backend 이름 해석은 노드 resolver로 한다. CoreDNS hosts(relay IP)를 다시 보지 않아 loop가 없다.
        "resolvers sadp_node",
        "    parse-resolv-conf",
        "    resolve_retries 3",
        "    timeout resolve 1s",
        "    timeout retry 1s",
        "    hold valid 30s",
        "",
        "defaults",
        "    mode tcp",
        "    log global",
        "    option tcplog",
        "    timeout connect 5s",
        "    timeout client 60s",
        "    timeout server 60s",
        "",
        "frontend sadp_idp_relay",
        f"    bind {relay['address']}:{relay['port']}",
        # 관리망 밖 출발지가 relay를 범용 TLS 터널로 쓰지 못하게 Squid와 같은 출발지로 제한한다.
        "    acl sadp_clients src " + " ".join(str(item) for item in cfg["client_cidrs"]),
        "    tcp-request connection reject unless sadp_clients",
        "    tcp-request inspect-delay 5s",
        "    tcp-request content reject unless { req.ssl_hello_type 1 }",
        # 허용 SNI 밖은 backend 선택 전에 끊는다. 규칙은 조건부로만 두어 허용 SNI까지 막지 않는다.
        "    acl idp_sni req.ssl_sni -m str -i " + " ".join(relay["hosts"]),
        "    tcp-request content reject unless idp_sni",
    ]
    backends = []
    for index, host in enumerate(relay["hosts"]):
        name = f"idp_{index}"
        lines.append(f"    use_backend {name} if {{ req.ssl_sni -m str -i {host} }}")
        backends += [
            "",
            f"backend {name}",
            f"    server upstream {host}:443 resolvers sadp_node resolve-prefer ipv4 init-addr last,libc,none",
        ]
    return "\n".join(lines + backends) + "\n"


def render_squid(cfg: dict) -> str:
    source_acls = "\n".join(f"acl sadp_clients src {item}" for item in cfg["client_cidrs"])
    packages = " ".join(cfg["package_domains"])
    # 연합 IdP는 CONNECT 443만 허용한다. package_domains와 달리 평문 HTTP는 열지 않는다.
    idp_acl = ""
    idp_access = ""
    if cfg["idp_domains"]:
        idp_acl = "\nacl idp_domains dstdomain " + " ".join(cfg["idp_domains"])
        idp_access = "\nhttp_access allow sadp_clients CONNECT idp_domains SSL_ports"
    return f"""# Generated by scripts/site/render-network.py. Do not edit.
http_port {cfg["squid_ip"]}:{cfg["squid_port"]}
visible_hostname sadp-squid-egress

{source_acls}
acl CONNECT method CONNECT
acl SSL_ports port 443
acl Safe_ports port 80 443
acl acme_domains dstdomain acme-v02.api.letsencrypt.org acme-staging-v02.api.letsencrypt.org
acl package_domains dstdomain {packages}{idp_acl}
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow sadp_clients CONNECT acme_domains SSL_ports
http_access allow sadp_clients CONNECT package_domains SSL_ports{idp_access}
http_access allow sadp_clients package_domains !CONNECT
http_access deny all

# Explicit CONNECT tunneling only: ssl_bump is intentionally not configured.
cache deny all
forwarded_for delete
request_header_access X-Forwarded-For deny all
access_log stdio:/var/log/squid/access.log squid
cache_log /var/log/squid/cache.log
"""


def no_proxy(cfg: dict) -> str:
    values = ["localhost", "127.0.0.1", ".svc", ".cluster.local"]
    values.extend(
        str(item)
        for key in ("pod_cidrs", "service_cidrs", "node_cidrs")
        for item in cfg[key]
    )
    values.extend(str(item) for item in cfg["api_addresses"])
    if cfg["rfc2136_update"]:
        values.append(str(cfg["rfc2136_update"]["address"]))
    return ",".join(dict.fromkeys(values))


def render_openbao_proxy(cfg: dict) -> str:
    # BusyBox wget은 HTTPS CONNECT를 지원하지 않아 같은 Pod의 curl로 경로를 검증한다.
    lock = yaml.safe_load((ROOT / "versions.lock.yaml").read_text(encoding="utf-8"))
    proxy = f"http://{cfg['squid_ip']}:{cfg['squid_port']}"
    environment = {"HTTP_PROXY": proxy, "HTTPS_PROXY": proxy, "NO_PROXY": no_proxy(cfg)}
    resource = {"server": {
        "extraEnvironmentVars": environment,
        "extraContainers": [{
            "name": "oidc-preflight",
            "image": f"docker.io/curlimages/curl:{lock['platform']['oidcProbeCurl']}",
            "imagePullPolicy": "IfNotPresent",
            "command": ["sh", "-c", "exec sleep infinity"],
            "env": [{"name": key, "value": value} for key, value in environment.items()],
            "securityContext": {"runAsNonRoot": True, "runAsUser": 100,
                "allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                "capabilities": {"drop": ["ALL"]}},
            "resources": {"requests": {"cpu": "5m", "memory": "16Mi"},
                "limits": {"cpu": "100m", "memory": "64Mi"}},
        }],
    }}
    return "# Generated by scripts/site/render-network.py. Do not edit.\n" + yaml.safe_dump(resource, sort_keys=False)


def render_proxy_env(cfg: dict) -> str:
    proxy = f"http://{cfg['squid_ip']}:{cfg['squid_port']}"
    return "\n".join(
        [
            "# Generated by scripts/site/render-network.py. Source this file in an approved shell.",
            f"export HTTP_PROXY={shlex.quote(proxy)}",
            f"export HTTPS_PROXY={shlex.quote(proxy)}",
            f"export NO_PROXY={shlex.quote(no_proxy(cfg))}",
            'export http_proxy="$HTTP_PROXY"',
            'export https_proxy="$HTTPS_PROXY"',
            'export no_proxy="$NO_PROXY"',
            "",
        ]
    )


def render_firewall_env(cfg: dict) -> str:
    values = {
        "INTERNAL_INTERFACE": cfg["interfaces"]["internal"],
        "EXTERNAL_INTERFACE": cfg["interfaces"]["external"],
        "GUARDED_INTERFACES": ",".join(cfg["interfaces"]["guarded"]),
        "INTERNAL_ALLOWED_TCP_PORTS": ",".join(map(str, cfg["allowed_ports"]["internalTCP"])),
        "INTERNAL_ALLOWED_UDP_PORTS": ",".join(map(str, cfg["allowed_ports"]["internalUDP"])),
        "EXTERNAL_ALLOWED_TCP_PORTS": ",".join(map(str, cfg["allowed_ports"]["externalTCP"])),
        "EXTERNAL_ALLOWED_UDP_PORTS": "",
    }
    return (
        "# Generated by scripts/site/render-network.py. Contains no credentials.\n"
        + "\n".join(f"{key}={shlex.quote(value)}" for key, value in values.items())
        + "\n"
    )


def render_policies(cfg: dict) -> str:
    api_peers = [{"ipBlock": {"cidr": f"{item}/32"}} for item in cfg["api_addresses"]]
    controller_egress = [
        {
            "to": [
                {
                    "namespaceSelector": {
                        "matchLabels": {"kubernetes.io/metadata.name": "kube-system"}
                    },
                    "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}},
                }
            ],
            "ports": [
                {"protocol": "UDP", "port": 53},
                {"protocol": "TCP", "port": 53},
            ],
        },
        {
            "to": [{"ipBlock": {"cidr": f"{cfg['squid_ip']}/32"}}],
            "ports": [{"protocol": "TCP", "port": cfg["squid_port"]}],
        },
        {
            "to": api_peers,
            "ports": [
                {"protocol": "TCP", "port": 443},
                {"protocol": "TCP", "port": 6443},
            ],
        },
    ]
    if cfg["rfc2136_update"]:
        controller_egress.append(
            {
                "to": [
                    {
                        "ipBlock": {
                            "cidr": f"{cfg['rfc2136_update']['address']}/32"
                        }
                    }
                ],
                "ports": [
                    {"protocol": "UDP", "port": cfg["rfc2136_update"]["port"]},
                    {"protocol": "TCP", "port": cfg["rfc2136_update"]["port"]},
                ],
            }
        )
    documents = [
        {
            "apiVersion": "networking.k8s.io/v1",
            "kind": "NetworkPolicy",
            "metadata": {
                "name": "cert-manager-controller-egress",
                "namespace": "cert-manager",
            },
            "spec": {
                "podSelector": {
                    "matchLabels": {
                        "app.kubernetes.io/component": "controller",
                        "app.kubernetes.io/instance": "cert-manager",
                    }
                },
                "policyTypes": ["Egress"],
                "egress": controller_egress,
            },
        },
    ]
    documents.extend(
        {
            "apiVersion": "networking.k8s.io/v1",
            "kind": "NetworkPolicy",
            "metadata": {"name": "default-deny-egress", "namespace": namespace},
            "spec": {"podSelector": {}, "policyTypes": ["Egress"]},
        }
        for namespace in cfg["deny_namespaces"]
    )
    return "# Generated by scripts/site/render-network.py. Do not edit.\n" + "---\n".join(
        yaml.safe_dump(item, sort_keys=False) for item in documents
    )


def render_coredns(cfg: dict) -> str:
    servers = [
        {
            "zones": [{"zone": ".", "use_tcp": True}],
            "port": 53,
            "plugins": [
                {"name": "errors"},
                {"name": "health", "configBlock": "lameduck 10s\n"},
                {"name": "ready"},
                {
                    "name": "kubernetes",
                    "parameters": "in-addr.arpa ip6.arpa",
                    "configBlock": (
                        "pods insecure\n"
                        "fallthrough in-addr.arpa ip6.arpa\n"
                        "ttl 30\n"
                    ),
                },
                {"name": "prometheus", "parameters": "0.0.0.0:9153"},
                *(
                    [
                        {
                            # Envoy Gateway가 proxy 없이 IdP에 접속하므로 IdP 호스트만 egress
                            # 호스트의 SNI relay로 해석한다. 나머지 이름은 아래 forward로 넘긴다.
                            "name": "hosts",
                            "configBlock": "".join(
                                f"{cfg['idp_relay']['address']} {host}\n"
                                for host in cfg["idp_relay"]["hosts"]
                            )
                            + "ttl 30\nfallthrough\n",
                        }
                    ]
                    if cfg["idp_relay"]
                    else []
                ),
                {
                    "name": "forward",
                    # 노드 resolv.conf 를 그대로 쓰면 egress 없는 워커의 CoreDNS 가
                    # 닿지 못하는 resolver 를 물고 외부 이름이 전부 SERVFAIL 이 된다.
                    "parameters": (
                        f". {cfg['upstream_dns']}"
                        if cfg["upstream_dns"]
                        else ". /etc/resolv.conf"
                    ),
                },
                {"name": "cache", "parameters": "30"},
                {"name": "loop"},
                {"name": "reload"},
                {"name": "loadbalance"},
            ],
        }
    ]
    resource = {
        "apiVersion": "helm.cattle.io/v1",
        "kind": "HelmChartConfig",
        "metadata": {"name": "rke2-coredns", "namespace": "kube-system"},
        "spec": {
            "valuesContent": yaml.safe_dump({"servers": servers}, sort_keys=False)
        },
    }
    return (
        "# Generated by scripts/site/render-network.py. Do not edit.\n"
        + yaml.safe_dump(resource, sort_keys=False)
    )


def cert_manager_scheduling(cfg: dict) -> dict:
    """controller 만 고정한다.

    raw DNS UPDATE/self-check 를 내보내는 것은 controller 뿐이고 webhook 과 cainjector
    는 apiserver 하고만 말한다. 셋 다 묶으면 control-plane 한 대에 불필요하게 몰린다.
    Chart 최상위 nodeSelector/tolerations 가 controller 전용 key 다.
    """
    if cfg["cert_manager_placement"] != "control-plane":
        return {}
    return {
        "nodeSelector": {CONTROL_PLANE_LABEL: "true"},
        "tolerations": [
            {
                "key": CONTROL_PLANE_LABEL,
                "operator": "Exists",
                "effect": "NoSchedule",
            }
        ],
    }


def render_cert_manager_application(cfg: dict) -> str:
    version_document = yaml.safe_load(
        (ROOT / "versions.lock.yaml").read_text(encoding="utf-8")
    )
    version = str(version_document["platform"]["certManager"])
    proxy = f"http://{cfg['squid_ip']}:{cfg['squid_port']}"
    resource = {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "Application",
        "metadata": {
            "name": "cert-manager",
            "namespace": "devtroncd",
            "annotations": {"argocd.argoproj.io/sync-wave": "-20"},
        },
        "spec": {
            "project": "platform-system",
            "source": {
                "chart": "cert-manager",
                "repoURL": "https://charts.jetstack.io",
                "targetRevision": f"v{version}",
                "helm": {
                    "valuesObject": {
                        "crds": {"enabled": True, "keep": True},
                        "extraEnv": [
                            {"name": "HTTP_PROXY", "value": proxy},
                            {"name": "HTTPS_PROXY", "value": proxy},
                            {"name": "NO_PROXY", "value": no_proxy(cfg)},
                        ],
                        "extraArgs": [
                            "--dns01-recursive-nameservers="
                            + ",".join(cfg["recursive_nameservers"]),
                            "--dns01-recursive-nameservers-only",
                        ],
                        **cert_manager_scheduling(cfg),
                    }
                },
            },
            "destination": {
                "namespace": "cert-manager",
                "server": "https://kubernetes.default.svc",
            },
            "syncPolicy": {
                "automated": {"prune": False, "selfHeal": True},
                "syncOptions": [
                    "CreateNamespace=true",
                    "ServerSideApply=true",
                ],
                "retry": {
                    "limit": 10,
                    "backoff": {
                        "duration": "10s",
                        "factor": 2,
                        "maxDuration": "3m",
                    },
                },
            },
            "ignoreDifferences": [
                {
                    "group": "apps",
                    "kind": "Deployment",
                    "jqPathExpressions": [".status.terminatingReplicas"],
                },
                {
                    "group": "apps",
                    "kind": "ReplicaSet",
                    "jqPathExpressions": [".status.terminatingReplicas"],
                },
            ],
        },
    }
    return (
        "# Generated by scripts/site/render-network.py. Do not edit.\n"
        "# HTTP(S)_PROXY is applied only to the cert-manager controller.\n"
        + yaml.safe_dump(resource, sort_keys=False)
    )


def rendered(spec: dict) -> dict[pathlib.Path, str | None]:
    cfg = settings(spec)
    provider_file = (
        "# RFC2136 is direct DNS UPDATE; DNS API hostnames through Squid are forbidden.\n"
        + "\n".join(cfg["provider_domains"])
        + "\n"
    )
    return {
        OUTPUTS["squid"]: render_squid(cfg),
        OUTPUTS["provider_domains"]: provider_file,
        OUTPUTS["proxy_env"]: render_proxy_env(cfg),
        OUTPUTS["openbao_proxy"]: render_openbao_proxy(cfg),
        OUTPUTS["firewall_env"]: render_firewall_env(cfg),
        OUTPUTS["policies"]: render_policies(cfg),
        OUTPUTS["coredns"]: render_coredns(cfg),
        OUTPUTS["cert_manager_application"]: render_cert_manager_application(cfg),
        OUTPUTS["idp_relay"]: render_idp_relay(cfg) if cfg["idp_relay"] else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        outputs = rendered(load())
    except (KeyError, TypeError, ValueError) as error:
        print(f"[FAIL] network contract: {error}", file=sys.stderr)
        return 1
    failed = False
    for path, content in outputs.items():
        if content is None:
            # 기능을 끈 계약의 생성물이 남으면 설치기가 옛 relay 설정을 다시 올릴 수 있다.
            if args.check:
                if path.exists():
                    print(f"[FAIL] {path.relative_to(ROOT)} must not exist", file=sys.stderr)
                    failed = True
            elif path.exists():
                path.unlink()
                print(f"[OK]   {path.relative_to(ROOT)} removed")
            continue
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                print(
                    f"[FAIL] {path.relative_to(ROOT)} is not synchronized",
                    file=sys.stderr,
                )
                failed = True
            else:
                print(f"[OK]   {path.relative_to(ROOT)} synchronized")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
            print(f"[OK]   {path.relative_to(ROOT)} generated")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
