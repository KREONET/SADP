#!/usr/bin/env python3
"""설치·검수·빌드가 계약의 동일한 1+N 노드 경계를 사용하게 한다."""
from __future__ import annotations

import argparse
import ipaddress
import json
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
SERVER_LABELS = ("node-role.kubernetes.io/control-plane", "node-role.kubernetes.io/master")


def expected_nodes(contract: dict) -> int:
    # 별도 workerCount를 저장하면 네트워크 노드 목록과 어긋날 수 있어 기존 SSOT에서 센다.
    addresses = contract["spec"]["network"].get("nodeAddresses")
    if not isinstance(addresses, list) or not addresses:
        raise ValueError("계약 network.nodeAddresses에 server 1대와 worker N대 주소가 필요함")
    normalized = [str(ipaddress.IPv4Address(item)) for item in addresses]
    if len(set(normalized)) != len(normalized):
        raise ValueError("계약 nodeAddresses 중복")
    return len(normalized)


def is_server(node: dict) -> bool:
    labels = node.get("metadata", {}).get("labels", {})
    return any(key in labels for key in SERVER_LABELS)


def ready(node: dict) -> bool:
    return any(c.get("type") == "Ready" and c.get("status") == "True"
               for c in node.get("status", {}).get("conditions", []))


def schedulable(node: dict) -> bool:
    spec = node.get("spec", {})
    return not spec.get("unschedulable", False) and not any(
        t.get("effect") in {"NoSchedule", "NoExecute"} for t in spec.get("taints", [])
    )


def validate_nodes(nodes: list[dict], expected: int, *, allow_not_ready: bool = False,
                   allow_unschedulable: bool = False) -> None:
    if len(nodes) != expected:
        raise ValueError(f"RKE2 노드 수가 계약과 다름: expected={expected}, actual={len(nodes)}")
    servers = sum(is_server(node) for node in nodes)
    if servers != 1:
        raise ValueError(f"RKE2 역할은 server 1대 + worker {expected - 1}대여야 함: "
                         f"server={servers}, worker={len(nodes) - servers}")
    if not allow_not_ready and not all(ready(node) for node in nodes):
        raise ValueError("Ready가 아닌 RKE2 노드가 있음")
    if expected == 1 and not allow_unschedulable and not schedulable(nodes[0]):
        raise ValueError("single 노드는 앱 배치가 가능해야 함: cordon/NoSchedule/NoExecute taint를 확인하라")


def memory_bytes(value: str) -> float:
    # kubectl 출력의 Ki 외에도 Kubernetes quantity 단위를 동일하게 비교한다.
    import re
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(Ki|Mi|Gi|Ti|Pi|Ei|K|M|G|T|P|E|m)?", value)
    if not match:
        raise ValueError("빌드 노드 allocatable.memory 형식 오류")
    suffix = match[2] or ""
    units = {"": 1, "m": 0.001}
    units.update({s: 1000 ** i for i, s in enumerate("KMGTPE", 1)})
    units.update({s + "i": 1024 ** i for i, s in enumerate("KMGTPE", 1)})
    return float(match[1]) * units[suffix]


def select_builder(nodes: list[dict], expected: int, name: str = "") -> str:
    validate_nodes(nodes, expected, allow_not_ready=True)
    candidates = [node for node in nodes if (expected == 1 or not is_server(node))
                  and ready(node) and schedulable(node)
                  and node.get("metadata", {}).get("labels", {}).get("kubernetes.io/os", "linux") == "linux"
                  and (not name or node["metadata"]["name"] == name)]
    if not candidates:
        raise ValueError("빌드를 돌릴 Ready·스케줄 가능 노드가 없음(single은 server, multi는 worker)")
    return max(candidates, key=lambda n: memory_bytes(n.get("status", {}).get("allocatable", {}).get("memory", "0")))["metadata"]["name"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=pathlib.Path, default=ROOT / "contracts/platform-production.yaml")
    parser.add_argument("--contract-only", action="store_true")
    parser.add_argument("--select-builder", action="store_true")
    parser.add_argument("--build-node", default="")
    parser.add_argument("--allow-not-ready", action="store_true")
    parser.add_argument("--allow-unschedulable", action="store_true")
    args = parser.parse_args()
    try:
        expected = expected_nodes(yaml.safe_load(args.contract.read_text(encoding="utf-8")))
        if args.contract_only:
            return 0
        nodes = json.load(sys.stdin)["items"]
        if args.select_builder:
            print(select_builder(nodes, expected, args.build_node))
        else:
            validate_nodes(nodes, expected, allow_not_ready=args.allow_not_ready,
                           allow_unschedulable=args.allow_unschedulable)
            state = "역할 일치" if args.allow_not_ready else "Ready"
            print(f"[OK]   RKE2 노드 {expected}/{expected} {state}(server 1 + worker {expected - 1})")
        return 0
    except (ValueError, KeyError, TypeError, OSError, yaml.YAMLError) as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
