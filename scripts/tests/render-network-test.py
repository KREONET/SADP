#!/usr/bin/env python3
"""Regression tests for the environment-contract network renderer."""

from __future__ import annotations

import ipaddress
import pathlib
import shutil
import subprocess
import sys
import tempfile

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
PASSED = 0
FAILED = 0


def contract(root: pathlib.Path) -> dict:
    """Read the workspace contract so expectations follow the site, not this testbed."""
    return yaml.safe_load(
        (root / "contracts/platform-production.yaml").read_text(encoding="utf-8")
    )["spec"]


def free_node_address(spec: dict) -> str:
    """Pick a node-CIDR address that no contract role already claims."""
    network = spec["network"]
    taken = {
        *(str(item) for item in network.get("nodeAddresses") or []),
        *(str(item) for item in network.get("kubernetesAPIAddresses") or []),
        str(network["squid"]["internalIP"]),
        str(spec["gateway"]["vip"]),
    }
    pool = str(spec["gateway"].get("addressPoolRange") or "")
    if "-" in pool:
        start, _, end = pool.partition("-")
        start_ip = ipaddress.ip_address(start.strip())
        end_ip = ipaddress.ip_address(end.strip())
    else:
        start_ip = end_ip = None
    for candidate in ipaddress.ip_network(network["nodeInternalCIDRs"][0]).hosts():
        if str(candidate) in taken:
            continue
        if start_ip is not None and start_ip <= candidate <= end_ip:
            continue
        return str(candidate)
    raise RuntimeError("nodeInternalCIDRs에 사용 가능한 주소가 없다")


def workspace() -> pathlib.Path:
    root = pathlib.Path(tempfile.mkdtemp(prefix="render-network-test-"))
    for relative in (
        "contracts/platform-production.yaml",
        "scripts/site/render-network.py",
        "versions.lock.yaml",
    ):
        source = ROOT / relative
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    return root


def mutate(root: pathlib.Path, callback) -> None:
    path = root / "contracts/platform-production.yaml"
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    callback(document["spec"])
    path.write_text(
        yaml.safe_dump(document, allow_unicode=True, sort_keys=False),
        encoding="utf-8",
    )


def run(root: pathlib.Path, *arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "scripts/site/render-network.py", *arguments],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )


def case(label: str, callback, expect_success: bool, verify=None, arguments=()) -> None:
    global PASSED, FAILED
    root = workspace()
    try:
        if callback:
            mutate(root, callback)
        result = run(root, *arguments)
        detail = ""
        if (result.returncode == 0) != expect_success:
            detail = f"exit={result.returncode}, expected_success={expect_success}"
        elif verify:
            detail = verify(root) or ""
        if detail:
            FAILED += 1
            print(f"[FAIL] {label}: {detail}")
            if result.stderr.strip():
                print("       " + result.stderr.strip().replace("\n", "\n       "))
        else:
            PASSED += 1
            print(f"[OK]   {label}")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def default_outputs(root: pathlib.Path) -> str:
    squid = (root / "platform/network/squid/squid.conf").read_text(encoding="utf-8")
    if "acme-v02.api.letsencrypt.org" not in squid:
        return "ACME allowlist 누락"
    if "registry.npmjs.org" not in squid:
        return "package allowlist 누락"
    if "idp_domains" in squid:
        return "IdP 미설정 계약에 IdP ACL이 생성됨"
    if "idp_domains !CONNECT" in squid:
        return "IdP 평문 HTTP가 허용됨"
    if "ssl_bump" in "\n".join(
        line for line in squid.splitlines() if not line.lstrip().startswith("#")
    ):
        return "ssl_bump가 활성화됨"
    nms = (root / "platform/network/nms-egress.env").read_text(encoding="utf-8")
    if "NMS_MODE=disabled" not in nms:
        return "미확정 NMS가 활성화됨"
    policies = list(
        yaml.safe_load_all(
            (root / "platform/network/egress-policies.yaml").read_text(encoding="utf-8")
        )
    )
    names = {item["metadata"]["name"] for item in policies if item}
    if names != {"cert-manager-controller-egress", "default-deny-egress"}:
        return f"egress policy 집합 불일치: {names}"
    application = yaml.safe_load(
        (root / "argocd/applications/cert-manager.yaml").read_text(encoding="utf-8")
    )
    values = application["spec"]["source"]["helm"]["valuesObject"]
    env = {item["name"]: item["value"] for item in values["extraEnv"]}
    spec = contract(root)
    squid = spec["network"]["squid"]
    expected_proxy = f'http://{squid["internalIP"]}:{squid["port"]}'
    if env.get("HTTP_PROXY") != expected_proxy:
        return "cert-manager controller proxy 불일치"
    if ".cluster.local" not in env.get("NO_PROXY", ""):
        return "cert-manager NO_PROXY 내부 서비스 누락"
    expected_args = [
        "--dns01-recursive-nameservers="
        + ",".join(str(item) for item in spec["tls"]["recursiveNameservers"]),
        "--dns01-recursive-nameservers-only",
    ]
    if values["extraArgs"] != expected_args:
        return "cert-manager recursive DNS 인자 불일치"
    patch = yaml.safe_load(
        (root / "platform/keycloak/proxy-patch.yaml").read_text(encoding="utf-8")
    )
    containers = patch["spec"]["template"]["spec"]["containers"]
    if [item["name"] for item in containers] != ["keycloak"]:
        return "Keycloak proxy patch 대상 컨테이너 불일치"
    kc_env = {item["name"]: item["value"] for item in containers[0]["env"]}
    if kc_env.get("HTTPS_PROXY") != expected_proxy:
        return "Keycloak proxy 불일치"
    if ".cluster.local" not in kc_env.get("NO_PROXY", ""):
        return "Keycloak NO_PROXY 내부 서비스 누락"
    return ""


def enable_network_nms(spec: dict) -> None:
    spec["network"]["interfaces"]["nms"] = "nms0"
    spec["network"]["nms"].update(
        {
            "mode": "network",
            "allowedApps": ["portal-lite"],
            "destinationCIDR": "192.0.2.0/24",
            "port": 8443,
            "gatewayInternalIP": free_node_address(spec),
            "interface": "nms0",
            "gatewayIP": "172.20.0.10",
            "nextHop": "172.20.0.1",
            "internalDomain": "nms.internal",
            "dnsServers": ["172.20.0.53:53"],
        }
    )


def enable_identity_provider(spec: dict) -> None:
    spec["network"]["squid"]["identityProviderDomains"] = [
        ".idp.example.org",
        "metadata.example.org",
    ]


def identity_provider_outputs(root: pathlib.Path) -> str:
    squid = (root / "platform/network/squid/squid.conf").read_text(encoding="utf-8")
    if "acl idp_domains dstdomain .idp.example.org metadata.example.org" not in squid:
        return "IdP allowlist 누락"
    if "allow sadp_clients CONNECT idp_domains SSL_ports" not in squid:
        return "IdP CONNECT 허용 규칙 누락"
    if "idp_domains !CONNECT" in squid:
        return "IdP 평문 HTTP가 허용됨"
    return ""


def enabled_outputs(root: pathlib.Path) -> str:
    squid = (root / "platform/network/squid/squid.conf").read_text(encoding="utf-8")
    if "dns_provider_domains" in squid:
        return "RFC2136 전용 구성에 DNS provider Squid ACL이 생성됨"
    nms = (root / "platform/network/nms-egress.env").read_text(encoding="utf-8")
    for required in (
        "NMS_MODE=network",
        "NMS_DESTINATION_CIDR=192.0.2.0/24",
        "NMS_PORT=8443",
        "NMS_INTERFACE=nms0",
    ):
        if required not in nms:
            return f"NMS env 누락: {required}"
    coredns = (root / "platform/dns/rke2-coredns-config.yaml").read_text(
        encoding="utf-8"
    )
    if "nms.internal" not in coredns or "172.20.0.53:53" not in coredns:
        return "CoreDNS NMS 조건부 forward 누락"
    return ""


def enable_api_nms(spec: dict) -> None:
    spec["network"]["interfaces"]["nms"] = ""
    spec["network"]["nms"].update(
        {
            "mode": "api",
            "allowedApps": ["portal-lite"],
            "destinationCIDR": "192.0.2.0/24",
            "port": 8443,
            "gatewayInternalIP": "",
            "interface": "",
            "gatewayIP": "",
            "nextHop": "",
            "internalDomain": "",
            "dnsServers": [],
            "apiBaseURL": "https://192.0.2.20:8443",
        }
    )


def api_outputs(root: pathlib.Path) -> str:
    nms = (root / "platform/network/nms-egress.env").read_text(encoding="utf-8")
    for required in (
        "NMS_MODE=api",
        "NMS_DESTINATION_CIDR=192.0.2.0/24",
        "NMS_PORT=8443",
        "NMS_API_BASE_URL=https://192.0.2.20:8443",
    ):
        if required not in nms:
            return f"NMS API env 누락: {required}"
    if "NMS_INTERFACE=nms0" in nms:
        return "API 모드가 전용 NMS interface를 렌더함"
    return ""


def enable_rfc2136(spec: dict) -> None:
    spec["tls"]["source"] = "acme"
    spec["tls"]["solver"]["provider"] = "rfc2136"
    spec["tls"]["solver"]["rfc2136"].update(
        {
            "nameserver": "192.0.2.53:5353",
            "tsigKeyName": "acme-key.example.com.",
            "tsigAlgorithm": "HMACSHA256",
        }
    )


def rfc2136_outputs(root: pathlib.Path) -> str:
    policies = list(
        yaml.safe_load_all(
            (root / "platform/network/egress-policies.yaml").read_text(encoding="utf-8")
        )
    )
    controller = next(
        item
        for item in policies
        if item and item["metadata"]["name"] == "cert-manager-controller-egress"
    )
    matching = [
        rule
        for rule in controller["spec"]["egress"]
        if {peer.get("ipBlock", {}).get("cidr") for peer in rule.get("to", [])}
        == {"192.0.2.53/32"}
    ]
    if len(matching) != 1:
        return "RFC2136 목적지 전용 egress rule 누락"
    ports = {(item["protocol"], item["port"]) for item in matching[0]["ports"]}
    if ports != {("TCP", 5353), ("UDP", 5353)}:
        return f"RFC2136 포트 불일치: {ports}"
    application = yaml.safe_load(
        (root / "argocd/applications/cert-manager.yaml").read_text(encoding="utf-8")
    )
    no_proxy = {
        item["name"]: item["value"]
        for item in application["spec"]["source"]["helm"]["valuesObject"]["extraEnv"]
    }["NO_PROXY"]
    if "192.0.2.53" not in no_proxy:
        return "RFC2136 server missing from NO_PROXY"
    return ""


case("NW-01 기본 계약은 최소 egress 산출물을 생성", None, True, default_outputs)
case("NW-01a 선택한 IdP 도메인은 HTTPS 전용 ACL로 렌더", enable_identity_provider, True, identity_provider_outputs)
case("NW-02 전용 망/포트 NMS 값 렌더", enable_network_nms, True, enabled_outputs)
case(
    "NW-03 NMS default route 거부",
    lambda spec: (
        enable_network_nms(spec),
        spec["network"]["nms"].update({"destinationCIDR": "0.0.0.0/0"}),
    ),
    False,
)
case(
    "NW-04 부분 NMS 입력 거부",
    lambda spec: spec["network"]["nms"].update({"mode": "network"}),
    False,
)
case("NW-05 미생성 상태의 --check 실패", None, False, arguments=("--check",))
case("NW-06 RFC2136 DNS UPDATE 목적지만 허용", enable_rfc2136, True, rfc2136_outputs)
case("NW-07 NMS API 직접 연결 값 렌더", enable_api_nms, True, api_outputs)
case(
    "NW-08 API 모드에서 전용 gateway 필드 거부",
    lambda spec: (
        enable_api_nms(spec),
        spec["network"]["nms"].update({"gatewayIP": "192.0.2.10"}),
    ),
    False,
)

case(
    "NW-09 IdP 도메인과 package 도메인 중복 거부",
    lambda spec: spec["network"]["squid"]["identityProviderDomains"].append(
        spec["network"]["squid"]["packageDomains"][0]
    ),
    False,
)
case(
    "NW-10 빈 IdP 도메인 항목 거부",
    lambda spec: spec["network"]["squid"]["identityProviderDomains"].append("  "),
    False,
)


def cert_manager_values(root: pathlib.Path) -> dict:
    application = yaml.safe_load(
        (root / "argocd/applications/cert-manager.yaml").read_text(encoding="utf-8")
    )
    return application["spec"]["source"]["helm"]["valuesObject"]


def coredns_forward(root: pathlib.Path) -> str:
    document = yaml.safe_load(
        (root / "platform/dns/rke2-coredns-config.yaml").read_text(encoding="utf-8")
    )
    servers = yaml.safe_load(document["spec"]["valuesContent"])["servers"]
    for plugin in servers[0]["plugins"]:
        if plugin["name"] == "forward":
            return str(plugin["parameters"])
    return ""


def pinned_to_control_plane(root: pathlib.Path) -> str:
    values = cert_manager_values(root)
    label = "node-role.kubernetes.io/control-plane"
    if (values.get("nodeSelector") or {}).get(label) != "true":
        return "controller가 control-plane에 고정되지 않았다"
    tolerations = values.get("tolerations") or []
    if not any(item.get("key") == label for item in tolerations):
        return "control-plane taint toleration 누락"
    return ""


def unpinned(root: pathlib.Path) -> str:
    values = cert_manager_values(root)
    if "nodeSelector" in values or "tolerations" in values:
        return "placement=any인데 스케줄링 제약이 렌더됨"
    return ""


case(
    "NW-11 certManagerPlacement=control-plane 이 controller 를 고정",
    lambda spec: spec["tls"].update({"certManagerPlacement": "control-plane"}),
    True,
    pinned_to_control_plane,
)
case(
    "NW-12 certManagerPlacement=any 는 스케줄링을 건드리지 않는다",
    lambda spec: spec["tls"].update({"certManagerPlacement": "any"}),
    True,
    unpinned,
)
case(
    "NW-13 알 수 없는 certManagerPlacement 거부",
    lambda spec: spec["tls"].update({"certManagerPlacement": "worker"}),
    False,
)
case(
    "NW-14 clusterUpstreamDNS 가 CoreDNS forward 대상이 된다",
    lambda spec: spec["network"].update({"clusterUpstreamDNS": "10.0.10.11:53"}),
    True,
    lambda root: (
        ""
        if coredns_forward(root) == ". 10.0.10.11:53"
        else f"forward 대상 불일치: {coredns_forward(root)}"
    ),
)
case(
    "NW-15 clusterUpstreamDNS 가 비면 노드 resolv.conf 를 쓴다",
    lambda spec: spec["network"].update({"clusterUpstreamDNS": ""}),
    True,
    lambda root: (
        ""
        if coredns_forward(root) == ". /etc/resolv.conf"
        else f"기본 forward 대상 불일치: {coredns_forward(root)}"
    ),
)
case(
    "NW-16 port 없는 clusterUpstreamDNS 거부",
    lambda spec: spec["network"].update({"clusterUpstreamDNS": "10.0.10.11"}),
    False,
)
case(
    "NW-17 Squid clientCIDRs 에 Pod CIDR이 빠지면 거부",
    lambda spec: spec["network"]["squid"].update(
        {"clientCIDRs": list(spec["network"]["nodeInternalCIDRs"])}
    ),
    False,
)
case(
    "NW-18 Squid clientCIDRs 에 Node CIDR이 빠지면 거부",
    lambda spec: spec["network"]["squid"].update(
        {"clientCIDRs": list(spec["network"]["podCIDRs"])}
    ),
    False,
)

print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(FAILED != 0)
