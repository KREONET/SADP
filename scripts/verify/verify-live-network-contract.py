#!/usr/bin/env python3
"""표준 입력의 Node 네트워크 상태가 저장소 계약과 일치하는지 검증한다."""

from __future__ import annotations

import ipaddress
import json
import pathlib
import sys

import yaml


def fail(message: str) -> None:
    raise SystemExit(f"[FAIL] {message}")


def parse_networks(values: object, where: str) -> list[ipaddress.IPv4Network]:
    result: list[ipaddress.IPv4Network] = []
    for value in values or []:
        try:
            network = ipaddress.ip_network(str(value), strict=True)
        except ValueError:
            fail(f"{where}에 잘못된 CIDR이 있음")
        if not isinstance(network, ipaddress.IPv4Network):
            fail(f"{where}는 IPv4 CIDR만 허용")
        result.append(network)
    if not result:
        fail(f"{where}가 비어 있음")
    return result


def main() -> None:
    if len(sys.argv) != 4:
        fail(
            "usage: verify-live-network-contract.py "
            "<contract> <kubernetes-service-ip> <cluster-dns-service-ip>"
        )

    contract_path = pathlib.Path(sys.argv[1])
    contract = yaml.safe_load(contract_path.read_text(encoding="utf-8")) or {}
    network = ((contract.get("spec") or {}).get("network") or {})
    contract_pods = parse_networks(network.get("podCIDRs"), "network.podCIDRs")
    contract_services = parse_networks(
        network.get("serviceCIDRs"), "network.serviceCIDRs"
    )
    squid_clients = parse_networks(
        (network.get("squid") or {}).get("clientCIDRs"),
        "network.squid.clientCIDRs",
    )
    try:
        kubernetes_service_ip = ipaddress.ip_address(sys.argv[2])
        cluster_dns_service_ip = ipaddress.ip_address(sys.argv[3])
        expected_cluster_dns = ipaddress.ip_address(str(network.get("clusterDNS") or ""))
    except ValueError:
        fail("클러스터 Service IP 또는 계약 clusterDNS가 잘못됨")
    if not all(
        isinstance(item, ipaddress.IPv4Address)
        for item in (
            kubernetes_service_ip,
            cluster_dns_service_ip,
            expected_cluster_dns,
        )
    ):
        fail("클러스터 Service IP는 IPv4여야 함")
    if not any(kubernetes_service_ip in subnet for subnet in contract_services):
        fail("실제 Kubernetes Service IP가 계약 network.serviceCIDRs 밖에 있음")
    if cluster_dns_service_ip != expected_cluster_dns:
        fail("실제 CoreDNS Service IP가 계약 network.clusterDNS와 다름")

    try:
        nodes = json.load(sys.stdin)
    except (ValueError, TypeError):
        fail("kubectl Node JSON을 읽지 못함")

    actual_pods: list[ipaddress.IPv4Network] = []
    for node in nodes.get("items") or []:
        spec = node.get("spec") or {}
        raw_cidrs = spec.get("podCIDRs") or []
        if not raw_cidrs and spec.get("podCIDR"):
            raw_cidrs = [spec["podCIDR"]]
        actual_pods.extend(parse_networks(raw_cidrs, "Node spec.podCIDRs"))

    if not actual_pods:
        fail("Node에 할당된 Pod CIDR이 없음")

    # 노드별 /24는 계약의 클러스터 /16 안에 있어야 한다. 이 검사가 없으면 RKE2가 이미
    # 다른 CIDR로 설치된 뒤에도 렌더와 Squid 검증이 모두 통과해 Pod만 403을 받는다.
    if any(
        not any(actual.subnet_of(expected) for expected in contract_pods)
        for actual in actual_pods
    ):
        fail("실제 Node Pod CIDR이 계약 network.podCIDRs 밖에 있음")
    if any(
        not any(actual.subnet_of(client) for client in squid_clients)
        for actual in actual_pods
    ):
        fail("실제 Node Pod CIDR이 Squid clientCIDRs에서 빠짐")


if __name__ == "__main__":
    main()
